-- ============================================================
-- 管理译文：删除某服务的译文后，菜单保持打开并原地刷新
--   buildManageMenu / buildDeleteProviderMenu / confirmDeleteProvider /
--   refreshMenuPage 的 keep_menu_open 契约
-- Run: luajit tests/manage_menu_test.lua
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

local ROOT = "/tmp/dt_manage_menu_test"
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
package.preload["ui/widget/infomessage"] = function()
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
local Store = require("dualtranslate_store")
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

-- 数据库层换成可控的假数据：这里验的是菜单接线，不是 Store 的删除协议。
local providers = {
    { id = "mcp:gpt-5", display_name = "GPT-5", count = 12, confirmed = true },
    { id = "microsoft_free", display_name = "Microsoft Edge", count = 3, confirmed = true },
}
local deleted = {}
Store.listProviders = function() return providers end
Store.deleteProvider = function(_, _, provider_id)
    deleted[#deleted + 1] = provider_id
    for index, item in ipairs(providers) do
        if item.id == provider_id then table.remove(providers, index); break end
    end
    return true
end

local function fake_menu(item_table)
    local menu = { item_table = item_table, updates = 0 }
    function menu:updateItems(page) self.updates = self.updates + 1; self.page = page end
    function menu:backToUpperMenu() self.backs = (self.backs or 0) + 1 end
    return menu
end

-- ============================================================
print("== 1. 管理译文页结构 ==")
do
    local items = dualtranslate:buildManageMenu()
    check("三个入口", #items == 3, #items)
    check("删除某服务译文可展开子页", items[1].sub_item_table_func ~= nil)
    check("删除本书全部译文保持菜单", items[2].keep_menu_open == true)
    check("修复数据保持菜单", items[3].keep_menu_open == true)
    check("管理页可自刷新", items.needs_refresh == true
        and type(items.refresh_func) == "function")
    check("刷新后仍是三个入口", #items.refresh_func() == 3)
end

-- ============================================================
print("== 2. 删除某服务的译文 ==")
do
    local page = dualtranslate:buildDeleteProviderMenu()
    check("列出两个服务", #page == 2, #page)
    check("服务行保持菜单", page[1].keep_menu_open == true
        and page[2].keep_menu_open == true)
    check("服务行带段数", page[1].text_func():find("12", 1, true) ~= nil,
        page[1].text_func())

    local menu = fake_menu(page)
    page[1].callback(menu)
    check("弹出删除确认", last_dialog and tostring(last_dialog.title):find("GPT-5", 1, true) ~= nil,
        last_dialog and tostring(last_dialog.title))

    last_dialog.buttons[1][2].callback()
    check("按 provider 删除", deleted[1] == "mcp:gpt-5", tostring(deleted[1]))
    check("删除后原地刷新", menu.updates == 1, menu.updates)
    check("刷新后只剩另一个服务", #menu.item_table == 1
        and menu.item_table[1].text_func():find("Microsoft Edge", 1, true) ~= nil,
        #menu.item_table)
    check("删除提示已发出", notifications[#notifications]
        and notifications[#notifications]:find("已删除", 1, true) ~= nil,
        notifications[#notifications])

    -- 删掉最后一个：页面不能变空（TouchMenu 会放弃渲染空表）。
    local next_row = menu.item_table[1]
    next_row.callback(menu)
    last_dialog.buttons[1][2].callback()
    check("删光后给出占位行", #menu.item_table == 1
        and menu.item_table[1].text == "没有可删除的译文"
        and menu.item_table[1].enabled == false, menu.item_table[1].text)
    check("删光后仍刷新在原页", menu.updates == 2, menu.updates)
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
