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

local notifications, last_dialog, last_viewer, style_calls = {}, {}, nil, 0
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
-- TranslationUI.showPersistent: a completion message the user dismisses, so it
-- lands in the same list the assertions read.
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) notifications[#notifications + 1] = o.text return o end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) last_dialog = o return o end }
end
-- Task detail: a scrollable viewer with our own close/delete row.
package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, o) last_viewer = o return o end }
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

-- TouchMenu stand-in: enough of the widget for the rebuild-in-place paths.
local function fake_menu(item_table)
    local menu = { item_table = item_table, updates = 0, backs = 0 }
    function menu:updateItems(page) self.updates = self.updates + 1; self.page = page end
    function menu:backToUpperMenu() self.backs = self.backs + 1 end
    return menu
end

-- TextViewer options carry the buttons as rows of {text, callback}.
local function viewer_button(viewer, label)
    for _, row in ipairs(viewer and viewer.buttons_table or {}) do
        for _, button in ipairs(row) do
            if button.text == label then return button end
        end
    end
end

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
local real_export_mcp_job = dualtranslate.exportMcpJob
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
    -- 选择任务的计数单位是文件：一个 XHTML 里可能装好几章
    check("选章弹出导出确认", dialog and dialog.title:find("2 个文件", 1, true) ~= nil,
        dialog and dialog.title)
    dialog.buttons[1][2].callback()
    check("确认后按所选章节导出", exported and #exported == 2
        and exported[1].index == 2 and exported[2].index == 5
        and exported[1].from == nil and exported[2].to == nil)

    exported = "unset"
    dualtranslate:translateWholeBook(true)
    last_dialog.buttons[1][2].callback()
    check("整本导出传 nil（全部章节）", exported == nil)
end

-- ============================================================
print("== 2. buildMcpMenu ==")
do
    local items = dualtranslate:buildMcpMenu()
    -- 3.2.1 removed the device-side inbox; 17 Q5 added the per-book glossary
    -- and style guide entries between export and the task list.
    check("五个入口", #items == 5)
    check("导出所选章节", items[1].text == "导出所选章节…")
    check("术语表入口", items[2].text_func() == "术语表…", items[2].text_func())
    check("风格指南入口", items[3].text == "风格指南…")
    check("任务列表带计数", items[4].text_func() == "任务列表（0）")
    check("刷新外部译文", items[5].text == "刷新外部译文")
    -- 3.2.2: actions keep the menu open, so a finished export returns to this
    -- page instead of dropping the user back into the book.
    check("导出保持菜单", items[1].keep_menu_open == true)
    check("刷新保持菜单", items[5].keep_menu_open == true)
    check("MCP 页可自刷新", items.refresh_func ~= nil and #items.refresh_func() == 5)

    -- 17 Q5: the row counts the book's terms and the file lives outside the
    -- manifest, so merely saving it changes nothing else.
    local Glossary = require("dualtranslate_glossary")
    local book_dir = dualtranslate:getBookCacheDirectory(BOOK)
    local saved = Glossary.save(book_dir, {
        terms = { { source = "Darcy", target = "达西" },
            { source = "Lizzy", target = "莉齐" } },
    })
    check("术语表可保存", saved ~= nil)
    local rebuilt = dualtranslate:buildMcpMenu()
    check("术语表入口带条数", rebuilt[2].text_func() == "术语表（2 条）…",
        rebuilt[2].text_func())
    os.remove(book_dir .. "/glossary.json")
    -- 导出走 MCP 引擎，与菜单里当前选中的翻译引擎无关：选择器的「已翻译」
    -- 标记必须按 MCP 的 provider 判，而不是按 getMode()。
    local picker_opts
    local real_picker = dualtranslate.showChapterPicker
    dualtranslate.showChapterPicker = function(_, opts) picker_opts = opts end
    items[1].callback(fake_menu(items))
    dualtranslate.showChapterPicker = real_picker
    check("导出按 MCP 引擎标记已译", picker_opts ~= nil
        and picker_opts.engine == "mcp_external",
        picker_opts and tostring(picker_opts.engine))
    -- 隐私框按章计数（选择器按 TOC 条目选），文件数只在多文件时作括号。
    dualtranslate:confirmMcpExport({ { index = 1 }, { index = 2 } }, nil, 3)
    check("隐私框按章计数", last_dialog ~= nil
        and tostring(last_dialog.title):find("3 章", 1, true) ~= nil
        and tostring(last_dialog.title):find("2 个文件", 1, true) ~= nil,
        last_dialog and tostring(last_dialog.title))
    local job_items = items[4].sub_item_table_func()
    check("空任务列表有占位行", #job_items == 1 and job_items[1].text == "没有任务")
    -- The menu builder runs twice per open; the second call must hit the cache.
    check("任务列表同秒复用", items[4].sub_item_table_func() == job_items)
end

-- ============================================================
print("== 2b. 有任务时构建列表项 ==")
do
    -- Regression guard: the row builder and the detail formatter both loop
    -- with a variable named position, never "_" -- shadowing gettext crashed
    -- the reader on menu open once.
    local job_id = "20261116_000000_0001"
    local job_dir = Mcp.jobDir(job_id)
    os.execute('mkdir -p "' .. job_dir .. '"')
    local job = {
        schema = "dualtranslate.job.v1", job_id = job_id, created_at = os.time(),
        book = { device_path = BOOK, title = "T", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 1, file_size = 1234, file_mtime = 0 },
        chapters = { { index = 1, title = "One" } },
        segments = { { id = "s000001", parent_id = "s000001", part = 1,
            parent_total = 1, chapter_index = 1, chapter_title = "One",
            selector = "p[1]", xpointer = "/body/p[1]", source = "Hello" } },
        options = { max_chars_per_segment = 4500 },
    }
    local file = assert(io.open(job_dir .. "/job.json", "wb"))
    file:write(JSON.encode(job)); file:close()
    -- The previous section built the empty list in the same second.
    dualtranslate._mcp_job_menu_cache = nil

    local ok, items = pcall(function() return dualtranslate:buildMcpJobMenu() end)
    check("有任务时列表可构建", ok and #items == 3, ok and #items or items)
    -- 第一行是「只显示本书任务」开关，第二行才是批量管理。
    check("首行是过滤开关", ok and items[1].text_func() == "只显示本书任务（1/1）",
        ok and items[1].text_func() or "")
    check("过滤默认关闭", ok and items[1].checked_func() == false)
    -- 本轮唯一依赖 TouchMenu 内部行为的标志：回调自己 updateItems。
    check("过滤行自行刷新", ok and items[1].check_callback_updates_menu == true)
    check("第二行是批量管理", ok and items[2].text_func() == "批量管理（1）")
    check("任务行含书名", ok and items[3].text:find("T", 1, true) ~= nil,
        ok and items[3].text or "")
    check("任务行状态是中文", ok and items[3].text:find("已导出", 1, true) ~= nil,
        ok and items[3].text or "")
    check("任务行带序号", ok and items[3].text:find("^1%. ") ~= nil,
        ok and items[3].text or "")
    -- 删除任务后菜单要留着：任务行的点击不能关菜单。
    check("任务行保持菜单", ok and items[3].keep_menu_open == true)
    check("列表可自刷新", ok and items.needs_refresh == true
        and type(items.refresh_func) == "function")
    check("标题计数来自目录名", Mcp.countJobs() == 1)

    -- 2b-1: 打开详情 → 删除任务，列表原地刷新而不是消失。
    local menu = fake_menu(items)
    items[3].callback(menu)
    check("点任务弹出详情", last_viewer ~= nil
        and tostring(last_viewer.text):find(job_id, 1, true) ~= nil,
        last_viewer and tostring(last_viewer.text))
    local detail = last_viewer and last_viewer.text or ""
    check("详情含书名", detail:find("书名：T", 1, true) ~= nil, detail)
    check("详情含章节标题", detail:find("1. One", 1, true) ~= nil, detail)
    check("详情含进度", detail:find("0 / 1 段", 1, true) ~= nil, detail)
    check("详情含状态", detail:find("已导出", 1, true) ~= nil, detail)
    check("详情有删除按钮", viewer_button(last_viewer, "删除任务") ~= nil)
    viewer_button(last_viewer, "删除任务").callback()
    check("删除后任务目录消失", Mcp.countJobs() == 0)
    check("删除后原地刷新菜单", menu.updates == 1 and menu.backs == 0)
    check("删除后列表只剩占位行", #menu.item_table == 1
        and menu.item_table[1].text == "没有任务", #menu.item_table)
    -- 缓存要跟着重建（不能把已删任务留在同秒缓存里）。
    check("删除后同秒缓存已重建", dualtranslate._mcp_job_menu_cache ~= nil
        and dualtranslate._mcp_job_menu_cache.items[1].text == "没有任务")
end

-- ============================================================
print("== 2c. 批量管理 ==")
do
    local function add_job(job_id)
        local dir = Mcp.jobDir(job_id)
        os.execute('mkdir -p "' .. dir .. '"')
        local job = {
            schema = "dualtranslate.job.v1", job_id = job_id, created_at = os.time(),
            book = { device_path = BOOK, title = "T", source_lang = "en",
                target_lang = "zh-Hans", spine_count = 1, file_size = 1234, file_mtime = 0 },
            chapters = { { index = 1, title = "One" } },
            segments = { { id = "s000001", parent_id = "s000001", part = 1,
                parent_total = 1, chapter_index = 1, chapter_title = "One",
                selector = "p[1]", xpointer = "/body/p[1]", source = "Hello" } },
            options = { max_chars_per_segment = 4500 },
        }
        local file = assert(io.open(dir .. "/job.json", "wb"))
        file:write(JSON.encode(job)); file:close()
    end
    add_job("20261117_100000_0001")
    add_job("20261117_090000_0002")
    dualtranslate._mcp_job_menu_cache = nil
    dualtranslate._mcp_batch_selected = nil
    check("两个任务", Mcp.countJobs() == 2)

    local batch = dualtranslate:buildMcpBatchMenu()
    check("全选 + 2 任务 + 删除行", #batch == 4, #batch)
    check("批量页标记", batch.batch == true)
    local select_all, first, second, delete_row = batch[1], batch[2], batch[3], batch[4]
    check("默认未选中", first.checked_func() == false
        and delete_row.enabled_func() == false)
    check("未选中时删除行文案", delete_row.text_func() == "删除所选任务…",
        delete_row.text_func())

    first.callback()
    check("勾选一行", first.checked_func() == true and second.checked_func() == false)
    check("删除行随选择更新", delete_row.enabled_func() == true
        and delete_row.text_func() == "删除所选（1）…", delete_row.text_func())

    select_all.callback()
    check("全选勾上所有行", first.checked_func() and second.checked_func())
    check("全选后按钮变取消", select_all.text_func() == "取消全选（2）",
        select_all.text_func())
    check("全选后计数", delete_row.text_func() == "删除所选（2）…",
        delete_row.text_func())
    select_all.callback()
    check("取消全选清空", first.checked_func() == false and second.checked_func() == false)

    -- 勾选只属于一次批量操作：从任务列表重新进入是干净的，
    -- 只有「删完原地重建」那条路（keep_selection）保留勾选。
    first.callback()
    local reentry = dualtranslate:buildMcpBatchMenu()
    check("重新进入清空勾选", reentry[2].checked_func() == false)
    check("重新进入后删除行禁用", reentry[4].enabled_func() == false)
    reentry[2].callback()
    local kept = dualtranslate:buildMcpBatchMenu(true)
    check("原地重建保留勾选", kept[2].checked_func() == true)

    -- 批量删除：确认后目录消失，页面原地刷新（不关菜单）。
    dualtranslate._mcp_batch_selected = {}
    local batch2 = dualtranslate:buildMcpBatchMenu(true)
    batch2[2].callback()
    local menu = fake_menu(batch2)
    batch2[4].callback(menu)
    check("批量删除弹确认", last_dialog and tostring(last_dialog.title):find("1", 1, true) ~= nil,
        last_dialog and tostring(last_dialog.title))
    last_dialog.buttons[1][2].callback()
    check("批量删除后剩一个任务", Mcp.countJobs() == 1, Mcp.countJobs())
    check("批量删除后原地刷新", menu.updates == 1 and menu.backs == 0)
    check("刷新后页面不含已删任务", #menu.item_table == 3, #menu.item_table)
    check("刷新后选择清空", menu.item_table[1].checked_func() == false)

    -- 删掉最后一个：批量页没有可选项，退回到（已刷新的）任务列表。
    local last_batch = menu.item_table
    last_batch[2].callback()
    local menu2 = fake_menu(last_batch)
    last_batch[3].callback(menu2)
    last_dialog.buttons[1][2].callback()
    check("全部删除后计数归零", Mcp.countJobs() == 0)
    check("批量页空了就退回任务列表", menu2.backs == 1 and menu2.updates == 0)
end

-- ============================================================
print("== 2d. 只显示本书任务 ==")
do
    local OTHER = ROOT .. "/other.epub"
    do local f = assert(io.open(OTHER, "wb")); f:write(string.rep("y", 64)); f:close() end

    -- writeJobFiles 走真实布局（meta.json + 逐行 job.json），详情读的是文件头
    -- created_at is passed in so the two rows have a fixed order.
    local function add_job(job_id, book_path, title, created_at)
        local job = {
            schema = "dualtranslate.job.v1", job_id = job_id, created_at = created_at,
            book = { device_path = book_path, title = title, source_lang = "en",
                target_lang = "zh-Hans", spine_count = 1, file_size = 1234, file_mtime = 0 },
            chapters = { { index = 1, title = "One" }, { index = 2, title = "Two" } },
            segments = {
                { id = "s000001", parent_id = "s000001", part = 1, parent_total = 1,
                    chapter_index = 1, chapter_title = "One", selector = "p[1]",
                    xpointer = "/body/p[1]", source = "Hello" },
                { id = "s000002", parent_id = "s000002", part = 1, parent_total = 1,
                    chapter_index = 2, chapter_title = "Two", selector = "p[2]",
                    xpointer = "/body/p[2]", source = "World" },
            },
            options = { max_chars_per_segment = 4500 },
        }
        assert(Mcp.writeJobFiles(Mcp.jobDir(job_id), job))
    end

    local now = os.time()
    add_job("20261118_100000_0001", BOOK, "本书", now - 60)
    add_job("20261118_090000_0002", OTHER, "别的书", now - 3600)
    dualtranslate:saveSetting("mcp_only_current_book", false)
    dualtranslate._mcp_job_menu_cache = nil

    local items = dualtranslate:buildMcpJobMenu(true)
    check("不过滤时 4 行（开关 + 批量 + 2 任务）", #items == 4, #items)
    check("过滤计数 2/2", items[1].text_func() == "只显示本书任务（2/2）",
        items[1].text_func())
    check("任务行显示各自书名", items[3].text:find("本书", 1, true) ~= nil
        and items[4].text:find("别的书", 1, true) ~= nil)

    local menu = fake_menu(items)
    items[1].callback(menu)
    check("过滤状态写入设置",
        dualtranslate:getSetting("mcp_only_current_book", false) == true)
    check("过滤开关已勾上", menu.item_table[1].checked_func() == true)
    check("过滤后只剩本书任务", #menu.item_table == 3, #menu.item_table)
    check("过滤后计数 1/2", menu.item_table[1].text_func() == "只显示本书任务（1/2）",
        menu.item_table[1].text_func())
    check("过滤后任务行是本书", menu.item_table[3].text:find("本书", 1, true) ~= nil,
        menu.item_table[3].text)

    -- 批量页与任务页看同一批行：全选不会碰到被过滤掉的书。
    local batch = dualtranslate:buildMcpBatchMenu()
    check("批量页只用本书任务", #batch == 3 and batch.batch == true, #batch)
    check("批量页计数是本页行数", batch[1].text_func() == "全选（1）",
        batch[1].text_func())
    check("批量页不含别的书", batch[2].text:find("本书", 1, true) ~= nil
        and batch[2].text:find("别的书", 1, true) == nil, batch[2].text)

    -- 隐藏书的任务即使残留在选中集里，也不会被这次删除带上。
    dualtranslate._mcp_batch_selected = { ["20261118_090000_0002"] = true }
    check("隐藏任务不进删除集", #dualtranslate:selectedMcpJobIds() == 0)
    dualtranslate._mcp_batch_selected = nil

    -- 本书没有任务：给出提示，而不是空页
    dualtranslate.ui.document.file = ROOT .. "/third.epub"
    dualtranslate._mcp_job_menu_cache = nil
    local none = dualtranslate:buildMcpJobMenu(true)
    check("本书无任务有提示", #none == 2
        and none[2].text:find("本书没有任务", 1, true) ~= nil,
        #none .. " / " .. tostring(none[2] and none[2].text))
    dualtranslate.ui.document.file = BOOK

    -- 再点一次关掉过滤，两本书的任务都回来
    dualtranslate._mcp_job_menu_cache = nil
    local reopened = fake_menu(dualtranslate:buildMcpJobMenu(true))
    reopened.item_table[1].callback(reopened)
    check("关闭过滤", dualtranslate:getSetting("mcp_only_current_book", false) == false)
    check("关闭后回到 4 行", #reopened.item_table == 4, #reopened.item_table)
end

-- ============================================================
print("== 2e. 长书名不挤掉时间 ==")
do
    -- 行是单行、末尾截断；书名必须先截，否则「同一本书导两次」靠时间区分
    -- 这件事在最需要它的长书名场景下失效。
    local job_id = "20261118_120000_0003"
    local job = {
        schema = "dualtranslate.job.v1", job_id = job_id, created_at = os.time(),
        book = { device_path = BOOK, title = string.rep("很长的书名", 5),
            source_lang = "en", target_lang = "zh-Hans", spine_count = 1,
            file_size = 1234, file_mtime = 0 },
        chapters = { { index = 1, title = "One" } },
        segments = { { id = "s000001", parent_id = "s000001", part = 1,
            parent_total = 1, chapter_index = 1, chapter_title = "One",
            selector = "p[1]", xpointer = "/body/p[1]", source = "Hello" } },
        options = { max_chars_per_segment = 4500 },
    }
    assert(Mcp.writeJobFiles(Mcp.jobDir(job_id), job))
    dualtranslate._mcp_job_menu_cache = nil
    local items = dualtranslate:buildMcpJobMenu(true)
    local row = items[3]
    check("长书名被截断", row.text:find("…", 1, true) ~= nil, row.text)
    check("时间仍留在行内", row.text:find("%d%d%-%d%d %d%d:%d%d") ~= nil, row.text)
    os.execute('rm -rf "' .. Mcp.jobDir(job_id) .. '"')

    -- 同一预算对拉丁书名同样成立：按列宽（ASCII 1 / 汉字 2）而不是字节。
    local english_id = "20261118_120500_0004"
    job.job_id = english_id
    job.book.title = "Pride and Prejudice - Jane Austen"
    assert(Mcp.writeJobFiles(Mcp.jobDir(english_id), job))
    dualtranslate._mcp_job_menu_cache = nil
    local english = dualtranslate:buildMcpJobMenu(true)
    check("长英文书名也被截断", english[3].text:find("…", 1, true) ~= nil,
        english[3].text)
    check("英文行时间仍在", english[3].text:find("%d%d%-%d%d %d%d:%d%d") ~= nil,
        english[3].text)
    os.execute('rm -rf "' .. Mcp.jobDir(english_id) .. '"')
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
print("== 5. exportMcpJob 分片驱动（3.2.0）==")
do
    -- 真机路径：begin_segment_export 开一次会话，事件循环每轮走一片，
    -- 进度框跟着更新，完成后再把结果交给 exportJob。这里用假会话 +
    -- 立即执行的 scheduleIn 把整条链路跑一遍，任何 UI API 用错都会报错。
    local UIManager = require("ui/uimanager")
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local real_schedule, real_new = UIManager.scheduleIn, ProgressbarDialog.new
    local dialogs = {}
    UIManager.scheduleIn = function(_, _, fn) fn() end
    ProgressbarDialog.new = function(_, opts)
        local widget = { title = opts.title, subtitle = opts.subtitle }
        function widget:show() self.shown = true; dialogs[#dialogs + 1] = self end
        function widget:reportProgress(percent) self.percent = percent end
        function widget:onCloseWidget() end
        return widget
    end

    local slices = 0
    local last_export_opts
    local fake_epub = { begin_segment_export = function(opts)
        last_export_opts = opts
        local session = { position = 0, total = 3 }
        function session:chapter_count() return self.total end
        function session:processed() return self.position end
        function session:step(budget) self.position = self.position + 1; slices = slices + 1; return self.position end
        function session:finish()
            return {
                book_path = opts.book_path, spine_count = 3,
                chapters = { { index = 1, title = "第一章" } },
                segments = { { id = "s000001", parent_id = "s000001", part = 1,
                    parent_total = 1, chapter_index = 1, chapter_title = "第一章",
                    selector = 'body > p:nth-of-type(1)', xpointer = "/body/p[1]",
                    source = "hello world" } },
                unreadable = 0, max_chars_per_segment = 4500,
            }
        end
        return session
    end }
    local real_outline, real_epub = dualtranslate.getBookOutline, dualtranslate.epub
    dualtranslate.getBookOutline = function() return { chapters = {} } end
    dualtranslate.epub = fake_epub
    dualtranslate.exportMcpJob = real_export_mcp_job

    notifications = {}
    dualtranslate:exportMcpJob(nil)
    check("分片次数等于章节数", slices == 3, tostring(slices))
    -- nil 是「整本书」，不能被当成空选择范围而拒绝整本导出
    check("整本导出不冒充范围", last_export_opts ~= nil
        and last_export_opts.chapter_ranges == nil, tostring(last_export_opts
        and type(last_export_opts.chapter_ranges)))
    check("进度框显示过", #dialogs == 1 and dialogs[1].shown == true)
    check("进度跑到 100%", dialogs[1] and dialogs[1].percent == 100,
        dialogs[1] and tostring(dialogs[1].percent))
    local done
    for _, text in ipairs(notifications) do
        if text:find("导出完成", 1, true) then done = text end
    end
    check("导出完成提示", done ~= nil, table.concat(notifications, " | "))
    check("结果来自 collected（1 段）", done and done:find("1 段", 1, true) ~= nil, tostring(done))
    check("完成提示等待轻触关闭", done and done:find("轻触屏幕", 1, true) ~= nil, tostring(done))

    -- 显式范围原样下传（不会被当成「整本」）
    dualtranslate:exportMcpJob({ { index = 2, from = "a", to = "b" } })
    check("显式范围原样下传", last_export_opts ~= nil
        and type(last_export_opts.chapter_ranges) == "table"
        and last_export_opts.chapter_ranges[1].index == 2
        and last_export_opts.chapter_ranges[1].from == "a")

    dualtranslate.getBookOutline, dualtranslate.epub = real_outline, real_epub
    UIManager.scheduleIn, ProgressbarDialog.new = real_schedule, real_new
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
