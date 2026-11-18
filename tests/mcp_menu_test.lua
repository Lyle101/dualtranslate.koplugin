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
    check("有任务时列表可构建", ok and #items == 1, tostring(items))
    check("列表项含段数", ok and items[1].text:find("段") ~= nil,
        ok and items[1].text or "")
    check("列表项带序号", ok and items[1].text:find("^1%. ") ~= nil,
        ok and items[1].text or "")
    check("标题计数来自目录名", Mcp.countJobs() == 1)

    os.execute('rm -rf "' .. job_dir .. '"')
    check("删除后计数归零", Mcp.countJobs() == 0)
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
