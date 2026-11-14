-- ============================================================
-- 章节选择器（P2-b / 设计 §7.1、§7.2、§12.3）
-- getBookOutline 内存缓存 / ChapterPickerDialog 纯逻辑与对话框流程
-- Run: luajit tests/chapter_picker_test.lua
-- 纯 Lua + stub，无需 KOReader 前端
-- ============================================================
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local DATA_DIR = "/tmp/dt_chapter_picker"

-- Menu stub: Picker builds a plain options table and drives it with
-- updateItems/onMenuSelect, so the fake only needs those two methods.
local opened_menus = {}
local closed_widgets = {}
local notifications = {}
local stubs = {
    ["logger"] = { warn = function() end, err = function() end, info = function() end, dbg = function() end },
    ["gettext"] = function(text) return text end,
    ["ui/uimanager"] = {
        show = function(_, widget) opened_menus[#opened_menus + 1] = widget end,
        close = function(_, widget) closed_widgets[#closed_widgets + 1] = widget end,
        setDirty = function() end,
        scheduleIn = function() end,
        nextTick = function() end,
    },
    ["ui/widget/notification"] = {
        Notification = { new = function(_, opts) return opts end },
    },
    ["ui/widget/menu"] = {
        new = function(_, opts)
            opts.updateItems = function(self) self.updated = (self.updated or 0) + 1 end
            return opts
        end,
    },
    ["ui/widget/progressbardialog"] = {},
    ["ui/widget/buttondialog"] = {},
    ["ui/widget/inputdialog"] = {},
    ["ui/widget/spinwidget"] = {},
    ["ui/event"] = { new = function() return {} end },
    ["ui/trapper"] = {
        dismissableRunInSubprocess = function() end,
        wrap = function() end,
    },
    ["util"] = { makePath = function() return true end, trim = function(text) return text end },
    ["libs/libkoreader-lfs"] = {
        attributes = function() return nil end,
        mkdir = function() return true end,
        rmdir = function() return true end,
        remove = function() return true end,
        dir = function() end,
    },
    ["ffi/archiver"] = {},
    ["json"] = { encode = function() return "{}" end, decode = function() return {} end },
    ["datastorage"] = { getDataDir = function() return DATA_DIR end },
    ["dualtranslate_cache"] = {},
    ["dualtranslate_providers"] = {},
    ["dualtranslate_overlay"] = {},
    ["dualtranslate_store"] = {},
}
for name, value in pairs(stubs) do package.preload[name] = function() return value end end
_G.G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() end,
    isTrue = function() return false end,
}

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
package.path = script_dir .. "/../?.lua;" .. package.path

local Reader = require("dualtranslate_reader")

-- ============================================================
print("== 1. getBookOutline 内存缓存 ==")
do
    local plugin = {}
    Reader.attach(plugin)
    local calls = 0
    local outline = {
        source = "ncx", spine_count = 2,
        chapters = { { index = 1, title = "Chapter One", level = 0 } },
    }
    plugin.epub = {
        -- Epub.outline accepts both dot and colon calls; the accessor uses dot.
        outline = function(path)
            calls = calls + 1
            plugin.last_outline_path = path
            return outline
        end,
    }
    local first = plugin:getBookOutline("/books/one.epub")
    check("首次解析返回目录", first == outline and calls == 1)
    check("解析带书路径", plugin.last_outline_path == "/books/one.epub")

    local second = plugin:getBookOutline("/books/one.epub")
    check("同书命中内存缓存", second == outline and calls == 1)

    plugin:getBookOutline("/books/two.epub")
    check("换书重新解析", calls == 2)

    local bad, bad_err = plugin:getBookOutline("/books/one.txt")
    check("非 EPUB 拒绝", bad == nil and type(bad_err) == "string")

    plugin.epub = nil
    plugin.loadEpubModule = nil
    local no_engine, no_engine_err = plugin:getBookOutline("/books/three.epub")
    check("无 EPUB 引擎报错", no_engine == nil and type(no_engine_err) == "string")

    plugin.epub = { outline = function() return nil, "坏的 container.xml" end }
    local parse_failed, parse_err = plugin:getBookOutline("/books/four.epub")
    check("解析失败透传错误", parse_failed == nil and parse_err == "坏的 container.xml")
end

print(string.format("\n==== 章节选择器结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
