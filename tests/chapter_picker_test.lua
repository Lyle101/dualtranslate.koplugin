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
    -- The picker asks before translating files a partial selection only
    -- covers in part; the fake keeps the title and buttons so the test can
    -- press them like the user would.
    ["ui/widget/buttondialog"] = {
        new = function(_, opts)
            opts.is_dialog = true
            return opts
        end,
    },
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
    ["dualtranslate_tools"] = {
        utf8_char_len = function(byte)
            if byte < 0xC0 then return 1 end
            if byte < 0xE0 then return 2 end
            if byte < 0xF0 then return 3 end
            return 4
        end,
    },
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

    -- 解析抛异常：错误要兜住，提示不能留在屏幕上
    notifications, repaints = {}, 0
    plugin.epub = { outline = function(_, before_parse)
        if before_parse then before_parse() end
        error("archiver exploded")
    end }
    local crashed, crash_err = plugin:getBookOutline("/books/six.epub")
    check("解析异常被兜住", crashed == nil and type(crash_err) == "string"
        and crash_err:find("archiver exploded", 1, true) ~= nil, tostring(crash_err))
    check("异常路径也关闭提示", #notifications == 1 and notifications[1].closed == true)

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
    Picker.select_rows(state, { 3, 1, 9 })
    check("按页选择忽略越界并保持升序",
        #Picker.selected_indexes(state) == 2
        and Picker.selected_indexes(state)[1] == 1
        and Picker.selected_indexes(state)[2] == 3)

    local big = Picker.new_state({ spine_count = 31, chapters = {} })
    check("分页数量", Picker.page_count(big, 30) == 2)
    check("首页 30 章", #Picker.page_chapters(big, 1, 30) == 30)
    local last_page = Picker.page_chapters(big, 2, 30)
    check("末页剩余 1 章", #last_page == 1 and last_page[1].index == 31)

    local visible = Picker.visible_row_keys({
        { text = "开始翻译" }, { text = "全选本书" },
        { row_key = 1 }, { row_key = 2 }, { row_key = 3 },
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

    -- 一个 spine 文件里有多个目录条目（扫描/PDF 转换书）：行数少于目录条数，
    -- 状态行必须同时给出两个数字，长按要说明合并了多少条。
    local merged_outline = {
        spine_count = 2,
        chapters = {
            { index = 1, title = "第一部分", level = 0,
              aliases = { "第一章", "第二章", "第三章" } },
            { index = 2, title = "第二部分", level = 0, aliases = { "第四章" } },
        },
    }
    local merged = Picker.new_state(merged_outline)
    check("toc_entries 计入别名", merged.chapters[1].toc_entries == 4
        and merged.chapters[2].toc_entries == 2)
    check("toc_total 为目录条数总和", merged.toc_total == 6)
    local merged_items = Picker.build_item_table(merged, {})
    check("合并时状态行同时给段数与目录条数",
        merged_items[6].text == "共 2 段 · 目录 6 条 · 已选 0 章",
        merged_items[6].text)
    check("章节行带 toc_entries 供长按使用", merged_items[7].toc_entries == 4)

    local gap_outline = Picker.new_state({
        spine_count = 3,
        chapters = { { index = 2, title = "正文" } },
    })
    check("目录未覆盖的 spine 不计入 toc_total",
        gap_outline.toc_total == 1 and gap_outline.chapters[1].toc_entries == 0)
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
print("== 2c. 按目录条目出行（锚点粒度） ==")
local section_outline
do
    -- 一个 XHTML 里有三章（扫描/PDF 转换书的典型形态），另一个文件只有一章。
    section_outline = {
        spine_count = 3,
        chapters = {
            { index = 1, title = "第一章", level = 0, aliases = { "第一节", "第二节" } },
            { index = 2, title = "第二章", level = 0 },
        },
        entries = {
            { index = 1, title = "第一章", level = 0, href = "OEBPS/a.xhtml" },
            { index = 1, anchor = "s1", title = "第一节", level = 1, href = "OEBPS/a.xhtml" },
            { index = 1, anchor = "s2", title = "第二节", level = 1, href = "OEBPS/a.xhtml" },
            { index = 2, anchor = "start", title = "第二章", level = 0,
              href = "OEBPS/b.xhtml" },
        },
    }
    local rows = Picker.chapters(section_outline)
    check("每条目录一行", #rows == 4, tostring(#rows))
    check("同文件条目连续并按 file.sub 编号",
        rows[1].index == 1 and rows[1].sub == 1
        and rows[2].sub == 2 and rows[3].sub == 3)
    check("单条目文件不加子号", rows[4].sub == nil and rows[4].index == 2)
    check("锚点随条目保留", rows[1].anchor == nil and rows[2].anchor == "s1"
        and rows[4].anchor == "start")
    check("行键唯一", rows[2].key == 2 and rows[1].key ~= rows[2].key)
    check("未列入目录的 spine 不再补行", #rows == #section_outline.entries)

    -- 稀疏目录（几个部分跨 100 个 spine 文件）不能把中间的章节藏起来
    local coarse = Picker.chapters({
        spine_count = 100,
        chapters = { { index = 1, title = "第一部分" }, { index = 40, title = "第二部分" } },
        entries = {
            { index = 1, title = "第一部分", href = "a" },
            { index = 40, title = "第二部分", href = "b" },
        },
    })
    check("一文件一条目时仍按文件出行", #coarse == 100, tostring(#coarse))
    check("稀疏目录保留标题并补齐空档",
        coarse[1].title == "第一部分" and coarse[2].title == "第 2 节")

    -- 同一个文件重复列出、但一条锚点都没有：定位不到章内位置，别把整本
    -- 切成两条（其余文件会跟着消失），继续按文件出行。
    local no_anchor = Picker.chapters({
        spine_count = 3,
        chapters = { { index = 1, title = "正文" }, { index = 2, title = "第二章" } },
        entries = {
            { index = 1, title = "正文", href = "a" },
            { index = 1, title = "正文（续）", href = "a" },
            { index = 2, title = "第二章", href = "b" },
        },
    })
    check("同文件重复但没有锚点时仍按文件出行", #no_anchor == 3, tostring(#no_anchor))

    local state = Picker.new_state(section_outline)
    check("状态区分条目与文件", state.file_count == 2 and #state.chapters == 4)
    check("toc_total 按文件累加，不随行重复", state.toc_total == 4,
        tostring(state.toc_total))
    local items = Picker.build_item_table(state, {})
    check("状态行给条数与文件数", items[6].text == "共 4 条 · 2 文件 · 已选 0 条",
        items[6].text)
    check("行标题按 file.sub 编号", items[7].text == "▢ 1.1. 第一章", items[7].text)
    check("子条目行带 sub 与锚点", items[8].sub_index == 2 and items[8].anchor == "s1")

    -- 同一文件里只选一条：交付给 job 的仍是唯一文件号，开始按钮按文件计数
    Picker.toggle(state, 2)
    local picked = Picker.build_item_table(state, {})
    check("选中同文件一条仍只交付一个文件",
        #Picker.selected_indexes(state) == 1 and Picker.selected_indexes(state)[1] == 1)
    check("开始按钮按文件计数", picked[1].text == "开始翻译（1 个文件）", picked[1].text)
    local export_items = Picker.build_item_table(state, {}, {
        start_text = "导出任务（%d 章）",
        start_text_files = "导出任务（%d 个文件）",
    })
    check("导出路径用文件措辞", export_items[1].text == "导出任务（1 个文件）",
        export_items[1].text)
    check("部分覆盖的文件被标出", #Picker.partial_files(state) == 1
        and Picker.partial_files(state)[1] == 1)
    Picker.select_all(state)
    check("全选后不再有部分覆盖", #Picker.partial_files(state) == 0)
    Picker.select_none(state)
end

print("== 2d. 部分选择先确认（锚点行仍按文件翻译） ==")
do
    local plugin = {
        currentBookPath = function() return "/books/sections.epub" end,
        getBookOutline = function() return section_outline end,
    }
    local started
    plugin.translateSelectedChapters = function(_, indexes) started = indexes end
    opened_menus, closed_widgets, notifications = {}, {}, {}

    local function last_dialog()
        for index = #opened_menus, 1, -1 do
            if opened_menus[index].is_dialog then return opened_menus[index] end
        end
        return nil
    end

    Picker.show(plugin)
    local menu = opened_menus[1]
    menu.perpage = 14
    -- 只选「1.2 第一节」：文件 1 还有另两条没选
    menu:onMenuSelect(menu.item_table[8])
    menu:onMenuSelect(menu.item_table[1])
    local dialog = last_dialog()
    check("部分选择先弹确认框", dialog ~= nil and #closed_widgets == 0,
        tostring(dialog and dialog.title))
    check("确认框说明会连带翻译其余章节", dialog ~= nil
        and tostring(dialog.title):find("其余章节", 1, true) ~= nil,
        dialog and dialog.title)
    dialog.buttons[1][1].callback()
    check("取消后不开始", started == nil)

    -- 再次点开始并确认：菜单关闭，交付唯一文件号
    menu:onMenuSelect(menu.item_table[1])
    dialog = last_dialog()
    dialog.buttons[1][2].callback()
    check("确认后开始翻译", started ~= nil and #started == 1 and started[1] == 1,
        started and table.concat(started, ","))
    check("确认后关闭菜单", #closed_widgets == 3 and closed_widgets[3] == menu)

    -- 选中文件内全部条目：不需要确认
    opened_menus, closed_widgets, started = {}, {}, nil
    Picker.show(plugin)
    menu = opened_menus[1]
    menu.perpage = 14
    menu:onMenuSelect(menu.item_table[7])
    menu:onMenuSelect(menu.item_table[8])
    menu:onMenuSelect(menu.item_table[9])
    menu:onMenuSelect(menu.item_table[1])
    check("整文件选中时不弹确认框", last_dialog() == nil)
    check("整文件选中直接开始", started ~= nil and #started == 1 and started[1] == 1)

    -- 长按说明所属文件、条目数与锚点
    opened_menus, notifications = {}, {}
    Picker.show(plugin)
    menu = opened_menus[1]
    menu:onMenuHold(menu.item_table[8])
    local text = tostring(notifications[1] and notifications[1].text)
    check("长按给出文件、条目数与锚点",
        text:find("第 1 个文件", 1, true) ~= nil
        and text:find("共有 3 条目录", 1, true) ~= nil
        and text:find("锚点：s1", 1, true) ~= nil, text)
end

-- ============================================================
print("== 2b. 已翻译标记跟随翻译引擎 ==")
do
    local Overlay = require("dualtranslate_overlay")
    local Providers = require("dualtranslate_providers")
    Providers.getProviderById = function(id)
        return id == "microsoft_free" and { id = id } or nil
    end
    Providers.getProviderName = function(id)
        if id == "microsoft_free" then return "Microsoft Edge（免费）" end
        return "未知翻译服务"
    end
    local manifest
    Overlay.loadBookIndex = function() return manifest end
    local plugin = {
        getMode = function() return "microsoft_free" end,
        getBookCacheDirectory = function() return "/tmp/picker-cache" end,
    }
    -- 设备端 manifest 里 display_name 存的是 provider id（真机实测），
    -- 长按文案必须换成菜单同源的引擎名。
    manifest = { providers = {
        microsoft_free = { display_name = "microsoft_free",
            chapters = { 1 }, partial_chapters = { 2 } },
        ["mcp:gpt-5"] = { display_name = "MCP · GPT-5", chapters = { 3 } },
    } }
    local cov = Picker.coverage(plugin, "/books/a.epub")
    check("覆盖度按当前引擎取", cov ~= nil and cov.full[1] == true
        and cov.partial[2] == true and cov.full[3] == nil,
        cov and tostring(cov.full and #cov.full))
    check("整章覆盖后不再算部分", cov ~= nil and cov.partial[1] == nil)
    check("标记带引擎名", cov ~= nil and cov.label == "Microsoft Edge（免费）",
        cov and cov.label)

    -- MCP 是一个引擎、多个模型：标记必须合并该引擎下所有模型。
    plugin.getMode = function() return "mcp_external" end
    local mcp = Picker.coverage(plugin, "/books/a.epub")
    check("MCP 引擎合并所有模型", mcp ~= nil and mcp.full[3] == true and mcp.full[1] == nil,
        mcp and tostring(mcp.full and mcp.full[1]))
    check("单一模型用模型名", mcp ~= nil and mcp.label == "MCP · GPT-5", mcp and mcp.label)
    -- 一个模型整章完成、另一个只做了一部分：合并后必须是「已翻译」。
    manifest.providers["mcp:claude"] = { display_name = "MCP · Claude",
        chapters = { 3 }, partial_chapters = { 3 } }
    local multi = Picker.coverage(plugin, "/books/a.epub")
    check("多模型回落到引擎名", multi ~= nil and multi.label == "MCP 外部翻译",
        multi and multi.label)
    check("整章标记压过部分标记", multi ~= nil and multi.full[3] == true
        and multi.partial[3] == nil)

    -- 导出路径显式指定 MCP 引擎：与菜单当前选中的引擎无关。
    plugin.getMode = function() return "microsoft_free" end
    local export_cov = Picker.coverage(plugin, "/books/a.epub", "mcp_external")
    check("显式引擎覆盖菜单设置", export_cov ~= nil and export_cov.full[3] == true
        and export_cov.full[1] == nil,
        export_cov and tostring(export_cov.full and export_cov.full[1]))

    plugin.getMode = function() return "system" end
    check("没有该引擎的译文时不标记", Picker.coverage(plugin, "/books/a.epub") == nil)
    check("插件没有引擎接口时不标记",
        Picker.coverage({ getBookCacheDirectory = function() return "/tmp/none" end },
            "/books/a.epub") == nil)
    plugin.getMode = function() return "microsoft_free" end
    manifest = nil
    check("无 manifest 时不标记", Picker.coverage(plugin, "/books/a.epub") == nil)

    -- 行文案与状态行
    manifest = { providers = { microsoft_free = { display_name = "Microsoft Edge",
        chapters = { 1 }, partial_chapters = { 2 } } } }
    local state = Picker.new_state({ spine_count = 3, chapters = {} },
        Picker.coverage(plugin, "/books/a.epub"))
    local items = Picker.build_item_table(state, {})
    check("已翻译行带标记", items[7].text == "▢ 1.（已翻译） 第 1 节", items[7].text)
    check("部分翻译行带标记", items[8].text == "▢ 2.（部分） 第 2 节", items[8].text)
    check("未翻译行不加标记", items[9].text == "▢ 3. 第 3 节", items[9].text)
    check("状态行统计已译", items[6].text == "共 3 章 · 已译 1 · 已选 0 章", items[6].text)

    -- 对话框流程：行标记 + 长按说明来源引擎
    opened_menus, notifications = {}, {}
    local flow_plugin = {
        currentBookPath = function() return "/books/picker.epub" end,
        getMode = function() return "microsoft_free" end,
        getBookCacheDirectory = function() return "/tmp/picker-cache" end,
        getBookOutline = function()
            return { spine_count = 2, chapters = {
                { index = 1, title = "One" }, { index = 2, title = "Two" } } }
        end,
    }
    Picker.show(flow_plugin)
    local menu = opened_menus[1]
    check("选择器行内标出已翻译", menu ~= nil
        and menu.item_table[7].text == "▢ 1.（已翻译） One",
        menu and menu.item_table[7].text)
    menu:onMenuHold(menu.item_table[7])
    check("长按说明标记来源", notifications[1] ~= nil
        and tostring(notifications[1].text):find("Microsoft Edge", 1, true) ~= nil,
        notifications[1] and notifications[1].text)

    -- 同一个选择器，导出流程传 engine="mcp_external" 时不显示 Edge 的标记。
    opened_menus = {}
    Picker.show(flow_plugin, { engine = "mcp_external" })
    check("导出时按 MCP 引擎判标记", opened_menus[1] ~= nil
        and opened_menus[1].item_table[7].text == "▢ 1. One",
        opened_menus[1] and opened_menus[1].item_table[7].text)

    Overlay.loadBookIndex = nil
    Providers.getProviderName = nil
    Providers.getProviderById = nil
    opened_menus, notifications = {}, {}
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

    -- 多目录条目合并到一个 spine 文件时，长按要说清合并了几条
    notifications = {}
    menu:onMenuHold({ chapter_index = 2, full_title = "第一部分", toc_entries = 4 })
    check("长按说明合并的目录条数", notifications[1] ~= nil
        and tostring(notifications[1].text):find("有 4 条", 1, true) ~= nil,
        notifications[1] and notifications[1].text)
    check("单标题行不加合并说明", (function()
        notifications = {}
        menu:onMenuHold({ chapter_index = 3, full_title = "独章", toc_entries = 1 })
        return notifications[1] ~= nil
            and tostring(notifications[1].text):find("合并为一个可翻译单元", 1, true) == nil
    end)())

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
