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
local repaints = 0
local stubs = {
    ["logger"] = { warn = function() end, err = function() end, info = function() end, dbg = function() end },
    ["gettext"] = function(text) return text end,
    ["ui/uimanager"] = {
        show = function(_, widget)
            -- Notices and menus are counted separately: the chapter list
            -- assertions below index opened_menus directly.
            if widget.is_notification then
                notifications[#notifications + 1] = widget
            else
                opened_menus[#opened_menus + 1] = widget
            end
        end,
        close = function(_, widget)
            if widget.is_notification then
                widget.closed = true
            else
                closed_widgets[#closed_widgets + 1] = widget
            end
        end,
        forceRePaint = function() repaints = repaints + 1 end,
        setDirty = function() end,
        scheduleIn = function() end,
        nextTick = function() end,
    },
    ["ui/widget/notification"] = {
        new = function(_, opts)
            opts.is_notification = true
            return opts
        end,
    },
    ["ui/widget/menu"] = {
        new = function(_, opts)
            -- Menu:init computes perpage from the reader setting; the fake
            -- mirrors its default so Picker.show can decide on the trailing
            -- confirm row.
            opts.perpage = opts.perpage or 14
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
        -- The stub also plays the cold-parse hook: the real module calls it only
        -- once the disk cache is known to be stale.
        outline = function(path, before_parse)
            calls = calls + 1
            plugin.last_outline_path = path
            if before_parse then before_parse() end
            return outline
        end,
    }
    local first = plugin:getBookOutline("/books/one.epub")
    check("首次解析返回目录", first == outline and calls == 1)
    check("解析带书路径", plugin.last_outline_path == "/books/one.epub")
    -- 冷解析约 1.9 s 会阻塞 UI：先落一帧提示，再同步解析
    check("冷解析先提示并强制重绘", #notifications == 1 and repaints == 1
        and tostring(notifications[1].text):find("正在解析目录", 1, true) ~= nil)
    check("解析结束关闭提示", notifications[1].closed == true)

    local second = plugin:getBookOutline("/books/one.epub")
    check("同书命中内存缓存", second == outline and calls == 1)
    check("命中缓存不再提示", #notifications == 1 and repaints == 1)

    plugin:getBookOutline("/books/two.epub")
    check("换书重新解析", calls == 2)

    local bad, bad_err = plugin:getBookOutline("/books/one.txt")
    check("非 EPUB 拒绝", bad == nil and type(bad_err) == "string")

    plugin.epub = nil
    plugin.loadEpubModule = nil
    local no_engine, no_engine_err = plugin:getBookOutline("/books/three.epub")
    check("无 EPUB 引擎报错", no_engine == nil and type(no_engine_err) == "string")

    plugin.epub = { outline = function(_, before_parse)
        if before_parse then before_parse() end
        return nil, "坏的 container.xml"
    end }
    local parse_failed, parse_err = plugin:getBookOutline("/books/four.epub")
    check("解析失败透传错误", parse_failed == nil and parse_err == "坏的 container.xml")
    check("解析失败同样关闭提示", #notifications == 3 and notifications[3].closed == true)
    check("无引擎分支不提示（重绘仍为 3 次）", repaints == 3)

    -- 磁盘缓存命中：Epub.outline 在调用 hook 之前就返回，选择器不应闪提示
    notifications, repaints = {}, 0
    plugin.epub = { outline = function() return outline end }
    local disk_hit = plugin:getBookOutline("/books/five.epub")
    check("磁盘缓存命中不提示", disk_hit == outline and #notifications == 0 and repaints == 0)
end

local Picker = require("dualtranslate_picker")

-- ============================================================
print("== 2. 选择器纯逻辑 ==")
do
    local ascii = Picker.truncate_title(string.rep("a", 45))
    check("ASCII 截断到 40 字符 + 省略号",
        ascii:sub(1, 40) == string.rep("a", 40) and ascii:sub(41) == "…")

    local chinese = Picker.truncate_title(string.rep("章", 45))
    check("中文按字符截断", chinese == string.rep("章", 40) .. "…")

    local emoji = Picker.truncate_title(string.rep("😀", 8), 5)
    check("4 字节字符不被切半", emoji == string.rep("😀", 5) .. "…")

    check("短标题原样返回", Picker.truncate_title("第一章") == "第一章")
    check("空标题返回空串", Picker.truncate_title(nil) == "")

    local chapters = Picker.chapters({
        spine_count = 4,
        chapters = {
            { index = 1, title = "封面", level = 0 },
            { index = 3, title = "第三章", level = 1 },
        },
    })
    check("按 spine 补齐缺失章节", #chapters == 4)
    check("目录标题保留", chapters[1].title == "封面" and chapters[3].title == "第三章")
    check("缺失章节用第 N 节", chapters[2].title == "第 2 节" and chapters[4].index == 4)

    local state = Picker.new_state({ spine_count = 3, chapters = {} })
    check("初始未选", Picker.count(state) == 0)
    Picker.toggle(state, 2)
    check("勾选单章", Picker.count(state) == 1 and Picker.selected_indexes(state)[1] == 2)
    Picker.invert(state)
    local inverted = Picker.selected_indexes(state)
    check("反选", Picker.count(state) == 2 and inverted[1] == 1 and inverted[2] == 3)
    Picker.select_all(state)
    check("全选本书", Picker.count(state) == 3)
    Picker.select_none(state)
    check("全不选", Picker.count(state) == 0)
    Picker.select_indexes(state, { 3, 1, 9 })
    check("按页选择忽略越界并保持升序",
        #Picker.selected_indexes(state) == 2
        and Picker.selected_indexes(state)[1] == 1
        and Picker.selected_indexes(state)[2] == 3)

    local big = Picker.new_state({ spine_count = 31, chapters = {} })
    check("分页数量", Picker.page_count(big, 30) == 2)
    check("首页 30 章", #Picker.page_chapters(big, 1, 30) == 30)
    local last_page = Picker.page_chapters(big, 2, 30)
    check("末页剩余 1 章", #last_page == 1 and last_page[1].index == 31)

    local visible = Picker.visible_chapter_indexes({
        { text = "开始翻译" }, { text = "全选本书" },
        { chapter_index = 1 }, { chapter_index = 2 }, { chapter_index = 3 },
    }, 1, 5)
    check("本页可见章节", #visible == 3 and visible[1] == 1 and visible[3] == 3)

    local empty_state = Picker.new_state({ spine_count = 3, chapters = {} })
    local items = Picker.build_item_table(empty_state, {})
    check("首行为开始翻译且未选时禁用",
        items[1].text:find("开始翻译", 1, true) ~= nil and items[1].select_enabled == false)
    check("包含全选/本页/全不选/反选",
        items[2].text == "全选本书" and items[3].text == "全选本页"
        and items[4].text == "全不选" and items[5].text == "反选")
    check("状态行显示章节与已选数",
        items[6].text == "共 3 章 · 已选 0 章" and items[6].select_enabled == false)
    check("章节行带标记、spine index 与标题",
        items[7].text == "▢ 1. 第 1 节" and items[7].chapter_index == 1
        and items[7].full_title == "第 1 节")
    check("单页列表不加尾部确认行", items[#items].chapter_index ~= nil)
    local trailing_items = Picker.build_item_table(empty_state, {}, { trailing = true })
    check("分页列表补尾部确认行",
        trailing_items[#trailing_items].text:find("开始翻译", 1, true) ~= nil)

    Picker.toggle(empty_state, 1)
    local selected_items = Picker.build_item_table(empty_state, {})
    check("勾选后标记与计数同步",
        selected_items[7].text == "▣ 1. 第 1 节"
        and selected_items[1].select_enabled == true
        and selected_items[1].text == "开始翻译（1 章）")
end

-- ============================================================
print("== 3. ChapterPickerDialog 流程 ==")
do
    local plugin = {}
    local outline = {
        spine_count = 3,
        chapters = {
            { index = 1, title = "Chapter One", level = 0 },
            { index = 2, title = "Chapter Two", level = 0 },
            { index = 3, title = "Chapter Three", level = 0 },
        },
    }
    plugin.currentBookPath = function() return "/books/picker.epub" end
    plugin.getBookOutline = function() return outline end
    local started
    plugin.translateSelectedChapters = function(_, indexes) started = indexes end

    opened_menus, closed_widgets = {}, {}
    Picker.show(plugin)
    local menu = opened_menus[1]
    check("打开选择器菜单", menu ~= nil and menu.title == "选择章节")
    check("副标题为书名", menu.subtitle == "picker")
    check("未选时开始禁用", menu.item_table[1].select_enabled == false)
    check("状态行显示章节数", menu.item_table[6].text == "共 3 章 · 已选 0 章")

    local function find_item(predicate)
        for _, item in ipairs(menu.item_table) do
            if predicate(item) then return item end
        end
    end

    menu.perpage = 14
    menu:onMenuSelect(find_item(function(item) return item.chapter_index == 2 end))
    check("勾选章节不关闭菜单", #closed_widgets == 0)
    check("菜单原地刷新", menu.updated and menu.updated >= 1)
    local row = find_item(function(item) return item.chapter_index == 2 end)
    check("章节行标记为已选并带 spine index", row.text == "▣ 2. Chapter Two")
    check("开始项计数更新",
        menu.item_table[1].select_enabled == true and menu.item_table[1].text == "开始翻译（1 章）")

    -- 长按显示未截断标题（M4）
    notifications = {}
    menu:onMenuHold(find_item(function(item) return item.chapter_index == 2 end))
    check("长按显示完整标题", notifications[1] ~= nil
        and tostring(notifications[1].text):find("Chapter Two", 1, true) ~= nil)

    menu:onMenuSelect(find_item(function(item) return item.text == "全选本页" end))
    check("全选本页选中全部可见章节", menu.item_table[1].text == "开始翻译（3 章）")

    menu:onMenuSelect(menu.item_table[1])
    check("开始翻译关闭菜单", #closed_widgets == 1 and closed_widgets[1] == menu)
    check("交付升序章节号",
        started ~= nil and #started == 3 and started[1] == 1 and started[3] == 3)

    -- 目录解析失败：提示，不打开空菜单
    plugin.getBookOutline = function() return nil, "坏的 container.xml" end
    opened_menus, notifications = {}, {}
    Picker.show(plugin)
    check("目录失败给出提示", #opened_menus == 0 and #notifications == 1
        and tostring(notifications[1].text):find("目录解析失败", 1, true) ~= nil)

    plugin.getBookOutline = function() return { spine_count = 0, chapters = {} } end
    opened_menus, notifications = {}, {}
    Picker.show(plugin)
    check("空目录给出提示", #opened_menus == 0 and #notifications == 1
        and tostring(notifications[1].text):find("没有可选择的章节", 1, true) ~= nil)

    -- M5: 超过一页的列表才追加尾部确认行，单页书不重复
    plugin.getBookOutline = function() return { spine_count = 40, chapters = {} } end
    opened_menus = {}
    Picker.show(plugin)
    local long_menu = opened_menus[1]
    check("长列表追加尾部确认行", long_menu ~= nil
        and long_menu.item_table[#long_menu.item_table].text:find("开始翻译", 1, true) ~= nil)
    check("长列表初始化时重建一次", long_menu and long_menu.updated == 1)
end

print(string.format("\n==== 章节选择器结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
