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

local function write_file(path, data)
    -- Atomic replacement: rename(2) overwrites the destination on POSIX, so
    -- there is no window where the old overlay is gone but the new one is
    -- not yet in place (a crash mid-checkpoint keeps the previous file).
    -- Durability: a failed write/close (e.g. full disk) must never rename a
    -- truncated tmp over the good file; drop the tmp and report failure.
    local temporary = path .. ".tmp"
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

function Overlay.loadEntries(dir, provider_id)
    local data = read_json(Overlay.entriesPath(dir, provider_id))
    if not data or data.version ~= 3 or type(data.entries) ~= "table" then
        return nil
    end
    -- Entries written before 3.2.0 may hold two shapes of the same paragraph;
    -- reading through the same rule as the writers means an upgraded book stops
    -- drawing both layers before it is ever re-translated.
    data.entries = Overlay.dedupeEntries(data.entries)
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
    return write_file(Overlay.entriesPath(dir, provider_id), encoded)
end

function Overlay.deleteEntries(dir, provider_id)
    if not provider_id or provider_id == "" then return false end
    local base = dir .. "/entries/" .. provider_slug(provider_id)
    os.remove(base .. ".json")
    os.remove(base .. ".ndjson")
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

-- External writers (dtctl, the MCP inbox importer) leave a reload.signal so a
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

local function render_v3(dir, manifest, provider, entries_doc, fallback, options)
    local color, size, font_family_css = rule_style(options)
    local by_selector, order = {}, {}
    local function add_entries(doc)
        if not doc then return end
        for _, entry in ipairs(doc.entries or {}) do
            local selector = entry.selector
            if selector and selector ~= "" and entry.translation and entry.translation ~= ""
                and by_selector[selector] == nil then
                by_selector[selector] = entry
                order[#order + 1] = selector
            end
        end
    end
    add_entries(entries_doc)
    if fallback then
        for _, pid in ipairs(manifest.fallback_order or {}) do
            if pid ~= provider and manifest.providers[pid] then
                add_entries(Overlay.loadEntries(dir, pid))
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

local function build_css_v3(manifest_path, options)
    local dir = manifest_path:match("^(.*)/manifest%.json$") or manifest_path
    local manifest = Overlay.loadManifest(dir)
    if not manifest then return "" end
    if options.translation_visible ~= true then return "" end
    local provider = resolve_display_provider(manifest, options.provider)
    if not provider or not manifest.providers[provider] then return "" end
    local fallback = options.fallback
    if fallback == nil then fallback = manifest.display_fallback end
    if fallback == nil then fallback = true end
    fallback = fallback == true

    local entries_path = Overlay.entriesPath(dir, provider)
    local emtime = lfs.attributes(entries_path, "modification")
    local esize = lfs.attributes(entries_path, "size")
    local cached = css_cache[manifest_path]
    local entries_doc, entries_revision
    -- The entries file can be megabytes; reuse its last parsed revision once
    -- mtime+size are unchanged AND the file is older than the FAT32 ~2 s
    -- mtime granularity window -- inside that window a same-size rewrite
    -- could hide behind identical stats, so the revision must be re-read.
    local stats_trustworthy = emtime ~= nil and (os.time() - emtime) > 3
    if cached and stats_trustworthy and cached.entries_path == entries_path
        and cached.emtime == emtime and cached.esize == esize then
        entries_revision = cached.entries_revision
    else
        entries_doc = Overlay.loadEntries(dir, provider)
        entries_revision = entries_doc and tonumber(entries_doc.revision) or 0
    end
    local key = table.concat({
        manifest_path,
        tostring(manifest.display_mode or "auto"),
        tostring(math.max(tonumber(manifest.revision) or 0, entries_revision or 0)),
        provider,
        fallback and "1" or "0",
        tostring(emtime), tostring(esize),
        "1",
        tostring(options.translation_color or ""),
        tostring(options.translation_size or ""),
        tostring(options.translation_font_family or ""),
    }, "|")
    if cached and cached.key == key then
        cache_touch(manifest_path)
        return cached.css
    end
    if not entries_doc then entries_doc = Overlay.loadEntries(dir, provider) end
    local css = render_v3(dir, manifest, provider, entries_doc, fallback, options)
    cache_store(manifest_path, {
        key = key, css = css, size = #css,
        entries_path = entries_path, emtime = emtime, esize = esize,
        entries_revision = entries_revision,
    })
    return css
end

function Overlay.buildCss(path, options)
    if not path then return "" end
    options = options or {}
    if lfs.attributes(path, "mode") == "directory" then
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