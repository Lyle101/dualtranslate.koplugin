-- Cross-platform helpers for DualTranslate.
--
-- This module removes the plugin's dependency on external shell tools
-- (unzip, find, mkdir, rm, curl, ...) wherever KOReader provides a native
-- equivalent, so the plugin also works on Kobo, PocketBook, Android, Linux
-- and macOS, not only on Kindle:
--   * zip read/extract       -> KOReader ffi/archiver (libarchive)
--   * recursive mkdir/rmtree -> lfs (pure Lua, no shell)
--
-- All functions are side-effect-safe: every path argument is treated as a
-- plain string and never interpolated into a shell command.

local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")

-- Archiver is required lazily: the MCP job commands (list-jobs / put /
-- import / list-providers) never touch an EPUB, and on a desktop checkout
-- libarchive may not be on the loader path.  Only the two extraction paths
-- need it, and they report a readable error when it is unavailable.
local function load_archiver()
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok or type(Archiver) ~= "table" or not Archiver.Reader then
        return nil, "EPUB 解包库不可用（ffi/archiver）"
    end
    return Archiver
end

local Tools = {}

-- Stable, path-safe hash used to name per-book cache directories.  The same
-- book path (and language suffix) always maps to the same directory, and the
-- digest cannot collide with user file names.
function Tools.stable_path_hash(value)
    local hash = 7
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 2147483647
    end
    return string.format("%08x", hash)
end

-- Recursive mkdir.  KOReader's own util.makePath already creates missing
-- parent components; keep this thin wrapper so call sites stay unchanged.
function Tools.mkdir_p(path)
    if not path or path == "" then return false end
    return util.makePath(path) == true
end

-- lfs.attributes follows symlinks; a recursive delete must not.  /mnt/us is
-- world-writable on Kindle, so a link planted in a cache/job directory could
-- otherwise make the plugin erase the link target (which may be the user's
-- documents).  symlinkattributes is present in every KOReader build we ship
-- for; the fallback keeps old builds usable.
local function path_mode(path)
    if lfs.symlinkattributes then return lfs.symlinkattributes(path, "mode") end
    return lfs.attributes(path, "mode")
end

-- Recursive delete, pure Lua. Returns true when the path no longer exists.
-- Symlinks are removed themselves, never followed (same rule as rm -rf).
function Tools.rmtree(path)
    if not path or path == "" then return true end
    local mode = path_mode(path)
    if not mode then return true end
    if mode == "directory" then
        local ok, iterator, state = pcall(lfs.dir, path)
        if ok and iterator then
            for name in iterator, state do
                if name ~= "." and name ~= ".." then
                    Tools.rmtree(path .. "/" .. name)
                end
            end
        end
        pcall(lfs.rmdir, path)
    else
        pcall(os.remove, path)
    end
    return path_mode(path) == nil
end

-- Split a paragraph into request-sized chunks.  Two callers need exactly the
-- same boundary rules: the reader (keeping a request below the engine limit)
-- and the MCP job exporter (design 10.2 max_chars_per_segment), because the
-- parts of one paragraph are stitched back together on import.  Cuts prefer
-- whitespace or sentence punctuation near the limit, then rewind to a UTF-8
-- character boundary so no chunk starts or ends inside a multi-byte rune.
function Tools.split_text(text, limit)
    text = tostring(text or "")
    limit = math.max(1, tonumber(limit) or 1)
    if #text <= limit then return { text } end
    local chunks = {}
    local rest = text
    local function to_char_boundary(cut)
        while cut > 1 do
            local byte = rest:byte(cut)
            if not byte or byte < 128 or byte > 191 then
                if byte and byte >= 192 then cut = cut - 1 end
                break
            end
            cut = cut - 1
        end
        return cut
    end
    while #rest > limit do
        local cut = limit
        local search_from = math.max(1, limit - 160)
        for index = limit, search_from, -1 do
            local character = rest:sub(index, index)
            if character:match("[%s%.,;:%?!]") then
                cut = index
                break
            end
        end
        cut = to_char_boundary(cut)
        local part = util.trim(rest:sub(1, cut))
        if part == "" then
            cut = to_char_boundary(limit)
            part = rest:sub(1, cut)
        end
        chunks[#chunks + 1] = part
        rest = util.trim(rest:sub(cut + 1))
    end
    if rest ~= "" then chunks[#chunks + 1] = rest end
    return chunks
end

-- Normalize a zip member name and reject absolute paths and ".." escapes.
local function safe_member(entry_path)
    local normalized = tostring(entry_path or ""):gsub("\\", "/")
    if normalized:sub(1, 1) == "/" then return nil end
    local parts = {}
    for part in normalized:gmatch("[^/]+") do
        if part == ".." then return nil end
        if part ~= "." and part ~= "" then table.insert(parts, part) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "/")
end

-- Extract only the wanted members (exact paths, raw or normalized) in a single
-- iterate() pass: reading container.xml/OPF/TOC must not unpack a whole EPUB.
-- Returns map wanted path -> extracted path, or nil, err.  Absent members are
-- simply missing from the map; the caller owns dest_dir and must clean it up.
function Tools.extract_entries(archive_path, dest_dir, wanted)
    if type(wanted) ~= "table" or next(wanted) == nil then return {} end
    if not Tools.mkdir_p(dest_dir) then return nil, "cannot create " .. tostring(dest_dir) end
    local Archiver, archiver_err = load_archiver()
    if not Archiver then return nil, archiver_err end
    local arc = Archiver.Reader:new()
    if not arc:open(archive_path) then
        logger.warn("dualtranslate: cannot open archive:", archive_path, tostring(arc.err))
        return nil, tostring(arc.err or "cannot open archive")
    end
    local extracted = {}
    local ok, err = pcall(function()
        for entry in arc:iterate() do
            local safe = safe_member(entry.path)
            if safe and entry.mode ~= "directory" and entry.path:sub(-1) ~= "/" then
                local key = wanted[entry.path] and entry.path or (wanted[safe] and safe or nil)
                if key then
                    local dest_path = dest_dir .. "/" .. safe
                    local parent = dest_path:match("^(.*)/[^/]+$")
                    if parent then Tools.mkdir_p(parent) end
                    if not arc:extractToPath(entry.path, dest_path) then
                        error("extract failed: " .. tostring(entry.path)
                            .. ": " .. tostring(arc.err))
                    end
                    extracted[key] = dest_path
                end
            end
        end
    end)
    arc:close()
    if not ok then
        logger.warn("dualtranslate: archive extract failed:", tostring(err))
        return nil, tostring(err)
    end
    return extracted
end

-- Extract a whole zip archive into dest_dir.
-- Path-traversal safe (rejects absolute members and ".." components).
function Tools.unzip_to(archive_path, dest_dir)
    if not Tools.mkdir_p(dest_dir) then return false end
    local Archiver = load_archiver()
    if not Archiver then return false end
    local arc = Archiver.Reader:new()
    if not arc:open(archive_path) then
        logger.warn("dualtranslate: cannot open archive:", archive_path, tostring(arc.err))
        return false
    end
    local ok, err = pcall(function()
        for entry in arc:iterate() do
            local safe = safe_member(entry.path)
            if safe then
                local dest_path = dest_dir .. "/" .. safe
                if entry.path:sub(-1) == "/" then
                    Tools.mkdir_p(dest_path)
                else
                    local parent = dest_path:match("^(.*)/[^/]+$")
                    if parent then Tools.mkdir_p(parent) end
                    if not arc:extractToPath(entry.path, dest_path) then
                        error("extract failed: " .. tostring(entry.path)
                            .. ": " .. tostring(arc.err))
                    end
                end
            end
        end
    end)
    arc:close()
    if not ok then
        logger.warn("dualtranslate: archive extract failed:", tostring(err))
        Tools.rmtree(dest_dir)
        return false
    end
    return true
end

-- A killed process (ssh timeout, reader restart) leaves its unpacked book tree
-- behind; one 646-chapter export is 25 MB, so a few crashes fill a 3 GB
-- partition.  Called before every new work dir.
function Tools.sweep_temp_dirs(base_dir, prefixes, max_age)
    local ok, iterator, state = pcall(lfs.dir, base_dir)
    if not ok or not iterator then return 0 end
    local now = os.time()
    local removed = 0
    for name in iterator, state do
        for _, prefix in ipairs(prefixes or {}) do
            if name:sub(1, #prefix) == prefix then
                local path = base_dir .. "/" .. name
                local mtime = lfs.attributes(path, "modification")
                if mtime and now - mtime > (max_age or 6 * 3600) then
                    Tools.rmtree(path)
                    removed = removed + 1
                end
                break
            end
        end
    end
    return removed
end

-- UTF-8 safe slices.  A 200-byte boundary lands inside a 3-byte character
-- two thirds of the time on Chinese sources; cutting by bytes produces an
-- invalid JSON string that strict clients reject outright.
function Tools.utf8_char_len(byte)
    if byte < 0xC0 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    return 4
end

function Tools.utf8_tail(text, limit)
    if type(text) ~= "string" or #text <= limit then return text end
    local start = #text - limit + 1
    -- 0x80-0xBF are continuation bytes: the slice would start mid-character.
    -- Step forward to the next character start: dropping one byte keeps the
    -- result within limit, stepping back would exceed it.
    while start <= #text do
        local byte = text:byte(start)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        start = start + 1
    end
    return text:sub(start)
end

function Tools.utf8_head(text, limit)
    if type(text) ~= "string" or #text <= limit then return text end
    local stop = limit
    while stop > 0 do
        local byte = text:byte(stop + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        stop = stop - 1
    end
    if stop == 0 then return "" end
    return text:sub(1, stop)
end

return Tools

