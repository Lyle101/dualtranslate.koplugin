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
-- TranslationUI.showPersistent: a completion message the user dismisses, so it
-- lands in the same list the assertions read.
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
    -- 3.2.1: the device-side inbox is gone (the agent always commits through
    -- dtctl), so only export / task list / refresh are left.
    check("三个入口", #items == 3)
    check("导出所选章节", items[1].text == "导出所选章节…")
    check("任务列表带计数", items[2].text_func() == "任务列表（0）")
    check("刷新外部译文", items[3].text == "刷新外部译文")
    -- 3.2.2: actions keep the menu open, so a finished export returns to this
    -- page instead of dropping the user back into the book.
    check("导出保持菜单", items[1].keep_menu_open == true)
    check("刷新保持菜单", items[3].keep_menu_open == true)
    check("MCP 页可自刷新", items.refresh_func ~= nil and #items.refresh_func() == 3)
    local job_items = items[2].sub_item_table_func()
    check("空任务列表有占位行", #job_items == 1 and job_items[1].text == "没有任务")
    -- The menu builder runs twice per open; the second call must hit the cache.
    check("任务列表同秒复用", items[2].sub_item_table_func() == job_items)
end

-- ============================================================
print("== 2b. 有任务时构建列表项 ==")
do
    -- Regression: the row text calls _("段") inside the loop.  Naming the loop
    -- variable "_" shadowed gettext and crashed the reader on menu open.
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
    check("有任务时列表可构建", ok and #items == 2, tostring(items))
    check("首行是批量管理", ok and items[1].text_func() == "批量管理（1）")
    check("任务行含段数", ok and items[2].text:find("段") ~= nil,
        ok and items[2].text or "")
    check("任务行带序号", ok and items[2].text:find("^1%. ") ~= nil,
        ok and items[2].text or "")
    -- 删除任务后菜单要留着：任务行的点击不能关菜单。
    check("任务行保持菜单", ok and items[2].keep_menu_open == true)
    check("列表可自刷新", ok and items.needs_refresh == true
        and type(items.refresh_func) == "function")
    check("标题计数来自目录名", Mcp.countJobs() == 1)

    -- 2b-1: 打开详情 → 删除任务，列表原地刷新而不是消失。
    local function fake_menu(item_table)
        local menu = { item_table = item_table, updates = 0, backs = 0 }
        function menu:updateItems(page) self.updates = self.updates + 1; self.page = page end
        function menu:backToUpperMenu() self.backs = self.backs + 1 end
        return menu
    end

    local menu = fake_menu(items)
    items[2].callback(menu)
    check("点任务弹出详情", last_dialog ~= nil
        and tostring(last_dialog.title):find(job_id, 1, true) ~= nil,
        last_dialog and tostring(last_dialog.title))
    last_dialog.buttons[1][2].callback()
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
    local function fake_menu(item_table)
        local menu = { item_table = item_table, updates = 0, backs = 0 }
        function menu:updateItems(page) self.updates = self.updates + 1; self.page = page end
        function menu:backToUpperMenu() self.backs = self.backs + 1 end
        return menu
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
    local fake_epub = { begin_segment_export = function(opts)
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

    dualtranslate.getBookOutline, dualtranslate.epub = real_outline, real_epub
    UIManager.scheduleIn, ProgressbarDialog.new = real_schedule, real_new
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
