-- MCP external translation (design 10): the device exports a job with the
-- paragraphs to translate, the PC-side agent fills them in and commits them
-- back through dtctl over SSH.  This module owns the job files; the data
-- writes on import live in dualtranslate_store.lua so dtctl can reuse them
-- headless.  There is no device-side inbox: the agent is the only producer,
-- and it always commits through dtctl.
--
-- No UI dependencies: the Reader decides when to call in, and dtctl.lua runs
-- the same functions from a plain luajit process.

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local JSON = require("json")
local logger = require("logger")
local Tools = require("dualtranslate_tools")
local Glossary = require("dualtranslate_glossary")

local Mcp = {}

Mcp.JOB_SCHEMA = "dualtranslate.job.v1"
Mcp.RESULT_SCHEMA = "dualtranslate.result.v1"
Mcp.STATE_SCHEMA = "dualtranslate.state.v1"

-- The segments array starts with this marker on its own line, so the job head
-- (book + chapters + options) can be read and decoded without touching the
-- megabytes that follow it.
local SEGMENTS_MARKER = '"segments":[\n'

function Mcp.rootDir()
    return DataStorage:getDataDir() .. "/cache/dualtranslate/mcp"
end

function Mcp.jobsDir()
    return Mcp.rootDir() .. "/jobs"
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

-- A job directory must be a real directory under jobs/.  lfs.attributes
-- follows symlinks, and /mnt/us is world-writable, so a link planted as a job
-- id could otherwise make listJobs read (and cleanupExpiredJobs erase) the
-- link target.  Template reclamation uses the same rule.
local function job_dir_is_real(job_id)
    local dir = Mcp.jobDir(job_id)
    if not dir then return false end
    local mode
    if lfs.symlinkattributes then mode = lfs.symlinkattributes(dir, "mode")
    else mode = lfs.attributes(dir, "mode") end
    return mode == "directory"
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
    if not lfs.attributes(path, "mode") then return nil, "找不到任务文件" end
    local job = Mcp.readJson(path)
    if not job then return nil, "任务文件损坏" end
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

-- Newest first.  A directory with neither a usable meta.json nor a decodable
-- job.json is skipped instead of aborting the whole listing: one interrupted
-- export must not hide every other job.
--
-- Rows come from meta.json: it carries the book fields and the totals, and
-- decoding it costs milliseconds where the full job.json costs seconds on a
-- 646-chapter book.  Directories without a usable meta.json (jobs exported
-- before the index layout) still take the whole-file path.
function Mcp.listJobs()
    local jobs = {}
    local ok, iterator, state = pcall(lfs.dir, Mcp.jobsDir())
    if not ok or not iterator then return jobs end
    for name in iterator, state do
        if Mcp.validJobId(name) and job_dir_is_real(name) then
            local meta = Mcp.loadMeta(name)
            local row
            local total = meta and tonumber(meta.total)
            -- A meta.json whose job.json is gone (half-deleted directory,
            -- interrupted tooling) must not produce a row that every later
            -- command fails on.  One stat, no read; a 0-byte file counts as
            -- missing.
            local job_size = lfs.attributes(Mcp.jobPath(name), "size")
            if meta and total and job_size and job_size > 0 then
                local book = meta.book or {}
                row = {
                    job_id = name,
                    created_at = tonumber(meta.created_at) or 0,
                    book_path = book.device_path,
                    title = book.title,
                    chapter_count = tonumber(meta.chapter_count) or 0,
                    total = total,
                }
            else
                local job = Mcp.loadJob(name)
                if job then
                    row = {
                        job_id = name,
                        created_at = tonumber(job.created_at) or 0,
                        book_path = job.book and job.book.device_path,
                        title = job.book and job.book.title,
                        chapter_count = #(job.chapters or {}),
                        total = #job.segments,
                    }
                end
            end
            if row then
                local job_state = Mcp.loadState(name) or {}
                row.status = job_state.status or "exported"
                row.provider_id = job_state.provider_id
                row.model_name = job_state.model_name
                row.submitted = tonumber(job_state.submitted) or 0
                row.updated_at = tonumber(job_state.updated_at) or 0
                jobs[#jobs + 1] = row
            end
        end
    end
    table.sort(jobs, function(a, b)
        if a.created_at ~= b.created_at then return a.created_at > b.created_at end
        return a.job_id > b.job_id
    end)
    return jobs
end

-- Counting only needs valid directory names; the menu renders on every open
-- and must not parse every job.json just to show "(N)".
function Mcp.countJobs()
    local count = 0
    local ok, iterator, state = pcall(lfs.dir, Mcp.jobsDir())
    if not ok or not iterator then return 0 end
    for name in iterator, state do
        if Mcp.validJobId(name) then count = count + 1 end
    end
    return count
end

local function book_title_of(book_path)
    local name = book_path:match("([^/]+)$") or book_path
    return (name:gsub("%.[Ee][Pp][Uu][Bb]$", ""))
end

-- Design 10.2: the device writes job.json + state.json; segments carry the
-- selectors CREngine will match, so the PC never parses the EPUB itself.
-- ---------------------------------------------------------------------------
-- Job index (meta.json + line-per-segment job.json)
--
-- A 10k-segment job.json is ~4.7 MB and takes ~9.8 s to decode+validate on a
-- Voyage; get-segments runs once per page, so the whole-file path was the
-- bottleneck.  Export writes the segments array one object per line (JSON
-- allows the newlines), plus a tiny meta.json for book fields and totals and
-- an options.json for the glossary.  The index stays inside job.json so it is
-- written once, not per page.
--
-- Measured on the device: io.lines()/read("*l") costs ~0.5-1 ms per line, so
-- every reader below slurps the file once (~24 ms) and slices it with
-- string.find; a page costs O(offset) characters, not O(offset) syscalls.
-- ---------------------------------------------------------------------------
Mcp.META_SCHEMA = "dualtranslate.job.meta.v1"
-- options.json: the glossary/style guide that travel with the job.  Separate
-- from meta.json so listing tasks never decodes up to 300 terms per job.
Mcp.OPTIONS_SCHEMA = "dualtranslate.job.options.v1"

function Mcp.slurp(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

-- LuaJSON encodes an empty table as {}; a list must still be [] so the PC
-- side can iterate options.glossary without a type check (same helper as
-- dtctl's as_array).
local function json_array(list)
    list = list or {}
    if #list == 0 and JSON.util and type(JSON.util.InitArray) == "function" then
        return JSON.util.InitArray(list)
    end
    return list
end

local function segments_start(blob)
    if not blob then return nil end
    local pos = blob:find(SEGMENTS_MARKER, 1, true)
    if not pos then return nil end
    return pos + #SEGMENTS_MARKER
end

-- Book and chapter titles only: everything above the segments array.  The
-- task detail dialog needs the chapter list, and a full job.json decode for
-- that costs ~10 s on a 646-chapter book.  One 64 KB read covers several
-- thousand chapter titles; the loop stops at the marker, never at the file
-- end, and gives up past JOB_HEAD_LIMIT.
Mcp.JOB_HEAD_LIMIT = 1024 * 1024

function Mcp.loadJobShell(job_id)
    if not Mcp.validJobId(job_id) then return nil end
    local path = Mcp.jobPath(job_id)
    local file = path and io.open(path, "rb")
    if file then
        local head, marker
        while true do
            local chunk = file:read(65536)
            if not chunk then break end
            head = head and (head .. chunk) or chunk
            marker = head:find(SEGMENTS_MARKER, 1, true)
            if marker or #head >= Mcp.JOB_HEAD_LIMIT then break end
        end
        file:close()
        if marker then
            -- The head ends with a comma because the segments field follows
            -- it; close the object there instead of decoding the rest.
            local shell = head:sub(1, marker - 1):gsub("%s+$", "")
            if shell:sub(-1) == "," then
                shell = shell:sub(1, -2) .. "}"
            else
                shell = shell .. "}"
            end
            local ok, decoded = pcall(JSON.decode, shell)
            if ok and type(decoded) == "table" then return decoded end
        end
    end
    -- A job written by an older plugin has no index layout: it is one JSON
    -- object, so the chapters are only reachable through a whole-file parse.
    -- That costs seconds on a big job and runs on the UI thread, so it is
    -- limited to small files; a large one opens without a chapter list.
    local size = path and (lfs.attributes(path, "size") or 0) or 0
    if size > Mcp.JOB_HEAD_LIMIT then return nil end
    local job = Mcp.loadJob(job_id)
    if not job then return nil end
    return {
        schema = job.schema, job_id = job.job_id, created_at = job.created_at,
        book = job.book, chapters = job.chapters, options = job.options,
    }
end

-- Byte offset of every SEGMENT_ANCHOR-th line, stored in meta.json so a page
-- near the end starts within one block instead of scanning thousands of lines
-- (a 10k-line scan costs ~0.6 s on a Voyage).
Mcp.SEGMENT_ANCHOR = 100

-- Lines [from, to] (1-based) of the segments array, one object per line.
-- A trailing comma belongs to the array, not to the object.
local function read_segment_lines(blob, anchors, from, to)
    local start = segments_start(blob)
    if not start then return nil end
    local index, pos = 1, start
    if anchors and #anchors > 0 then
        local block = math.floor((from - 1) / Mcp.SEGMENT_ANCHOR) + 1
        if anchors[block] then
            pos = anchors[block]
            index = (block - 1) * Mcp.SEGMENT_ANCHOR + 1
        end
    end
    local lines = {}
    while index <= to do
        local stop = blob:find("\n", pos, true)
        if not stop then break end
        local line = blob:sub(pos, stop - 1)
        if line:sub(-1) == "," then line = line:sub(1, -2) end
        if index >= from then lines[index] = line end
        pos = stop + 1
        index = index + 1
    end
    return lines
end

local function count_segment_lines(blob)
    local start = segments_start(blob)
    if not start then return 0 end
    local count, pos = 0, start
    while true do
        local stop = blob:find("\n", pos, true)
        if not stop then break end
        count = count + 1
        pos = stop + 1
    end
    return count
end

-- Encodes every segment once and lays the array out one object per line, so
-- the same bytes serve job.json compatibility and the page index.
function Mcp.writeJobFiles(dir, job)
    if not dir or type(job) ~= "table" or type(job.segments) ~= "table" then
        return false
    end
    local lines = {}
    for index, segment in ipairs(job.segments) do
        local encoded = JSON.encode(segment)
        if not encoded then return false end
        lines[index] = encoded
    end
    local shell = {
        schema = job.schema, job_id = job.job_id, created_at = job.created_at,
        book = job.book, chapters = job.chapters, options = job.options,
    }
    local encoded_shell = JSON.encode(shell)
    if not encoded_shell then return false end
    -- JSON.encode returns an object literal; drop its closing brace and
    -- append the already-encoded segments (JSON field order does not matter).
    local head = encoded_shell:sub(1, -2) .. "," .. SEGMENTS_MARKER
    local anchors, cursor = {}, #head + 1
    for index, line in ipairs(lines) do
        if (index - 1) % Mcp.SEGMENT_ANCHOR == 0 then
            anchors[#anchors + 1] = cursor
        end
        cursor = cursor + #line + 2 -- ",\n" between objects
    end
    local job_json = head .. table.concat(lines, ",\n") .. "\n]}"
    -- options live in their own small file: meta.json is decoded once per job
    -- every time the task list is rebuilt, and a 300-term glossary makes it
    -- ~180 KB.  dtctl job-status and the PC both read options from here.
    local meta = {
        schema = Mcp.META_SCHEMA,
        job_id = job.job_id,
        created_at = job.created_at,
        book = job.book,
        chapter_count = #(job.chapters or {}),
        total = #job.segments,
        -- Kept for readers of an older meta shape and for jobs whose options
        -- file is missing (the PC can still split long segments).
        max_chars_per_segment = job.options and job.options.max_chars_per_segment,
        anchors = anchors,
    }
    if not Tools.mkdir_p(dir) then return false end
    if not write_file(dir .. "/job.json", job_json) then return false end
    if type(job.options) == "table" then
        local options = {
            schema = Mcp.OPTIONS_SCHEMA,
            job_id = job.job_id,
            options = job.options,
        }
        if not Mcp.writeJson(dir .. "/options.json", options) then return false end
    end
    return Mcp.writeJson(dir .. "/meta.json", meta)
end

function Mcp.loadMeta(job_id)
    if not Mcp.validJobId(job_id) then return nil end
    local data = Mcp.readJson(Mcp.jobDir(job_id) .. "/meta.json")
    if type(data) ~= "table" or data.schema ~= Mcp.META_SCHEMA then return nil end
    return data
end

-- Translation instructions for a job.  New jobs keep them in options.json;
-- jobs exported before the split keep a copy in meta.json.  meta is accepted
-- so job-status, which already read it, does not pay for a second decode.
function Mcp.loadOptions(job_id, meta)
    if not Mcp.validJobId(job_id) then return nil end
    local data = Mcp.readJson(Mcp.jobDir(job_id) .. "/options.json")
    if type(data) == "table" and data.schema == Mcp.OPTIONS_SCHEMA
        and data.job_id == job_id and type(data.options) == "table" then
        return data.options
    end
    meta = meta or Mcp.loadMeta(job_id)
    if type(meta) == "table" and type(meta.options) == "table" then
        return meta.options
    end
    return nil
end

-- One task as the detail dialog shows it: which book, which chapters, how far
-- the agent got.  base is the list row, used only for the totals of a job
-- directory old enough to have no meta.json.
function Mcp.jobDetail(job_id, base)
    if not Mcp.validJobId(job_id) then return nil end
    local meta = Mcp.loadMeta(job_id)
    local shell = Mcp.loadJobShell(job_id)
    if not meta and not shell then return nil end
    local book = (meta and meta.book) or (shell and shell.book)
    if type(book) ~= "table" then book = {} end
    local job_state = Mcp.loadState(job_id) or {}
    local chapters = (shell and shell.chapters) or {}
    local options = Mcp.loadOptions(job_id, meta) or (shell and shell.options)
    local terms = type(options) == "table" and type(options.glossary) == "table"
        and #options.glossary or 0
    local guide = type(options) == "table" and options.style_guide or nil
    return {
        job_id = job_id,
        created_at = tonumber(meta and meta.created_at)
            or tonumber(shell and shell.created_at) or 0,
        updated_at = tonumber(job_state.updated_at) or 0,
        book_path = book.device_path,
        title = book.title,
        author = book.author,
        source_lang = book.source_lang,
        target_lang = book.target_lang,
        chapter_count = tonumber(meta and meta.chapter_count) or #chapters,
        total = tonumber(meta and meta.total) or tonumber(base and base.total) or 0,
        chapters = chapters,
        status = job_state.status or "exported",
        provider_id = job_state.provider_id,
        model_name = job_state.model_name,
        submitted = tonumber(job_state.submitted) or 0,
        glossary_terms = terms,
        -- Empty and "still the default" both mean the user wrote nothing.
        style_guide_custom = type(guide) == "string" and guide ~= ""
            and guide ~= Glossary.DEFAULT_STYLE_GUIDE or false,
    }
end

function Mcp.readSegmentPage(job_id, offset, limit, with_context)
    if not Mcp.validJobId(job_id) then return nil, "invalid job id" end
    local blob = Mcp.slurp(Mcp.jobDir(job_id) .. "/job.json")
    if not blob or not segments_start(blob) then
        return nil, "没有可用的段落索引"
    end
    local meta = Mcp.loadMeta(job_id)
    local total = meta and tonumber(meta.total) or nil
    if not total then total = count_segment_lines(blob) end
    local from = math.max(1, offset)
    local last = offset + limit + 1
    local lines = read_segment_lines(blob, meta and meta.anchors, from, last)
    -- Decode each line once: neighbours are reused for prev/next instead of
    -- being decoded again per row (120 decodes -> 41 for a 50-row page).
    local decoded = {}
    for position = from, last do
        local line = lines[position]
        if line then
            -- A line that another tool reformatted (or a truncated tail) must
            -- surface as "index unusable" so the caller can fall back, not as
            -- a Lua error the agent cannot act on.
            local ok, segment = pcall(JSON.decode, line)
            if not ok or type(segment) ~= "table" then
                return nil, "段落索引损坏"
            end
            decoded[position] = segment
        end
    end
    local rows = {}
    for position = offset + 1, offset + limit do
        local segment = decoded[position]
        if not segment or position > total then break end
        local row = {
            id = segment.id,
            parent_id = segment.parent_id or segment.id,
            part = segment.part or 1,
            parent_total = segment.parent_total or 1,
            chapter_index = segment.chapter_index,
            chapter_title = segment.chapter_title,
            source = segment.source,
        }
        if with_context then
            local previous = decoded[position - 1]
            local following = decoded[position + 1]
            row.prev = previous and previous.source
                and Tools.utf8_tail(previous.source, 200) or nil
            row.next = following and following.source
                and Tools.utf8_head(following.source, 200) or nil
        end
        rows[#rows + 1] = row
    end
    -- A truncated job.json (power loss while writing) would otherwise come
    -- back as an empty page with next_offset == offset and spin the client.
    if #rows == 0 and offset < total then
        return nil, "段落索引不完整"
    end
    return { segments = rows, total = total }
end

function Mcp.listSegmentIds(job_id)
    if not Mcp.validJobId(job_id) then return nil end
    local blob = Mcp.slurp(Mcp.jobDir(job_id) .. "/job.json")
    local start = segments_start(blob)
    if not start then return nil end
    local ids, pos = {}, start
    while true do
        local found = blob:find('"id":"', pos, true)
        if not found then break end
        local stop = blob:find('"', found + 6, true)
        if not stop then break end
        ids[#ids + 1] = blob:sub(found + 6, stop - 1)
        pos = stop + 1
    end
    return ids
end

function Mcp.exportJob(opts)
    opts = opts or {}
    local book_path = opts.book_path
    if not book_path then return nil, "缺少书路径" end
    -- Required lazily: Epub is also required by the reader, and the MCP
    -- module must stay loadable from dtctl without UI modules.  The reader
    -- passes its own instance so the plugin never ends up with two engines.
    --
    -- 3.2.0: the reader already walked the book in slices and hands the
    -- finished table in as opts.collected.  Re-collecting here would take the
    -- whole export back onto the UI thread.
    local extracted, err = opts.collected
    if not extracted then
        local Epub = opts.epub or require("dualtranslate_epub")
        if type(Epub) ~= "table" then return nil, "EPUB 模块未加载" end
        extracted, err = Epub.collect_segments{
            book_path = book_path,
            chapter_indexes = opts.chapter_indexes,
            chapter_ranges = opts.chapter_ranges,
            titles = opts.titles,
            max_chars = opts.max_chars,
        }
    end
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
            -- 17 Q5: the reader passes the per-book glossary; normalizing here
            -- keeps job.json schema-valid even for a caller that built the
            -- table itself (dtctl, tests).
            glossary = json_array(Glossary.normalizeTerms(
                type(opts.glossary) == "table" and opts.glossary or {})),
            style_guide = opts.style_guide ~= nil
                and tostring(opts.style_guide) or Glossary.DEFAULT_STYLE_GUIDE,
        },
    }
    -- One encode per segment, shared by job.json and the index (10.3).
    if not Mcp.writeJobFiles(dir, job) then
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

-- "Delete every translation of this book" must also remove the job files:
-- job.json contains the book's source text and cannot be left behind
-- (design 10.2).
function Mcp.cleanupBookJobs(book_path)
    if type(book_path) ~= "string" or book_path == "" then return 0 end
    local removed = 0
    for _, item in ipairs(Mcp.listJobs()) do
        if item.book_path == book_path and job_dir_is_real(item.job_id) then
            Tools.rmtree(Mcp.jobDir(item.job_id))
            removed = removed + 1
        end
    end
    return removed
end

-- Design 10.2: a committed job keeps the whole book's source text and the
-- user's glossary, but it has already been imported; the directory is only
-- useful for inspection.  Drop the ones older than a week on the next
-- successful import.  Jobs still in flight (exported/submitted) are never
-- touched, and neither is the job this import just committed.
Mcp.JOB_RETENTION_DAYS = 7

-- Only a *finished* import is disposable: `--allow-partial` also writes
-- "committed", but the PC still needs get-segments/submit for the missing
-- parts, so submitted < total stays.  total == 0 (an export with no
-- segments) is never deleted either: it costs nothing and "finished" is
-- meaningless there.
local function job_is_finished(job_state)
    local submitted = tonumber(job_state.submitted)
    local total = tonumber(job_state.total)
    return submitted ~= nil and total ~= nil and total > 0 and submitted >= total
end

function Mcp.cleanupExpiredJobs(opts)
    opts = opts or {}
    local days = tonumber(opts.days) or Mcp.JOB_RETENTION_DAYS
    local cutoff = (tonumber(opts.now) or os.time()) - days * 86400
    local keep_id = opts.keep_job_id
    local removed = 0
    local ok, iterator, state = pcall(lfs.dir, Mcp.jobsDir())
    if not ok or not iterator then return 0 end
    -- Collect first: deleting a directory while lfs.dir walks the parent can
    -- skip the next entry on some filesystems.
    local names = {}
    for name in iterator, state do names[#names + 1] = name end
    for _, name in ipairs(names) do
        if Mcp.validJobId(name) and name ~= keep_id
            and job_dir_is_real(name) then
            local dir = Mcp.jobDir(name)
            local job_state = Mcp.loadState(name)
            local stamp, disposable
            if type(job_state) == "table" then
                disposable = job_state.status == "committed"
                    and job_is_finished(job_state)
                -- updated_at is written at commit; the state file's own mtime
                -- covers a state.json written before that field existed or one
                -- that lost it (0 would otherwise read as "ancient").
                stamp = tonumber(job_state.updated_at)
                if not stamp or stamp <= 0 then
                    stamp = lfs.attributes(dir .. "/state.json", "modification")
                end
            else
                -- No readable state.json: an export that died between job.json
                -- and state.json.  It was never importable, so the directory
                -- mtime is all we have; leaving it forever is the leak this
                -- cleanup exists to stop.
                disposable = true
                stamp = lfs.attributes(dir, "modification")
            end
            if disposable and stamp and stamp < cutoff
                and Tools.rmtree(dir) then
                removed = removed + 1
            end
        end
    end
    return removed
end

return Mcp
