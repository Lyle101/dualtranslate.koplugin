-- ============================================================
-- P3-c：MCP 菜单与插件侧刷新（真实 lfs/json，UI 全 stub）
--   buildMcpMenu / mcp_external 时的翻译入口改导出 / 隐私确认 /
--   reload.signal 的 seq 判定 / 空收件箱提示
-- Run: luajit tests/mcp_menu_test.lua
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

local ROOT = "/tmp/dt_mcp_menu_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')
local data_dir = ROOT .. "/data"
os.execute('mkdir -p "' .. data_dir .. '"')

local notifications, last_dialog, style_calls = {}, {}, 0
package.preload["lua-ljsqlite3/init"] = function() return SQ3 end
package.preload["libs/libkoreader-lfs"] = function() return lfs end
package.preload["json"] = function() return JSON end
package.preload["datastorage"] = function() return { getDataDir = function() return data_dir end } end
package.preload["logger"] = function()
    return { warn = function() end, err = function() end,
        info = function() end, dbg = function() end }
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
        sleep = function() end, usleep = function() end,
        getTimestamp = function() return os.time() end }
end
package.preload["ffi/util"] = function()
    return { template = function(s) return s end, md5 = function() return "x" end,
        sleep = function() end, usleep = function() end,
        getTimestamp = function() return os.time() end }
end
package.preload["ffi/archiver"] = function()
    return { Reader = { new = function()
        return { open = function() return false end, close = function() end }
    end } }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end,
        getHeight = function() return 800 end } }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["socket.http"] = function() return { request = function() return nil end } end
package.preload["ltn12"] = function()
    return { source = { string = function(s) return s end },
        sink = { table = function(t) return function() end end } }
end
package.preload["socketutil"] = function()
    return { request = function() return false end,
        set_timeout = function() end, reset_timeout = function() end }
end
package.preload["socket"] = function() return { sleep = function() end } end
package.preload["socket.url"] = function()
    return { escape = function(s) return tostring(s) end,
        unescape = function(s) return tostring(s) end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end,
        scheduleIn = function() end, nextTick = function(fn) end }
end
package.preload["ui/widget/notification"] = function()
    return { new = function(_, o) notifications[#notifications + 1] = o.text return o end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) last_dialog = o return o end }
end
package.preload["ui/widget/progressbardialog"] = function()
    return { new = function() return {} end }
end
package.preload["ui/widget/inputdialog"] = function() return { new = function() return {} end } end
package.preload["ui/widget/spinwidget"] = function() return { new = function() return {} end } end
package.preload["ui/widget/menu"] = function() return { new = function() return {} end } end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(base, o)
        o = o or {}; o.__index = o; setmetatable(o, { __index = base }); return o
    end }
end
package.preload["ui/trapper"] = function()
    return { dismissableRunInSubprocess = function() end, wrap = function() end }
end
package.preload["ui/event"] = function() return { new = function() return {} end } end
package.preload["document/credocument"] = function() return { engineInit = function() return {} end } end
package.preload["fontlist"] = function() return { getLocalizedFontName = function(n) return n end } end
package.preload["ui/translator"] = function() return {} end
package.preload["dump"] = function() return function() return "{}" end end

_G.__settings = {}
_G.G_reader_settings = {
    readSetting = function(_, key) return _G.__settings[key] end,
    saveSetting = function(_, key, value) _G.__settings[key] = value end,
}

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
package.path = script_dir .. "/../?.lua;" .. package.path
local Overlay = require("dualtranslate_overlay")
local Store = require("dualtranslate_store")
local Mcp = require("dualtranslate_mcp")
local dualtranslate = dofile(script_dir .. "/../main.lua")

local BOOK = ROOT .. "/book.epub"
do local f = assert(io.open(BOOK, "wb")); f:write(string.rep("x", 1234)); f:close() end

dualtranslate.ui = {
    menu = { registerToMainMenu = function() end },
    document = { file = BOOK, default_css = "",
        setStyleSheet = function() style_calls = style_calls + 1 end },
    typeset = { css = "" },
    styletweak = { getCssText = function() return "" end },
    view = { recalculate = function() end },
}
dualtranslate:init()
dualtranslate.ui.document.file = BOOK

-- Real provider registry: the point of this file is that mcp_external is in
-- Providers.list and that getMode() lets it through (P3's first deliverable).
check("Providers 含 mcp_external", require("dualtranslate_providers")
    .isProviderEnabled("mcp_external") == true)
dualtranslate:saveSetting("mode", "mcp_external")
check("getMode 返回 mcp_external", dualtranslate:getMode() == "mcp_external")

local function translations_to_epub_calls()
    local count = 0
    local original = dualtranslate.enqueueTranslation
    dualtranslate.enqueueTranslation = function() count = count + 1 end
    return function()
        dualtranslate.enqueueTranslation = original
        return count
    end
end

-- ============================================================
print("== 1. 翻译入口在 mcp_external 时改导出 ==")
do
    local finish = translations_to_epub_calls()
    dualtranslate:translateWholeBook(true)
    check("整本不进入翻译队列", finish() == 0)
    check("整本弹出导出确认", last_dialog and last_dialog.title
        and last_dialog.title:find("整本书", 1, true) ~= nil, last_dialog and last_dialog.title)

    local exported
    dualtranslate.exportMcpJob = function(_, indexes) exported = indexes end
    dualtranslate:translateSelectedChapters({ 2, 5 })
    local dialog = last_dialog
    check("选章弹出导出确认", dialog and dialog.title:find("2 章", 1, true) ~= nil,
        dialog and dialog.title)
    dialog.buttons[1][2].callback()
    check("确认后按所选章节导出", exported and #exported == 2
        and exported[1] == 2 and exported[2] == 5)

    exported = "unset"
    dualtranslate:translateWholeBook(true)
    last_dialog.buttons[1][2].callback()
    check("整本导出传 nil（全部章节）", exported == nil)
end

-- ============================================================
print("== 2. buildMcpMenu ==")
do
    local items = dualtranslate:buildMcpMenu()
    check("六个入口", #items == 6)
    check("导出所选章节", items[1].text == "导出所选章节…")
    check("任务列表带计数", items[2].text_func() == "任务列表（0）")
    check("导入结果", items[3].text == "导入结果")
    check("允许部分导入开关", items[4].text == "允许导入未完成的任务"
        and items[4].checked_func() == false)
    check("自动切换开关", items[5].text == "导入后自动切换显示"
        and items[5].checked_func() == false)
    check("刷新外部译文", items[6].text == "刷新外部译文")
    local job_items = items[2].sub_item_table_func()
    check("空任务列表有占位行", #job_items == 1 and job_items[1].text == "没有任务")
    -- The menu builder runs twice per open; the second call must hit the cache.
    check("任务列表同秒复用", items[2].sub_item_table_func() == job_items)
end

-- ============================================================
print("== 3. reload.signal seq 判定 ==")
do
    local dir = dualtranslate:getBookCacheDirectory(BOOK)
    check("无信号时返回 nil", dualtranslate:checkExternalReload(false) == nil)
    Overlay.saveSignal(dir, { seq = 5, op = "import", provider = "mcp:gpt-5", count = 9 })
    local signal = dualtranslate:checkExternalReload(false)
    check("新 seq 触发刷新", signal and signal.seq == 5)
    check("refreshDocumentStyles 被调用", style_calls > 0)
    check("同一 seq 不重复刷新", dualtranslate:checkExternalReload(false) == nil)
    Overlay.saveSignal(dir, { seq = 6, op = "import", provider = "mcp:gpt-5", count = 10 })
    check("更大 seq 再次刷新", dualtranslate:checkExternalReload(false) ~= nil)
    check("force 不看 seq", dualtranslate:checkExternalReload(true) ~= nil)
end

-- ============================================================
print("== 4. 空收件箱提示 ==")
do
    notifications = {}
    dualtranslate:importMcpResults()
    local found = false
    for _, text in ipairs(notifications) do
        if text:find("没有待导入", 1, true) then found = true end
    end
    check("提示没有待导入", found, table.concat(notifications, " | "))
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
