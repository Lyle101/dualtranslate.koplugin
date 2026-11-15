-- MCP external translation (design 10): the device exports a job with the
-- paragraphs to translate, the PC-side agent fills them in, and the result
-- comes back through the inbox.  This module owns the job/inbox files; the
-- data writes on import live in dualtranslate_store.lua so dtctl can reuse
-- them headless.
--
-- No UI dependencies: the Reader decides when to call in, and dtctl.lua runs
-- the same functions from a plain luajit process.

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local JSON = require("json")
local logger = require("logger")
local Tools = require("dualtranslate_tools")

local Mcp = {}

Mcp.JOB_SCHEMA = "dualtranslate.job.v1"
Mcp.RESULT_SCHEMA = "dualtranslate.result.v1"
Mcp.STATE_SCHEMA = "dualtranslate.state.v1"

local DEFAULT_STYLE_GUIDE = "保留段落结构，不添加解释，不合并段落。"

function Mcp.rootDir()
    return DataStorage:getDataDir() .. "/cache/dualtranslate/mcp"
end

function Mcp.jobsDir()
    return Mcp.rootDir() .. "/jobs"
end

function Mcp.inboxDir()
    return Mcp.rootDir() .. "/inbox"
end

-- Job ids name a directory, so they must never contain a separator, a dot or
-- an empty component.  The pattern is shared with dtctl's --job validation.
function Mcp.validJobId(job_id)
    return type(job_id) == "string" and job_id:match("^[0-9A-Za-z_%-]+$") ~= nil
end

function Mcp.jobDir(job_id)
    if not Mcp.validJobId(job_id) then return nil end
    return Mcp.jobsDir() .. "/" .. job_id
end

function Mcp.jobPath(job_id)
    local dir = Mcp.jobDir(job_id)
    return dir and (dir .. "/job.json") or nil
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

-- Atomic replacement (tmp + rename): a crash mid-write can never leave a
-- truncated job or state file behind.
local function write_file(path, data)
    local temporary = path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then return false end
    local written = file:write(data)
    local closed = file:close()
    if not written or not closed or not os.rename(temporary, path) then
        os.remove(temporary)
        return false
    end
    return true
end

function Mcp.readJson(path)
    local raw = read_file(path)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

function Mcp.writeJson(path, data)
    local ok, encoded = pcall(JSON.encode, data)
    if not ok or not encoded then return false end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and not Tools.mkdir_p(parent) then return false end
    return write_file(path, encoded)
end

-- <YYYYMMDD>_<HHMMSS>_<4 digits>: lexically sortable and instantly readable
-- in a log or an SSH listing.
function Mcp.newJobId(now)
    now = now or os.time()
    local stamp = os.date("%Y%m%d_%H%M%S", now)
    for _ = 1, 20 do
        local candidate = string.format("%s_%04d", stamp, math.random(0, 9999))
        if not lfs.attributes(Mcp.jobsDir() .. "/" .. candidate, "mode") then
            return candidate
        end
    end
    return nil, "无法生成唯一的任务编号"
end

function Mcp.loadJob(job_id)
    local path = Mcp.jobPath(job_id)
    if not path then return nil, "任务编号不合法" end
    local job = Mcp.readJson(path)
    if not job then return nil, "找不到任务文件" end
    if job.schema ~= Mcp.JOB_SCHEMA or type(job.segments) ~= "table" then
        return nil, "任务文件格式不正确"
    end
    return job
end

function Mcp.loadState(job_id)
    local dir = Mcp.jobDir(job_id)
    if not dir then return nil end
    return Mcp.readJson(dir .. "/state.json")
end

function Mcp.saveState(job_id, state)
    local dir = Mcp.jobDir(job_id)
    if not dir then return false end
    state.updated_at = os.time()
    return Mcp.writeJson(dir .. "/state.json", state)
end

-- Newest first.  Damaged job directories are skipped instead of aborting the
-- whole listing: one interrupted export must not hide every other job.
function Mcp.listJobs()
    local jobs = {}
    local ok, iterator, state = pcall(lfs.dir, Mcp.jobsDir())
    if not ok or not iterator then return jobs end
    for name in iterator, state do
        if Mcp.validJobId(name) then
            local job = Mcp.loadJob(name)
            if job then
                local job_state = Mcp.loadState(name) or {}
                jobs[#jobs + 1] = {
                    job_id = name,
                    created_at = tonumber(job.created_at) or 0,
                    book_path = job.book and job.book.device_path,
                    title = job.book and job.book.title,
                    chapter_count = #(job.chapters or {}),
                    total = #job.segments,
                    status = job_state.status or "exported",
                    provider_id = job_state.provider_id,
                    model_name = job_state.model_name,
                    submitted = tonumber(job_state.submitted) or 0,
                    updated_at = tonumber(job_state.updated_at) or 0,
                }
            end
        end
    end
    table.sort(jobs, function(a, b)
        if a.created_at ~= b.created_at then return a.created_at > b.created_at end
        return a.job_id > b.job_id
    end)
    return jobs
end

local function book_title_of(book_path)
    local name = book_path:match("([^/]+)$") or book_path
    return (name:gsub("%.[Ee][Pp][Uu][Bb]$", ""))
end

-- Design 10.2: the device writes job.json + state.json; segments carry the
-- selectors CREngine will match, so the PC never parses the EPUB itself.
function Mcp.exportJob(opts)
    opts = opts or {}
    local book_path = opts.book_path
    if not book_path then return nil, "缺少书路径" end
    -- Required lazily: Epub is also required by the reader, and the MCP
    -- module must stay loadable from dtctl without UI modules.  The reader
    -- passes its own instance so the plugin never ends up with two engines.
    local Epub = opts.epub or require("dualtranslate_epub")
    if type(Epub) ~= "table" then return nil, "EPUB 模块未加载" end
    local extracted, err = Epub.collect_segments{
        book_path = book_path,
        chapter_indexes = opts.chapter_indexes,
        titles = opts.titles,
        max_chars = opts.max_chars,
    }
    if not extracted then return nil, err end

    local job_id, id_err = Mcp.newJobId()
    if not job_id then return nil, id_err end
    local dir = Mcp.jobDir(job_id)
    if not dir or not Tools.mkdir_p(dir) then return nil, "无法创建任务目录" end

    local job = {
        schema = Mcp.JOB_SCHEMA,
        job_id = job_id,
        created_at = os.time(),
        book = {
            device_path = book_path,
            title = opts.book_title or book_title_of(book_path),
            author = opts.book_author,
            source_lang = opts.source_lang,
            target_lang = opts.target_lang,
            spine_count = extracted.spine_count,
            file_size = lfs.attributes(book_path, "size") or 0,
            file_mtime = lfs.attributes(book_path, "modification") or 0,
        },
        chapters = extracted.chapters,
        segments = extracted.segments,
        options = {
            max_chars_per_segment = extracted.max_chars_per_segment,
            split_long_segments = true,
            glossary = type(opts.glossary) == "table" and opts.glossary or {},
            style_guide = opts.style_guide or DEFAULT_STYLE_GUIDE,
        },
    }
    if not Mcp.writeJson(dir .. "/job.json", job) then
        Tools.rmtree(dir)
        return nil, "无法写入任务文件"
    end
    local state = {
        schema = Mcp.STATE_SCHEMA,
        status = "exported",
        provider_id = nil,
        model_name = nil,
        submitted = 0,
        total = #job.segments,
        updated_at = os.time(),
    }
    if not Mcp.writeJson(dir .. "/state.json", state) then
        Tools.rmtree(dir)
        return nil, "无法写入任务状态"
    end
    logger.info("dualtranslate: exported MCP job", job_id, #job.segments, "segments")
    return {
        job_id = job_id,
        dir = dir,
        chapters = #job.chapters,
        segments = #job.segments,
        unreadable = extracted.unreadable or 0,
        job = job,
    }
end

-- ---------------------------------------------------------------------------
-- Inbox (design 10.2/10.5)
--
-- The PC writes the translated result either into the job directory
-- (dtctl put) or, when headless import is unavailable, into mcp/inbox/.  Both
-- locations are polled here; the job is always resolved by result.job_id, so
-- the file name never decides which book a result belongs to.
-- ---------------------------------------------------------------------------

function Mcp.importFile(path, opts)
    opts = opts or {}
    if type(path) ~= "string" or path == "" then return nil, "缺少结果文件" end
    local result = Mcp.readJson(path)
    if not result then return nil, "结果文件不是合法 JSON" end
    if result.schema ~= Mcp.RESULT_SCHEMA then return nil, "结果文件格式不正确" end
    if not Mcp.validJobId(result.job_id) then return nil, "结果缺少合法任务编号" end
    local job, job_err = Mcp.loadJob(result.job_id)
    if not job then return nil, job_err end
    -- Required lazily so a pure export path never loads the DB layer.
    local Store = require("dualtranslate_store")
    local summary, import_err = Store.importResult(job, result, {
        set_display = opts.set_display,
        allow_partial = opts.allow_partial,
        lock_timeout = opts.lock_timeout,
        cache = opts.cache,
        book_path = opts.book_path,
    })
    if not summary then return nil, import_err end

    -- Keep a copy in the job directory as the audit trail and clear the
    -- inbox entry.  Copied through Lua, not os.rename: an inbox filled over
    -- USB may live on a different filesystem.
    local dir = Mcp.jobDir(result.job_id)
    local target = dir .. "/result.json"
    if path ~= target then
        local raw = read_file(path)
        if raw and write_file(target, raw) then os.remove(path) end
    end
    local state = Mcp.loadState(result.job_id) or {}
    state.schema = Mcp.STATE_SCHEMA
    state.status = "committed"
    state.provider_id = result.provider.provider_id
    state.model_name = result.provider.model_name
    state.submitted = summary.submitted
    state.total = summary.total
    state.imported_at = os.time()
    Mcp.saveState(result.job_id, state)
    return summary
end

-- Result files waiting to be imported: inbox first, then job directories
-- whose state is not committed yet.  A missing/committed job is skipped
-- instead of aborting the scan.
function Mcp.pendingResults()
    local pending = {}
    local ok, iterator, state = pcall(lfs.dir, Mcp.inboxDir())
    if ok and iterator then
        for name in iterator, state do
            if name:match("%.json$") then
                pending[#pending + 1] = Mcp.inboxDir() .. "/" .. name
            end
        end
    end
    ok, iterator, state = pcall(lfs.dir, Mcp.jobsDir())
    if ok and iterator then
        for name in iterator, state do
            if Mcp.validJobId(name) then
                local job_state = Mcp.loadState(name)
                if not (job_state and job_state.status == "committed") then
                    local path = Mcp.jobsDir() .. "/" .. name .. "/result.json"
                    if lfs.attributes(path, "mode") then
                        pending[#pending + 1] = path
                    end
                end
            end
        end
    end
    table.sort(pending)
    return pending
end

function Mcp.importPending(opts)
    local imported, failed = {}, {}
    for _, path in ipairs(Mcp.pendingResults()) do
        local summary, err = Mcp.importFile(path, opts)
        if summary then
            imported[#imported + 1] = summary
        else
            failed[#failed + 1] = { path = path, error = tostring(err) }
        end
    end
    return { imported = imported, failed = failed, count = #imported }
end

-- "Delete every translation of this book" must also remove the job files:
-- job.json contains the book's source text and cannot be left behind
-- (design 10.2).
function Mcp.cleanupBookJobs(book_path)
    if type(book_path) ~= "string" or book_path == "" then return 0 end
    local removed = 0
    for _, item in ipairs(Mcp.listJobs()) do
        if item.book_path == book_path then
            Tools.rmtree(Mcp.jobDir(item.job_id))
            os.remove(Mcp.inboxDir() .. "/" .. item.job_id .. ".json")
            removed = removed + 1
        end
    end
    return removed
end

return Mcp
