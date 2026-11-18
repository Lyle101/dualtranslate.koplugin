local settings = {}
local function gettext(s) return s end
local function template(fmt, ...)
    local n = select("#", ...)
    local out = fmt
    for i = 1, n do out = out:gsub("%%" .. i, tostring(select(i, ...) or "")) end
    return out
end
local scheduled_calls = {}
local ui_shows = {}
local stubs = {
    ["logger"] = { warn = function() end, err = function() end, info = function() end, dbg = function() end },
    ["gettext"] = gettext,
    ["datastorage"] = { getDataDir = function() return "/tmp/dt_data" end },
    ["util"] = { makePath = function() return true end, trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end, removeFile = function() end },
    ["ffi/util"] = { template = template, md5 = function() return "x" end,
        sleep = function() end, usleep = function() end,
        getTimestamp = function() return os.time() end },
    ["ffi/archiver"] = {},
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end }, hasClipboard = function() return false end, input = { setClipboardText = function() end } },
    ["libs/libkoreader-lfs"] = { attributes = function() return nil end, mkdir = function() return true end, rmdir = function() return true end, remove = function() return true end, dir = function() end },
    ["json"] = { encode = function() return "{}" end, decode = function() return {} end },
    ["socket.http"] = {}, ["ltn12"] = {}, ["socketutil"] = { request = function() return false end, set_timeout = function() end, reset_timeout = function() end },
    ["socket.url"] = { escape = function(s) return s end, unescape = function(s) return s end },
    -- init() now runs Store.migrateIfNeeded -> Cache:initSchema; a fake
    -- connection reporting user_version=3 keeps the migration a no-op.
    ["lua-ljsqlite3/init"] = {
        open = function()
            return {
                prepare = function(_, sql)
                    local row = sql:find("user_version", 1, true) and { 3 } or nil
                    return {
                        bind = function() end,
                        step = function() return row end,
                        close = function() end,
                    }
                end,
                close = function() end,
            }
        end,
    },
    ["ui/uimanager"] = { show = function(_, widget, refresh)
            ui_shows[#ui_shows + 1] = { widget = widget, refresh = refresh }
        end,
        close = function() end, setDirty = function() end,
        -- Recorded so a test can drive the deferred callbacks itself
        -- (_runTranslation's progress poller is a local closure).
        scheduleIn = function(_, delay, fn)
            scheduled_calls[#scheduled_calls + 1] = { delay = delay, fn = fn }
        end,
        nextTick = function() end },
    ["ui/widget/notification"] = { Notification = {} },
    ["ui/widget/textviewer"] = {}, ["ui/widget/buttondialog"] = {}, ["ui/widget/menu"] = {},
    ["ui/widget/progressbardialog"] = {}, ["ui/widget/inputdialog"] = {}, ["ui/widget/spinwidget"] = {},
    ["ui/widget/container/widgetcontainer"] = { extend = function(self, o) o = o or {}; o.__index = o; setmetatable(o, { __index = self }) return o end },
    ["ui/trapper"] = { dismissableRunInSubprocess = function() end, wrap = function() end },
    ["ui/event"] = { new = function() return {} end },
    ["fontlist"] = { getLocalizedFontName = function(n) return n end },
    ["document/credocument"] = { engineInit = function() return {} end },
    ["dump"] = function() return "{}" end,
}
for k, v in pairs(stubs) do package.preload[k] = function() return v end end
_G.G_reader_settings = {
    readSetting = function(self, key) return settings[key] end,
    saveSetting = function(self, key, value) settings[key] = value end,
}
_G.UIManager = stubs["ui/uimanager"]
local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local plugin_dir = script_dir .. "/.."
package.path = plugin_dir .. "/?.lua;" .. package.path
local dualtranslate = dofile(plugin_dir .. "/main.lua")
dualtranslate.ui = { menu = { registerToMainMenu = function(self, plugin) plugin:addToMainMenu({}) end }, document = nil }
local ok, err = pcall(function() dualtranslate:init() end)
assert(ok, "init failed: " .. tostring(err))
print("init: true")
-- 设置读写验证
dualtranslate:saveSetting("test_key", 123)
assert(dualtranslate:getSetting("test_key") == 123, "settings roundtrip failed")
assert(dualtranslate:getSetting("nonexistent", "default") == "default")
assert(type(dualtranslate.cancelTranslation) == "function", "cancelTranslation not attached")
assert(type(dualtranslate.buildTranslationQueueMenu) == "function", "buildTranslationQueueMenu not attached")
assert(type(dualtranslate.reopenTranslationProgress) == "function", "reopenTranslationProgress missing")
print("attach points: true")
local menu_items = {}
local ok2, err2 = pcall(function() dualtranslate:addToMainMenu(menu_items) end)
assert(ok2, "menu build failed: " .. tostring(err2))
print("addToMainMenu: true")
local sub = menu_items.dualtranslate.sub_item_table
local provider_names = {}
local function walk(items, depth)
    for _, item in ipairs(items) do
        if item.text_func then item.text_func() end
        if item.checked_func then item.checked_func() end
        if item.enabled_func then item.enabled_func() end
        local t = item.text_func and item.text_func() or item.text
        if item.radio and t and (t:match("KOReader") or t:match("Microsoft")) then
            provider_names[t] = true
        end
        if item.sub_item_table then walk(item.sub_item_table, depth + 1) end
        if item.sub_item_table_func then walk(item.sub_item_table_func(), depth + 1) end
    end
end
local ok3, err3 = pcall(function() walk(sub, 0) end)
assert(ok3, "menu walk failed: " .. tostring(err3))
print("walk menu: true")
local n = 0
for _ in pairs(provider_names) do n = n + 1 end
assert(n == 2, "provider names not distinct: " .. tostring(n))
print("provider names distinct: true")

-- 翻译本书: the three scopes (整本 / 当前章节 / 选择章节…) live in one submenu.
assert(type(dualtranslate.showChapterPicker) == "function", "showChapterPicker not attached")
local translate_entry
for _, item in ipairs(sub) do
    if item.text == "翻译本书" then translate_entry = item end
end
assert(translate_entry and translate_entry.sub_item_table, "translate submenu missing")
local labels = {}
for _, item in ipairs(translate_entry.sub_item_table) do labels[#labels + 1] = item.text end
assert(labels[1] == "翻译整本" and labels[2] == "翻译当前章节" and labels[3] == "选择章节…",
    "translate submenu labels: " .. table.concat(labels, ","))
print("translate submenu: true")

-- A menu tap is a manual start, so the reader must put the progress dialog up
-- (_runTranslation only builds one when item.silent is falsy).  The flag kept
-- its old all_chapters value through the scope split, which muted the dialog
-- for 翻译整本 and 翻译当前章节 while 选择章节… still showed it.
local started = {}
local real_whole, real_chapter =
    dualtranslate.translateWholeBook, dualtranslate.translateCurrentChapter
dualtranslate.translateWholeBook = function(_, silent, auto)
    started.whole = { silent = silent, auto = auto }
end
dualtranslate.translateCurrentChapter = function(_, silent, auto)
    started.chapter = { silent = silent, auto = auto }
end
for _, item in ipairs(translate_entry.sub_item_table) do
    if item.text == "翻译整本" or item.text == "翻译当前章节" then item.callback() end
end
dualtranslate.translateWholeBook = real_whole
dualtranslate.translateCurrentChapter = real_chapter
assert(started.whole and started.whole.silent == false,
    "翻译整本 silent: " .. tostring(started.whole and started.whole.silent))
assert(started.chapter and started.chapter.silent == false,
    "翻译当前章节 silent: " .. tostring(started.chapter and started.chapter.silent))
-- A menu tap is one job, not a page-turn follow: auto must stay unset or the
-- completion notice would be suppressed (see _runTranslation).
assert(not started.whole.auto and not started.chapter.auto,
    "menu entries must not pass auto")
print("translate entries start non-silent: true")

-- Reopening a hidden progress dialog (queue row, or the same command again)
-- must put the bar back: the native init() rebuilds it at 0%, so the reader
-- replays the last reported percentage instead of leaving an empty bar.
local fake_dialog = {
    _dualtranslate_hidden = true,
    init = function(self) self.inited = true end,
    reportProgress = function(self, value) self.reported = value end,
}
dualtranslate._translation_progress = {
    active = true, dialog = fake_dialog, last_percentage = 42,
}
ui_shows = {}
assert(dualtranslate:reopenTranslationProgress() == true, "reopen should succeed")
assert(fake_dialog.inited, "reopen should re-init the dialog")
assert(fake_dialog.reported == 42,
    "reopen should restore the last percentage, got " .. tostring(fake_dialog.reported))
-- init() rebuilt the tree, so the re-show must carry a refresh type or the
-- card stays invisible until something else repaints the screen.
local last_show = ui_shows[#ui_shows]
assert(last_show and last_show.widget == fake_dialog and last_show.refresh == "ui",
    "reopen must re-show the dialog with the \"ui\" refresh")
dualtranslate._translation_progress = nil
print("reopen progress restores the bar: true")

-- The bar is driven by a poller defined inside _runTranslation, so it can only
-- be exercised by running a job: a manual span start must build the dialog,
-- and a tick that lands while the card is hidden must re-arm the chain without
-- reading the progress file (that is what lets the reopen above keep updating).
-- The ticks are addressed by index because _runTranslation schedules them in a
-- fixed order (0.1 s show, then 0.5 s polls); Trapper.wrap is stubbed to a
-- no-op, so no worker ever runs.
local SpanBook = "/tmp/dt_span.epub"
local ProgressbarDialog = require("ui/widget/progressbardialog")
local real_new, real_save = ProgressbarDialog.new, dualtranslate.saveTranslationQueue
ProgressbarDialog.new = function(_, opts)
    local dialog = { title = opts.title, subtitle = opts.subtitle }
    function dialog:show() self.shown = true end
    function dialog:onCloseWidget() end
    function dialog:reportProgress(value) self.percentage = value end
    return dialog
end
dualtranslate.saveTranslationQueue = function() end
dualtranslate.ui.document = { file = SpanBook }
scheduled_calls = {}
dualtranslate:_runTranslation({ book_path = SpanBook, mode = "span",
    status = "queued", fragment = "1", span = 1 })
assert(#scheduled_calls == 1 and scheduled_calls[1].delay == 0.1,
    "expected the deferred show callback, got " .. #scheduled_calls)
scheduled_calls[1].fn()
local dialog = dualtranslate._translation_progress
    and dualtranslate._translation_progress.dialog
assert(dialog and dialog.shown, "a manual span job must create the progress dialog")
assert(tostring(dialog.title):find("当前章节", 1, true) ~= nil,
    "span dialog title: " .. tostring(dialog.title))
assert(scheduled_calls[2] and scheduled_calls[2].delay == 0.5,
    "the poller should be armed at 0.5s")
dialog._dualtranslate_hidden = true
local reads = 0
local real_open = io.open
io.open = function(...) reads = reads + 1 return real_open(...) end
scheduled_calls[2].fn()
io.open = real_open
assert(reads == 0, "a hidden tick must not read the progress file, got " .. reads)
assert(scheduled_calls[3] and scheduled_calls[3].delay == 1,
    "a hidden tick must re-arm the poller, or the reopened bar freezes")
-- A late tick must never leak into the next job: once the watchdog releases
-- this entry and the next job installs its own table, the old chain stops
-- instead of writing this run's percentage into it.
local next_job = { active = true }
dualtranslate._translation_progress = next_job
local before = #scheduled_calls
scheduled_calls[3].fn()
assert(#scheduled_calls == before, "a stale poller must stop once its entry is replaced")
assert(next_job.last_percentage == nil, "a stale poller must not write the next job's entry")
-- Leave nothing running.
next_job.active = false
dualtranslate._translation_progress = nil
dualtranslate._active_translation_book = nil
dualtranslate.ui.document = nil
dualtranslate.saveTranslationQueue = real_save
ProgressbarDialog.new = real_new
scheduled_calls = {}
print("hidden poller stays alive: true")
