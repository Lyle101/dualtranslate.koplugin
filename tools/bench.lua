-- ============================================================
-- 性能基准：设计 §15.4 的四项可脚本化指标
--   outline   章节目录解析（冷，删磁盘缓存）
--   css       CSS 构建（3,000 段；单 provider / fallback 三服务）
--   import    MCP 导入（3,000 段；锁 + 事务 + entries/manifest/signal）
--   anchor    锚点页表（单章锚点解析，冷；每个 run 解析一个最重的章节）
--
-- 口径：outline / css / import 各跑 --runs 次（默认 5）取中位数；anchor 每个 run
-- 解析一个不同章节（共 --runs 章）后取中位数。不拿单次读数下结论。
-- 目标是 §15.4 的 Kindle 真机 P50 参考值，本脚本只负责测量与判定。
--
-- 真机（KOReader 自带 luajit，必须用 KO_ROOT 下的 libs）：
--   cd /mnt/us/koreader
--   KO_ROOT=/mnt/us/koreader DT_PLUGIN=/mnt/us/koreader/plugins/dualtranslate.koplugin \
--     ./luajit /mnt/us/koreader/plugins/dualtranslate.koplugin/tools/bench.lua \
--     --device "Kindle PW2" \
--     --book "/mnt/us/documents/Z-Lib/吴军作品.epub" \
--     --book "/mnt/us/documents/programming/C++编程思想.epub" \
--     --book "/mnt/us/documents/electron/PHP和MySQL Web开发(原书第4版).epub" \
--     --runs 5 --work /mnt/us/dtbench \
--     --md /mnt/us/dtbench/PERF.md --json /mnt/us/dtbench/bench.json
--
-- 桌面校验（同 tests/ 的库路径；KOReader.app 的 dylib 需要 DYLD_LIBRARY_PATH）：
--   DYLD_LIBRARY_PATH=/Applications/KOReader.app/Contents/koreader/libs \
--     KO_ROOT=/Applications/KOReader.app/Contents/koreader \
--     luajit tools/bench.lua --book /tmp/one.epub --runs 2 --work /tmp/dt_bench
--
-- 先看有哪些书、形状如何（不跑基准）：
--   luajit tools/bench.lua --list --list-dir /mnt/us/documents
--
-- 参数：--book EPUB（可重复）| --runs N | --segments N | --css-segments N
--       --only outline,css,import,anchor | --work DIR | --md PATH | --json PATH
--       --device NAME（默认读 DT_DEVICE）| --list [--list-dir DIR] | --keep | --help
--
-- 安全：只写 --work 目录（默认设备 /mnt/us/dtbench，桌面 /tmp/dt_bench），
-- 目录里有 .dtbench 标记才会清理 data/ 与 css/；--work 与 KO_ROOT 重叠会被拒绝。
-- --keep 保留 data/ 与 css/ 以便复现。不碰 KOReader 真实的 data 目录；
-- 导入用例只在基准库里删自己的行。
-- ============================================================

local ffi = require("ffi")

local function script_plugin_dir()
    local env = os.getenv("DT_PLUGIN")
    if env and env ~= "" then return (env:gsub("[/\\]+$", "")) end
    local dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
    -- bench.lua lives in tools/, modules live one level up; probe instead of
    -- guessing so `luajit tools/bench.lua` and an absolute path both work.
    for _, candidate in ipairs({ dir, dir .. "/.." }) do
        local probe = io.open(candidate .. "/dualtranslate_tools.lua", "rb")
        if probe then
            probe:close()
            return candidate
        end
    end
    return dir
end

local PLUGIN = script_plugin_dir()

-- ---------------- arguments ----------------
local opts = {
    runs = 5,
    segments = 3000,
    css_segments = 3000,
    books = {},
    only = nil,
    work = nil,
    md = nil,
    json = nil,
    device = os.getenv("DT_DEVICE") or "",
    list_dir = nil,
    list = false,
    keep = false,
}
do
    local index = 1
    local function next_value(flag)
        index = index + 1
        local value = arg[index]
        if value == nil or value:sub(1, 2) == "--" then
            io.stderr:write("参数 " .. flag .. " 缺少取值\n")
            os.exit(2)
        end
        return value
    end
    while arg and index <= #arg do
        local item = arg[index]
        if item == "--runs" then opts.runs = tonumber(next_value(item)) or opts.runs
        elseif item == "--segments" then opts.segments = tonumber(next_value(item)) or opts.segments
        elseif item == "--css-segments" then opts.css_segments = tonumber(next_value(item)) or opts.css_segments
        elseif item == "--book" then opts.books[#opts.books + 1] = next_value(item)
        elseif item == "--only" then opts.only = next_value(item)
        elseif item == "--work" then opts.work = next_value(item)
        elseif item == "--md" then opts.md = next_value(item)
        elseif item == "--json" then opts.json = next_value(item)
        elseif item == "--device" then opts.device = next_value(item)
        elseif item == "--list" then opts.list = true
        elseif item == "--list-dir" then opts.list_dir = next_value(item)
        elseif item == "--keep" then opts.keep = true
        elseif item == "--help" or item == "-h" then
            print("用法: luajit tools/bench.lua [--book EPUB]... [--runs N] [--segments N]")
            print("      [--css-segments N] [--only outline,css,import,anchor] [--work DIR]")
            print("      [--md PATH] [--json PATH] [--device NAME] [--keep]")
            print("      luajit tools/bench.lua --list [--list-dir DIR]")
            os.exit(0)
        else
            io.stderr:write("忽略未知参数: " .. tostring(item) .. "\n")
        end
        index = index + 1
    end
end
opts.runs = math.max(1, math.floor(opts.runs))
opts.segments = math.max(1, math.floor(opts.segments))
opts.css_segments = math.max(1, math.floor(opts.css_segments))

local METRICS = { outline = true, css = true, import = true, anchor = true }
local only = nil
if opts.only then
    only = {}
    local count = 0
    for name in tostring(opts.only):gmatch("[^,%s]+") do
        if not METRICS[name] then
            io.stderr:write("未知指标: " .. name .. "（可选 outline,css,import,anchor）\n")
            os.exit(2)
        end
        if not only[name] then
            only[name] = true
            count = count + 1
        end
    end
    if count == 0 then
        io.stderr:write("--only 至少要给一个指标\n")
        os.exit(2)
    end
end
local function wants(name) return not only or only[name] == true end

-- ---------------- runtime paths ----------------
local KO = os.getenv("KO_ROOT")
if not KO or KO == "" then
    for _, candidate in ipairs({
        "/mnt/us/koreader",
        "/Applications/KOReader.app/Contents/koreader",
    }) do
        local probe = io.open(candidate .. "/reader.lua", "rb")
        if probe then
            probe:close()
            KO = candidate
            break
        end
    end
end
KO = (KO or "."):gsub("[/\\]+$", "")

package.path = table.concat({
    KO .. "/?.lua", KO .. "/common/?.lua", KO .. "/frontend/?.lua",
    KO .. "/common/?/init.lua", PLUGIN .. "/?.lua", package.path,
}, ";")
package.cpath = table.concat({
    KO .. "/?.so", KO .. "/common/?.so", KO .. "/?.dylib", package.cpath,
}, ";")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then
    io.stderr:write("SKIP: libkoreader-lfs unavailable（请设置 KO_ROOT）\n")
    os.exit(2)
end

-- Absolute paths before the chdir below (ffi.loadlib resolves libs/ from cwd).
local cwd = lfs.currentdir()
local function absolute(path)
    if not path or path == "" or path:sub(1, 1) == "/" then return path end
    return (cwd .. "/" .. path):gsub("/%./", "/")
end
PLUGIN = absolute(PLUGIN):gsub("/+$", "")
package.path = PLUGIN .. "/?.lua;" .. package.path
opts.md = absolute(opts.md)
opts.json = absolute(opts.json)
if opts.md == "" then opts.md = nil end
if opts.json == "" then opts.json = nil end
for position, book in ipairs(opts.books) do opts.books[position] = absolute(book) end

local default_work = lfs.attributes("/mnt/us", "mode") == "directory"
    and "/mnt/us/dtbench" or "/tmp/dt_bench"
opts.work = (absolute(opts.work) or default_work):gsub("/+$", "")
-- Deleting <work>/data and <work>/css must never reach into KOReader or a
-- bare root; the marker file checked in cleanup_work() covers the rest.
if opts.work == "" or opts.work == "/" or opts.work:match("^/[^/]+$") or opts.work == KO
    or KO:sub(1, #opts.work + 1) == opts.work .. "/"
    or opts.work:sub(1, #KO + 1) == KO .. "/" then
    io.stderr:write("拒绝 --work=" .. tostring(opts.work)
        .. "（为空、根目录/一级目录，或与 KO_ROOT 重叠）\n")
    os.exit(2)
end

-- Bundled native libs (libs/libarchive.so.13, libsqlite3 ...) are found
-- relative to the KOReader root; chdir there before anything loads them.
pcall(lfs.chdir, KO)
if type(ffi.loadlib) ~= "function" then pcall(require, "ffi/loadlib") end
if type(ffi.loadlib) ~= "function" then
    ffi.loadlib = function(name) return ffi.load(name) end
end

local ok_json, JSON = pcall(require, "json")
local ok_sq3 = pcall(require, "lua-ljsqlite3/init")
if not ok_json or not ok_sq3 then
    io.stderr:write("SKIP: json / lua-ljsqlite3 unavailable（请设置 KO_ROOT）\n")
    os.exit(2)
end

-- ---------------- isolated data dir + stubs ----------------
local data_dir = opts.work .. "/data"
package.preload["datastorage"] = function()
    return { getDataDir = function() return data_dir end }
end
package.preload["logger"] = function()
    return {
        warn = function(...) end, err = function(...) end,
        info = function(...) end, dbg = function(...) end,
    }
end
package.preload["util"] = function()
    return {
        makePath = function(path)
            if not path or path == "" then return false end
            if lfs.attributes(path, "mode") == "directory" then return true end
            local prefix = path:sub(1, 1) == "/" and "" or "."
            for component in path:gmatch("[^/]+") do
                prefix = prefix .. "/" .. component
                if lfs.attributes(prefix, "mode") ~= "directory" then
                    local ok = lfs.mkdir(prefix)
                    if not ok and lfs.attributes(prefix, "mode") ~= "directory" then
                        return false
                    end
                end
            end
            return lfs.attributes(path, "mode") == "directory"
        end,
        trim = function(value)
            return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end,
        sleep = function() end, usleep = function() end,
        getTimestamp = function() return os.time() end,
    }
end

-- Modules are loaded from the plugin dir and registered under the names the
-- other modules require(), so Epub/Store see the same instances.
local function load_module(name)
    local module = dofile(PLUGIN .. "/" .. name .. ".lua")
    package.loaded[name] = module
    return module
end

local Tools = load_module("dualtranslate_tools")
local Overlay = load_module("dualtranslate_overlay")
-- Preloaded only so Store/Epub share this instance through require().
load_module("dualtranslate_coverage")
local Cache = load_module("dualtranslate_cache")
local Store = load_module("dualtranslate_store")
local Epub = load_module("dualtranslate_epub")

-- ---------------- clock ----------------
local clock
do
    local label = "cpu"
    pcall(function()
        local ts
        if pcall(ffi.typeof, "struct timespec") then
            ts = ffi.new("struct timespec")
        else
            ffi.cdef[[ struct dt_bench_timespec { long tv_sec; long tv_nsec; };
                int clock_gettime(int, struct dt_bench_timespec *); ]]
            ts = ffi.new("struct dt_bench_timespec")
        end
        if ffi.C.clock_gettime(0, ts) == 0 then
            label = "wall"
            clock = function()
                ffi.C.clock_gettime(0, ts)
                return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
            end
        end
    end)
    clock = clock or os.clock
    opts.clock_label = label
end

-- ---------------- small helpers ----------------
local function median(samples)
    if #samples == 0 then return nil end
    local sorted = {}
    for index, value in ipairs(samples) do sorted[index] = value end
    table.sort(sorted)
    return sorted[math.max(1, math.floor((#sorted + 1) / 2))]
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, data)
    local file = io.open(path, "wb")
    if not file then return false end
    file:write(data)
    file:close()
    return true
end

-- The report is the deliverable: a half-written PERF.md must not survive a
-- crash mid-write, so land it under .tmp and rename.
local function write_atomic(path, data)
    local temporary = path .. ".tmp"
    if not write_file(temporary, data) then return false end
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return false
    end
    return true
end

local function mkdir_p(path)
    return Tools.mkdir_p(path)
end

local function basename(path)
    return (path:gsub("[/\\]+$", ""):match("([^/\\]+)$")) or path
end

local function label_of(path)
    return (basename(path):gsub("%.[Ee][Pp][Uu][Bb]$", ""))
end

local function fmt_ms(value)
    if not value then return "—" end
    if value >= 1000 then return string.format("%.2f s", value / 1000) end
    return string.format("%.1f ms", value)
end

local function fmt_kb(bytes)
    if not bytes then return "—" end
    return string.format("%.0f KB", bytes / 1024)
end

local function fmt_samples(samples)
    local sorted = {}
    for index, value in ipairs(samples) do sorted[index] = value end
    table.sort(sorted)
    local parts = {}
    for _, value in ipairs(sorted) do parts[#parts + 1] = fmt_ms(value) end
    return table.concat(parts, " / ")
end

local function outline_cache_path(book_path)
    return data_dir .. "/cache/dualtranslate/outline/"
        .. Tools.stable_path_hash(book_path) .. ".json"
end

local function read_small(path)
    local data = read_file(path)
    if not data then return nil end
    return (data:gsub("%s+$", ""))
end

-- ---------------- book shapes ----------------
local function scan_books(root)
    local found = {}
    local function walk(dir, depth)
        if depth > 4 then return end
        local ok, iterator, state = pcall(lfs.dir, dir)
        if not ok or not iterator then return end
        for name in iterator, state do
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    walk(path, depth + 1)
                elseif mode == "file" and name:lower():match("%.epub$") then
                    found[#found + 1] = path
                end
            end
        end
    end
    walk(root, 1)
    table.sort(found)
    return found
end

local function book_shape(path)
    local size = lfs.attributes(path, "size")
    if not size then return nil, "找不到书文件" end
    os.remove(outline_cache_path(path))
    local started = clock()
    local outline, err = Epub.outline(path)
    local elapsed = (clock() - started) * 1000
    if not outline then return nil, err or "目录解析失败" end
    return {
        path = path,
        label = label_of(path),
        size = size,
        spine_count = outline.spine_count or 0,
        chapters = #(outline.chapters or {}),
        entries = #(outline.entries or {}),
        source = outline.source,
        first_parse_ms = elapsed,
        outline = outline,
    }
end

-- ---------------- outline ----------------
local function bench_outline(book)
    local cache_file = outline_cache_path(book.path)
    local samples, last = {}, nil
    for _ = 1, opts.runs do
        os.remove(cache_file)
        os.remove(cache_file .. ".tmp")
        collectgarbage("collect")
        local started = clock()
        local outline, err = Epub.outline(book.path)
        samples[#samples + 1] = (clock() - started) * 1000
        if not outline then
            return nil, "目录解析失败: " .. tostring(err)
        end
        last = outline
    end
    local chapters = #(last.chapters or {})
    local entries = #(last.entries or {})
    -- §15.4 defines the target on 100 chapters, so the divisor is the chapter
    -- rows (TOC-referenced spine files).  The extrapolation is linear while
    -- the real cost also has fixed extraction overhead; keep the raw median
    -- next to it and treat the derived value as an order-of-magnitude check
    -- (see the caveat in the generated report).
    local divisor = math.max(1, chapters)
    return {
        samples = samples,
        median_ms = median(samples),
        normalized_100_ms = median(samples) * 100 / divisor,
        spine_count = last.spine_count or 0,
        chapters = chapters,
        entries = entries,
        source = last.source,
    }, last
end

-- ---------------- CSS ----------------
local PROVIDER_A = "mcp:bench-a"
local PROVIDER_B = "mcp:bench-b"
local PROVIDER_C = "mcp:bench-c"

local function make_entries(count, salt, offset)
    local entries = {}
    for index = 1, count do
        local key = (offset or 0) + index
        local chapter = (key - 1) % 200 + 1
        local paragraph = math.floor((key - 1) / 200) + 1
        local href = string.format("OEBPS/Text/ch%03d.xhtml", chapter)
        -- Same spelling collect_chapter_candidates writes: the fragment is
        -- addressed by its Source attribute, the path uses :nth-of-type, and a
        -- list parent rides on its child list's ::before (three CSS rules).
        local head = string.format(
            'DocFragment[Source="%s"] > body > div:nth-of-type(1)', href)
        local fragment = "/body/DocFragment"
            .. (chapter > 1 and ("[" .. chapter .. "]") or "")
        local entry
        if key % 97 == 0 then
            entry = {
                selector = head .. " > ul:nth-of-type(1) > li:nth-of-type(2)"
                    .. " > ol:nth-of-type(1)::before",
                xpointer = fragment .. "/body/div/ul/li/ol",
                list_indent = "2.2em",
            }
        else
            entry = {
                selector = head .. " > p:nth-of-type(" .. (paragraph + 1) .. ")",
                xpointer = fragment .. "/body/div/p[" .. (paragraph + 1) .. "]",
            }
        end
        entry.chapter_index = chapter
        entry.source = string.format("Benchmark paragraph %d, %s.", key, salt)
        entry.translation = string.format("第 %d 段译文，用于 CSS 构建基准，%s。", key, salt)
        entry.created_at = 0
        entries[index] = entry
    end
    return entries
end

local function prepare_css_fixture(dir, book, providers)
    Tools.rmtree(dir)
    if not mkdir_p(dir) then return nil, "无法创建 CSS 基准目录" end
    local manifest = {
        version = 3, revision = 0,
        book_path = book.path,
        source_lang = "en", target_lang = "zh-Hans",
        spine_count = book.spine_count,
        book_size = book.size, book_mtime = 0,
        display_mode = "manual", display_provider = providers[1].id,
        display_fallback = #providers > 1,
        last_used_at = {},
        fallback_order = {},
        providers = {},
    }
    for _, provider in ipairs(providers) do
        manifest.providers[provider.id] = {
            display_name = provider.id, kind = "mcp", confirmed = true,
            chapters = {}, partial_chapters = {}, failed_chapters = {},
            complete = false, translated_count = provider.count,
            updated_at = 0,
        }
        manifest.fallback_order[#manifest.fallback_order + 1] = provider.id
        manifest.last_used_at[provider.id] = 0
    end
    if not Overlay.saveManifest(dir, manifest) then return nil, "无法写 manifest" end
    local sizes = {}
    for position, provider in ipairs(providers) do
        local entries = make_entries(provider.count, "服务" .. position, provider.offset)
        if not Overlay.saveEntries(dir, provider.id, {
            target_lang = "zh-Hans", entries = entries,
        }) then
            return nil, "无法写 entries: " .. provider.id
        end
        sizes[provider.id] = lfs.attributes(Overlay.entriesPath(dir, provider.id), "size") or 0
    end
    -- Backdate past the FAT32 ~2 s window: the overlay cache only trusts its
    -- entries stats once the file is older than that, and the steady state
    -- (the case a reader hits when changing font size minutes after an
    -- import) must be measurable too.  Cold builds are unaffected.
    local backdated = type(lfs.touch) == "function"
    if backdated then
        for _, provider in ipairs(providers) do
            local ok, touched = pcall(
                lfs.touch, Overlay.entriesPath(dir, provider.id), nil, os.time() - 10)
            if not ok or not touched then backdated = false end
        end
    end
    return { dir = dir, sizes = sizes, backdated = backdated }
end

local function bench_css(dir, provider, fallback, backdated)
    local options = {
        translation_visible = true,
        translation_color = "#666666",
        translation_size = "1em",
        provider = provider,
        fallback = fallback,
    }
    -- Entry decode alone: this is the part the CSS cache cannot skip when the
    -- option key changes (see build_css_v3), so it is reported on its own.
    local load_samples = {}
    for _ = 1, opts.runs do
        collectgarbage("collect")
        local started = clock()
        local doc = Overlay.loadEntries(dir, provider)
        load_samples[#load_samples + 1] = (clock() - started) * 1000
        if not doc then return nil, "entries 读取失败: " .. provider end
    end
    local samples, bytes = {}, 0
    for _ = 1, opts.runs do
        Overlay.clearCssCache()
        collectgarbage("collect")
        local started = clock()
        local css = Overlay.buildCss(dir, options)
        samples[#samples + 1] = (clock() - started) * 1000
        bytes = #css
        if bytes == 0 then return nil, "CSS 为空" end
    end
    -- Same options again: a full cache hit is what a page re-render costs.
    local hit_samples
    if backdated then
        Overlay.clearCssCache()
        Overlay.buildCss(dir, options)
        hit_samples = {}
        for _ = 1, opts.runs do
            collectgarbage("collect")
            local started = clock()
            Overlay.buildCss(dir, options)
            hit_samples[#hit_samples + 1] = (clock() - started) * 1000
        end
    end
    return {
        samples = samples,
        median_ms = median(samples),
        bytes = bytes,
        load_samples = load_samples,
        load_ms = median(load_samples),
        hit_samples = hit_samples,
        hit_ms = hit_samples and median(hit_samples) or nil,
    }
end

-- §15.4's fallback case is "3,000 segments across three services": the
-- selectors are disjoint (each paragraph was translated by one provider), so
-- the merged stylesheet still has 3,000 rules.
local function split_specs(total)
    local per = math.floor(total / 3)
    local first = total - per * 2
    return {
        { id = PROVIDER_A, count = first, offset = 0 },
        { id = PROVIDER_B, count = per, offset = first },
        { id = PROVIDER_C, count = per, offset = first + per },
    }
end

-- The other real shape: every provider was run over the whole book, so each
-- entries file holds all 3,000 segments and merging keeps the first non-nil
-- rule.  That is the storage/IO worst case (3x file size, 3x JSON decode),
-- reported without a §15.4 target.
local function full_specs(total)
    return {
        { id = PROVIDER_A, count = total, offset = 0 },
        { id = PROVIDER_B, count = total, offset = 0 },
        { id = PROVIDER_C, count = total, offset = 0 },
    }
end

local function bench_css_for(book)
    local base = opts.work .. "/css/" .. book.index
    local single, single_err = prepare_css_fixture(base .. "_single", book,
        { { id = PROVIDER_A, count = opts.css_segments, offset = 0 } })
    if not single then return nil, single_err end
    local split, split_err = prepare_css_fixture(
        base .. "_split", book, split_specs(opts.css_segments))
    if not split then return nil, split_err end
    local full, full_err = prepare_css_fixture(
        base .. "_full", book, full_specs(opts.css_segments))
    if not full then return nil, full_err end
    local single_result, single_error = bench_css(
        single.dir, PROVIDER_A, false, single.backdated)
    if not single_result then return nil, single_error end
    local split_result, split_error = bench_css(
        split.dir, PROVIDER_A, true, split.backdated)
    if not split_result then return nil, split_error end
    local full_result, full_error = bench_css(
        full.dir, PROVIDER_A, true, full.backdated)
    if not full_result then return nil, full_error end
    local function sum(sizes)
        local total = 0
        for _, provider in ipairs({ PROVIDER_A, PROVIDER_B, PROVIDER_C }) do
            total = total + (sizes[provider] or 0)
        end
        return total
    end
    return {
        single = single_result,
        fallback = split_result,
        fallback_full = full_result,
        entries_single_bytes = single.sizes[PROVIDER_A] or 0,
        entries_fallback_bytes = sum(split.sizes),
        entries_fallback_full_bytes = sum(full.sizes),
    }
end

-- ---------------- import ----------------
local function build_import_case(book, outline, target_lang, provider_id)
    local chapters = outline.chapters or {}
    if #chapters == 0 then
        chapters = { { index = 1, title = "Chapter 1" } }
    end
    local used, used_seen = {}, {}
    local segments = {}
    local parent_number = 0
    while #segments < opts.segments do
        parent_number = parent_number + 1
        local parts = (parent_number % 20 == 0) and 2 or 1
        local chapter = chapters[((parent_number - 1) % #chapters) + 1]
        local chapter_index = tonumber(chapter.index) or 1
        if not used_seen[chapter_index] then
            used_seen[chapter_index] = true
            used[#used + 1] = { index = chapter_index, title = chapter.title or ("Chapter " .. chapter_index) }
        end
        local paragraph = math.floor((parent_number - 1) / #chapters) + 1
        local base_selector = string.format(
            "/body/DocFragment[%d]/body/div/p[%d]", chapter_index, paragraph)
        local parent_id = string.format("s%06d", parent_number)
        for part = 1, parts do
            local id = parts == 1 and parent_id
                or string.format("%s_%d", parent_id, part)
            segments[#segments + 1] = {
                id = id,
                parent_id = parts == 1 and id or parent_id,
                part = part,
                parent_total = parts,
                chapter_index = chapter_index,
                chapter_title = chapter.title,
                selector = base_selector,
                xpointer = base_selector,
                source = string.format("Benchmark source %d part %d.", parent_number, part),
                list_indent = (parent_number % 50 == 0) and "2.2em" or nil,
            }
        end
    end
    table.sort(used, function(left, right) return left.index < right.index end)
    local job_id = string.format("bench_%d", os.time())
    local job = {
        schema = "dualtranslate.job.v1",
        job_id = job_id,
        created_at = os.time(),
        book = {
            device_path = book.path,
            title = book.label,
            source_lang = "en",
            target_lang = target_lang,
            spine_count = book.spine_count,
            file_size = book.size,
            file_mtime = lfs.attributes(book.path, "modification") or 0,
        },
        chapters = used,
        segments = segments,
        options = { max_chars_per_segment = 4500, split_long_segments = true },
    }
    local translations = {}
    for _, segment in ipairs(segments) do
        translations[#translations + 1] = {
            id = segment.id,
            text = string.format("译文 %s", segment.id),
        }
    end
    local result = {
        schema = "dualtranslate.result.v1",
        job_id = job_id,
        provider = {
            provider_id = provider_id, kind = "mcp",
            model_name = "bench-model", display_name = "Bench",
            confirmed = true,
        },
        translations = translations,
    }
    return { job = job, result = result, segments = #segments,
        parents = parent_number, chapters = #used }
end

local function bench_import(book, outline, cache)
    local target_lang = "zh-Hans"
    local provider_id = "mcp:bench-import"
    local case = build_import_case(book, outline, target_lang, provider_id)
    local dir = Store.bookDir(book.path, target_lang)
    local function reset()
        Tools.rmtree(dir)
        -- Public helper: drops this book's rows from the bench database only.
        cache:clearForBook(book.path)
        local rows = cache:_queryAll(
            "SELECT COUNT(*) FROM book_translations WHERE book_path = ?", book.path)
        local remaining = tonumber(rows[1] and rows[1][1])
        -- nil means the query itself failed; do not turn that into a false
        -- "cannot clean" error, the import will surface a real DB failure.
        if remaining and remaining ~= 0 then
            error("无法清理基准数据行")
        end
        Overlay.clearCssCache()
    end
    local samples, last = {}, nil
    for _ = 1, opts.runs do
        reset()
        collectgarbage("collect")
        local started = clock()
        local summary, err = Store.importResult(case.job, case.result)
        samples[#samples + 1] = (clock() - started) * 1000
        if not summary then
            return nil, "导入失败: " .. tostring(err)
        end
        last = summary
    end
    if last.submitted ~= case.segments or last.accepted ~= case.parents then
        return nil, string.format("导入结果不符: submitted=%s accepted=%s（期望 %d/%d）",
            tostring(last.submitted), tostring(last.accepted),
            case.segments, case.parents)
    end
    return {
        samples = samples,
        median_ms = median(samples),
        segments = case.segments,
        parents = case.parents,
        chapters = case.chapters,
        submitted = last.submitted,
        accepted = last.accepted,
        rejected = #(last.rejected or {}),
        translated_count = last.translated_count,
        entries_bytes = lfs.attributes(
            Overlay.entriesPath(dir, provider_id), "size") or 0,
    }
end

-- ---------------- anchor page table ----------------
local function pick_anchor_chapters(outline, count)
    local per_index = {}
    for _, entry in ipairs(outline.entries or {}) do
        local index = tonumber(entry.index)
        if index then per_index[index] = (per_index[index] or 0) + 1 end
    end
    local candidates = {}
    for index, entries in pairs(per_index) do
        candidates[#candidates + 1] = { index = index, anchors = entries }
    end
    if #candidates == 0 then
        for _, chapter in ipairs(outline.chapters or {}) do
            local index = tonumber(chapter.index)
            if index then candidates[#candidates + 1] = { index = index, anchors = 1 } end
        end
    end
    -- Heaviest files first: those are the chapters whose page table costs the
    -- most; ties resolved by index so the sample is stable across runs.
    table.sort(candidates, function(left, right)
        if left.anchors ~= right.anchors then return left.anchors > right.anchors end
        return left.index < right.index
    end)
    local picked = {}
    for position = 1, math.min(count, #candidates) do
        picked[#picked + 1] = candidates[position]
    end
    return picked
end

local function bench_anchor(book, outline)
    local candidates = pick_anchor_chapters(outline, opts.runs)
    if #candidates == 0 then return nil, "没有可测的目录锚点" end
    -- Warm the per-book spine cache outside the timing: entering a new chapter
    -- reuses it in the real reader too.
    Epub.spine(book.path)
    local samples, anchors, paths_count = {}, {}, {}
    for _, candidate in ipairs(candidates) do
        collectgarbage("collect")
        local started = clock()
        local paths = Epub.chapter_anchor_paths(book.path, candidate.index)
        samples[#samples + 1] = (clock() - started) * 1000
        if type(paths) ~= "table" then
            return nil, "锚点解析失败: spine " .. tostring(candidate.index)
        end
        local total = 0
        for _ in pairs(paths) do total = total + 1 end
        anchors[#anchors + 1] = candidate.anchors
        paths_count[#paths_count + 1] = total
    end
    return {
        samples = samples,
        median_ms = median(samples),
        anchors = anchors,
        paths = paths_count,
        chapters = #candidates,
    }
end

-- ---------------- report ----------------
local skipped_books = {}

local function collect_environment()
    local environment = {
        device = opts.device ~= "" and opts.device or "未标注",
        ko_root = KO,
        kor_version = read_small(KO .. "/git-rev") or "未知",
        luajit = jit and jit.version or _VERSION,
        platform = tostring(ffi.os) .. "/" .. tostring(ffi.arch),
        kernel = "未知",
        runs = opts.runs,
        segments = opts.segments,
        css_segments = opts.css_segments,
        clock = opts.clock_label,
        work = opts.work,
        data = data_dir,
        generated_at = os.date("%Y-%m-%d %H:%M"),
        skipped_books = skipped_books,
    }
    local handle = io.popen("uname -srm 2>/dev/null")
    if handle then
        local line = handle:read("*l")
        handle:close()
        if line and line ~= "" then environment.kernel = line end
    end
    return environment
end

local TARGETS = {
    outline_100 = 500,
    css_single = 200,
    css_fallback = 500,
    import_3000 = 5000,
}

local function judge(value, target)
    if not value then return "—" end
    if value <= target then return "达标" end
    return "未达标"
end

local function range_of(books, results, getter)
    local low, high
    for _, book in ipairs(books) do
        local value = getter(results[book.label] or {})
        if value then
            if not low or value < low then low = value end
            if not high or value > high then high = value end
        end
    end
    return low, high
end

local function fmt_range(low, high)
    if not low then return "—" end
    if low == high then return fmt_ms(low) end
    return fmt_ms(low) .. " – " .. fmt_ms(high)
end

local function status_of(books, results, getter, target)
    local seen, over = false, 0
    for _, book in ipairs(books) do
        local value = getter(results[book.label] or {})
        if value then
            seen = true
            if value > target then over = over + 1 end
        end
    end
    if not seen then return "未测", 0 end
    return (over == 0 and "达标" or "未达标"), over
end

local function render_markdown(environment, books, results)
    local lines = {}
    local function add(text) lines[#lines + 1] = text end

    add("# 性能基准（设计 §15.4）")
    add("")
    add(string.format("> 由 `tools/bench.lua` 生成于 %s；同一设备每项 %d 次取中位数。"
        .. "单次读数不作为结论。", environment.generated_at, environment.runs))
    add("")
    add("## 1. 环境")
    add("")
    add("| 项 | 值 |")
    add("| --- | --- |")
    add(string.format("| 设备 | %s |", environment.device))
    add(string.format("| 内核 | %s |", environment.kernel))
    add(string.format("| KOReader | %s |", environment.kor_version))
    add(string.format("| LuaJIT | %s |", environment.luajit))
    add(string.format("| 平台 | %s |", environment.platform))
    add(string.format("| 计时源 | %s |", environment.clock == "wall" and "墙钟 clock_gettime" or "CPU os.clock"))
    add(string.format("| KO_ROOT | `%s` |", environment.ko_root))
    add(string.format("| 数据目录 | `%s` |", environment.data))
    add("")
    add("## 2. 代表书")
    add("")
    add("| 标签 | 大小 | spine 文件 | 目录章节 | 目录条目 | 来源 |")
    add("| --- | --- | --- | --- | --- | --- |")
    for _, book in ipairs(books) do
        add(string.format("| %s | %s | %d | %d | %d | %s |",
            book.label, fmt_kb(book.size), book.spine_count,
            book.chapters, book.entries, book.source))
    end
    if environment.skipped_books and #environment.skipped_books > 0 then
        add("")
        add("未测的书：")
        add("")
        for _, item in ipairs(environment.skipped_books) do
            add(string.format("- `%s`：%s", item.path, item.error))
        end
    end
    add("")
    add("## 3. 结果")
    add("")
    for _, book in ipairs(books) do
        local result = results[book.label] or {}
        add("### " .. book.label)
        add("")
        add("`" .. book.path .. "`")
        add("")
        add("| 指标 | 中位数 | 换算 | " .. environment.runs .. " 次样本 | §15.4 目标 | 结论 |")
        add("| --- | --- | --- | --- | --- | --- |")
        local outline = result.outline
        if outline then
            add(string.format("| 章节目录解析（冷） | %s | 100 章 ≈ %s（%d 章折算） | %s | 100 章 < 500 ms | %s |",
                fmt_ms(outline.median_ms), fmt_ms(outline.normalized_100_ms),
                outline.chapters, fmt_samples(outline.samples),
                judge(outline.normalized_100_ms, TARGETS.outline_100)))
        else
            add("| 章节目录解析（冷） | " .. (result.outline_error or "未执行") .. " | — | — | 100 章 < 500 ms | — |")
        end
        local css = result.css
        if css then
            add(string.format("| CSS 构建（%d 段，单 provider，冷） | %s | CSS %s | %s | < 200 ms | %s |",
                environment.css_segments, fmt_ms(css.single.median_ms), fmt_kb(css.single.bytes),
                fmt_samples(css.single.samples), judge(css.single.median_ms, TARGETS.css_single)))
            add(string.format("| CSS 构建（%d 段，fallback 三服务均分，冷） | %s | CSS %s | %s | < 500 ms | %s |",
                environment.css_segments,
                fmt_ms(css.fallback.median_ms), fmt_kb(css.fallback.bytes),
                fmt_samples(css.fallback.samples), judge(css.fallback.median_ms, TARGETS.css_fallback)))
            add(string.format("| CSS 构建（三服务各 %d 条，%d 条加载，冷） | %s | CSS %s | %s | 无 | — |",
                environment.css_segments, environment.css_segments * 3,
                fmt_ms(css.fallback_full.median_ms), fmt_kb(css.fallback_full.bytes),
                fmt_samples(css.fallback_full.samples)))
            add(string.format("| entries 读取（单服务，JSON 解码） | %s | %s | %s | — | — |",
                fmt_ms(css.single.load_ms), fmt_kb(css.entries_single_bytes),
                fmt_samples(css.single.load_samples)))
            if css.single.hit_ms then
                add(string.format("| CSS 命中（单服务，参数不变） | %s | — | %s | — | — |",
                    fmt_ms(css.single.hit_ms), fmt_samples(css.single.hit_samples)))
            else
                add("| CSS 命中（单服务，参数不变） | 未测 | lfs.touch 失败/不可用 | — | — | — |")
            end
            if css.fallback.hit_ms then
                add(string.format("| CSS 命中（三服务均分，参数不变） | %s | — | %s | — | — |",
                    fmt_ms(css.fallback.hit_ms), fmt_samples(css.fallback.hit_samples)))
            else
                add("| CSS 命中（三服务均分，参数不变） | 未测 | lfs.touch 失败/不可用 | — | — | — |")
            end
            add(string.format("| overlay 体积（单 provider entries） | %s | — | — | 3,000 段约 0.8–1.5 MB | — |",
                fmt_kb(css.entries_single_bytes)))
            add(string.format("| overlay 体积（三服务均分，三份之和） | %s | — | — | 按 3 份计 | — |",
                fmt_kb(css.entries_fallback_bytes)))
            add(string.format("| overlay 体积（三服务全量，三份之和） | %s | — | — | 按 3 份计 | — |",
                fmt_kb(css.entries_fallback_full_bytes)))
        else
            add("| CSS 构建 | " .. (result.css_error or "未执行") .. " | — | — | < 200 / 500 ms | — |")
        end
        local import = result.import
        if import then
            add(string.format("| MCP 导入（%d 段） | %s | %d 段 / %d 父段 | %s | < 5 s | %s |",
                import.segments, fmt_ms(import.median_ms), import.segments, import.accepted,
                fmt_samples(import.samples), judge(import.median_ms, TARGETS.import_3000)))
        else
            add("| MCP 导入 | " .. (result.import_error or "未执行") .. " | — | — | < 5 s | — |")
        end
        local anchor = result.anchor
        if anchor then
            local anchors, paths = {}, {}
            for _, value in ipairs(anchor.anchors) do anchors[#anchors + 1] = tostring(value) end
            for _, value in ipairs(anchor.paths or {}) do paths[#paths + 1] = tostring(value) end
            add(string.format("| 锚点页表（单章，冷） | %s | TOC 条目 %s / 路径 %s | %s | 无（基线） | — |",
                fmt_ms(anchor.median_ms), table.concat(anchors, "/"),
                table.concat(paths, "/"), fmt_samples(anchor.samples)))
        else
            add("| 锚点页表（单章，冷） | " .. (result.anchor_error or "未执行") .. " | — | — | 无（基线） | — |")
        end
        add("")
    end

    add("## 4. 汇总")
    add("")
    local import_segments = environment.segments
    for _, book in ipairs(books) do
        local result = results[book.label] or {}
        if result.import then
            import_segments = result.import.segments
            break
        end
    end
    add("| 书 | outline 100 章 ≈ | CSS 单 provider | CSS 三服务均分 | 导入 "
        .. import_segments .. " 段 | 锚点单章 |")
    add("| --- | --- | --- | --- | --- | --- |")
    for _, book in ipairs(books) do
        local result = results[book.label] or {}
        local outline = result.outline and fmt_ms(result.outline.normalized_100_ms) or "—"
        local css = result.css
        local css_single = css and fmt_ms(css.single.median_ms) or "—"
        local css_fallback = css and fmt_ms(css.fallback.median_ms) or "—"
        local imported = result.import and fmt_ms(result.import.median_ms) or "—"
        local anchor = result.anchor and fmt_ms(result.anchor.median_ms) or "—"
        add(string.format("| %s | %s | %s | %s | %s | %s |",
            book.label, outline, css_single, css_fallback, imported, anchor))
    end
    add("")
    add("## 5. 结论")
    add("")
    local outline_low, outline_high = range_of(books, results, function(result)
        return result.outline and result.outline.normalized_100_ms
    end)
    local outline_raw_low, outline_raw_high = range_of(books, results, function(result)
        return result.outline and result.outline.median_ms
    end)
    local outline_status, outline_over = status_of(books, results, function(result)
        return result.outline and result.outline.normalized_100_ms
    end, TARGETS.outline_100)
    add(string.format("- **目录解析**：冷解析 %s；按目录章节线性折算 100 章 %s，"
        .. "§15.4 目标 < 500 ms，%s%s。解包与 OPF 是固定开销，线性折算只作量级参考；"
        .. "解析完成后命中磁盘缓存。",
        fmt_range(outline_raw_low, outline_raw_high),
        fmt_range(outline_low, outline_high),
        outline_status,
        outline_over > 0 and string.format("（%d 本超目标）", outline_over) or ""))

    local css_single_low, css_single_high = range_of(books, results, function(result)
        return result.css and result.css.single.median_ms
    end)
    local css_fallback_low, css_fallback_high = range_of(books, results, function(result)
        return result.css and result.css.fallback.median_ms
    end)
    local css_full_low, css_full_high = range_of(books, results, function(result)
        return result.css and result.css.fallback_full.median_ms
    end)
    local css_load_low, css_load_high = range_of(books, results, function(result)
        return result.css and result.css.single.load_ms
    end)
    local css_hit_low, css_hit_high = range_of(books, results, function(result)
        return result.css and result.css.single.hit_ms
    end)
    local css_single_status = status_of(books, results, function(result)
        return result.css and result.css.single.median_ms
    end, TARGETS.css_single)
    local css_fallback_status = status_of(books, results, function(result)
        return result.css and result.css.fallback.median_ms
    end, TARGETS.css_fallback)
    add(string.format("- **CSS 构建**：单 provider 冷构建 %s（目标 < 200 ms，%s）；"
        .. "fallback 三家均分 %d 段 %s（目标 < 500 ms，%s）；三家各持 %d 条"
        .. "（%d 条加载）%s（无目标）。分解：entries 读取（JSON 解码 + 去重）%s，"
        .. "同参数命中 %s——阅读中重绘不贵，改字号/切服务才会走冷路径。",
        fmt_range(css_single_low, css_single_high), css_single_status,
        environment.css_segments,
        fmt_range(css_fallback_low, css_fallback_high), css_fallback_status,
        environment.css_segments, environment.css_segments * 3,
        fmt_range(css_full_low, css_full_high),
        fmt_range(css_load_low, css_load_high), fmt_range(css_hit_low, css_hit_high)))

    local import_low, import_high = range_of(books, results, function(result)
        return result.import and result.import.median_ms
    end)
    local import_status = status_of(books, results, function(result)
        return result.import and result.import.median_ms
    end, TARGETS.import_3000)
    add(string.format("- **MCP 导入**：%d 段 %s，§15.4 目标 < 5 s，%s。",
        import_segments, fmt_range(import_low, import_high), import_status))

    local anchor_low, anchor_high = range_of(books, results, function(result)
        return result.anchor and result.anchor.median_ms
    end)
    local heaviest = 0
    for _, book in ipairs(books) do
        local result = results[book.label] or {}
        for _, value in ipairs(result.anchor and result.anchor.anchors or {}) do
            if value > heaviest then heaviest = value end
        end
    end
    add(string.format("- **锚点页表**：单章冷解析 %s（基线，无 §15.4 目标）；"
        .. "取锚点最多的章节，最重一章有 %d 条 TOC 锚点。CREngine 的逐锚点 "
        .. "`getPageFromXPointer` 探测未计入，真机阅读时每章另加 N 次渲染器调用。",
        fmt_range(anchor_low, anchor_high), heaviest))

    local overlay_low, overlay_high = range_of(books, results, function(result)
        return result.css and result.css.entries_single_bytes
    end)
    add(string.format("- **overlay 体积**：单 provider %s（§15.4 参考 3,000 段 0.8–1.5 MB）；"
        .. "fallback 均分与全量两行各是三份 entries 之和；entries 每段都带 "
        .. "source/translation/xpointer。",
        overlay_low and (overlay_low == overlay_high and fmt_kb(overlay_low)
            or (fmt_kb(overlay_low) .. " – " .. fmt_kb(overlay_high))) or "—"))
    add("")
    add("## 6. 口径与限制")
    add("")
    add("- **outline**：每次删除 `data/cache/dualtranslate/outline/<hash>.json` 后冷解析；"
        .. "「100 章 ≈」= 中位数 × 100 / 目录章节数（线性折算）。解包、OPF 解析和 spine "
        .. "映射是固定开销，折算只用于和 §15.4 的 100 章目标对照，不作为精确预测。"
        .. "前面的书形状探测已读过同一文件，文件页缓存是热的。")
    add("- **CSS**：合成 " .. environment.css_segments .. " 条 entries，selector 采用生产写法"
        .. "（`DocFragment[Source=\"…\"] > body > div:nth-of-type(n) > p:nth-of-type(n)`，"
        .. "约 1% 为列表父项的 `… > ol:nth-of-type(1)::before`，各生成 3 条规则）；"
        .. "每次 `Overlay.clearCssCache()` 后 `Overlay.buildCss`。fallback 有两个夹具："
        .. "① §15.4 口径的「3,000 段分给三家」（1,000/1,000/1,000，selector 互不相交，"
        .. "合并后 3,000 条规则）；② 三家都翻完整本（各 3,000 条，9,000 条加载、"
        .. "合并后仍是 3,000 条规则），这是存储与 JSON 解码的最坏形态，只报数不判定；"
        .. "三家各翻不同段落会得到 9,000 条规则，那等价于一本 9,000 段的书，不在 3,000 段口径内。"
        .. "「entries 读取」是同一份文件的 JSON 解码 + 去重；「CSS 命中」是 entries 落盘超过 "
        .. "3 秒后同参数再调用（阅读中翻页/重绘的稳态）。注意 `build_css_v3` 在参数"
        .. "（颜色/字号/服务）变化时会重新解析 entries，所以改字号/切服务属于「冷」这一列。"
        .. "同一份 entries 拆成三份后 JSON 解析会明显变快（LuaJSON 1.3.5 的大文档开销），"
        .. "因此「三服务均分」行低于单 provider 行是文件布局差异，不代表 fallback 更快。"
        .. "CSS 夹具与书内容无关；同轮不同书之间的差异与夹具无关，判定按整轮最大值。")
    add("- **导入**：`Store.importResult` 全链路（书锁、SQLite 事务、entries/manifest/signal "
        .. "写入）；每次前清空该书 overlay 目录与 DB 行，但复用同一个基准库（WAL 与页缓存是热的），"
        .. "不等价于空库首次导入。")
    add("- **锚点页表**：`Epub.chapter_anchor_paths` 冷解析目录锚点最多的 " .. environment.runs
        .. " 个章节（各不同，3 槽 LRU 不会命中），中位数为单章成本；这是最坏单章，不是均匀抽样。"
        .. "CREngine 的 `getPageFromXPointer` 探测（每章 N 次）无法在 headless 复现，未计入。")
    add("- **未覆盖**：章节选择器打开（< 1 s）、DB v3 迁移（100k 行 < 10 s）、内存增量"
        .. "（< 20 / 40 MB）、以及「相对旧版不劣化 20%」所需的历史基线——本次只记录绝对值。")
    add("")
    return table.concat(lines, "\n")
end

-- ---------------- main ----------------
mkdir_p(opts.work)
local marker = opts.work .. "/.dtbench"
local known_work = read_file(marker) ~= nil
-- A pre-existing data/ or css/ that this tool did not create must never be
-- deleted by cleanup_work(); refuse the directory instead of trusting a
-- marker this very run would write.  A non-empty directory without the
-- marker is somebody else's (e.g. --work /mnt/us/documents), so refuse it too.
for _, owned in ipairs({ "data", "css" }) do
    if lfs.attributes(opts.work .. "/" .. owned, "mode") and not known_work then
        io.stderr:write("拒绝 --work=" .. opts.work .. "：已存在 " .. owned
            .. "/ 且没有 .dtbench 标记\n")
        os.exit(2)
    end
end
if not known_work then
    local foreign = 0
    local ok, iterator, state = pcall(lfs.dir, opts.work)
    if ok and iterator then
        for name in iterator, state do
            if name ~= "." and name ~= ".." then foreign = foreign + 1 end
        end
    end
    if foreign > 0 then
        io.stderr:write("拒绝 --work=" .. opts.work .. "：目录非空且没有 .dtbench 标记\n")
        os.exit(2)
    end
end
if not write_file(marker, "dualtranslate bench work dir\n") then
    io.stderr:write("无法写 .dtbench 标记: " .. marker .. "\n")
    os.exit(2)
end
mkdir_p(data_dir)
mkdir_p(data_dir .. "/cache/dualtranslate/outline")

-- Remove only the fixtures this tool owns; the marker stops a mistyped --work
-- from deleting an unrelated data/ or css/ directory.
local function cleanup_work()
    if opts.keep then return end
    if not read_file(opts.work .. "/.dtbench") then return end
    Tools.rmtree(opts.work .. "/data")
    Tools.rmtree(opts.work .. "/css")
end

if opts.list then
    local root = opts.list_dir or "/mnt/us/documents"
    local found = scan_books(root)
    print(string.format("扫描 %s：%d 本 EPUB（冷解析耗时仅作参考）", root, #found))
    for _, path in ipairs(found) do
        local shape, err = book_shape(path)
        if shape then
            print(string.format("%8.0f KB  spine=%4d chapters=%4d entries=%4d src=%-5s %7.1f ms  %s",
                shape.size / 1024, shape.spine_count, shape.chapters, shape.entries,
                tostring(shape.source), shape.first_parse_ms, path))
        else
            print(string.format("  ERR %s  %s", tostring(err), path))
        end
    end
    cleanup_work()
    os.exit(0)
end

if #opts.books == 0 then
    io.stderr:write("没有 --book；先用 --list --list-dir <书籍目录> 选书\n")
    os.exit(2)
end

local cache = Cache:new()
Store.setCache(cache)
if not cache:open() then
    io.stderr:write("缓存数据库不可用: " .. tostring(cache:getDbPath()) .. "\n")
    cache:close()
    cleanup_work()
    os.exit(2)
end
if not Store.migrateIfNeeded(cache) then
    io.stderr:write("cache schema 初始化失败\n")
    cache:close()
    cleanup_work()
    os.exit(2)
end

local books, results = {}, {}
local failures = 0

local function bench_book(position, path)
    local shape, err = book_shape(path)
    if not shape then
        io.stderr:write(string.format("跳过 %s: %s\n", path, tostring(err)))
        skipped_books[#skipped_books + 1] = { path = path, error = tostring(err) }
        return false
    end
    shape.index = position
    local label, suffix = shape.label, 2
    while results[label] do
        label = string.format("%s (%d)", shape.label, suffix)
        suffix = suffix + 1
    end
    shape.label = label
    books[#books + 1] = shape
    local result = {}
    results[label] = result
    print(string.format("[%d/%d] %s  spine=%d chapters=%d entries=%d",
        position, #opts.books, label, shape.spine_count, shape.chapters, shape.entries))

    local outline_doc = shape.outline
    if wants("outline") then
        local outline, doc_or_error = bench_outline(shape)
        if outline then
            result.outline = outline
            outline_doc = doc_or_error
            shape.outline = outline_doc
            print(string.format("  outline  %s（100 章 ≈ %s）",
                fmt_ms(outline.median_ms), fmt_ms(outline.normalized_100_ms)))
        else
            failures = failures + 1
            result.outline_error = doc_or_error
            print("  outline  FAIL " .. tostring(doc_or_error))
        end
    end

    if wants("css") then
        local css, css_err = bench_css_for(shape)
        if css then
            result.css = css
            print(string.format("  css      single %s / fallback %s",
                fmt_ms(css.single.median_ms), fmt_ms(css.fallback.median_ms)))
        else
            failures = failures + 1
            result.css_error = css_err
            print("  css      FAIL " .. tostring(css_err))
        end
    end

    if wants("import") then
        if not outline_doc then
            failures = failures + 1
            result.import_error = "缺少目录信息"
            print("  import   FAIL 缺少目录信息")
        else
            local imported, import_err = bench_import(shape, outline_doc, cache)
            if imported then
                result.import = imported
                print(string.format("  import   %s（%d 段 / %d 父段）",
                    fmt_ms(imported.median_ms), imported.segments, imported.accepted))
            else
                failures = failures + 1
                result.import_error = import_err
                print("  import   FAIL " .. tostring(import_err))
            end
        end
    end

    if wants("anchor") then
        if not outline_doc then
            failures = failures + 1
            result.anchor_error = "缺少目录信息"
            print("  anchor   FAIL 缺少目录信息")
        else
            local anchor, anchor_err = bench_anchor(shape, outline_doc)
            if anchor then
                result.anchor = anchor
                print(string.format("  anchor   %s（%d 章）",
                    fmt_ms(anchor.median_ms), anchor.chapters))
            else
                failures = failures + 1
                result.anchor_error = anchor_err
                print("  anchor   FAIL " .. tostring(anchor_err))
            end
        end
    end
    return true
end

for position, path in ipairs(opts.books) do
    -- One bad book must not take the other two and the report down with it.
    local ok, measured = pcall(bench_book, position, path)
    if not ok then
        failures = failures + 1
        io.stderr:write(string.format("跳过 %s: %s\n", path, tostring(measured)))
        skipped_books[#skipped_books + 1] = { path = path, error = tostring(measured) }
    elseif measured == false then
        failures = failures + 1
    end
end

local environment = collect_environment()
local markdown = render_markdown(environment, books, results)
local md_path = opts.md or (opts.work .. "/PERF.md")
local md_parent = md_path:match("^(.*)/[^/]+$")
if md_parent then mkdir_p(md_parent) end
if not write_atomic(md_path, markdown) then
    io.stderr:write("无法写报告: " .. md_path .. "\n")
    failures = failures + 1
else
    print("报告: " .. md_path)
end

local json_path = opts.json or (opts.work .. "/bench.json")
local json_parent = json_path:match("^(.*)/[^/]+$")
if json_parent then mkdir_p(json_parent) end
local payload = { environment = environment, books = {}, results = results }
for _, book in ipairs(books) do
    payload.books[#payload.books + 1] = {
        label = book.label, path = book.path, size = book.size,
        spine_count = book.spine_count, chapters = book.chapters,
        entries = book.entries, source = book.source,
    }
end
local encoded_ok, encoded = pcall(JSON.encode, payload)
if encoded_ok and write_atomic(json_path, encoded) then
    print("JSON: " .. json_path)
else
    io.stderr:write("JSON 输出失败: " .. (encoded_ok and "无法写文件" or tostring(encoded)) .. "\n")
    failures = failures + 1
end

cache:close()
cleanup_work()

if failures > 0 then
    io.stderr:write(string.format("完成，%d 项失败\n", failures))
    os.exit(1)
end
if only then
    print("完成（按 --only 只测量了部分指标）")
else
    print("完成，全部指标已测量")
end
