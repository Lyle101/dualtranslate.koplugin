-- ============================================================
-- 章节选择器打开耗时（设计 §15.4 的「< 1 s」）
--
-- 必须在**正在运行的阅读器**里测：Picker 读的是插件实例、EPUB 目录的
-- 内存缓存和 overlay 索引，headless 复现不了。 KOReader 的 httpinspector
-- 插件（端口 8080）可以用 dofile 在阅读器进程里跑这个文件：
--
--   curl "http://<device>:8080/koreader/globals/dofile/'/mnt/us/koreader/plugins/dualtranslate.koplugin/tools/probe_picker.lua'"
--
-- 默认测当前打开的书。 想测另一本而不切换文档时，把路径写进
-- /mnt/us/dtprobe/book.txt（一行），探针会改测那一本：
--
--   echo "/mnt/us/documents/Z-Lib/吴军作品.epub" > /mnt/us/dtprobe/book.txt
--
-- 返回一个表；httpinspector 会把它序列化成 JSON（客户端看到的是一行）。 分段含义：
--   outline_ms   目录解析（内存缓存清空后；磁盘缓存命中则只有几十 ms）
--   coverage_ms  overlay 索引里「已翻译」标记的读取
--   items_ms     796 行的菜单项构建
--   open_ms      真正点开选择器：目录 + 覆盖度 + 菜单项 + Menu:new + show
--   rss_*_kb     进程 RSS（菜单弹出前后）
--
-- 注意：cold outline（没有磁盘缓存）属于「第一次打开这本书」，耗时是
-- 解包 + 遍历 spine 的固定成本，另见 docs/PERF.md §3，不要把那个数字
-- 当成选择器本身的成本。
-- ============================================================
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local Overlay = require("dualtranslate_overlay")
local Picker = require("dualtranslate_picker")
local ffi = require("ffi")

-- Wall clock, same source as tools/bench.lua: the §15.4 numbers must be
-- comparable across scripts.  os.clock() would report CPU only, and the
-- picker does read manifest/entries from disk.
local clock
do
    local ts
    local ok = pcall(function()
        if pcall(ffi.typeof, "struct timespec") then
            ts = ffi.new("struct timespec")
        else
            ffi.cdef[[ struct dt_probe_timespec { long tv_sec; long tv_nsec; };
                int clock_gettime(int, struct dt_probe_timespec *); ]]
            ts = ffi.new("struct dt_probe_timespec")
        end
        if ffi.C.clock_gettime(0, ts) ~= 0 then error("clock_gettime") end
    end)
    if ok then
        clock = function()
            ffi.C.clock_gettime(0, ts)
            return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
        end
    else
        clock = os.clock
    end
end

local ui = ReaderUI.instance
local plugin = ui and ui.dualtranslate
if not plugin then return { error = "dualtranslate plugin not loaded" } end

local function read_first_line(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local line = handle:read("*l")
    handle:close()
    -- A CRLF from a Windows editor would otherwise become part of the path.
    return line and line:gsub("^%s+", ""):gsub("%s+$", "") or nil
end

local book = read_first_line("/mnt/us/dtprobe/book.txt")
if not book or book == "" then
    book = plugin.currentBookPath and plugin:currentBookPath()
        or (ui.document and ui.document.file)
end
if not book then return { error = "no book" } end

local function rss_kb()
    local handle = io.open("/proc/self/status", "rb")
    if not handle then return nil end
    for line in handle:lines() do
        local value = line:match("^VmRSS:%s*(%d+)")
        if value then
            handle:close()
            return tonumber(value)
        end
    end
    handle:close()
    return nil
end

local function median(list)
    table.sort(list)
    return list[math.max(1, math.floor(#list / 2 + 0.5))]
end

local samples = { outline = {}, coverage = {}, items = {}, open = {} }
local rows
for _ = 1, 5 do
    -- Cold memory, warm disk: the picker after the book has been opened once.
    plugin._book_outline_cache = nil
    Overlay.clearEntriesCache()
    local t0 = clock()
    local outline = plugin:getBookOutline(book)
    local t1 = clock()
    if not outline then return { error = "outline failed" } end
    local coverage = Picker.coverage(plugin, book, "mcp_external")
    local t2 = clock()
    local state = Picker.new_state(outline, coverage)
    local t3 = clock()
    local items = Picker.build_item_table(state, {}, {})
    local t4 = clock()
    samples.outline[#samples.outline + 1] = (t1 - t0) * 1000
    samples.coverage[#samples.coverage + 1] = (t2 - t1) * 1000
    samples.items[#samples.items + 1] = (t4 - t3) * 1000
    rows = #items
end

-- The actual tap.  A book other than the open one cannot go through
-- showChapterPicker (it reads the current document), so leave open_ms out.
local open_ms
if book == (plugin.currentBookPath and plugin:currentBookPath()
    or (ui.document and ui.document.file)) then
    local before = rss_kb()
    for _ = 1, 3 do
        plugin._book_outline_cache = nil
        Overlay.clearEntriesCache()
        local t0 = clock()
        -- A raise after UIManager:show would leave the menu on screen; the
        -- inspector only returns the traceback, it cannot clean up for us.
        local ok, menu = pcall(plugin.showChapterPicker, plugin,
            { engine = "mcp_external" })
        local t1 = clock()
        if ok and menu then UIManager:close(menu) end
        samples.open[#samples.open + 1] = (t1 - t0) * 1000
    end
    open_ms = median(samples.open)
    return {
        book = book, rows = rows,
        outline_ms = median(samples.outline),
        coverage_ms = median(samples.coverage),
        items_ms = median(samples.items),
        open_ms = open_ms,
        open_samples = samples.open,
        rss_before_kb = before,
        rss_after_kb = rss_kb(),
    }
end

return {
    book = book, rows = rows,
    outline_ms = median(samples.outline),
    coverage_ms = median(samples.coverage),
    items_ms = median(samples.items),
    -- No menu is shown for another book: this is the cost of everything the
    -- picker has to compute before Menu:new.
    open_ms = median(samples.outline) + median(samples.coverage)
        + median(samples.items),
}
