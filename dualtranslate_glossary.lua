-- Per-book glossary and style guide (design 17 Q5).
--
-- The file lives next to manifest.json in the per-book/per-language cache
-- directory, but it is deliberately a separate file: editing a term must not
-- bump the overlay revision, rebuild css-template.css or make a running reader
-- reload its entries.  Nothing in the translation pipeline reads it either --
-- only the MCP exporter does, when it fills options.glossary/style_guide of a
-- job, so the PC-side agent sees the user's terminology.
--
-- Format on disk:
--   { "schema": "dualtranslate.glossary.v1",
--     "terms": [ { "source": "Darcy", "target": "达西" } ],
--     "style_guide": "保留段落结构，不添加解释，不合并段落。" }

local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Tools = require("dualtranslate_tools")

local Glossary = {}

Glossary.FILE = "glossary.json"
Glossary.SCHEMA = "dualtranslate.glossary.v1"
Glossary.DEFAULT_STYLE_GUIDE = "保留段落结构，不添加解释，不合并段落。"

-- Sanity limits, not product limits: a pasted page must not end up in every
-- job.json (the PC copies options for every exported job).  Limits are bytes
-- (about 66/133 Chinese characters), which is what the JSON writer budgets.
Glossary.MAX_TERMS = 300
Glossary.MAX_SOURCE_BYTES = 200
Glossary.MAX_TARGET_BYTES = 400
Glossary.MAX_STYLE_GUIDE_BYTES = 2000

-- Corrupt files are reported once per directory; the MCP menu re-reads the
-- file on every rebuild and must not flood the log.
local warned_corrupt = {}

-- %s does not cover the ideographic space U+3000 or the no-break space
-- U+00A0 that a Chinese/Japanese keyboard or a pasted term brings along; an
-- invisible leading U+3000 would make the term never match the book text.
local function trim(value)
    local text = tostring(value or "")
        :gsub("\227\128\128", " ")
        :gsub("\194\160", " ")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- One term per line, "source=target".  A full-width equals is accepted too:
-- the editor keyboard on a Chinese device produces it very easily.  When both
-- forms appear, the earliest one is the separator ("a＝b=c" -> source "a").
local function split_term(line)
    local half = line:find("=", 1, true)
    local full = line:find("＝", 1, true)
    local position, width
    if half and (not full or half < full) then
        position, width = half, 1
    elseif full then
        position, width = full, #"＝"
    else
        return nil
    end
    return line:sub(1, position - 1), line:sub(position + width)
end

local function new_stats()
    return { lines = 0, invalid = 0, duplicate = 0, too_long = 0, overflow = 0 }
end

-- Trim, drop empty/invalid/over-long rows, and keep one row per source.  The
-- last spelling of a repeated source wins: it is what the user just typed.
-- Exposed as Glossary.normalizeTerms at the end of this file: the exporter
-- must never write a term the editor could not have produced.
local function normalize_terms(list, stats)
    stats = stats or new_stats()
    local order, values = {}, {}
    for _, item in ipairs(type(list) == "table" and list or {}) do
        if type(item) == "table" then
            local source = trim(item.source or item[1])
            local target = trim(item.target or item[2])
            -- A newline would split one term into two lines when the editor
            -- round-trips the file.
            source = source:gsub("[\r\n]+", " ")
            target = target:gsub("[\r\n]+", " ")
            if source == "" or target == "" then
                stats.invalid = stats.invalid + 1
            elseif #source > Glossary.MAX_SOURCE_BYTES
                or #target > Glossary.MAX_TARGET_BYTES then
                stats.too_long = stats.too_long + 1
            else
                if values[source] == nil then
                    order[#order + 1] = source
                else
                    stats.duplicate = stats.duplicate + 1
                end
                values[source] = target
            end
        else
            stats.invalid = stats.invalid + 1
        end
    end
    local terms = {}
    for _, source in ipairs(order) do
        if #terms >= Glossary.MAX_TERMS then
            stats.overflow = stats.overflow + 1
        else
            terms[#terms + 1] = { source = source, target = values[source] }
        end
    end
    return terms, stats
end

-- Parse the editor text.  Blank lines are not "dropped rows" and stay out of
-- the stats; the dialog only reports what the user would expect to lose.
function Glossary.parse(text)
    local stats = new_stats()
    local raw = {}
    local normalized = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
        line = trim(line)
        if line ~= "" then
            stats.lines = stats.lines + 1
            local source, target = split_term(line)
            if not source then
                stats.invalid = stats.invalid + 1
            else
                raw[#raw + 1] = { source = source, target = target }
            end
        end
    end
    local terms = normalize_terms(raw, stats)
    return terms, stats
end

function Glossary.format(terms)
    local lines = {}
    for _, term in ipairs(normalize_terms(terms)) do
        lines[#lines + 1] = term.source .. "=" .. term.target
    end
    return table.concat(lines, "\n")
end

-- The keep path itself can be occupied (a stale directory from an old bug, a
-- read-only mount): park_keep then uses "<keep>.1".  Recovery checks both, so
-- a fallback copy is still brought back instead of leaking forever.
local KEEP_SUFFIXES = { "", ".1" }

-- A cache sweep moves the file out of the directory before deleting it (see
-- Glossary.stash); recover it if that process died before moving it back.
-- Only a regular file is recovered: a directory (or a socket) sitting at the
-- keep path is somebody else's leftover, and renaming it into place would
-- leave "glossary.json" unreadable for good.
local function recover_stash(dir)
    local target = dir .. "/" .. Glossary.FILE
    if lfs.attributes(target, "mode") then return end
    -- Newest copy wins: a failed rename-over-existing can leave an older keep
    -- next to the bytes that were just parked.
    local candidate, candidate_time, candidate_suffix
    for _, suffix in ipairs(KEEP_SUFFIXES) do
        local keep = Glossary.keepPath(dir) .. suffix
        if lfs.attributes(keep, "mode") == "file" then
            local stamp = lfs.attributes(keep, "modification") or 0
            if not candidate or stamp > candidate_time then
                candidate, candidate_time, candidate_suffix = keep, stamp, suffix
            end
        end
    end
    if not candidate then return end
    Tools.mkdir_p(dir)
    if not os.rename(candidate, target) then return end
    for _, suffix in ipairs(KEEP_SUFFIXES) do
        if suffix ~= candidate_suffix then
            os.remove(Glossary.keepPath(dir) .. suffix)
        end
    end
end

-- Always returns a usable table: a missing file means "no terms and the
-- default style guide".  A corrupt file is flagged (corrupt = true) so the
-- menu can say so instead of silently showing zero terms.
function Glossary.load(dir)
    local empty = { terms = {}, style_guide = Glossary.DEFAULT_STYLE_GUIDE }
    if type(dir) ~= "string" or dir == "" then return empty end
    recover_stash(dir)
    local file = io.open(dir .. "/" .. Glossary.FILE, "rb")
    if not file then return empty end
    local raw = file:read("*a")
    file:close()
    if not raw or raw == "" then return empty end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then
        -- Keep one copy of the unreadable bytes: the editor shows an empty
        -- list, and saving would otherwise replace the user's only copy.
        local backup = dir .. "/" .. Glossary.FILE .. ".corrupt"
        local backup_mode
        if lfs.symlinkattributes then backup_mode = lfs.symlinkattributes(backup, "mode")
        else backup_mode = lfs.attributes(backup, "mode") end
        -- A link would redirect the backup write; drop it and write a real
        -- file instead of truncating its target.
        if backup_mode == "link" then
            os.remove(backup)
            backup_mode = nil
        end
        if not backup_mode then
            local out = io.open(backup, "wb")
            if out then out:write(raw); out:close() end
        end
        if not warned_corrupt[dir] then
            warned_corrupt[dir] = true
            logger.warn("dualtranslate: glossary file is corrupt:", dir)
        end
        return { terms = {}, style_guide = Glossary.DEFAULT_STYLE_GUIDE,
            corrupt = true }
    end
    warned_corrupt[dir] = nil
    local terms = normalize_terms(data.terms)
    local style = type(data.style_guide) == "string" and trim(data.style_guide) or ""
    if #style > Glossary.MAX_STYLE_GUIDE_BYTES then
        style = Tools.utf8_head(style, Glossary.MAX_STYLE_GUIDE_BYTES)
    end
    if style == "" then style = Glossary.DEFAULT_STYLE_GUIDE end
    return { terms = terms, style_guide = style }
end

-- LuaJSON encodes an empty table as {}; the schema declares terms as an
-- array, so force [] on the wire (same helper as dtctl's as_array).
local function json_array(list)
    if #list == 0 and JSON.util and type(JSON.util.InitArray) == "function" then
        return JSON.util.InitArray(list)
    end
    return list
end

-- Atomic replace: a crash mid-write must not leave a truncated glossary that
-- the next export would silently read as "no terms".
function Glossary.saveRaw(dir, raw)
    if type(dir) ~= "string" or dir == "" or type(raw) ~= "string" then
        return false
    end
    if not Tools.mkdir_p(dir) then return false end
    local path = dir .. "/" .. Glossary.FILE
    local file, temporary = Tools.open_temp(path, "wb")
    if not file then return false end
    local written = file:write(raw)
    local closed = file:close()
    if not written or not closed or not os.rename(temporary, path) then
        os.remove(temporary)
        return false
    end
    return true
end

-- Shared body of save(): normalize + encode + atomic write at an explicit
-- path.  save() keeps the per-book contract; the default glossary and the
-- document-folder export reuse this with their own paths.
local function saveEncoded(path, data)
    local terms, stats = normalize_terms(type(data) == "table" and data.terms or {})
    local style = type(data) == "table" and trim(data.style_guide) or ""
    if #style > Glossary.MAX_STYLE_GUIDE_BYTES then
        style = Tools.utf8_head(style, Glossary.MAX_STYLE_GUIDE_BYTES)
        stats.style_truncated = true
    end
    if style == "" then style = Glossary.DEFAULT_STYLE_GUIDE end
    local payload = {
        schema = Glossary.SCHEMA,
        terms = json_array(terms),
        style_guide = style,
    }
    local ok, encoded = pcall(JSON.encode, payload)
    if not ok or not encoded then return nil, "术语表编码失败" end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and not Tools.mkdir_p(parent) then return nil, "无法创建目录" end
    local file, temporary = Tools.open_temp(path, "wb")
    if not file then return nil, "无法写入术语表" end
    local written = file:write(encoded)
    local closed = file:close()
    if not written or not closed or not os.rename(temporary, path) then
        os.remove(temporary)
        return nil, "无法写入术语表"
    end
    return { terms = terms, style_guide = style, stats = stats }
end

function Glossary.save(dir, data)
    if type(dir) ~= "string" or dir == "" then return nil, "缺少书目录" end
    return saveEncoded(dir .. "/" .. Glossary.FILE, data)
end

-- The stash lives next to the book directory, not inside it: "delete every
-- translation" removes the directory as a whole.
function Glossary.keepPath(dir)
    if type(dir) ~= "string" or dir == "" then return nil end
    return dir .. ".glossary.keep"
end

-- Take the glossary out of a directory that is about to be deleted.  Rename is
-- preferred because it needs no free space and the bytes are still there if
-- this process dies before unstash.  A read-only/odd filesystem falls back to
-- an in-memory copy; unreadable returns nil, "unreadable" so the caller can
-- skip the delete instead of destroying the only copy.
function Glossary.stash(dir)
    if type(dir) ~= "string" or dir == "" then return nil end
    local source = dir .. "/" .. Glossary.FILE
    -- A directory named glossary.json is not user terms; moving it aside would
    -- only make the next load fail on a directory instead of a missing file.
    if lfs.attributes(source, "mode") ~= "file" then return nil end
    local keep = Glossary.keepPath(dir)
    if os.rename(source, keep) then return { keep = keep } end
    local file = io.open(source, "rb")
    if not file then return nil, "unreadable" end
    local raw = file:read("*a")
    file:close()
    if raw == nil then return nil, "unreadable" end
    return { data = raw }
end

-- Park in-memory glossary bytes next to the cache directory.  Atomic like
-- saveRaw: a half-written keep must not replace a complete one left by an
-- earlier crash.  A keep path occupied by a directory falls back to ".1",
-- which recover_stash also reads.
local function park_keep(dir, data)
    local keep = Glossary.keepPath(dir)
    for _, suffix in ipairs(KEEP_SUFFIXES) do
        local target = keep .. suffix
        local out, temporary = Tools.open_temp(target, "wb")
        if out then
            local written = out:write(data)
            local closed = out:close()
            if written and closed and os.rename(temporary, target) then
                return true
            end
            os.remove(temporary)
        end
    end
    return false
end

function Glossary.unstash(dir, stashed)
    if type(dir) ~= "string" or dir == "" or stashed == nil then return true end
    if not Tools.mkdir_p(dir) then
        -- The directory could not be recreated.  A keep file is already safe
        -- where it is (recover_stash retries on the next load), but memory
        -- bytes would die with this process, so park them the same way.
        if stashed.data then park_keep(dir, stashed.data) end
        return false
    end
    if stashed.keep then
        -- A failed rename leaves the keep file where it is: recover_stash
        -- will put it back on the next load, so no bytes are lost.
        return os.rename(stashed.keep, dir .. "/" .. Glossary.FILE) ~= nil
    end
    if Glossary.saveRaw(dir, stashed.data) then return true end
    -- The directory is gone and the normal write failed.  Park the bytes next
    -- to it so recover_stash can still bring them back later.
    park_keep(dir, stashed.data)
    return false
end

Glossary.normalizeTerms = function(list)
    return normalize_terms(list)
end

-- ---------------------------------------------------------------------------
-- Cross-book reuse (17 Q5 follow-up): series books share one translator's
-- terminology.  Three mechanisms, all built on the same payload shape:
--   * a global default glossary (save the current book's as default, load it
--     into another book);
--   * copying from another book that already has a glossary;
--   * a JSON file next to the book (export/import, also the cross-device path).
-- The default lives outside the books/ trees so "delete every translation"
-- never touches it.
-- ---------------------------------------------------------------------------

-- The default is per target language: a translator's Chinese terms for an
-- English book are not the right default for a Japanese book, and the old
-- single file silently shared both.  A code is sanitized so it can never
-- leave the dualtranslate directory; defaultPath() without a code keeps the
-- pre-3.4 path for reading an upgraded installation's file.
local function language_key(target_lang)
    if type(target_lang) ~= "string" or target_lang == "" then return nil end
    return (target_lang:gsub("[^%w_-]", "_"))
end

function Glossary.defaultPath(target_lang)
    local DataStorage = require("datastorage")
    local base = DataStorage:getDataDir() .. "/cache/dualtranslate/"
    local key = language_key(target_lang)
    if key then return base .. "glossary.default." .. key .. ".json" end
    return base .. "glossary.default.json"
end

-- Read and normalize a glossary payload from an explicit file.  Returns
-- nil + a readable reason, so a damaged export cannot silently import as
-- "no terms".
-- Third return value is a stable reason code ("missing", "empty",
-- "invalid", "empty_terms"): loadDefault falls back to the old shared file
-- only on "missing", and must not break when a message is reworded.
function Glossary.loadFile(path)
    if type(path) ~= "string" or path == "" then
        return nil, "缺少文件路径", "invalid"
    end
    local file = io.open(path, "rb")
    if not file then return nil, "找不到文件：" .. path, "missing" end
    local raw = file:read("*a")
    file:close()
    if not raw or raw == "" then return nil, "文件是空的", "empty" end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then
        return nil, "文件不是有效的术语表 JSON", "invalid"
    end
    local terms = normalize_terms(data.terms)
    local style = type(data.style_guide) == "string" and trim(data.style_guide) or ""
    if #style > Glossary.MAX_STYLE_GUIDE_BYTES then
        style = Tools.utf8_head(style, Glossary.MAX_STYLE_GUIDE_BYTES)
    end
    if #terms == 0 and style == "" then
        return nil, "文件里没有术语", "empty_terms"
    end
    if style == "" then style = Glossary.DEFAULT_STYLE_GUIDE end
    return { terms = terms, style_guide = style }
end

-- Missing per-language file falls back to the pre-3.4 shared default once, so
-- an upgrade does not make the user's saved default disappear.  A corrupt
-- per-language file is reported instead of silently replaced by the shared
-- one.  legacy_default lets the menu say where the terms came from.
function Glossary.loadDefault(target_lang)
    local payload, err, code = Glossary.loadFile(Glossary.defaultPath(target_lang))
    if not payload and language_key(target_lang) and code == "missing" then
        local legacy = Glossary.loadFile(Glossary.defaultPath())
        if legacy then
            legacy.legacy_default = true
            return legacy, nil, "legacy"
        end
    end
    return payload, err, code
end

function Glossary.saveDefault(data, target_lang)
    return saveEncoded(Glossary.defaultPath(target_lang), data)
end

-- Books that carry a glossary, newest first, excluding exclude_dir (the book
-- being edited).  Only regular files count -- the same no-symlink rule the
-- MCP job listing applies.  Terms are counted so the picker can say what it
-- would overwrite.
function Glossary.listGlossaryBooks(exclude_dir)
    local DataStorage = require("datastorage")
    local books_root = DataStorage:getDataDir() .. "/cache/dualtranslate/books"
    local out = {}
    local ok, iterator, state = pcall(lfs.dir, books_root)
    if not ok or not iterator then return out end
    local function mode_of(path)
        if lfs.symlinkattributes then
            return lfs.symlinkattributes(path, "mode")
        end
        return lfs.attributes(path, "mode")
    end
    for name in iterator, state do
        if name ~= "." and name ~= ".." then
            local dir = books_root .. "/" .. name
            local file = dir .. "/" .. Glossary.FILE
            if dir ~= exclude_dir and mode_of(dir) == "directory"
                and mode_of(file) == "file" then
                local payload = Glossary.loadFile(file)
                if payload then
                    local title
                    local manifest = io.open(dir .. "/manifest.json", "rb")
                    if manifest then
                        local raw = manifest:read("*a")
                        manifest:close()
                        local ok_json, data = pcall(JSON.decode, raw)
                        if ok_json and type(data) == "table" then
                            local book_path = tostring(data.book_path or "")
                            title = book_path:match("([^/]+)$")
                        end
                    end
                    out[#out + 1] = {
                        dir = dir,
                        title = title or name,
                        terms = #payload.terms,
                        updated_at = lfs.attributes(file, "modification") or 0,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.updated_at ~= b.updated_at then return a.updated_at > b.updated_at end
        return a.title < b.title
    end)
    return out
end

-- Copy the current book's glossary bytes to an explicit file (atomic), e.g.
-- "<book folder>/<book name>.dualtranslate-glossary.json".  The bytes, not a
-- re-encoding, travel: what the user saved is what lands in the export.
function Glossary.exportFile(dir, target_path)
    if type(dir) ~= "string" or dir == "" then return nil, "缺少书目录" end
    if type(target_path) ~= "string" or target_path == "" then
        return nil, "缺少导出路径"
    end
    local source = dir .. "/" .. Glossary.FILE
    if lfs.attributes(source, "mode") ~= "file" then return nil, "本书还没有术语表" end
    local file = io.open(source, "rb")
    if not file then return nil, "术语表不可读" end
    local raw = file:read("*a")
    file:close()
    if not raw then return nil, "术语表不可读" end
    local parent = target_path:match("^(.*)/[^/]+$")
    if parent and not Tools.mkdir_p(parent) then return nil, "无法创建导出目录" end
    local out, temporary = Tools.open_temp(target_path, "wb")
    if not out then return nil, "无法写导出文件" end
    local written = out:write(raw)
    local closed = out:close()
    if not written or not closed or not os.rename(temporary, target_path) then
        os.remove(temporary)
        return nil, "无法写导出文件"
    end
    return { bytes = #raw }
end

-- Import an exported glossary file into a book directory: normalized on the
-- way in (same limits as the editor), saved atomically.  Returns the saved
-- payload, or nil + reason.
function Glossary.importFile(path, dir)
    local payload, err = Glossary.loadFile(path)
    if not payload then return nil, err end
    local saved, save_err = Glossary.save(dir, payload)
    if not saved then return nil, save_err end
    return saved
end

return Glossary
