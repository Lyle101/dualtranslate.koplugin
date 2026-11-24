-- ============================================================
-- P1-c production switch (real lfs/json/sqlite via KO_ROOT):
--   State.hasActiveJob / PageTrans per-provider / Reader v3 paths /
--   Epub v3 checkpoint union + legacy absorption / main menu + onReadSettings
-- Run: luajit tests/p1c_switch_test.lua
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
local ffi = require("ffi")
if not ffi.loadlib then ffi.loadlib = function(name) return ffi.load(name) end end
package.path = KO .. "/?.lua;" .. KO .. "/common/?.lua;" .. KO .. "/common/?/init.lua;" .. package.path
package.cpath = KO .. "/?.so;" .. KO .. "/?.dylib;" .. package.cpath
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_json, JSON = pcall(require, "json")
local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3")
if not ok_lfs or not ok_json or not ok_sq3 then
    print("SKIP: lfs / json / lua-ljsqlite3 unavailable"); os.exit(0)
end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local ROOT = "/tmp/dt_p1c_switch"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')
local data_dir = ROOT .. "/data"
os.execute('mkdir -p "' .. data_dir .. '"')

local warns, notifications, shown_dialogs = {}, {}, {}
local last_dialog
local function joinArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end

package.preload["lua-ljsqlite3/init"] = function() return SQ3 end
package.preload["libs/libkoreader-lfs"] = function() return lfs end
package.preload["json"] = function() return JSON end
package.preload["datastorage"] = function() return { getDataDir = function() return data_dir end } end
package.preload["logger"] = function()
    return { warn = function(...) warns[#warns + 1] = joinArgs(...) end,
        err = function(...) warns[#warns + 1] = joinArgs(...) end, info = function() end }
end
package.preload["util"] = function()
    return { makePath = function(path)
            if lfs.attributes(path, "mode") == "directory" then return true end
            local prefix = path:sub(1, 1) == "/" and "" or "."
            for c in path:gmatch("[^/]+") do
                prefix = prefix .. "/" .. c
                if lfs.attributes(prefix, "mode") ~= "directory" then lfs.mkdir(prefix) end
            end
            return lfs.attributes(path, "mode") == "directory"
        end,
        trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
        removeFile = function() end }
end
package.preload["ffi/util"] = function()
    return { template = function(s) return s end, md5 = function() return "x" end,
        sleep = function() end, usleep = function() end,
        getTimestamp = function() return os.time() end }
end
package.preload["ffi/archiver"] = function()
    return { Reader = { new = function() return { open = function() return false end, close = function() end } end } }
end
package.preload["device"] = function() return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["socket.http"] = function() return {} end
package.preload["ltn12"] = function() return {} end
package.preload["socketutil"] = function() return { request = function() return false end, set_timeout = function() end, reset_timeout = function() end } end
package.preload["socket.url"] = function() return { escape = function(s) return s end, unescape = function(s) return s end } end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end,
        scheduleIn = function() end, nextTick = function() end }
end
package.preload["ui/widget/notification"] = function()
    return { new = function(_, o) notifications[#notifications + 1] = o.text return {} end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) last_dialog = o; shown_dialogs[#shown_dialogs + 1] = o; return o end }
end
package.preload["ui/widget/progressbardialog"] = function() return { new = function() return {} end } end
package.preload["ui/widget/inputdialog"] = function() return { new = function() return {} end } end
package.preload["ui/widget/spinwidget"] = function() return { new = function() return {} end } end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, o) o = o or {}; o.__index = o; setmetatable(o, { __index = _ }) return o end }
end
package.preload["ui/trapper"] = function() return { dismissableRunInSubprocess = function() end, wrap = function() end } end
package.preload["ui/event"] = function() return { new = function() return {} end } end
package.preload["document/credocument"] = function() return { engineInit = function() return {} end } end
package.preload["fontlist"] = function() return { getLocalizedFontName = function(n) return n end } end
package.preload["ui/translator"] = function() return {} end
package.preload["dump"] = function() return function() return "{}" end end
package.preload["dualtranslate_providers"] = function()
    return {
        list = { { id = "system", name = "KOReader 内置" }, { id = "microsoft_free", name = "Microsoft Edge" } },
        getProviderName = function(id) return id == "system" and "KOReader 内置" or "Microsoft Edge" end,
        -- getMode() only lets known engines through, so the stub answers it too.
        isProviderEnabled = function(id) return id == "system" or id == "microsoft_free" end,
        translate = function(_, text) return { translated_text = "T:" .. text } end,
        translate_microsoft_free_batch = function(texts)
            local out = {} for i, t in ipairs(texts) do out[i] = "B:" .. t end return out
        end,
    }
end

-- Real Tools, but unzip_to copies a prepared EPUB tree (Epub worker path).
local RealTools = dofile("dualtranslate_tools.lua")
local EPUB_SRC = ROOT .. "/epub_src"
local Tools = {
    stable_path_hash = RealTools.stable_path_hash,
    mkdir_p = RealTools.mkdir_p,
    rmtree = RealTools.rmtree,
    unzip_to = function(_, dest)
        os.execute('rm -rf "' .. dest .. '" && mkdir -p "' .. dest .. '"')
        os.execute('cp -r "' .. EPUB_SRC .. '/." "' .. dest .. '/"')
        return true
    end,
}
package.preload["dualtranslate_tools"] = function() return Tools end

_G.G_reader_settings = {
    readSetting = function(_, key) return _G.__settings[key] end,
    saveSetting = function(_, key, value) _G.__settings[key] = value end,
}
_G.__settings = {}

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
package.path = script_dir .. "/../?.lua;" .. package.path
local Overlay = require("dualtranslate_overlay")
local Store = require("dualtranslate_store")
local Cache = require("dualtranslate_cache")
local State = require("dualtranslate_state")
local dualtranslate = dofile(script_dir .. "/../main.lua")

-- A real book file so lfs.attributes(size/mtime) is meaningful.
local BOOK = ROOT .. "/book.epub"
do local f = assert(io.open(BOOK, "wb")); f:write(string.rep("x", 1234)); f:close() end

dualtranslate.ui = {
    menu = { registerToMainMenu = function() end },
    document = { file = BOOK, setStyleSheet = function() end, default_css = "" },
    typeset = { css = "" },
    styletweak = { getCssText = function() return "" end },
    view = { recalculate = function() end },
}
dualtranslate:init()
dualtranslate.ui.document.file = BOOK

local function seedV3(book, lang, specs)
    local dir = Store.bookDir(book, lang)
    local manifest = {
        version = 3, revision = 0, book_path = book, source_lang = "auto",
        target_lang = lang, spine_count = 2, book_size = 0, book_mtime = 0,
        display_mode = "auto", display_fallback = true,
        last_used_at = {}, fallback_order = {}, providers = {},
    }
    for _, spec in ipairs(specs) do
        local entries = {}
        for j = 1, (spec.count or 1) do
            entries[j] = { selector = spec.id .. ":p[" .. j .. "]", source = "s" .. j,
                translation = spec.id .. "t" .. j }
        end
        Overlay.saveEntries(dir, spec.id, { target_lang = lang, entries = entries })
        manifest.providers[spec.id] = {
            display_name = spec.display_name or spec.id, kind = spec.kind or "builtin",
            chapters = spec.chapters or {}, partial_chapters = spec.partial or {},
            failed_chapters = spec.failed or {}, entry_ranges = spec.entry_ranges,
            complete = spec.complete == true,
            translated_count = spec.count or 1, updated_at = 100, confirmed = true,
        }
        manifest.last_used_at[spec.id] = 100
        manifest.fallback_order[#manifest.fallback_order + 1] = spec.id
    end
    Overlay.saveManifest(dir, manifest)
    return dir
end

-- ============================================================
print("== 1. State.hasActiveJob ==")
do
    local p = dualtranslate
    p._translation_queue = {
        { book_path = BOOK, status = "queued", provider = "system" },
        { book_path = BOOK, status = "done", provider = "microsoft_free" },
        { book_path = "/other.epub", status = "active", provider = "system" },
    }
    p._translation_progress = nil
    check("queued same provider blocks", p:hasActiveJob(BOOK, "system") == true)
    check("queued other provider free", p:hasActiveJob(BOOK, "microsoft_free") == false)
    check("done ignored", p:hasActiveJob(BOOK, "microsoft_free") == false)
    check("other book ignored", p:hasActiveJob("/other.epub", "microsoft_free") == false)
    -- legacy item without provider matches any (conservative)
    p._translation_queue = { { book_path = BOOK, status = "active" } }
    check("no-provider blocks any", p:hasActiveJob(BOOK, "system") == true
        and p:hasActiveJob(BOOK, "microsoft_free") == true)
    -- progress active
    p._translation_queue = {}
    p._translation_progress = { active = true, book_path = BOOK, item = { provider = "system" } }
    check("progress active blocks", p:hasActiveJob(BOOK, "system") == true)
    check("progress other provider free", p:hasActiveJob(BOOK, "microsoft_free") == false)
    p._translation_progress = nil
    -- enqueue stamps provider; migration flag blocks
    p._translation_queue = {}
    p:saveSetting("mode", "system")
    p._translation_migration_failed = nil
    p.enqueueTranslation = State.enqueue
    p.startNextQueuedTranslation = function() end
    p.saveTranslationQueue = function() end
    p.TranslationUI = { showInfo = function() end }
    State.enqueue(p, { book_path = BOOK, mode = "all", silent = true })
    check("enqueue stamps provider", p._translation_queue[1]
        and p._translation_queue[1].provider == "system")
    p._translation_queue = {}
    p._translation_migration_failed = true
    State.enqueue(p, { book_path = BOOK, mode = "all", silent = true })
    check("migration failure blocks enqueue", #p._translation_queue == 0)
    p._translation_migration_failed = nil
end

-- ============================================================
print("== 2. PageTrans per generation engine ==")
do
    local p = dualtranslate
    local lang = "zh-Hans"
    p:saveSetting("target_lang", lang)
    seedV3(BOOK, lang, {
        { id = "system", count = 2, complete = false, chapters = { 1, 2 } },
        { id = "microsoft_free", count = 1, complete = false, chapters = {} },
    })
    p:saveSetting("page_translation", true)
    p._page_translation_follow_active = true
    p._translation_progress = nil
    local scheduled
    p.translateCurrentChapter = function(_, silent, auto) scheduled = { silent = silent, auto = auto } end
    local fragment = "1"
    p.getCurrentFragment = function() return fragment end
    local function attempt(mode, frag)
        p:saveSetting("mode", mode)
        fragment = frag
        p._page_translation_last_fragment = nil
        p._page_translation_overlay_state = nil
        scheduled = nil
        -- 生产路径（onPageUpdate / onPosUpdate / onDocumentRerendered）都传
        -- silent=false：翻页续译同样显示进度框，只是 auto 压掉完成提示。
        p:maybeSchedulePageTranslation(false)
        return scheduled ~= nil
    end
    check("system covered chapter skipped", attempt("system", "1") == false)
    check("system uncovered chapter schedules", attempt("system", "3") == true)
    check("翻页续译转发 silent=false / auto=true",
        scheduled and scheduled.silent == false and scheduled.auto == true,
        scheduled and tostring(scheduled.silent) .. "/" .. tostring(scheduled.auto))
    check("microsoft_free not complete schedules", attempt("microsoft_free", "1") == true)
    -- a complete provider blocks every chapter, even uncovered ones
    seedV3(BOOK, lang, {
        { id = "system", count = 2, complete = true, chapters = { 1, 2 } },
    })
    check("complete provider blocks all", attempt("system", "9") == false)
    -- partial/failed chapters stay re-queueable
    seedV3(BOOK, lang, {
        { id = "system", count = 2, complete = false, chapters = { 1 }, partial = { 2 }, failed = { 3 } },
    })
    check("partial chapter re-queueable", attempt("system", "2") == true)
    check("failed chapter re-queueable", attempt("system", "3") == true)
    check("covered chapter still skipped", attempt("system", "1") == false)

    -- 条目级：同一文件只有一条翻过时，翻到已翻的那条要跳过，翻到下一条要调度
    seedV3(BOOK, lang, {
        { id = "system", count = 1, complete = false, chapters = {},
          partial = { 1 },
          entry_ranges = { ["1"] = { { from = "a", to = "b", done = true } } } },
    })
    local rows = { { anchor = "a" }, { anchor = "b" }, { anchor = "c" } }
    p.getCurrentFragment = nil
    local function attempt_entry(pos)
        p:saveSetting("mode", "system")
        p._page_translation_last_fragment = nil
        p._page_translation_overlay_state = nil
        scheduled = nil
        p.currentChapterRange = function()
            return { index = 1, from = rows[pos].anchor }, "1." .. pos, rows
        end
        p:maybeSchedulePageTranslation(false)
        return scheduled ~= nil
    end
    check("已翻条目跳过", attempt_entry(1) == false)
    check("同文件未翻条目仍然调度", attempt_entry(3) == true)
    p.currentChapterRange = function() return nil end
    p.getCurrentFragment = function() return fragment end
    -- mcp_external never auto-schedules (7.4 guard)
    local real_getMode = p.getMode
    p.getMode = function() return "mcp_external" end
    fragment = "9"
    p._page_translation_last_fragment = nil
    p._page_translation_overlay_state = nil
    scheduled = nil
    p:maybeSchedulePageTranslation(false)
    check("mcp_external guard", scheduled == nil)
    p.getMode = real_getMode
end

-- ============================================================
print("== 3. Reader v3 paths ==")
do
    local p = dualtranslate
    local lang = "en"
    p:saveSetting("target_lang", lang)
    check("overlay path is manifest", p:getTranslationOverlayPath(BOOK):match("/manifest%.json$") ~= nil)
    check("entries path per provider", p:getEntriesPath(BOOK, "system"):match("/entries/system%.json$") ~= nil)
    -- v2 overlay -> hasTranslationOverlay migrates lazily
    local dir = p:getBookCacheDirectory(BOOK)
    Tools.mkdir_p(dir)
    Overlay.save(dir .. "/overlay.json", {
        version = 2, complete = true, provider = "system", book_path = BOOK,
        source_lang = "auto", target_lang = lang,
        entries = { { selector = "a", source = "s", translation = "t" } }, chapters = { 1 },
    })
    check("v2 overlay detected", p:hasTranslationOverlay(BOOK) == true)
    check("v2 migrated to manifest", Overlay.loadManifest(dir) ~= nil)
    check("v2 retired to bak", lfs.attributes(dir .. "/overlay.v2.bak", "mode") == "file")
    -- remove sweeps v3 dirs across languages
    seedV3(BOOK, lang, { { id = "system", count = 1 } })
    seedV3(BOOK, "zh-Hans", { { id = "system", count = 1 } })
    local removed = p:removeTranslationFilesForBook(BOOK)
    check("remove counts both languages", removed == 2, tostring(removed))
    check("current lang dir gone", lfs.attributes(p:getBookCacheDirectory(BOOK), "mode") == nil)
end

-- ============================================================
print("== 4. Epub v3 checkpoint union + legacy absorption ==")
do
    os.execute('mkdir -p "' .. EPUB_SRC .. '/META-INF" "' .. EPUB_SRC .. '/OEBPS"')
    local function write(rel, c)
        local f = assert(io.open(EPUB_SRC .. "/" .. rel, "w")); f:write(c); f:close()
    end
    write("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]])
    write("OEBPS/content.opf", [[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest><item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="c1"/></spine>
</package>]])
    write("OEBPS/chap1.xhtml", [[<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Alpha para.</p><p>Beta para.</p></body></html>]])
    local Epub = require("dualtranslate_epub")
    local lang = "fr"
    local dir = Store.bookDir(BOOK, lang)
    local function run(provider)
        return Epub:translate_overlay({
            book_path = BOOK, mode = "all", fragment = "1",
            source_lang = "auto", target_lang = lang, provider = provider,
            progress_path = ROOT .. "/prog.txt", output_dir = dir,
            translate = function(text) return "T:" .. text end,
            translate_batch = function(texts)
                local o = {}
                for i, t in ipairs(texts) do o[i] = "B:" .. t end
                return o
            end,
        })
    end
    local r1 = run("system")
    check("first v3 run ok", r1 ~= nil)
    check("manifest written", Overlay.loadManifest(dir) ~= nil)
    local e1 = Overlay.loadEntries(dir, "system")
    check("entries written", e1 and #e1.entries == 2)
    -- another writer lands an extra entry; next run must union, not clobber
    local extra = { selector = "extra[1]", source = "x", translation = "extra" }
    local merged = {}
    for _, e in ipairs(e1.entries) do merged[#merged + 1] = e end
    merged[#merged + 1] = extra
    Overlay.saveEntries(dir, "system", { target_lang = lang, entries = merged })
    local r2 = run("system")
    check("second run ok", r2 ~= nil)
    local e2 = Overlay.loadEntries(dir, "system")
    local has_extra = false
    for _, e in ipairs(e2.entries) do if e.selector == "extra[1]" then has_extra = true end end
    check("union preserves other writer entry", has_extra and #e2.entries == 3, tostring(#e2.entries))
    -- legacy absorption: a v2 overlay for another provider, no manifest
    local ldir = Store.bookDir(BOOK, "de")
    Tools.mkdir_p(ldir)
    Overlay.save(ldir .. "/overlay.json", {
        version = 2, complete = false, provider = "microsoft_free", book_path = BOOK,
        source_lang = "auto", target_lang = "de",
        entries = { { selector = "legacy[1]", source = "s", translation = "lt" } }, chapters = { 1 },
    })
    local rl = Epub:translate_overlay({
        book_path = BOOK, mode = "all", fragment = "1",
        source_lang = "auto", target_lang = "de", provider = "system",
        progress_path = ROOT .. "/prog2.txt", output_dir = ldir,
        translate = function(text) return "T:" .. text end,
        translate_batch = function(texts)
            local o = {}
            for i, t in ipairs(texts) do o[i] = "B:" .. t end
            return o
        end,
    })
    check("legacy-absorb run ok", rl ~= nil)
    local lm = Overlay.loadManifest(ldir)
    check("legacy provider preserved", lm and lm.providers.microsoft_free ~= nil)
    check("current provider present", lm and lm.providers.system ~= nil)
    local le = Overlay.loadEntries(ldir, "microsoft_free")
    check("legacy entries absorbed", le and #le.entries == 1 and le.entries[1].selector == "legacy[1]")
    check("legacy overlay retired", lfs.attributes(ldir .. "/overlay.v2.bak", "mode") == "file"
        and lfs.attributes(ldir .. "/overlay.json", "mode") == nil)
end

-- ============================================================
print("== 5. main onReadSettings migration + stale ==")
do
    local p = dualtranslate
    local lang = "it"
    p:saveSetting("target_lang", lang)
    p:saveSetting("translation_visible", true)
    p:saveSetting("plugin_enabled", true)
    local dir = p:getBookCacheDirectory(BOOK)
    Tools.mkdir_p(dir)
    Overlay.save(dir .. "/overlay.json", {
        version = 2, complete = true, provider = "system", book_path = BOOK,
        source_lang = "auto", target_lang = lang,
        entries = { { selector = "a", source = "s", translation = "t" } }, chapters = { 1 },
    })
    local styled = 0
    p.ui.document.setStyleSheet = function() styled = styled + 1 end
    p.ui.document.getCurrentPage = function() return 1 end
    notifications = {}
    p._translation_stale = nil
    p:onReadSettings()
    check("onReadSettings migrates v2", Overlay.loadManifest(dir) ~= nil)
    check("onReadSettings refreshes", styled > 0)
    check("fresh book not stale", p._translation_stale == nil)
    -- stale: manifest size mismatch hides layer + prompts
    local manifest = Overlay.loadManifest(dir)
    manifest.book_size = 999999
    Overlay.saveManifest(dir, manifest)
    notifications = {}
    p._translation_stale = nil
    p:onReadSettings()
    check("stale detected", p._translation_stale == true)
    local prompted = false
    for _, n in ipairs(notifications) do
        if n:find("缓存与当前文件不符", 1, true) then prompted = true end
    end
    check("stale prompt shown", prompted)
    -- onCloseDocument clears the session flag
    p:onCloseDocument()
    check("close clears stale", p._translation_stale == nil)
end

-- ============================================================
print("== 6. main menu build / render / delete flow ==")
do
    local p = dualtranslate
    local lang = "es"
    p:saveSetting("target_lang", lang)
    p.ui.document.file = BOOK
    seedV3(BOOK, lang, {
        { id = "system", count = 3, display_name = "KOReader 内置" },
        { id = "microsoft_free", count = 2, display_name = "Microsoft Edge" },
    })
    local menu_items = {}
    p:addToMainMenu(menu_items)
    local sub = menu_items.dualtranslate.sub_item_table
    local labels = {}
    local display_item, manage_item, engine_item
    for _, item in ipairs(sub) do
        local t = item.text_func and item.text_func() or item.text
        labels[#labels + 1] = t
        if t and t:find("显示译文", 1, true) then display_item = item end
        if t == "管理译文" then manage_item = item end
        if t and t:find("翻译引擎", 1, true) then engine_item = item end
    end
    check("engine renamed", engine_item ~= nil)
    check("display submenu present", display_item ~= nil and display_item.sub_item_table_func ~= nil)
    check("manage submenu present", manage_item ~= nil and manage_item.sub_item_table_func ~= nil)
    -- render display menu
    local display = display_item.sub_item_table_func()
    local provider_rows, auto_row, fallback_row, visible_row = {}, nil, nil, nil
    for _, item in ipairs(display) do
        local t = item.text_func and item.text_func() or item.text
        if item.radio and t and t:find("KOReader", 1, true) then provider_rows[#provider_rows + 1] = item end
        if item.radio and t and t:find("Microsoft", 1, true) then provider_rows[#provider_rows + 1] = item end
        if t == "自动（最近使用）" then auto_row = item end
        if t and t:find("缺失段落回退", 1, true) then fallback_row = item end
        if t == "显示译文" and item.checkbox then visible_row = item end
    end
    check("display lists 2 providers", #provider_rows == 2, tostring(#provider_rows))
    check("display has auto + fallback + visible", auto_row ~= nil and fallback_row ~= nil and visible_row ~= nil)
    check("provider row shows count", provider_rows[1].text_func():find("3", 1, true) ~= nil
        or provider_rows[2].text_func():find("2", 1, true) ~= nil)
    -- click a provider -> manual display, fallback_order untouched (D9)
    local before_order = Overlay.loadManifest(Store.bookDir(BOOK, lang)).fallback_order
    provider_rows[1].callback()
    local m = Overlay.loadManifest(Store.bookDir(BOOK, lang))
    check("provider click sets manual", m.display_mode == "manual" and m.display_provider ~= nil)
    local same_order = #m.fallback_order == #before_order
    for i, v in ipairs(before_order) do if m.fallback_order[i] ~= v then same_order = false end end
    check("display switch keeps fallback_order", same_order)
    -- fallback toggle: on -> off -> on（回归：and/or 优先级曾导致只能关不能开）
    local fb_before = m.display_fallback
    check("fallback initially checked", fallback_row.checked_func() == true)
    fallback_row.callback()
    local m2 = Overlay.loadManifest(Store.bookDir(BOOK, lang))
    check("fallback toggled", m2.display_fallback ~= fb_before)
    check("fallback off persisted + unchecked", m2.display_fallback == false
        and fallback_row.checked_func() == false)
    fallback_row.callback()
    local m3 = Overlay.loadManifest(Store.bookDir(BOOK, lang))
    check("fallback toggles back on", m3.display_fallback == true
        and fallback_row.checked_func() == true)
    -- manage menu delete flow
    local manage = manage_item.sub_item_table_func()
    local delete_sub, clear_row, repair_row
    for _, item in ipairs(manage) do
        if item.text == "删除某服务的译文…" then delete_sub = item end
        if item.text == "删除本书全部译文" then clear_row = item end
        if item.text == "修复本书译文数据" then repair_row = item end
    end
    check("manage has delete/clear/repair", delete_sub ~= nil and clear_row ~= nil and repair_row ~= nil)
    -- 删除页改为 sub_item_table_func：每次展开重建，删除后菜单留在原页刷新
    local delete_page = delete_sub.sub_item_table_func()
    check("delete lists providers", #delete_page == 2, tostring(#delete_page))
    check("delete rows keep menu open", delete_page[1].keep_menu_open == true
        and delete_page[2].keep_menu_open == true)
    -- guard: active job blocks delete
    p._translation_queue = { { book_path = BOOK, status = "active", provider = "system" } }
    notifications = {}
    delete_page[1].callback()
    check("delete opens confirm dialog", last_dialog ~= nil)
    last_dialog.buttons[1][2].callback()
    local blocked = false
    for _, n in ipairs(notifications) do if n:find("正在翻译中", 1, true) then blocked = true end end
    check("active job blocks delete", blocked)
    check("blocked delete keeps entries", Overlay.loadEntries(Store.bookDir(BOOK, lang), "system") ~= nil)
    -- no job -> delete succeeds
    p._translation_queue = {}
    notifications = {}
    delete_page[1].callback()
    last_dialog.buttons[1][2].callback()
    check("delete removes entries", Overlay.loadEntries(Store.bookDir(BOOK, lang), "system") == nil)
    local deleted_notice
    for _, n in ipairs(notifications) do if n:find("已删除", 1, true) then deleted_notice = n end end
    check("delete notifies count", deleted_notice ~= nil)
    -- 6.2.1 口径：通知用 entries 段数（3），不是 DB 行数（本书 DB 无行=0）
    check("delete notice uses entries count", deleted_notice ~= nil
        and deleted_notice:find("译文 3 段", 1, true) ~= nil, tostring(deleted_notice))
    -- repair runs full reconcile without error
    notifications = {}
    repair_row.callback()
    local repaired = false
    for _, n in ipairs(notifications) do if n:find("修复完成", 1, true) then repaired = true end end
    check("repair completes", repaired)
    -- clear-all guard：任意 provider 的 queued 任务都阻止删除本书全部译文
    -- （与按服务删除同一 hasActiveJob 口径，不再只看 progress.active）
    p._translation_queue = { { book_path = BOOK, status = "queued", provider = "microsoft_free" } }
    p._translation_progress = nil
    notifications = {}
    clear_row.callback()
    last_dialog.buttons[1][2].callback()
    local clear_blocked = false
    for _, n in ipairs(notifications) do
        if n:find("这本书正在翻译", 1, true) then clear_blocked = true end
    end
    check("queued job blocks clear-all", clear_blocked)
    check("blocked clear keeps entries",
        Overlay.loadEntries(Store.bookDir(BOOK, lang), "microsoft_free") ~= nil)
    p._translation_queue = {}
    -- migration failure disables translate entry
    p._translation_migration_failed = true
    local translate_enabled
    for _, item in ipairs(sub) do
        if item.text == "翻译本书" then translate_enabled = item.enabled_func() end
    end
    check("migration failure disables translate", translate_enabled == false)
    p._translation_migration_failed = nil
end

print(string.format("\n==== P1-c switch 结果：%d 通过，%d 失败 ====", passed, failed))
os.execute('rm -rf "' .. ROOT .. '"')
os.exit(failed == 0 and 0 or 1)