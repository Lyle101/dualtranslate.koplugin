-- Non-destructive, per-book inline layers for EPUB documents.
-- The original archive is never modified.  Translations are persisted as
-- JSON and exposed to CREngine as generated CSS text.
--
-- v3 layout (design 6.3): manifest.json + entries/<provider slug>.json per
-- book directory.  The v2 single-file API (load/save) is kept for the legacy
-- overlay.json path until every book has been migrated.

local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")

local Overlay = {}

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local write_counter = 0
-- Two processes may rewrite the same file (reader CSS build vs. dtctl import
-- template).  A shared "<path>.tmp" would let them mix chunks into one inode,
-- so every write gets a process-unique suffix; rename(2) stays the atomic
-- commit point.  PID is the reliable part; the table address is only a
-- fallback for hosts without /proc (and may collide without ASLR).
local function make_process_tag()
    local file = io.open("/proc/self/stat", "r")
    if file then
        local line = file:read("*l")
        file:close()
        local pid = line and line:match("^(%d+)")
        if pid then return pid end
    end
    file = io.open("/dev/urandom", "rb")
    if file then
        local bytes = file:read(4)
        file:close()
        if bytes and #bytes == 4 then
            return string.format("%02x%02x%02x%02x", bytes:byte(1, 4))
        end
    end
    return tostring({}):match("0x(%x+)") or tostring(os.time())
end
local process_tag = make_process_tag()

local function write_file(path, data)
    -- Atomic replacement: rename(2) overwrites the destination on POSIX, so
    -- there is no window where the old overlay is gone but the new one is
    -- not yet in place (a crash mid-checkpoint keeps the previous file).
    -- Durability: a failed write/close (e.g. full disk) must never rename a
    -- truncated tmp over the good file; drop the tmp and report failure.
    write_counter = write_counter + 1
    local temporary = path .. ".tmp." .. process_tag .. "." .. write_counter
    local file = io.open(temporary, "wb")
    if not file then return false end
    local written = file:write(data)
    if not written then
        file:close()
        os.remove(temporary)
        return false
    end
    local closed = file:close()
    if not closed then
        os.remove(temporary)
        return false
    end
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return false
    end
    return true
end

local function mkdir_p(path)
    if not path or path == "" then return false end
    if lfs.attributes(path, "mode") == "directory" then return true end
    local prefix = path:sub(1, 1) == "/" and "" or "."
    for component in path:gmatch("[^/]+") do
        prefix = prefix .. "/" .. component
        if lfs.attributes(prefix, "mode") ~= "directory" then
            local ok = lfs.mkdir(prefix)
            if not ok and lfs.attributes(prefix, "mode") ~= "directory" then
                return false
            end
        end
    end
    return lfs.attributes(path, "mode") == "directory"
end

-- LuaJSON decodes JSON null into a sentinel function; normalize it back to
-- nil so nullable manifest fields (model_name, display_provider) stay plain
-- Lua values and re-encoding never leaks the sentinel.
local null_sentinel = JSON.util and JSON.util.null
local function denull(value)
    if type(value) ~= "table" then return value end
    for key, item in pairs(value) do
        if null_sentinel and item == null_sentinel then
            value[key] = nil
        elseif type(item) == "table" then
            denull(item)
        end
    end
    return value
end

local function read_json(path)
    local raw = read_file(path)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then return nil end
    return denull(data)
end

local function provider_slug(provider_id)
    return (tostring(provider_id):gsub("[^%w._-]", "_"))
end

local function provider_kind(provider_id)
    if provider_id == "system" then return "builtin" end
    if provider_id == "microsoft_free" then return "http" end
    if provider_id == "legacy" then return "legacy" end
    return "mcp"
end

local function count_unique_selectors(entries)
    local seen, count = {}, 0
    for _, entry in ipairs(entries or {}) do
        local selector = entry.selector
        if selector and selector ~= "" and not seen[selector] then
            seen[selector] = true
            count = count + 1
        end
    end
    return count
end

-- A list parent's translation has been anchored on three different nodes
-- across releases: the <li> itself (3.0.x), its ::before (3.1.0) and the
-- child <ol>/<ul> (3.2.0, the only point that sits between the parent's text
-- and its first child).  All three describe the same paragraph, so an entry
-- written by an older build would render the same translation a second time
-- once a re-translation merges the new shape next to it.  The identity is the
-- element that owns the text: strip the pseudo-element, and for a child-list
-- anchor also the list step itself.
local function entry_identity(selector)
    local base = selector:gsub("::[%a%-]+$", "")
    return (base:gsub(" > [ou]l:nth%-of%-type%(%d+%)$", ""))
end

-- Collapse the stale shapes of one paragraph into the newest one.  Writers
-- append the newer shape after the older one (disk before this run, existing
-- rows before the import), so the last entry seen wins; it keeps the position
-- of the first so re-translating a chapter updates entries in place instead of
-- shifting the whole file.
function Overlay.dedupeEntries(entries)
    if type(entries) ~= "table" then return entries end
    local position, out = {}, {}
    for _, entry in ipairs(entries) do
        local selector = type(entry) == "table" and entry.selector or nil
        if type(selector) ~= "string" or selector == "" then
            out[#out + 1] = entry
        else
            local key = entry_identity(selector)
            local at = position[key]
            if at then
                out[at] = entry
            else
                out[#out + 1] = entry
                position[key] = #out
            end
        end
    end
    return out
end

local function css_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
    value = value:gsub("\r\n", "\\A "):gsub("[\r\n]", "\\A ")
    value = value:gsub("%z", "")
    return '"' .. value .. '"'
end

function Overlay.load(path)
    local raw = read_file(path)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or type(data.entries) ~= "table" then
        return nil
    end
    return data
end

function Overlay.save(path, data)
    local ok, encoded = pcall(JSON.encode, data)
    if not ok or not encoded then return false end
    return write_file(path, encoded)
end

function Overlay.exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    local size = file:seek("end") or 0
    file:close()
    return size > 0
end

-- ---------------------------------------------------------------------------
-- v3 manifest / entries / intent files
-- ---------------------------------------------------------------------------

function Overlay.entriesPath(dir, provider_id)
    return dir .. "/entries/" .. provider_slug(provider_id) .. ".json"
end

function Overlay.loadManifest(dir)
    local path = dir
    if not path:match("manifest%.json$") then path = dir .. "/manifest.json" end
    local data = read_json(path)
    if not data or data.version ~= 3 or type(data.providers) ~= "table" then
        return nil
    end
    return data
end

-- Every successful write bumps revision (design 6.3); callers never manage
-- the counter themselves.  The passed table is updated in place.
function Overlay.saveManifest(dir, manifest)
    if type(manifest) ~= "table" then return false end
    local previous = manifest.revision
    manifest.revision = (tonumber(manifest.revision) or 0) + 1
    local ok, encoded = pcall(JSON.encode, manifest)
    if not ok or not encoded then
        manifest.revision = previous
        return false
    end
    if not mkdir_p(dir) or not write_file(dir .. "/manifest.json", encoded) then
        manifest.revision = previous
        return false
    end
    return true
end

function Overlay.removeManifest(dir)
    os.remove(dir .. "/manifest.json")
    return not Overlay.exists(dir .. "/manifest.json")
end

-- Parsed-entries cache: every style rebuild used to re-decode the whole
-- entries file (452 ms for 1.2 MB on a Kindle Voyage), which dominated the
-- "CSS build" number.  Keep the decoded document keyed by path + stat, with
-- its own budget (the JSON text is a fair proxy for the decoded tables, and
-- the 8 MB CSS budget does not cover them).  Writers invalidate explicitly
-- because FAT32 mtime has ~2 s granularity.
local entries_cache = {}
local entries_order = {}
local entries_total = 0
local ENTRIES_CACHE_BYTES = 8 * 1024 * 1024
local cache_stats = {
    css_builds = 0, css_hits = 0,
    entries_loads = 0, entries_hits = 0,
    template_hits = 0, template_misses = 0, template_writes = 0,
}

local function entries_cache_drop(path)
    local cached = entries_cache[path]
    if not cached then return end
    entries_total = entries_total - cached.bytes
    entries_cache[path] = nil
    for index, key in ipairs(entries_order) do
        if key == path then
            table.remove(entries_order, index)
            break
        end
    end
end

local function entries_cache_get(path, emtime, esize)
    local cached = entries_cache[path]
    if not cached then return nil end
    if cached.emtime ~= emtime or cached.esize ~= esize then
        entries_cache_drop(path)
        return nil
    end
    for index, key in ipairs(entries_order) do
        if key == path then
            table.remove(entries_order, index)
            break
        end
    end
    table.insert(entries_order, 1, path)
    cache_stats.entries_hits = cache_stats.entries_hits + 1
    return cached.doc
end

local function entries_cache_store(path, emtime, esize, doc)
    entries_cache_drop(path)
    entries_cache[path] = {
        emtime = emtime, esize = esize, bytes = esize, doc = doc,
    }
    entries_total = entries_total + esize
    table.insert(entries_order, 1, path)
    -- Evict least recently used until the budget fits, but always keep the doc
    -- just stored: a single entries file larger than 8 MB (a 10k+ paragraph
    -- book) is still cheaper to hold than to re-decode on every style change.
    -- The budget is therefore a soft cap for that one case.
    while entries_total > ENTRIES_CACHE_BYTES and #entries_order > 1 do
        entries_cache_drop(table.remove(entries_order))
    end
end

function Overlay.clearEntriesCache()
    entries_cache = {}
    entries_order = {}
    entries_total = 0
end

-- ---------------------------------------------------------------------------
-- Precompiled rule template (style-independent)
--
-- Every generated rule differs only in three style values (colour, size, font
-- stack).  Decoding the 1.2 MB entries JSON to re-format 3,000 rules costs
-- ~450 ms on a Kindle Voyage; reading the precompiled rules and substituting
-- the three values is an order of magnitude cheaper.  Store.importResult
-- writes this file right after an import, and every cold build refreshes it,
-- so the next process can skip the JSON decode entirely.
--
-- The placeholders are NUL-delimited: css_string() strips NUL from
-- translations, so a translation can never collide with one.
local CSS_TEMPLATE_FILE = "css-template.css"
-- Bump whenever the rule text, placeholder set or on-disk layout changes;
-- the key otherwise has no way to tell an old compiled sheet from a new one.
local TEMPLATE_FORMAT = "2"
local TEMPLATE_COLOR = "\0DT_COLOR\0"
local TEMPLATE_SIZE = "\0DT_SIZE\0"
local TEMPLATE_FONT_CSS = "\0DT_FONT_CSS\0"

-- Solving the token substitution with gsub costs ~140 ms on the device: the
-- pattern engine has to walk the whole 1.2 MB twice (scan + rebuild) and call
-- into Lua for every rule.  The file therefore stores the static text and a
-- 5-byte-per-token index (kind + uint32 offset) instead, and the sheet is
-- rebuilt with string.sub + table.concat (~32 ms, no pattern scan).
local TEMPLATE_KIND_COLOR = 1
local TEMPLATE_KIND_SIZE = 2
local TEMPLATE_KIND_FONT = 3

-- On-disk templates live next to each book's entries (~1.2 MB each), so a
-- large library can pin tens of megabytes forever.  Reclaim templates that
-- have not been used for 30 days, then enforce a 50 MB total cap (oldest
-- first); the book currently open is never touched.  Usage updates mtime when
-- a template is read, so the age is "last opened", not "last written".
local TEMPLATE_GC_MAX_AGE_DAYS = 30
local TEMPLATE_GC_MAX_BYTES = 50 * 1024 * 1024
local TEMPLATE_GC_MAX_REMOVE = 20
local TEMPLATE_GC_INTERVAL = 6 * 60 * 60
local last_template_gc = 0

-- Only the most recent book is kept: this is the hot path for repeated font
-- size changes, and one extra 1.2 MB string is cheaper than re-reading and
-- re-indexing the file every time.
local template_cache = { dir = nil, key = nil, template = nil }
-- Read-only cache dir / full disk: retrying a 1.2 MB write on every cold build
-- makes things worse.  The in-memory template is still cached below, so style
-- changes keep the fast path; only the on-disk copy is skipped.
local template_write_failures = {}

local function normalize_dir(dir)
    if not dir or dir == "" then return dir end
    -- Collapse duplicate separators as well as a trailing one: the reclaimer
    -- compares the current book by string equality, and a caller that builds
    -- the path as ".../books//<hash>" must not quietly lose that protection.
    dir = dir:gsub("//+", "/")
    if dir ~= "/" then dir = dir:gsub("/+$", "") end
    -- Store.bookDir may hand back "./cache/..." while a CLI/bench passes an
    -- absolute path.  The template key embeds dir, so resolve both to the same
    -- string or the two processes would rewrite the same file under different
    -- keys and never hit each other's work.
    if dir ~= "/" and dir:sub(1, 1) ~= "/" then
        local cwd = lfs.currentdir()
        if cwd then
            dir = cwd .. "/" .. dir:gsub("^%./", "")
        end
    end
    return dir
end

local function template_path(dir)
    return normalize_dir(dir) .. "/" .. CSS_TEMPLATE_FILE
end

local function read_template_key(dir)
    local file = io.open(template_path(dir), "rb")
    if not file then return nil end
    local key = file:read("*l")
    file:close()
    return key
end

local function read_template(dir)
    local raw = read_file(template_path(dir))
    if not raw then return nil end
    local first = raw:find("\n", 1, true)
    if not first then return nil end
    local second = raw:find("\n", first + 1, true)
    if not second then return nil end
    local key = raw:sub(1, first - 1)
    local count, data_len = raw:sub(first + 1, second - 1):match("^v2 (%d+) (%d+)$")
    if not count then return nil end
    count, data_len = tonumber(count), tonumber(data_len)
    local index_start = second + 1
    local data_start = index_start + count * 5
    if data_start - 1 > #raw then return nil end
    local data = raw:sub(data_start)
    if #data ~= data_len then return nil end
    -- The writer's static text never contains NUL (css_string strips it), so a
    -- NUL means the data section was truncated/zeroed without a length change;
    -- reject it instead of emitting garbage and re-hitting the same file.
    if data:find("\0", 1, true) then return nil end
    local index = raw:sub(index_start, data_start - 1)
    -- Reject a corrupted index instead of emitting mangled rules.  The check
    -- is ~9k byte reads on a 3,133-rule book and runs once per cold read.
    local previous = 0
    for i = 0, count - 1 do
        local kind, b1, b2, b3, b4 = index:byte(i * 5 + 1, i * 5 + 5)
        if not kind or not b4 then return nil end
        local offset = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        if kind < TEMPLATE_KIND_COLOR or kind > TEMPLATE_KIND_FONT
            or offset < previous or offset > data_len then
            return nil
        end
        previous = offset
    end
    return key, {
        index = index,
        data = data,
        count = count,
    }
end

-- mtime is the template's last-use marker for the reclaimer below.  Failure
-- (read-only card) is harmless: the file simply ages out sooner.
local function touch_template(dir)
    if not lfs.touch then return false end
    local path = template_path(dir)
    -- Only touch an existing template (defensive: keep some lfs builds from
    -- creating a 0-byte placeholder on touch).
    if not lfs.attributes(path, "size") then return false end
    local now = os.time()
    return pcall(lfs.touch, path, now, now)
end

-- Record "this book was opened" for the reclaimer, even when translations are
-- hidden and no template is read.  A missing template remains missing.
function Overlay.touchCssTemplate(dir)
    if not dir or dir == "" then return false end
    if dir:match("manifest%.json$") then
        dir = dir:match("^(.*)/manifest%.json$") or dir
    end
    return touch_template(normalize_dir(dir))
end

local function load_template(dir, key)
    if template_cache.dir == dir and template_cache.key == key and template_cache.template then
        return template_cache.template
    end
    -- Read the (tiny) key line first: after a checkpoint the key almost always
    -- differs, and pulling 1.2 MB just to reject it would be wasted I/O.
    if read_template_key(dir) ~= key then return nil end
    local saved_key, template = read_template(dir)
    if saved_key == key then
        template_cache = { dir = dir, key = key, template = template }
        touch_template(dir)
        return template
    end
    return nil
end

-- Turn the NUL-token form into (index, static text).  Offsets are 0-based
-- byte positions in the static text.
local function encode_template(body)
    local chunks, index, count, offset = {}, {}, 0, 0
    local pos = 1
    while true do
        local start, finish, name = body:find("%zDT_([A-Z_]+)%z", pos)
        if not start then
            chunks[#chunks + 1] = body:sub(pos)
            offset = offset + #chunks[#chunks]
            break
        end
        local text = body:sub(pos, start - 1)
        chunks[#chunks + 1] = text
        offset = offset + #text
        local kind = name == "COLOR" and TEMPLATE_KIND_COLOR
            or name == "SIZE" and TEMPLATE_KIND_SIZE or TEMPLATE_KIND_FONT
        index[#index + 1] = string.char(kind,
            offset % 256, math.floor(offset / 256) % 256,
            math.floor(offset / 65536) % 256, math.floor(offset / 16777216) % 256)
        count = count + 1
        pos = finish + 1
    end
    return table.concat(index), table.concat(chunks), count, offset
end

local function cache_template(dir, key, index, data, count)
    local template = { index = index, data = data, count = count }
    template_cache = { dir = dir, key = key, template = template }
    return template
end

local function write_template(dir, key, index, data, count, data_len)
    local payload = string.format("%s\nv2 %d %d\n", key, count, data_len) .. index .. data
    return write_file(template_path(dir), payload)
end

function Overlay.clearTemplateCache()
    template_cache = { dir = nil, key = nil, template = nil }
end

function Overlay.removeCssTemplate(dir)
    if not dir or dir == "" then return false end
    if dir:match("manifest%.json$") then
        dir = dir:match("^(.*)/manifest%.json$") or dir
    end
    dir = normalize_dir(dir)
    if template_cache.dir == dir then
        Overlay.clearTemplateCache()
    end
    template_write_failures[dir] = nil
    os.remove(template_path(dir))
    return not Overlay.exists(template_path(dir))
end

local function apply_style(template, color, size, font_css)
    local values = {
        [TEMPLATE_KIND_COLOR] = color,
        [TEMPLATE_KIND_SIZE] = size,
        [TEMPLATE_KIND_FONT] = font_css,
    }
    local index, data, count = template.index, template.data, template.count
    local parts, previous = {}, 1
    for i = 0, count - 1 do
        local base = i * 5
        local kind, b1, b2, b3, b4 = index:byte(base + 1, base + 5)
        local offset = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216 + 1
        if offset > previous then
            parts[#parts + 1] = data:sub(previous, offset - 1)
        end
        parts[#parts + 1] = values[kind] or ""
        previous = offset
    end
    if previous <= #data then parts[#parts + 1] = data:sub(previous) end
    return table.concat(parts)
end

-- Reclaim on-disk templates.  Two independent limits:
--   1) templates not read for max_age_days;
--   2) total bytes above max_bytes, deleting the least recently used first.
-- The current book is skipped, and only the exact css-template.css file is
-- removed: entries and manifest stay intact.  Throttled per process unless
-- opts.force is set.  Returns a report instead of failing the caller.
function Overlay.reclaimCssTemplates(books_root, current_dir, opts)
    opts = opts or {}
    if not books_root or books_root == "" then
        return { skipped = "no_root" }
    end
    books_root = normalize_dir(books_root)
    if books_root ~= "books" and not books_root:match("/books$") then
        return { skipped = "not_books" }
    end
    local now = os.time()
    local interval = tonumber(opts.interval) or TEMPLATE_GC_INTERVAL
    if not opts.force and last_template_gc > 0 and now - last_template_gc < interval then
        return { skipped = "throttled" }
    end
    current_dir = current_dir and normalize_dir(current_dir) or nil
    local max_age = (tonumber(opts.max_age_days) or TEMPLATE_GC_MAX_AGE_DAYS) * 86400
    local max_bytes = tonumber(opts.max_bytes) or TEMPLATE_GC_MAX_BYTES
    local max_remove = tonumber(opts.max_remove) or TEMPLATE_GC_MAX_REMOVE
    local candidates = {}
    local removed, freed, deferred = 0, 0, false
    local ok, iterator, state = pcall(lfs.dir, books_root)
    if not ok or not iterator then
        return { skipped = "no_books_dir" }
    end
    local function entry_mode(path)
        -- Current KOReader builds ship symlinkattributes.  If an older build
        -- lacks it, this follows links; the books root is still the same
        -- internal cache path, so the fallback only loses link hardening.
        if lfs.symlinkattributes then return lfs.symlinkattributes(path, "mode") end
        return lfs.attributes(path, "mode")
    end
    for name in iterator, state do
        if name ~= "." and name ~= ".." then
            local dir = books_root .. "/" .. name
            -- symlinkattributes: a symlinked cache dir or template must never
            -- lead the reclaimer outside the books root.
            if entry_mode(dir) == "directory" then
                local path = dir .. "/" .. CSS_TEMPLATE_FILE
                if entry_mode(path) == "file" then
                    local mtime = lfs.attributes(path, "modification")
                    local size = lfs.attributes(path, "size")
                    if mtime and size then
                        local current = current_dir ~= nil and normalize_dir(dir) == current_dir
                        if not current and mtime < now - max_age then
                            if removed < max_remove and os.remove(path) then
                                removed = removed + 1
                                freed = freed + size
                            else
                                if removed >= max_remove then deferred = true end
                                candidates[#candidates + 1] = {
                                    path = path, mtime = mtime, size = size, current = current,
                                }
                            end
                        else
                            candidates[#candidates + 1] = {
                                path = path, mtime = mtime, size = size, current = current,
                            }
                        end
                    end
                end
            end
        end
    end
    local total, kept = 0, #candidates
    for _, item in ipairs(candidates) do total = total + item.size end
    if total > max_bytes then
        table.sort(candidates, function(a, b)
            if a.mtime == b.mtime then return a.path < b.path end
            return a.mtime < b.mtime
        end)
        for _, item in ipairs(candidates) do
            if total <= max_bytes then break end
            if not item.current then
                if removed >= max_remove then
                    deferred = true
                    break
                end
                if os.remove(item.path) then
                    removed = removed + 1
                    freed = freed + item.size
                    total = total - item.size
                    kept = kept - 1
                end
            end
        end
    end
    last_template_gc = now
    return {
        removed = removed,
        freed_bytes = freed,
        total_bytes = total,
        kept = kept,
        deferred = deferred,
    }
end

-- LuaJSON emits table keys in hash order, so revision is sometimes before the
-- entries array and sometimes after it.  The fast path reads the first bytes;
-- when that does not contain the header we scan the raw text (still much
-- cheaper than decoding 1.2 MB of JSON).  An escaped quote inside a
-- translation is skipped, so text like \"revision\":1 cannot be mistaken for
-- the document field.
local function revision_in_text(raw, from)
    local pos = from or 1
    while true do
        local start, finish = raw:find('"revision"', pos, true)
        if not start then return nil end
        if raw:sub(start - 1, start - 1) ~= "\\" then
            local value = tonumber(raw:sub(finish + 1, finish + 40):match("^%s*:%s*(%d+)"))
            if value then return value end
        end
        pos = finish + 1
    end
end

-- Fallback-heavy books can have several entries files.  Re-reading a file to
-- find its revision on every colour/font change would defeat the template, so
-- cache (path, mtime, size) -> revision.  Inside the FAT32 ~2 s window the
-- stats are not trustworthy and the file is re-read; saveEntries/deleteEntries
-- also drop the entry explicitly.
local revision_cache = {}

local function forget_revision(path)
    revision_cache[path] = nil
end

local function peek_entries_revision(path)
    local emtime = lfs.attributes(path, "modification")
    local esize = lfs.attributes(path, "size")
    local cached = revision_cache[path]
    local trustworthy = emtime ~= nil and (os.time() - emtime) > 3
    if cached and trustworthy and cached.emtime == emtime and cached.esize == esize then
        return cached.revision
    end
    local file = io.open(path, "rb")
    if not file then return nil end
    local head = file:read(256)
    if not head then
        file:close()
        return nil
    end
    local revision = revision_in_text(head)
    if not revision then
        -- The remainder alone does not know where head ended; seek back and
        -- read the whole file.  Scanning a remainder from an offset would
        -- silently skip the first ~244 bytes and could miss the only field.
        file:seek("set", 0)
        local raw = file:read("*a")
        if raw then revision = revision_in_text(raw) end
    end
    file:close()
    if revision and emtime and esize then
        revision_cache[path] = { emtime = emtime, esize = esize, revision = revision }
    end
    return revision
end

function Overlay.clearRevisionCache()
    revision_cache = {}
end

function Overlay.loadEntries(dir, provider_id)
    local path = Overlay.entriesPath(dir, provider_id)
    local emtime = lfs.attributes(path, "modification")
    local esize = lfs.attributes(path, "size")
    if emtime and esize then
        local cached = entries_cache_get(path, emtime, esize)
        if cached then return cached end
    end
    cache_stats.entries_loads = cache_stats.entries_loads + 1
    local data = read_json(path)
    if not data or data.version ~= 3 or type(data.entries) ~= "table" then
        return nil
    end
    -- Entries written before 3.2.0 may hold two shapes of the same paragraph;
    -- reading through the same rule as the writers means an upgraded book stops
    -- drawing both layers before it is ever re-translated.
    data.entries = Overlay.dedupeEntries(data.entries)
    if emtime and esize then
        entries_cache_store(path, emtime, esize, data)
    end
    -- The returned doc can be the cached table itself: callers must treat it
    -- as read-only and copy the rows they want to change (the import and
    -- checkpoint paths already build a fresh array).
    return data
end

-- Entries lead the manifest by one revision (design 8.2): writers land the
-- entries revision first so a crash before the manifest write still
-- invalidates the CSS cache through max(manifest.revision, entries.revision).
function Overlay.saveEntries(dir, provider_id, entries_doc)
    if not provider_id or provider_id == "" or type(entries_doc) ~= "table" then
        return false
    end
    local entries = entries_doc.entries
    if type(entries) ~= "table" then entries = entries_doc end
    entries = Overlay.dedupeEntries(entries)
    local manifest = Overlay.loadManifest(dir)
    local doc = {
        version = 3,
        revision = (manifest and tonumber(manifest.revision) or 0) + 1,
        provider = provider_id,
        target_lang = entries_doc.target_lang
            or (manifest and manifest.target_lang) or "",
        entries = entries,
    }
    local ok, encoded = pcall(JSON.encode, doc)
    if not ok or not encoded then return false end
    if not mkdir_p(dir .. "/entries") then return false end
    local path = Overlay.entriesPath(dir, provider_id)
    if not write_file(path, encoded) then return false end
    -- A successful write means the filesystem is writable again; allow the
    -- template write to recover after an earlier disk-full failure.
    template_write_failures[dir] = nil
    -- Same-second rewrites may keep mtime and size, so drop the parsed doc
    -- and the revision peek here instead of relying on the stat check.
    entries_cache_drop(path)
    forget_revision(path)
    return true
end

function Overlay.deleteEntries(dir, provider_id)
    if not dir or dir == "" or not provider_id or provider_id == "" then return false end
    local base = dir .. "/entries/" .. provider_slug(provider_id)
    os.remove(base .. ".json")
    os.remove(base .. ".ndjson")
    entries_cache_drop(base .. ".json")
    forget_revision(base .. ".json")
    -- The precompiled template merges every visible provider, so removing any
    -- one of them makes the whole file stale.  Drop it (and the in-memory
    -- copy) instead of keeping up to 1.2 MB of rules that can never be used.
    Overlay.removeCssTemplate(dir)
    return not Overlay.exists(base .. ".json") and not Overlay.exists(base .. ".ndjson")
end

function Overlay.saveIntent(dir, intent)
    if type(intent) ~= "table" then return false end
    local ok, encoded = pcall(JSON.encode, intent)
    if not ok or not encoded then return false end
    if not mkdir_p(dir) then return false end
    return write_file(dir .. "/delete.pending.json", encoded)
end

function Overlay.loadIntent(dir)
    local data = read_json(dir .. "/delete.pending.json")
    if not data or type(data.op) ~= "string" then return nil end
    return data
end

function Overlay.clearIntent(dir)
    os.remove(dir .. "/delete.pending.json")
    return not Overlay.exists(dir .. "/delete.pending.json")
end

-- External writers (dtctl, i.e. an MCP commit) leave a reload.signal so a
-- running plugin knows the overlay changed.  The payload carries a monotonic
-- seq (the manifest revision) instead of relying on mtime: FAT32 timestamps
-- only have ~2 s granularity, so two imports in the same second would
-- otherwise be silently skipped (design 10.7).
function Overlay.saveSignal(dir, payload)
    if type(payload) ~= "table" then return false end
    local ok, encoded = pcall(JSON.encode, payload)
    if not ok or not encoded then return false end
    if not mkdir_p(dir) then return false end
    return write_file(dir .. "/reload.signal", encoded)
end

function Overlay.loadSignal(dir)
    local data = read_json(dir .. "/reload.signal")
    if not data or type(data.seq) ~= "number" then return nil end
    return data
end

-- A running reader only refreshes when seq grows, and "delete every
-- translation" removes the manifest so the next import starts again at
-- revision 1.  Bumping against max(revision, previous seq) keeps the signal
-- monotonic across delete + re-import; every external writer (Store.importResult,
-- dtctl) must go through here instead of copying the revision (design 10.7).
function Overlay.bumpSignal(dir, payload)
    if type(payload) ~= "table" then return nil end
    local manifest = Overlay.loadManifest(dir)
    local previous = Overlay.loadSignal(dir)
    local revision = manifest and tonumber(manifest.revision) or 0
    local last = previous and tonumber(previous.seq) or 0
    local seq = math.max(revision, last) + 1
    payload.seq = seq
    payload.at = payload.at or os.time()
    if not Overlay.saveSignal(dir, payload) then return nil end
    return seq
end

-- Same-shaped book index for v3 manifests and legacy v2 overlays, so display
-- and page-translation code can ask one API before/after migration.
-- Top-level complete/chapters mirror the resolved display provider.
local function resolve_display_provider(manifest, override)
    if override and override ~= "" then return override end
    if manifest.display_mode == "manual" then return manifest.display_provider end
    local best, best_at
    for pid, at in pairs(manifest.last_used_at or {}) do
        if manifest.providers[pid]
            and (not best_at or at > best_at or (at == best_at and pid > best)) then
            best, best_at = pid, at
        end
    end
    return best or manifest.display_provider
end

function Overlay.loadBookIndex(dir_or_path)
    local dir = dir_or_path
    if dir:match("manifest%.json$") or dir:match("overlay%.json$") then
        dir = dir:match("^(.*)/[^/]+$") or dir
    end
    local manifest = Overlay.loadManifest(dir)
    if manifest then
        local index = manifest
        local pid = resolve_display_provider(manifest)
        local provider = pid and manifest.providers[pid]
        index.complete = provider and provider.complete == true or false
        index.chapters = provider and provider.chapters or {}
        return index
    end
    local path = dir .. "/overlay.json"
    local data = Overlay.load(path)
    if not data then return nil end
    local pid = data.provider
    if not pid or pid == "" then pid = "legacy" end
    local updated_at = lfs.attributes(path, "modification") or 0
    local chapters = type(data.chapters) == "table" and data.chapters or {}
    local complete = data.complete == true
    return {
        version = 2,
        book_path = data.book_path,
        source_lang = data.source_lang,
        target_lang = data.target_lang,
        spine_count = 0,
        book_size = 0,
        book_mtime = 0,
        display_mode = "manual",
        display_provider = pid,
        display_fallback = false,
        fallback_order = { pid },
        last_used_at = { [pid] = updated_at },
        providers = {
            [pid] = {
                display_name = pid,
                kind = provider_kind(pid),
                confirmed = true,
                chapters = chapters,
                partial_chapters = {},
                failed_chapters = {},
                complete = complete,
                translated_count = count_unique_selectors(data.entries),
                updated_at = updated_at,
            },
        },
        complete = complete,
        chapters = chapters,
    }
end

-- A replaced book file (same path, new edition) invalidates the overlay.
-- Recorded 0 means "unknown at write time" and never marks the book stale.
function Overlay.isStale(manifest, book_path)
    if type(manifest) ~= "table" or not book_path then return false end
    local size = tonumber(manifest.book_size) or 0
    local mtime = tonumber(manifest.book_mtime) or 0
    if size == 0 and mtime == 0 then return false end
    local current_size = lfs.attributes(book_path, "size")
    local current_mtime = lfs.attributes(book_path, "modification")
    if not current_size or not current_mtime then return false end
    if size ~= 0 and current_size ~= size then return true end
    if mtime ~= 0 and current_mtime ~= mtime then return true end
    return false
end

-- Serialize a user font setting into a valid CSS font-family value.
-- Multi-word family names ("Noto Serif CJK SC") must be quoted, but the CSS
-- generic families (serif, sans-serif, ...) must NOT be quoted.  Quoted parts
-- the user already wrote are kept as-is.
local generic_families = {
    ["serif"] = true, ["sans-serif"] = true, ["monospace"] = true,
    ["cursive"] = true, ["fantasy"] = true, ["system-ui"] = true,
}
function Overlay.cssFontFamily(value)
    if not value or value == "" then return "" end
    local parts = {}
    for part in tostring(value):gmatch("[^,]+") do
        part = part:gsub("^%s+", ""):gsub("%s+$", "")
        if part ~= "" then
            if generic_families[part] then
                table.insert(parts, part)
            elseif part:match("^['\"]") and part:match("['\"]$") then
                table.insert(parts, part)
            else
                table.insert(parts, '"' .. part .. '"')
            end
        end
    end
    return table.concat(parts, ", ")
end

-- CREngine implements generated ::before/::after content as real layout
-- nodes.  It therefore participates in pagination without touching EPUB
-- XHTML.  Rebuilding this CSS only changes the visible layers.
--
-- Cache policy (design 8.2): one entry per book plus a global 8 MB budget
-- with LRU eviction.  The revision fields enter the key because FAT32 mtime
-- has ~2 s granularity: a same-second rewrite must still invalidate.
local css_cache = {}
local cache_order = {}
local cache_total = 0
local CSS_CACHE_BYTES = 8 * 1024 * 1024

local function cache_touch(book_key)
    for index, key in ipairs(cache_order) do
        if key == book_key then
            table.remove(cache_order, index)
            break
        end
    end
    table.insert(cache_order, 1, book_key)
end

local function cache_store(book_key, entry)
    local previous = css_cache[book_key]
    if previous then
        cache_total = cache_total - previous.size
        for index, key in ipairs(cache_order) do
            if key == book_key then
                table.remove(cache_order, index)
                break
            end
        end
    end
    css_cache[book_key] = entry
    cache_total = cache_total + entry.size
    table.insert(cache_order, 1, book_key)
    while cache_total > CSS_CACHE_BYTES and #cache_order > 1 do
        local victim = table.remove(cache_order)
        cache_total = cache_total - css_cache[victim].size
        css_cache[victim] = nil
    end
end

function Overlay.clearCssCache()
    css_cache = {}
    cache_order = {}
    cache_total = 0
    -- Parsed entries are not cleared here on purpose: their writers
    -- (saveEntries / deleteEntries) drop the exact path, and callers such as
    -- the display-provider switch only change which provider is drawn.  Wiping
    -- every doc there would re-decode 1.2 MB (~450 ms) for nothing.
    -- The one write that bypasses those helpers (reconcile removing an orphan
    -- entries file) is covered by the stat check in loadEntries: the file is
    -- gone, so mtime/size are nil and the cache is not consulted.
end

-- Diagnostics for tests and tools: counters plus current cache occupancy.
function Overlay.cacheStats()
    return {
        css_builds = cache_stats.css_builds,
        css_hits = cache_stats.css_hits,
        entries_loads = cache_stats.entries_loads,
        entries_hits = cache_stats.entries_hits,
        entries_bytes = entries_total,
        entries_budget = ENTRIES_CACHE_BYTES,
        css_entries = #cache_order,
        css_bytes = cache_total,
        css_budget = CSS_CACHE_BYTES,
        template_hits = cache_stats.template_hits,
        template_misses = cache_stats.template_misses,
        template_writes = cache_stats.template_writes,
    }
end

local function rule_style(options)
    local color = options.translation_color or "#666666"
    local size = options.translation_size or "1em"
    -- Empty font family inherits the paragraph's own font (default).
    local font_family = options.translation_font_family
    local font_family_css = ""
    if font_family and font_family ~= "" then
        font_family_css = "font-family:" .. Overlay.cssFontFamily(font_family) .. "!important;"
    end
    return color, size, font_family_css
end

-- A selector may already name the pseudo-element: a list parent's translation
-- is attached to its child list, so the entry is stored as
-- "... > li:nth-of-type(2) > ol:nth-of-type(1)::before".
-- Fallback only: entries carry the indent measured from the book's own
-- stylesheets (dualtranslate_listindent.lua); this value is used for overlays
-- written before that field existed.
local LIST_TRANSLATION_OFFSET = "-1.5em"

local function split_pseudo(selector)
    if selector:sub(-8) == "::before" then
        return selector:sub(1, -9), "::before"
    end
    if selector:sub(-7) == "::after" then
        return selector:sub(1, -8), "::after"
    end
    return selector, "::after"
end

-- The book-derived indent for a list-parent entry, already in CSS units.
local function list_offset(entry)
    local indent = type(entry) == "table" and entry.list_indent or nil
    if type(indent) == "string" and indent:match("^%d+%.?%d*em$") then
        return "-" .. indent
    end
    return LIST_TRANSLATION_OFFSET
end

local function append_rule(rules, selector, entry, color, size, font_family_css)
    local base, pseudo = split_pseudo(selector)
    local translation = type(entry) == "table" and entry.translation or entry
    -- A list parent's translation rides on its child list, so the box starts at
    -- the child items' indent; pull it back by exactly that indent to line up
    -- with the parent's own text.
    local margin = "margin:0!important;"
    if pseudo == "::before" then
        local tag = base:match("([%a]+):nth%-of%-type%(%d+%)$")
        if tag == "ol" or tag == "ul" then
            -- CREngine pins a generated box to the list's content edge and
            -- ignores margin/position/text-indent on it, so the offset has to
            -- come from the list itself: drop its indent and give the same
            -- amount back to the items.  The ::before then starts where the
            -- parent's own text does, and the items stay where they were.
            local indent = list_offset(entry):sub(2)
            table.insert(rules, string.format(
                "%s{margin-left:0!important;padding-left:0!important;}", base))
            table.insert(rules, string.format(
                "%s > li{margin-left:%s!important;}", base, indent))
        end
    end
    table.insert(rules, string.format(
        "%s%s{content:%s!important;display:block!important;white-space:pre-wrap!important;color:%s!important;font-size:%s!important;%sline-height:130%%!important;%spadding:0!important;}",
        base, pseudo, css_string(translation), color, size, font_family_css, margin))
end

local function build_css(path, options)
    local data = Overlay.load(path)
    if not data then return "" end
    options = options or {}
    local translation_visible = options.translation_visible == true
    local color, size, font_family_css = rule_style(options)
    local rules = {
        "/* DualTranslate non-destructive generated layers */",
    }
    for _, entry in ipairs(data.entries) do
        local selector = entry.selector
        if selector and selector ~= "" then
            if translation_visible and entry.translation and entry.translation ~= "" then
                append_rule(rules, selector, entry, color, size, font_family_css)
            end
        end
    end
    return table.concat(rules, "\n")
end

local function build_css_legacy(path, options)
    -- When the mtime cannot be read (no overlay yet, exotic filesystem) skip
    -- the cache entirely rather than risk serving stale CSS.
    local mtime = lfs.attributes(path, "modification")
    if not mtime then return build_css(path, options) end
    local key = table.concat({
        tostring(path), tostring(mtime),
        options.translation_visible == true and "1" or "0",
        tostring(options.translation_color or ""),
        tostring(options.translation_size or ""),
        tostring(options.translation_font_family or ""),
    }, "|")
    local cached = css_cache[path]
    if cached and cached.key == key then
        cache_touch(path)
        return cached.css
    end
    local css = build_css(path, options)
    cache_store(path, { key = key, css = css, size = #css })
    return css
end

-- The providers whose entries actually enter one stylesheet, in display
-- order (primary first, then the fallback list).  Missing files are skipped:
-- they contribute no rules and must not keep the template key alive.
local function selected_providers(dir, manifest, provider, fallback)
    local selected = { provider }
    if fallback then
        for _, pid in ipairs(manifest.fallback_order or {}) do
            if pid ~= provider and manifest.providers[pid]
                and lfs.attributes(Overlay.entriesPath(dir, pid), "size") then
                selected[#selected + 1] = pid
            end
        end
    end
    return selected
end

-- Key for the on-disk rule template.  Style is intentionally absent: colour,
-- size and font are substituted when the file is read.  Everything that
-- changes which rules exist is present (display resolution, manifest
-- revision, each provider's file identity and revision).
local function template_key(dir, manifest, provider, fallback, selected, revisions)
    local parts = {
        dir,
        TEMPLATE_FORMAT,
        tostring(manifest.display_mode or "auto"),
        tostring(tonumber(manifest.revision) or 0),
        provider,
        fallback and "1" or "0",
    }
    for _, pid in ipairs(selected) do
        local path = Overlay.entriesPath(dir, pid)
        local emtime = lfs.attributes(path, "modification")
        local esize = lfs.attributes(path, "size")
        if not emtime or not esize then return nil end
        local revision = revisions and revisions[pid]
        if revision == nil then revision = peek_entries_revision(path) end
        if revision == nil then return nil end
        parts[#parts + 1] = table.concat({
            pid, tostring(emtime), tostring(esize), tostring(revision),
        }, "\1")
    end
    return table.concat(parts, "\1")
end

local function render_v3(dir, selected, docs, color, size, font_family_css)
    local by_selector, order = {}, {}
    for _, pid in ipairs(selected) do
        local doc = docs and docs[pid] or Overlay.loadEntries(dir, pid)
        if doc then
            for _, entry in ipairs(doc.entries or {}) do
                local selector = entry.selector
                if selector and selector ~= "" and entry.translation and entry.translation ~= ""
                    and by_selector[selector] == nil then
                    by_selector[selector] = entry
                    order[#order + 1] = selector
                end
            end
        end
    end
    local rules = {
        "/* DualTranslate non-destructive generated layers */",
    }
    for _, selector in ipairs(order) do
        append_rule(rules, selector, by_selector[selector], color, size, font_family_css)
    end
    return table.concat(rules, "\n")
end

-- Precompile the rules for the manifest's current display selection.  Called
-- after an import so the first open (and every later cold start) can skip the
-- entries JSON decode.  Style is not part of the key, so a later font-size or
-- colour change still hits this file.
function Overlay.warmCssTemplate(dir, entries_doc, entries_provider)
    if not dir or dir == "" then return false end
    if dir:match("manifest%.json$") then
        dir = dir:match("^(.*)/manifest%.json$") or dir
    end
    dir = normalize_dir(dir)
    local manifest = Overlay.loadManifest(dir)
    if not manifest then return false end
    local provider = resolve_display_provider(manifest)
    if not provider or not manifest.providers[provider] then return false end
    local fallback = manifest.display_fallback
    if fallback == nil then fallback = true end
    fallback = fallback == true
    local selected = selected_providers(dir, manifest, provider, fallback)
    local docs, revisions = {}, {}
    if entries_doc and entries_provider then
        -- The import/checkpoint already has the fresh rows in memory; using
        -- them avoids a second 0.5 s decode inside the book lock.  This also
        -- applies when the freshly written provider is a fallback, while the
        -- display provider itself still comes from disk.
        local doc = entries_doc.entries and entries_doc or { entries = entries_doc }
        docs[entries_provider] = doc
        -- The file is the source of truth for the revision; manifest.revision
        -- may be behind in the crash window.
        revisions[entries_provider] = peek_entries_revision(
            Overlay.entriesPath(dir, entries_provider))
            or tonumber(doc.revision) or tonumber(manifest.revision) or 0
    end
    local primary = docs[provider] or Overlay.loadEntries(dir, provider)
    if not primary then return false end
    docs[provider] = primary
    revisions[provider] = revisions[provider] or tonumber(primary.revision) or 0
    for _, pid in ipairs(selected) do
        if pid ~= provider then
            local doc = docs[pid] or Overlay.loadEntries(dir, pid)
            docs[pid] = doc
            revisions[pid] = doc and (tonumber(doc.revision) or 0) or nil
        end
    end
    local key = template_key(dir, manifest, provider, fallback, selected, revisions)
    if not key then return false end
    if read_template_key(dir) == key then
        touch_template(dir)
        return true
    end
    local body = render_v3(dir, selected, docs,
        TEMPLATE_COLOR, TEMPLATE_SIZE, TEMPLATE_FONT_CSS)
    local index, data, count, data_len = encode_template(body)
    cache_template(dir, key, index, data, count)
    if template_write_failures[dir] then return false end
    local ok = write_template(dir, key, index, data, count, data_len)
    if ok then
        cache_stats.template_writes = cache_stats.template_writes + 1
    else
        template_write_failures[dir] = true
    end
    return ok
end

local function build_css_v3(manifest_path, options)
    local dir = normalize_dir(manifest_path:match("^(.*)/manifest%.json$") or manifest_path)
    manifest_path = dir .. "/manifest.json"
    local manifest = Overlay.loadManifest(dir)
    if not manifest then return "" end
    if options.translation_visible ~= true then return "" end
    local provider = resolve_display_provider(manifest, options.provider)
    if not provider or not manifest.providers[provider] then return "" end
    local fallback = options.fallback
    if fallback == nil then fallback = manifest.display_fallback end
    if fallback == nil then fallback = true end
    fallback = fallback == true

    local selected = selected_providers(dir, manifest, provider, fallback)
    local entries_path = Overlay.entriesPath(dir, provider)
    local emtime = lfs.attributes(entries_path, "modification")
    local esize = lfs.attributes(entries_path, "size")
    local cached = css_cache[manifest_path]
    local color, size, font_family_css = rule_style(options)

    -- The entries file can be megabytes; reuse its last parsed revision once
    -- mtime+size are unchanged AND the file is older than the FAT32 ~2 s
    -- mtime granularity window -- inside that window a same-size rewrite
    -- could hide behind identical stats, so the revision must be re-read.
    -- Outside the window the first bytes are enough (peek_entries_revision);
    -- that is what lets a cold start avoid the full decode.
    local entries_revision
    local stats_trustworthy = emtime ~= nil and (os.time() - emtime) > 3
    if cached and stats_trustworthy and cached.entries_path == entries_path
        and cached.emtime == emtime and cached.esize == esize then
        entries_revision = cached.entries_revision
    else
        entries_revision = peek_entries_revision(entries_path)
    end
    -- The CSS cache must notice a fallback file changing too, not only the
    -- primary.  One cheap stat + cached revision per provider keeps this
    -- constant for style-only rebuilds.
    local selected_info = {}
    for _, pid in ipairs(selected) do
        local path = Overlay.entriesPath(dir, pid)
        local pmtime = pid == provider and emtime or lfs.attributes(path, "modification")
        local psize = pid == provider and esize or lfs.attributes(path, "size")
        local revision = pid == provider and entries_revision
            or peek_entries_revision(path)
        selected_info[#selected_info + 1] = {
            pid = pid, emtime = pmtime, esize = psize, revision = revision,
        }
    end
    local function selected_signature()
        local parts = {}
        for _, item in ipairs(selected_info) do
            parts[#parts + 1] = table.concat({
                item.pid, tostring(item.emtime), tostring(item.esize),
                tostring(item.revision or "?"),
            }, ":")
        end
        return table.concat(parts, ";")
    end
    local function selected_revisions()
        local map = {}
        for _, item in ipairs(selected_info) do map[item.pid] = item.revision end
        return map
    end
    local function css_key(revision, signature)
        return table.concat({
            manifest_path,
            tostring(manifest.display_mode or "auto"),
            tostring(math.max(tonumber(manifest.revision) or 0, revision or 0)),
            provider,
            fallback and "1" or "0",
            tostring(emtime), tostring(esize),
            "1",
            signature,
            tostring(options.translation_color or ""),
            tostring(options.translation_size or ""),
            tostring(options.translation_font_family or ""),
        }, "|")
    end
    local key
    if entries_revision ~= nil then
        key = css_key(entries_revision, selected_signature())
        if cached and cached.key == key then
            cache_stats.css_hits = cache_stats.css_hits + 1
            cache_touch(manifest_path)
            return cached.css
        end
        local tkey = template_key(dir, manifest, provider, fallback, selected,
            selected_revisions())
        if tkey then
            local template = load_template(dir, tkey)
            if template then
                cache_stats.template_hits = cache_stats.template_hits + 1
                local css = apply_style(template, color, size, font_family_css)
                cache_store(manifest_path, {
                    key = key, css = css, size = #css,
                    entries_path = entries_path, emtime = emtime, esize = esize,
                    entries_revision = entries_revision,
                })
                return css
            end
            cache_stats.template_misses = cache_stats.template_misses + 1
        end
    end

    -- No usable template: decode the entries (the part the cache exists to
    -- remove from later style rebuilds) and rebuild both the CSS and the
    -- template.  Fallback docs are only loaded when the merged sheet needs
    -- them; the primary doc is already in the parsed-entries cache.
    local docs, revisions = {}, {}
    local primary = Overlay.loadEntries(dir, provider)
    if primary then
        docs[provider] = primary
        entries_revision = tonumber(primary.revision) or entries_revision or 0
    end
    for _, pid in ipairs(selected) do
        local doc = docs[pid]
        if pid ~= provider then
            doc = Overlay.loadEntries(dir, pid)
            if doc then docs[pid] = doc end
        end
        revisions[pid] = doc and (tonumber(doc.revision) or 0) or nil
    end
    revisions[provider] = entries_revision or 0
    for _, item in ipairs(selected_info) do
        item.revision = revisions[item.pid]
    end
    key = css_key(entries_revision, selected_signature())
    if cached and cached.key == key then
        cache_stats.css_hits = cache_stats.css_hits + 1
        cache_touch(manifest_path)
        return cached.css
    end
    cache_stats.css_builds = cache_stats.css_builds + 1
    local body = render_v3(dir, selected, docs,
        TEMPLATE_COLOR, TEMPLATE_SIZE, TEMPLATE_FONT_CSS)
    local index, data, count, data_len = encode_template(body)
    local tkey = template_key(dir, manifest, provider, fallback, selected, revisions)
    if tkey then
        -- Cache the compiled template even if the disk write fails, so later
        -- style changes in this process still avoid the decode.
        cache_template(dir, tkey, index, data, count)
        if not template_write_failures[dir] then
            if write_template(dir, tkey, index, data, count, data_len) then
                cache_stats.template_writes = cache_stats.template_writes + 1
            else
                template_write_failures[dir] = true
            end
        end
    end
    local css = apply_style({ index = index, data = data, count = count },
        color, size, font_family_css)
    cache_store(manifest_path, {
        key = key, css = css, size = #css,
        entries_path = entries_path, emtime = emtime, esize = esize,
        entries_revision = entries_revision or 0,
    })
    return css
end

function Overlay.buildCss(path, options)
    if not path then return "" end
    options = options or {}
    if lfs.attributes(path, "mode") == "directory" then
        path = normalize_dir(path)
        if Overlay.exists(path .. "/manifest.json") then
            path = path .. "/manifest.json"
        else
            path = path .. "/overlay.json"
        end
    end
    if path:match("manifest%.json$") then
        return build_css_v3(path, options)
    end
    return build_css_legacy(path, options)
end

return Overlay