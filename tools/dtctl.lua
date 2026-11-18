-- Headless MCP tool runner (design 10.5).
--
-- Called either locally (./tools/dtctl.sh list-jobs) or through an SSH forced
-- command, where sshd puts the client's command line into
-- SSH_ORIGINAL_COMMAND and leaves argv empty.  stdout carries exactly one line
-- of JSON; every log line goes to stderr so the PC side can json.decode() the
-- output without stripping noise.

-- Resolve the plugin directory from this script's own path so a checkout,
-- a simulator and the device install all work without KO_ROOT/plugins.
local script_path = arg and arg[0] or ""
if script_path:sub(1, 1) ~= "/" then script_path = "./" .. script_path end
local script_dir = script_path:match("^(.*)/[^/]+$") or "."
local plugin_dir = script_dir:match("^(.*)/[^/]+$") or "."
local root = os.getenv("KO_ROOT") or "/mnt/us/koreader"

package.path = table.concat({
    plugin_dir .. "/?.lua",
    "./?.lua",
    root .. "/?.lua",
    root .. "/common/?.lua",
    root .. "/common/?/init.lua",
    root .. "/frontend/?.lua",
    root .. "/frontend/?/init.lua",
    package.path,
}, ";")
package.cpath = table.concat({
    root .. "/?.so",
    root .. "/common/?.so",
    root .. "/libs/?.so",
    root .. "/?.dylib",
    root .. "/common/?.dylib",
    root .. "/libs/?.dylib",
    package.cpath,
}, ";")
-- stdout carries only the final JSON line, so redirect print BEFORE the
-- loader runs: setupkoenv and ffi/loadlib announce themselves with print.
local real_print = print
print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[index] = tostring((select(index, ...)))
    end
    io.stderr:write(table.concat(parts, "\t") .. "\n")
end

-- KOReader's own loader knows the device-specific paths; the fallback above
-- covers a plain luajit run on a desktop checkout.
pcall(require, "setupkoenv")

-- The logger wrapper must accept varargs: every call site in the plugin is
-- logger.warn("msg", ...), so function(_, ...) would swallow the message.
local function redirect_logger()
    local ok, logger = pcall(require, "logger")
    if not ok or type(logger) ~= "table" then return end
    local function to_stderr(level)
        return function(...)
            local parts = {}
            for index = 1, select("#", ...) do
                parts[index] = tostring((select(index, ...)))
            end
            io.stderr:write("[" .. level .. "] " .. table.concat(parts, " ") .. "\n")
        end
    end
    logger.dbg = to_stderr("DBG")
    logger.info = to_stderr("INFO")
    logger.warn = to_stderr("WARN")
    logger.err = to_stderr("ERR")
end
redirect_logger()

local ok_json, JSON = pcall(require, "json")
if not ok_json or type(JSON) ~= "table" then
    real_print('{"ok":false,"code":"NO_JSON","message":"json module unavailable"}')
    os.exit(1)
end
local lfs = require("libs/libkoreader-lfs")

-- A desktop/debug run must not write into the user's live KOReader data dir;
-- DT_DATA_DIR points the whole run (cache db + mcp tree) somewhere else.
local data_dir_override = os.getenv("DT_DATA_DIR")
if data_dir_override and data_dir_override ~= "" then
    local DataStorage = require("datastorage")
    DataStorage.getDataDir = function() return data_dir_override end
end

local Mcp = require("dualtranslate_mcp")
local Store = require("dualtranslate_store")
local Overlay = require("dualtranslate_overlay")
local Tools = require("dualtranslate_tools")

local SUBCOMMANDS = {
    extract = true, put = true, import = true, ["list-jobs"] = true,
    ["list-providers"] = true, ["delete-provider"] = true,
    ["set-display"] = true, ["touch-reload"] = true,
    cat = true, ["job-status"] = true, ["get-segments"] = true,
}

local ALLOWED_KEYS = {
    extract = { book = true, chapters = true, source = true, target = true, out = true },
    put = { job = true, name = true },
    import = { job = true, result = true, ["allow-partial"] = true },
    ["list-jobs"] = {},
    ["list-providers"] = { book = true, target = true },
    ["delete-provider"] = { book = true, target = true, provider = true },
    ["set-display"] = { book = true, target = true, provider = true },
    ["touch-reload"] = { book = true, target = true, op = true },
    cat = { job = true, name = true },
    ["job-status"] = { job = true },
    ["get-segments"] = { job = true, offset = true, limit = true, context = true },
}

-- Flags take no value; every other --key needs one.
local FLAGS = {
    import = { ["allow-partial"] = true },
    ["get-segments"] = { context = true },
}

local function fail(code, message, detail)
    local payload = { ok = false, code = code, message = message }
    if detail then payload.detail = detail end
    real_print(JSON.encode(payload))
    os.exit(code == "INVALID_ARGUMENT" and 2 or 1)
end

-- Absolute path, no ".." escapes.  Returns nil when the path is not absolute
-- or tries to climb above the filesystem root.
local function normalize_path(path)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return nil end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts == 0 then return nil end
            table.remove(parts)
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

-- Split a command string honouring single/double quotes, so
-- --book "/mnt/us/documents/novel/Pride and Prejudice.epub" stays one
-- argument.  This is not a shell: metacharacters are still rejected outright.
local function split_command(raw)
    if raw:find("[;|&$`<>\n\r]") then return nil, "illegal character" end
    local tokens, index, length = {}, 1, #raw
    while index <= length do
        local char = raw:sub(index, index)
        if char:match("%s") then
            index = index + 1
        elseif char == "'" or char == '"' then
            local quote = char
            local buffer, closed = {}, false
            index = index + 1
            while index <= length do
                local current = raw:sub(index, index)
                if current == quote then
                    closed = true
                    index = index + 1
                    break
                end
                if quote == '"' and current == "\\" then
                    local escaped = raw:sub(index + 1, index + 1)
                    if escaped == '"' or escaped == "\\" then
                        buffer[#buffer + 1] = escaped
                        index = index + 2
                    else
                        buffer[#buffer + 1] = current
                        index = index + 1
                    end
                else
                    buffer[#buffer + 1] = current
                    index = index + 1
                end
            end
            if not closed then return nil, "unterminated quote" end
            tokens[#tokens + 1] = table.concat(buffer)
        else
            local start = index
            while index <= length and not raw:sub(index, index):match("%s") do
                index = index + 1
            end
            tokens[#tokens + 1] = raw:sub(start, index - 1)
        end
    end
    return tokens
end

local function parse_original_command(raw)
    local tokens, token_err = split_command(raw)
    if not tokens then return nil, token_err end
    if #tokens == 0 then return nil, "missing subcommand" end
    local command = tokens[1]
    if not SUBCOMMANDS[command] then
        -- "sftp" lands here: the write key is not allowed to open a subsystem.
        return nil, "unknown subcommand: " .. command
    end
    local allowed = ALLOWED_KEYS[command]
    local flags = FLAGS[command] or {}
    local argv = { command }
    local index = 2
    while index <= #tokens do
        local token = tokens[index]
        if token:sub(1, 2) ~= "--" then return nil, "positional arguments not accepted" end
        local key = token:sub(3)
        if not allowed[key] then return nil, "unexpected option: " .. token end
        argv[#argv + 1] = token
        if not flags[key] then
            local value = tokens[index + 1]
            if not value then return nil, "missing value for " .. token end
            argv[#argv + 1] = value
            index = index + 2
        else
            index = index + 1
        end
    end
    return argv
end

local function parse_argv(argv)
    if type(argv) ~= "table" or not argv[1] then return nil, "missing subcommand" end
    local command = argv[1]
    if not SUBCOMMANDS[command] then return nil, "unknown subcommand: " .. tostring(command) end
    local allowed = ALLOWED_KEYS[command]
    local flags = FLAGS[command] or {}
    local opts = {}
    local index = 2
    while index <= #argv do
        local token = argv[index]
        if token:sub(1, 2) ~= "--" then return nil, "positional arguments not accepted" end
        local key = token:sub(3)
        if not allowed[key] then return nil, "unexpected option: " .. token end
        if flags[key] then
            opts[key] = true
            index = index + 1
        else
            local value = argv[index + 1]
            if not value then return nil, "missing value for " .. token end
            opts[key] = value
            index = index + 2
        end
    end
    return command, opts
end

-- --job must be exactly mcp/jobs/<id>/job.json, so a caller can never point
-- the importer at another book's job or escape the directory (10.5).
local function validate_job_path(path)
    local normalized = normalize_path(path)
    if not normalized then return nil, "invalid job path" end
    local job_id = normalized:match("/mcp/jobs/([^/]+)/job%.json$")
    if not job_id then return nil, "--job must be mcp/jobs/<id>/job.json" end
    if not Mcp.validJobId(job_id) then return nil, "invalid job id" end
    local expected = normalize_path(Mcp.jobDir(job_id) .. "/job.json")
    if normalized ~= expected then return nil, "job path outside the jobs directory" end
    return normalized, job_id
end

local function validate_book(path)
    if type(path) ~= "string" or path == "" or path == "/" then
        return nil, "missing --book"
    end
    if not path:lower():match("%.epub$") then
        return nil, "--book must be an EPUB file"
    end
    if not lfs.attributes(path, "mode") then return nil, "book not found: " .. path end
    local book_root = os.getenv("DT_BOOK_ROOT")
    if book_root and book_root ~= "" then
        local normalized_root = normalize_path(book_root)
        local normalized = normalize_path(path)
        if not normalized or not normalized_root
            or normalized:sub(1, #normalized_root + 1) ~= normalized_root .. "/" then
            return nil, "book outside DT_BOOK_ROOT"
        end
    end
    return path
end

local function validate_target(code)
    if type(code) ~= "string" or code == "" then return nil, "missing --target" end
    local Languages = require("dualtranslate_languages")
    for _, language in ipairs(Languages.list) do
        if language.code == code then return code end
    end
    return nil, "unknown target language: " .. code
end

-- new writes may not mint "legacy" (6.1), but deleting the migrated layer is
-- the user's right.
local function validate_provider(provider_id, allow_legacy)
    if allow_legacy and provider_id == "legacy" then return provider_id end
    if not Store.validProviderId(provider_id) then
        return nil, "invalid provider id"
    end
    return provider_id
end

local function read_stdin(limit)
    limit = limit or 50 * 1024 * 1024
    local chunks, total = {}, 0
    while true do
        local chunk = io.read(65536)
        if not chunk then break end
        total = total + #chunk
        if total > limit then return nil, "stdin exceeds size limit" end
        chunks[#chunks + 1] = chunk
    end
    return table.concat(chunks)
end

local function write_atomic(path, data)
    local parent = path:match("^(.*)/[^/]+$")
    if parent and not Tools.mkdir_p(parent) then return false end
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

-- Per-job lock for put (mkdir semantics, stale after 300 s).
local function with_job_lock(dir, fn)
    local lock = dir .. "/.lock"
    local function acquire()
        if lfs.mkdir(lock) then return true end
        local mtime = lfs.attributes(lock, "modification")
        if mtime and os.time() - mtime > 300 then
            lfs.rmdir(lock)
            return lfs.mkdir(lock) == true
        end
        return false
    end
    if not acquire() then return nil, "job is locked by another writer" end
    local ok, result, err = pcall(fn)
    lfs.rmdir(lock)
    if not ok then error(result, 0) end
    return result, err
end

local function book_dir_for(book_path, target_lang)
    return Store.bookDir(book_path, target_lang)
end

-- srcOverlay.bumpSignal owns the monotonic rule (max(revision, previous seq)
-- + 1); a delete leaves no manifest, so copying the revision would go backwards
-- and a running reader would ignore the change.
local function write_signal(book_path, target_lang, op, provider)
    local dir = book_dir_for(book_path, target_lang)
    local manifest = Overlay.loadManifest(dir)
    return Overlay.bumpSignal(dir, {
        op = op,
        provider = provider,
        count = provider and manifest and manifest.providers
            and manifest.providers[provider]
            and manifest.providers[provider].translated_count or nil,
    })
end

-- ---------------------------------------------------------------------------
-- Subcommands
-- ---------------------------------------------------------------------------

-- LuaJSON encodes an empty table as {}; a list must still be [] so the PC
-- side can iterate it without a type check.
local function as_array(list)
    list = list or {}
    if #list == 0 and JSON.util and type(JSON.util.InitArray) == "function" then
        return JSON.util.InitArray(list)
    end
    return list
end

-- Body of an rpc call (put/import): the envelope travels on stdin, so the
-- actual file content is a field inside it.
local rpc_stdin = nil

local handlers = {}

handlers["list-jobs"] = function()
    return { ok = true, jobs = as_array(Mcp.listJobs()) }
end

-- Read the job body for the PC side.  The reader never needs the whole file
-- (get-segments paginates on the device), but load_job still wants one copy
-- after a transport change.
local CAT_NAMES = { ["job.json"] = true, ["state.json"] = true,
    ["result.json"] = true, ["result.partial.json"] = true }

handlers.cat = function(opts)
    local job_path, job_id_or_err = validate_job_path(opts.job)
    if not job_path then return nil, job_id_or_err end
    local name = opts.name
    if not CAT_NAMES[name] then
        return nil, "--name must be job.json, state.json, result.json or result.partial.json"
    end
    local path = Mcp.jobDir(job_id_or_err) .. "/" .. name
    local size = lfs.attributes(path, "size")
    if not size then return { ok = true, name = name, exists = false } end
    if size > 16 * 1024 * 1024 then return nil, "file too large to read" end
    local file = io.open(path, "rb")
    if not file then return nil, "cannot read " .. name end
    local content = file:read("*a")
    file:close()
    return { ok = true, name = name, exists = true, bytes = #content, content = content }
end

handlers["job-status"] = function(opts)
    local job_path, job_id_or_err = validate_job_path(opts.job)
    if not job_path then return nil, job_id_or_err end
    local job_id = job_id_or_err
    local state = Mcp.loadState(job_id) or {}
    local meta = Mcp.loadMeta(job_id)
    local book, total, chapter_count, segment_ids
    if meta then
        -- Index path: no job.json decode at all.
        book = meta.book or {}
        segment_ids = Mcp.listSegmentIds(job_id) or {}
        total = tonumber(meta.total) or #segment_ids
        chapter_count = tonumber(meta.chapter_count) or 0
        if total <= 0 or #segment_ids ~= total then
            -- The index disagrees with meta.total: a truncated file or an
            -- encoder that changed the line format.  Never hand the PC a
            -- short id list -- it caches it and would then commit a partial
            -- job as complete (10.2).
            segment_ids = nil
        end
    end
    if not segment_ids then
        local job, job_err = Mcp.loadJob(job_id)
        if not job then return nil, job_err or "任务索引不可用" end
        book = job.book or {}
        segment_ids = {}
        for index, segment in ipairs(job.segments) do segment_ids[index] = segment.id end
        total = #job.segments
        chapter_count = #(job.chapters or {})
    end
    return {
        ok = true, job_id = job_id,
        book_path = book.device_path,
        title = book.title,
        source_lang = book.source_lang,
        target_lang = book.target_lang,
        spine_count = book.spine_count,
        file_size = book.file_size,
        file_mtime = book.file_mtime,
        total = total,
        chapter_count = chapter_count,
        segment_ids = segment_ids,
        status = state.status or "exported",
        provider_id = state.provider_id,
        model_name = state.model_name,
        submitted = tonumber(state.submitted) or 0,
    }
end

-- Pagination lives on the device.  With the NDJSON index a page costs
-- O(offset) short lines; a job exported before the index existed falls back
-- to the old whole-file path.
handlers["get-segments"] = function(opts)
    local job_path, job_id_or_err = validate_job_path(opts.job)
    if not job_path then return nil, job_id_or_err end
    local job_id = job_id_or_err
    local offset = tonumber(opts.offset) or 0
    local limit = tonumber(opts.limit) or 50
    if offset < 0 or offset ~= math.floor(offset) then return nil, "invalid --offset" end
    if limit ~= math.floor(limit) then return nil, "invalid --limit" end
    limit = math.max(1, math.min(limit, 100))
    local with_context = opts.context == true
    local page, page_err = Mcp.readSegmentPage(job_id, offset, limit, with_context)
    if page then
        local last = offset + #page.segments
        return {
            ok = true, job_id = job_id, total = page.total,
            next_offset = last < page.total and last or nil,
            segments = page.segments,
        }
    end
    local job, job_err = Mcp.loadJob(job_id)
    if not job then return nil, job_err or page_err end
    local segments = job.segments
    local rows = {}
    local last = math.min(offset + limit, #segments)
    for index = offset + 1, last do
        local segment = segments[index]
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
            row.prev = index > 1 and Tools.utf8_tail(segments[index - 1].source, 200) or nil
            row.next = index < #segments
                and Tools.utf8_head(segments[index + 1].source, 200) or nil
        end
        rows[#rows + 1] = row
    end
    return {
        ok = true, job_id = job_id, total = #segments,
        next_offset = last < #segments and last or nil,
        segments = rows,
    }
end

function handlers.extract(opts)
    local book, err = validate_book(opts.book)
    if not book then return nil, err end
    local target, target_err = validate_target(opts.target)
    if not target then return nil, target_err end
    local chapters
    if opts.chapters and opts.chapters ~= "" then
        chapters = {}
        for token in tostring(opts.chapters):gmatch("[^,]+") do
            local index = tonumber(token)
            if not index or index < 1 then return nil, "invalid --chapters" end
            chapters[#chapters + 1] = index
        end
    end
    local result, export_err = Mcp.exportJob{
        book_path = book,
        chapter_indexes = chapters,
        source_lang = opts.source or "auto",
        target_lang = target,
    }
    if not result then return nil, export_err end
    if opts.out then
        local encoded = JSON.encode(result.job)
        if not write_atomic(opts.out, encoded) then
            return nil, "cannot write --out"
        end
    end
    return {
        ok = true, job_id = result.job_id, dir = result.dir,
        chapters = result.chapters, segments = result.segments,
        out = opts.out,
    }
end

function handlers.put(opts)
    local job_path, job_id_or_err = validate_job_path(opts.job)
    if not job_path then return nil, job_id_or_err end
    local job_id = job_id_or_err
    local dir = Mcp.jobDir(job_id)
    local raw, read_err
    if rpc_stdin ~= nil then
        raw, read_err = rpc_stdin, nil
    else
        raw, read_err = read_stdin()
    end
    if not raw then return nil, read_err end
    if raw == "" then return nil, "empty stdin" end
    local decoded, document = pcall(JSON.decode, raw)
    if not decoded or type(document) ~= "table" then return nil, "stdin is not valid JSON" end

    local name = opts.name
    if name ~= "state.json" and name ~= "result.partial.json" and name ~= "result.json" then
        return nil, "--name must be state.json, result.partial.json or result.json"
    end
    local target = dir .. "/" .. name
    return with_job_lock(dir, function()
        if not write_atomic(target, raw) then return nil, "cannot write target file" end
        return { ok = true, path = target, bytes = #raw }
    end)
end

function handlers.import(opts)
    local job_path, job_id_or_err = validate_job_path(opts.job)
    if not job_path then return nil, job_id_or_err end
    local job_id = job_id_or_err
    local result_path = opts.result
    if result_path then
        local normalized = normalize_path(result_path)
        local expected = normalize_path(Mcp.jobDir(job_id) .. "/result.json")
        local expected_partial = normalize_path(Mcp.jobDir(job_id) .. "/result.partial.json")
        if not normalized or (normalized ~= expected and normalized ~= expected_partial) then
            return nil, "--result must be inside the job directory"
        end
        result_path = normalized
    else
        result_path = Mcp.jobDir(job_id) .. "/result.json"
    end
    local job, job_err = Mcp.loadJob(job_id)
    if not job then return nil, job_err end
    local result = Mcp.readJson(result_path)
    if not result then return nil, "cannot read result file" end
    local summary, import_err = Store.importResult(job, result, {
        allow_partial = opts["allow-partial"] == true,
    })
    if not summary then return nil, import_err end
    local state = Mcp.loadState(job_id) or { schema = Mcp.STATE_SCHEMA }
    state.status = "committed"
    state.provider_id = result.provider and result.provider.provider_id
    state.model_name = result.provider and result.provider.model_name
    state.submitted = summary.submitted
    state.total = summary.total
    Mcp.saveState(job_id, state)
    summary.rejected = as_array(summary.rejected)
    summary.chapters = as_array(summary.chapters)
    summary.partial_chapters = as_array(summary.partial_chapters)
    summary.failed_chapters = as_array(summary.failed_chapters)
    return { ok = true, job_id = job_id, imported = summary }
end

handlers["list-providers"] = function(opts)
    local book, err = validate_book(opts.book)
    if not book then return nil, err end
    local target, target_err = validate_target(opts.target)
    if not target then return nil, target_err end
    return { ok = true, providers = as_array(Store.listProviders(book, target)) }
end

handlers["delete-provider"] = function(opts)
    local book, err = validate_book(opts.book)
    if not book then return nil, err end
    local target, target_err = validate_target(opts.target)
    if not target then return nil, target_err end
    local provider, provider_err = validate_provider(opts.provider, true)
    if not provider then return nil, provider_err end
    local result, delete_err = Store.deleteProvider(book, target, provider)
    if not result then return nil, delete_err end
    write_signal(book, target, "delete", provider)
    return { ok = true, deleted = result.deleted, display_provider = result.display_provider }
end

handlers["set-display"] = function(opts)
    local book, err = validate_book(opts.book)
    if not book then return nil, err end
    local target, target_err = validate_target(opts.target)
    if not target then return nil, target_err end
    local provider = opts.provider
    if provider ~= "auto" then
        local provider_err
        provider, provider_err = validate_provider(provider)
        if not provider then return nil, provider_err end
    end
    local manifest, set_err = Store.setDisplayProvider(book, target, provider)
    if not manifest then return nil, set_err end
    write_signal(book, target, "display", provider ~= "auto" and provider or nil)
    return { ok = true, display_mode = manifest.display_mode,
        display_provider = manifest.display_provider }
end

handlers["touch-reload"] = function(opts)
    local book, err = validate_book(opts.book)
    if not book then return nil, err end
    local target, target_err = validate_target(opts.target)
    if not target then return nil, target_err end
    local op = opts.op or "refresh"
    if op ~= "import" and op ~= "delete" and op ~= "display" and op ~= "refresh" then
        return nil, "invalid --op"
    end
    local seq = write_signal(book, target, op)
    return { ok = true, seq = seq, op = op }
end

-- ---------------------------------------------------------------------------
-- Entry
-- ---------------------------------------------------------------------------

-- Read-only commands a key may run.  Everything else needs the write key.
-- list-providers is not here on purpose: it opens the cache DB, and opening a
-- v2 database runs the schema migration (a write).  A read-only key must never
-- trigger that, so provider listing needs the write key.
local READ_COMMANDS = {
    ["list-jobs"] = true, cat = true, ["job-status"] = true,
    ["get-segments"] = true,
}
local MODE_ALLOWED = { read = READ_COMMANDS, write = SUBCOMMANDS }

-- JSON over stdin removes the "ssh joins argv into a string, the far side
-- splits it again" problem: a book path with spaces or quotes is just another
-- array element.  The payload is small and bounded.
local function read_rpc_payload()
    -- Bodies are result.json / state.json uploads; 16 MB covers a ten-thousand
    -- segment job while staying well under the device's memory budget.
    local raw, read_err = read_stdin(16 * 1024 * 1024)
    if not raw then return nil, read_err end
    if raw == "" then return nil, "empty rpc payload" end
    -- JSON.decode returns nil on malformed input; an unprotected call would
    -- leak a Lua traceback to the caller (agent) instead of a JSON error.
    local decoded, document = pcall(JSON.decode, raw)
    if not decoded or type(document) ~= "table" or type(document.argv) ~= "table" then
        return nil, "invalid rpc payload"
    end
    local arguments = {}
    for index, value in ipairs(document.argv) do
        if type(value) ~= "string" or #value > 4096 then return nil, "invalid rpc argument" end
        arguments[index] = value
        if #arguments > 32 then return nil, "too many rpc arguments" end
    end
    if #arguments == 0 then return nil, "missing subcommand" end
    if document.stdin ~= nil and type(document.stdin) ~= "string" then
        return nil, "invalid rpc body"
    end
    return arguments, document.stdin
end

local argv = {}
for index = 1, #arg do argv[index] = arg[index] end

-- --mode comes from the forced command in authorized_keys, never from the
-- client: the client cannot prepend it to SSH_ORIGINAL_COMMAND.
local mode = "write"
if argv[1] and argv[1]:match("^%-%-mode=") then
    mode = argv[1]:match("^%-%-mode=(%a+)$")
    if mode ~= "read" and mode ~= "write" then fail("INVALID_ARGUMENT", "invalid mode") end
    table.remove(argv, 1)
end

local original = os.getenv("SSH_ORIGINAL_COMMAND")
if argv[1] == "rpc" then
    local payload, body_or_err = read_rpc_payload()
    if not payload then fail("INVALID_ARGUMENT", body_or_err) end
    rpc_stdin = body_or_err
    argv = payload
elseif original and original ~= "" then
    local parsed, parse_err = parse_original_command(original)
    if not parsed then fail("INVALID_ARGUMENT", parse_err or "invalid command") end
    argv = parsed
end

if not argv[1] then fail("INVALID_ARGUMENT", "missing subcommand") end
-- Unknown commands are a client bug (INVALID_ARGUMENT); a known command that
-- the key may not run is a permission decision (FORBIDDEN).  Keeping the two
-- apart makes the PC side's error handling unambiguous.
if not SUBCOMMANDS[argv[1]] then
    fail("INVALID_ARGUMENT", "unknown subcommand: " .. argv[1])
end
if not MODE_ALLOWED[mode][argv[1]] then
    fail("FORBIDDEN", "command not allowed in " .. mode .. " mode")
end

local command, opts_or_err = parse_argv(argv)
if not command then fail("INVALID_ARGUMENT", opts_or_err) end
local handler = handlers[command]
if not handler then fail("INVALID_ARGUMENT", "unsupported subcommand") end

local ok, result, err = pcall(handler, opts_or_err)
if not ok then
    fail("INTERNAL", "command failed", tostring(result))
end
if not result then fail("INVALID_ARGUMENT", tostring(err)) end
real_print(JSON.encode(result))
os.exit(0)
