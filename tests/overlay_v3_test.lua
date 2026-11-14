-- ============================================================
-- Overlay v3：manifest/entries 读写 / 原子替换 / slug / loadBookIndex /
-- isStale / buildCss v3 / Store.migrateBookIfNeeded 各分支
-- Run: luajit tests/overlay_v3_test.lua
-- 需要真实文件系统语义，用 KOReader 自带 lfs + json；缺失时跳过。
-- DB 归属分支用 stub cache（_queryAll/getProvider），真实 SQLite 的删除
-- 端到端在 store_delete_test.lua。
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
package.path = KO .. "/common/?.lua;" .. KO .. "/common/?/init.lua;" .. package.path
package.cpath = KO .. "/?.so;" .. KO .. "/?.dylib;" .. package.cpath
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_json, JSON = pcall(require, "json")
if not ok_lfs or not ok_json then
    print("SKIP: libkoreader-lfs / json unavailable"); os.exit(0)
end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local ROOT = "/tmp/dt_overlay_v3_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local data_dir = ROOT .. "/data"
os.execute('mkdir -p "' .. data_dir .. '"')
local warnings = {}
local function joinArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end

package.preload["datastorage"] = function()
    return { getDataDir = function() return data_dir end }
end
package.preload["logger"] = function()
    return {
        warn = function(...) warnings[#warnings + 1] = joinArgs(...) end,
        err = function(...) warnings[#warnings + 1] = joinArgs(...) end,
        info = function() end,
    }
end
-- 锁模块（经 Store 引入）依赖 ffi/util 的睡眠/墙钟；本测试无锁竞争，
-- 提供 no-op 睡眠与秒级墙钟即可。
package.preload["ffi/util"] = function()
    return { sleep = function() end, usleep = function() end,
        getTimestamp = function() return os.time() end }
end
package.preload["util"] = function()
    return { makePath = function(path)
        if lfs.attributes(path, "mode") == "directory" then return true end
        local prefix = path:sub(1, 1) == "/" and "" or "."
        for component in path:gmatch("[^/]+") do
            prefix = prefix .. "/" .. component
            if lfs.attributes(prefix, "mode") ~= "directory" then
                local ok, err = lfs.mkdir(prefix)
                if not ok and lfs.attributes(prefix, "mode") ~= "directory" then
                    return false
                end
            end
        end
        return lfs.attributes(path, "mode") == "directory"
    end }
end

-- 轻量 OPF 读取的 archiver stub：按书名提供 container.xml / OPF 内容
local archive_files = {}
package.preload["ffi/archiver"] = function()
    return { Reader = { new = function()
        return {
            open = function(self, path)
                self.path = path
                return archive_files[path] ~= nil
            end,
            extractToMemory = function(self, key)
                local files = archive_files[self.path]
                return files and files[key] or nil
            end,
            close = function() end,
        }
    end } }
end

-- 迁移归属分支的 stub cache：记录 SQL，返回可配置的行
local stub_cache = {
    query_rows = {},
    provider_rows = {},
    last_sql = nil,
    _queryAll = function(self, sql, ...)
        self.last_sql = sql
        return self.query_rows
    end,
    getProvider = function(self, pid) return self.provider_rows[pid] end,
}
package.preload["dualtranslate_cache"] = function()
    return { new = function() return stub_cache end }
end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Overlay = dofile(script_dir .. "/../dualtranslate_overlay.lua")
local Tools = dofile(script_dir .. "/../dualtranslate_tools.lua")
local Store = dofile(script_dir .. "/../dualtranslate_store.lua")

local case_no = 0
local function newDir(label)
    case_no = case_no + 1
    local dir = string.format("%s/%02d_%s", ROOT, case_no, label)
    os.execute('mkdir -p "' .. dir .. '"')
    return dir
end

local function fileExists(path)
    local handle = io.open(path, "rb")
    if handle then handle:close(); return true end
    return false
end

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function writeFile(path, content)
    local handle = assert(io.open(path, "wb"))
    handle:write(content)
    handle:close()
end

local function noTmpLeft(dir)
    local ok, iterator, state = pcall(lfs.dir, dir)
    if not ok then return true end
    for name in iterator, state do
        if name:match("%.tmp$") then return false end
    end
    return true
end

local function entry(selector, translation, source)
    return { selector = selector, translation = translation, source = source or "src" }
end

local function makeManifest(dir, overrides)
    local manifest = {
        version = 3,
        book_path = "/books/x.epub",
        source_lang = "auto",
        target_lang = "zh-Hans",
        spine_count = 0,
        book_size = 0,
        book_mtime = 0,
        display_mode = "manual",
        display_provider = "system",
        display_fallback = true,
        last_used_at = { system = 100 },
        fallback_order = { "system" },
        providers = {
            system = {
                display_name = "KOReader 内置（Google）", kind = "builtin",
                chapters = {}, partial_chapters = {}, failed_chapters = {},
                complete = false, translated_count = 1, updated_at = 100,
                confirmed = true,
            },
        },
    }
    for key, value in pairs(overrides or {}) do manifest[key] = value end
    assert(Overlay.saveManifest(dir, manifest))
    return manifest
end

-- ============================================================
print("== 1. manifest / entries 读写与原子替换 ==")
do
    local dir = newDir("roundtrip")
    check("空目录 loadManifest 为 nil", Overlay.loadManifest(dir) == nil)
    local manifest = makeManifest(dir)
    check("saveManifest 首次 revision=1", manifest.revision == 1, tostring(manifest.revision))
    local loaded = Overlay.loadManifest(dir)
    check("loadManifest 读回", loaded and loaded.version == 3 and loaded.revision == 1
        and loaded.providers.system.translated_count == 1)
    check("manifest 路径直读", Overlay.loadManifest(dir .. "/manifest.json") ~= nil)
    check("写入无 .tmp 残留", noTmpLeft(dir))
    local raw = readFile(dir .. "/manifest.json")
    check("落盘是合法 JSON", raw and JSON.decode(raw).version == 3)

    manifest.display_provider = "system"
    check("再次写入 revision=2", Overlay.saveManifest(dir, manifest) and manifest.revision == 2)
    check("原子替换后内容更新", Overlay.loadManifest(dir).revision == 2)
    check("替换后无 .tmp 残留", noTmpLeft(dir))

    check("saveEntries 成功", Overlay.saveEntries(dir, "system", {
        target_lang = "zh-Hans",
        entries = { entry("p[1]", "你好") },
    }))
    local doc = Overlay.loadEntries(dir, "system")
    check("entries 头部 revision=manifest+1", doc and doc.revision == 3, doc and tostring(doc.revision))
    check("entries 写完整 provider", doc and doc.provider == "system" and doc.version == 3)
    check("entries 内容读回", doc and doc.entries[1].translation == "你好")
    check("entries 无 .tmp 残留", noTmpLeft(dir .. "/entries"))

    -- 覆盖写：旧内容被整体替换
    Overlay.saveEntries(dir, "system", { entries = { entry("p[2]", "世界") } })
    local doc2 = Overlay.loadEntries(dir, "system")
    check("entries 原子覆盖", doc2 and #doc2.entries == 1 and doc2.entries[1].selector == "p[2]")

    check("loadEntries 不存在返回 nil", Overlay.loadEntries(dir, "mcp:none") == nil)
    check("saveEntries 空 provider 拒绝", Overlay.saveEntries(dir, "", { entries = {} }) == false)
    check("saveManifest 非表拒绝", Overlay.saveManifest(dir, nil) == false)

    -- 满盘耐久性：write/close 失败必须删 tmp、返回 false、绝不 rename
    -- 截断的 tmp 覆盖好文件（manifest/entries/intent 共用 write_file）。
    local real_io_open = io.open
    local function fakeHandle(write_ok, close_ok)
        return {
            write = function() if write_ok then return true end return nil, "No space left on device" end,
            close = function() if close_ok then return true end return nil, "No space left on device" end,
        }
    end
    local function withBrokenWrites(write_ok, close_ok, fn)
        io.open = function(path, mode)
            if mode == "wb" then return fakeHandle(write_ok, close_ok) end
            return real_io_open(path, mode)
        end
        local ok, err = pcall(fn)
        io.open = real_io_open
        assert(ok, err)
    end
    local before_raw = readFile(dir .. "/manifest.json")
    local rev_before = manifest.revision
    withBrokenWrites(false, true, function()
        check("write 失败：saveManifest 返回 false", Overlay.saveManifest(dir, manifest) == false)
    end)
    check("write 失败：revision 回滚", manifest.revision == rev_before, tostring(manifest.revision))
    check("write 失败：好文件未被覆盖", readFile(dir .. "/manifest.json") == before_raw)
    check("write 失败：无 .tmp 残留", noTmpLeft(dir))
    withBrokenWrites(true, false, function()
        check("close 失败：saveManifest 返回 false", Overlay.saveManifest(dir, manifest) == false)
        check("close 失败：saveEntries 返回 false", Overlay.saveEntries(dir, "system",
            { entries = { entry("p[3]", "坏") } }) == false)
        check("close 失败：saveIntent 返回 false", Overlay.saveIntent(dir,
            { op = "delete_provider", provider = "system" }) == false)
    end)
    check("close 失败：revision 回滚", manifest.revision == rev_before, tostring(manifest.revision))
    check("close 失败：好文件未被覆盖", readFile(dir .. "/manifest.json") == before_raw)
    check("close 失败：entries 未被覆盖", Overlay.loadEntries(dir, "system").entries[1].selector == "p[2]")
    check("close 失败：无 .tmp 残留", noTmpLeft(dir) and noTmpLeft(dir .. "/entries"))
    check("失败后仍可正常写入", Overlay.saveManifest(dir, manifest) == true)
end

-- ============================================================
print("== 2. slug 文件名 / deleteEntries / intent ==")
do
    local dir = newDir("slug")
    check("slug 规则", Overlay.entriesPath(dir, "mcp:gpt-5")
        == dir .. "/entries/mcp_gpt-5.json")
    check("slug 替换非法字符", Overlay.entriesPath(dir, "a/b c:d")
        == dir .. "/entries/a_b_c_d.json")
    Overlay.saveEntries(dir, "mcp:gpt-5", { entries = { entry("p[1]", "译文") } })
    check("文件按 slug 落盘", fileExists(dir .. "/entries/mcp_gpt-5.json"))
    local raw = JSON.decode(readFile(dir .. "/entries/mcp_gpt-5.json"))
    check("文件内是完整 provider id", raw.provider == "mcp:gpt-5")

    -- .ndjson 变体一并删除
    writeFile(dir .. "/entries/mcp_gpt-5.ndjson", '{"selector":"p[9]"}\n')
    check("deleteEntries 删除两种变体", Overlay.deleteEntries(dir, "mcp:gpt-5")
        and not fileExists(dir .. "/entries/mcp_gpt-5.json")
        and not fileExists(dir .. "/entries/mcp_gpt-5.ndjson"))
    check("deleteEntries 幂等", Overlay.deleteEntries(dir, "mcp:gpt-5") == true)
    check("deleteEntries 空 provider 拒绝", Overlay.deleteEntries(dir, "") == false)

    check("saveIntent", Overlay.saveIntent(dir, {
        op = "delete_provider", provider = "system", target_lang = "zh-Hans", started_at = 1,
    }))
    local intent = Overlay.loadIntent(dir)
    check("loadIntent 读回", intent and intent.op == "delete_provider" and intent.provider == "system")
    check("intent 无 .tmp 残留", noTmpLeft(dir))
    check("clearIntent", Overlay.clearIntent(dir) and Overlay.loadIntent(dir) == nil)
    check("clearIntent 幂等", Overlay.clearIntent(dir) == true)

    makeManifest(dir)
    check("removeManifest", Overlay.removeManifest(dir) and Overlay.loadManifest(dir) == nil)
    check("removeManifest 幂等", Overlay.removeManifest(dir) == true)
end

-- ============================================================
print("== 3. loadBookIndex：v3 / v2 归一化 ==")
do
    local dir = newDir("index_v3")
    makeManifest(dir, {
        providers = {
            system = { display_name = "内置", kind = "builtin", chapters = { 1, 2 },
                partial_chapters = {}, failed_chapters = {}, complete = true,
                translated_count = 5, updated_at = 100, confirmed = true },
        },
        spine_count = 2,
    })
    local index = Overlay.loadBookIndex(dir)
    check("v3 索引带 providers", index and index.version == 3 and index.providers.system)
    check("v3 顶层 complete/chapters 跟随显示 provider", index.complete == true
        and #index.chapters == 2)
    check("传 manifest 路径也可", Overlay.loadBookIndex(dir .. "/manifest.json") ~= nil)

    local dir2 = newDir("index_v2")
    Overlay.save(dir2 .. "/overlay.json", {
        version = 2, complete = true, provider = "microsoft_free",
        book_path = "/books/x.epub", source_lang = "auto", target_lang = "zh-Hans",
        chapters = { 1, 2 },
        entries = { entry("p[1]", "一"), entry("p[1]", "重复"), entry("p[2]", "二") },
    })
    local index2 = Overlay.loadBookIndex(dir2)
    check("v2 归一化形状", index2 and index2.version == 2
        and index2.display_mode == "manual" and index2.display_provider == "microsoft_free")
    check("v2 complete/chapters 保留", index2.complete == true and #index2.chapters == 2)
    check("v2 translated_count 去重", index2.providers.microsoft_free.translated_count == 2,
        tostring(index2.providers.microsoft_free.translated_count))
    check("v2 传 overlay 路径也可", Overlay.loadBookIndex(dir2 .. "/overlay.json") ~= nil)

    local dir3 = newDir("index_v2_legacy")
    Overlay.save(dir3 .. "/overlay.json", {
        version = 2, complete = false,
        book_path = "/books/x.epub", source_lang = "auto", target_lang = "zh-Hans",
        entries = { entry("p[1]", "一") },
    })
    local index3 = Overlay.loadBookIndex(dir3)
    check("v2 无 provider → legacy", index3 and index3.display_provider == "legacy"
        and index3.providers.legacy.kind == "legacy")

    check("都没有返回 nil", Overlay.loadBookIndex(newDir("index_empty")) == nil)
end

-- ============================================================
print("== 4. isStale ==")
do
    local dir = newDir("stale")
    local book = dir .. "/book.epub"
    writeFile(book, "epub-content-v1")
    local size = lfs.attributes(book, "size")
    local mtime = lfs.attributes(book, "modification")
    local manifest = { book_size = size, book_mtime = mtime }
    check("一致 → 不 stale", Overlay.isStale(manifest, book) == false)
    lfs.touch(book, mtime + 5, mtime + 5)
    check("mtime 不一致 → stale", Overlay.isStale(manifest, book) == true)
    lfs.touch(book, mtime, mtime)
    writeFile(book, "epub-content-v2-longer")
    check("size 不一致 → stale", Overlay.isStale(manifest, book) == true)
    check("记 0 表示未知 → 不 stale", Overlay.isStale({ book_size = 0, book_mtime = 0 }, book) == false)
    check("单字段 0 只比另一个", Overlay.isStale({ book_size = 0, book_mtime = mtime }, book) == false)
    check("书文件不存在 → 不 stale", Overlay.isStale(manifest, dir .. "/gone.epub") == false)
    check("缺 manifest → 不 stale", Overlay.isStale(nil, book) == false)
end

-- ============================================================
print("== 5. buildCss v3：provider 过滤 / fallback / auto ==")
do
    local dir = newDir("css")
    makeManifest(dir, {
        display_provider = "mcp:gpt-5",
        last_used_at = { ["mcp:gpt-5"] = 200, system = 100 },
        fallback_order = { "mcp:gpt-5", "system" },
        providers = {
            ["mcp:gpt-5"] = { display_name = "MCP · GPT-5", kind = "mcp", chapters = {},
                partial_chapters = {}, failed_chapters = {}, complete = false,
                translated_count = 1, updated_at = 200, confirmed = true },
            system = { display_name = "内置", kind = "builtin", chapters = {},
                partial_chapters = {}, failed_chapters = {}, complete = false,
                translated_count = 2, updated_at = 100, confirmed = true },
        },
    })
    Overlay.saveEntries(dir, "mcp:gpt-5", { entries = { entry("p[1]", "MCP译文") } })
    Overlay.saveEntries(dir, "system", { entries = {
        entry("p[1]", "内置译文"), entry("p[2]", "内置第二段"),
    } })
    local manifest_path = dir .. "/manifest.json"
    local opts = { translation_visible = true }

    local css = Overlay.buildCss(manifest_path, opts)
    check("只显示选中 provider", css:find("MCP译文", 1, true) ~= nil
        and css:find("内置译文", 1, true) == nil)
    check("fallback 补缺失 selector", css:find("内置第二段", 1, true) ~= nil)
    check("fallback 不覆盖主 provider", css:find("p[1]::after{content:\"MCP译文\"", 1, true) ~= nil)

    local css_nofb = Overlay.buildCss(manifest_path, { translation_visible = true, fallback = false })
    check("fallback 关闭只剩选中 provider", css_nofb:find("内置第二段", 1, true) == nil
        and css_nofb:find("MCP译文", 1, true) ~= nil)

    local css_override = Overlay.buildCss(manifest_path, { translation_visible = true, provider = "system" })
    check("options.provider 覆盖", css_override:find("内置译文", 1, true) ~= nil
        and css_override:find("MCP译文", 1, true) == nil)

    check("不可见返回空串", Overlay.buildCss(manifest_path, { translation_visible = false }) == "")
    check("无 manifest 返回空串", Overlay.buildCss(newDir("css_empty") .. "/manifest.json", opts) == "")

    -- 目录参数自动识别
    local css_dir = Overlay.buildCss(dir, opts)
    check("目录参数识别 manifest", css_dir:find("MCP译文", 1, true) ~= nil)

    -- auto：last_used_at 最大者
    Overlay.saveManifest(dir, (function()
        local m = Overlay.loadManifest(dir)
        m.display_mode = "auto"
        m.display_provider = nil
        return m
    end)())
    Overlay.clearCssCache()
    local css_auto = Overlay.buildCss(manifest_path, opts)
    check("auto 取 last_used_at 最大", css_auto:find("MCP译文", 1, true) ~= nil)
    local m = Overlay.loadManifest(dir)
    m.last_used_at.system = 300
    Overlay.saveManifest(dir, m)
    Overlay.clearCssCache()
    local css_auto2 = Overlay.buildCss(manifest_path, opts)
    check("auto 跟随最近使用切换", css_auto2:find("内置译文", 1, true) ~= nil
        and css_auto2:find("MCP译文", 1, true) == nil)

    -- 样式参数沿用
    local css_style = Overlay.buildCss(manifest_path, {
        translation_visible = true, translation_color = "#123456",
        translation_size = "0.9em", translation_font_family = "Noto Serif CJK SC",
    })
    check("颜色/字号/字体生效", css_style:find("color:#123456!important", 1, true) ~= nil
        and css_style:find("font-size:0.9em!important", 1, true) ~= nil
        and css_style:find('font-family:"Noto Serif CJK SC"!important', 1, true) ~= nil)

    -- legacy overlay.json 路径保持旧行为
    local legacy_dir = newDir("css_legacy")
    Overlay.save(legacy_dir .. "/overlay.json", {
        version = 2, entries = { entry("p[1]", "旧版译文") },
    })
    local css_legacy = Overlay.buildCss(legacy_dir .. "/overlay.json", opts)
    check("legacy 路径仍生成 CSS", css_legacy:find("旧版译文", 1, true) ~= nil)
    local css_legacy_dir = Overlay.buildCss(legacy_dir, opts)
    check("目录参数识别 legacy", css_legacy_dir:find("旧版译文", 1, true) ~= nil)
end

-- ============================================================
print("== 6. v2 → v3 迁移：provider 归属各分支 ==")
local function seedV2(dir, overrides)
    local data = {
        version = 2, complete = false,
        book_path = "/books/x.epub", source_lang = "auto", target_lang = "zh-Hans",
        chapters = { 1 },
        entries = { entry("p[1]", "一", "one"), entry("p[2]", "二", "two") },
    }
    for key, value in pairs(overrides or {}) do data[key] = value end
    Overlay.save(dir .. "/overlay.json", data)
    return data
end

-- 迁移目录必须与 Store.bookDir 一致；书文件放在独立用例区
local function setupMigration(label)
    case_no = case_no + 1
    local area = string.format("%s/%02d_%s", ROOT, case_no, label)
    os.execute('mkdir -p "' .. area .. '"')
    local book = area .. "/book.epub"
    writeFile(book, "epub-bytes")
    local dir = Store.bookDir(book, "zh-Hans")
    os.execute('mkdir -p "' .. dir .. '"')
    return area, book, dir
end

do
    local area, book, dir = setupMigration("migrate_provider_field")
    seedV2(dir, { provider = "microsoft_free", complete = true, chapters = { 1, 2 } })
    archive_files[book] = {
        ["META-INF/container.xml"] = [[<container><rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>]],
        ["OEBPS/content.opf"] = [[<package><manifest>
            <item id="c1" href="c1.xhtml"/><item id="c2" href="c2.xhtml"/>
        </manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>]],
    }
    stub_cache.provider_rows = {
        microsoft_free = { display_name = "Microsoft Edge（免费）", kind = "http", confirmed = true },
    }
    local manifest, err = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("迁移成功", manifest ~= nil, tostring(err))
    check("v2 provider 字段直接用", manifest and manifest.providers.microsoft_free ~= nil)
    check("display manual 且非空", manifest and manifest.display_mode == "manual"
        and manifest.display_provider == "microsoft_free")
    check("revision 初始 1", manifest and manifest.revision == 1, manifest and tostring(manifest.revision))
    check("entries revision 也是 1", Overlay.loadEntries(dir, "microsoft_free").revision == 1)
    check("spine_count 从 OPF 读取", manifest and manifest.spine_count == 2,
        manifest and tostring(manifest.spine_count))
    check("chapters 沿用（单一 provider）", manifest and #manifest.providers.microsoft_free.chapters == 2)
    check("complete：全覆盖 + v2 complete", manifest and manifest.providers.microsoft_free.complete == true)
    check("translated_count 正确", manifest and manifest.providers.microsoft_free.translated_count == 2)
    check("DB 元数据投影（D10）", manifest and manifest.providers.microsoft_free.display_name
        == "Microsoft Edge（免费）" and manifest.providers.microsoft_free.kind == "http")
    check("book_size/book_mtime 记录", manifest and manifest.book_size == lfs.attributes(book, "size")
        and manifest.book_mtime == lfs.attributes(book, "modification"))
    check("fallback_order 含 display", manifest and manifest.fallback_order[1] == "microsoft_free")
    check("last_used_at 用 updated_at 初始化", manifest
        and manifest.last_used_at.microsoft_free == manifest.providers.microsoft_free.updated_at)
    check("overlay.json → overlay.v2.bak", not fileExists(dir .. "/overlay.json")
        and fileExists(dir .. "/overlay.v2.bak"))
    check("bak 内容保留", JSON.decode(readFile(dir .. "/overlay.v2.bak")).provider == "microsoft_free")
    check("迁移后无 .tmp 残留", noTmpLeft(dir) and noTmpLeft(dir .. "/entries"))
    check("迁移持锁后释放", not fileExists(dir .. "/.lock") and lfs.attributes(dir .. "/.lock", "mode") == nil)

    local before = readFile(dir .. "/manifest.json")
    local again = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("幂等：有 manifest 直接返回", again and again.revision == 1
        and readFile(dir .. "/manifest.json") == before)
end

do
    local area, book, dir = setupMigration("migrate_db_unique")
    seedV2(dir)
    stub_cache.query_rows = { { "system", 2 } }
    stub_cache.provider_rows = {}
    local manifest = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("DB 唯一 provider → 用它", manifest and manifest.providers.system ~= nil)
    check("归属 SQL 带 GROUP BY", stub_cache.last_sql
        and stub_cache.last_sql:find("GROUP BY provider", 1, true) ~= nil)
    check("chapters 沿用", manifest and #manifest.providers.system.chapters == 1)
    check("无 DB 元数据时回退占位名", manifest and manifest.providers.system.display_name == "system"
        and manifest.providers.system.kind == "builtin")
end

do
    local area, book, dir = setupMigration("migrate_db_multi")
    seedV2(dir, { chapters = { 1, 2 } })
    stub_cache.query_rows = { { "system", 1 }, { "microsoft_free", 1 } }
    local manifest = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("DB 多个 provider → legacy", manifest and manifest.providers.legacy ~= nil
        and manifest.display_provider == "legacy")
    check("legacy 不沿用 chapters", manifest and #manifest.providers.legacy.chapters == 0)
    check("legacy kind", manifest and manifest.providers.legacy.kind == "legacy")
end

do
    local area, book, dir = setupMigration("migrate_db_zero")
    seedV2(dir)
    stub_cache.query_rows = {}
    local manifest = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("DB 0 provider → legacy", manifest and manifest.providers.legacy ~= nil)
end

do
    local area, book, dir = setupMigration("migrate_no_spine")
    seedV2(dir, { provider = "system", complete = true, chapters = { 1, 2 } })
    -- archive_files 无此书 → spine 读不到
    local manifest = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("spine 读不到 = 0", manifest and manifest.spine_count == 0)
    check("spine=0 时 complete 恒 false", manifest and manifest.providers.system.complete == false)
end

do
    local area, book, dir = setupMigration("migrate_partial")
    seedV2(dir, { provider = "system", complete = true, chapters = { 1 } })
    archive_files[book] = {
        ["META-INF/container.xml"] = [[<container><rootfiles>
            <rootfile full-path="content.opf"/></rootfiles></container>]],
        ["content.opf"] = [[<package><manifest>
            <item id="c1" href="c1.xhtml"/><item id="c2" href="c2.xhtml"/>
        </manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>]],
    }
    local manifest = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("部分覆盖 → complete=false", manifest and manifest.providers.system.complete == false)
    check("partial/failed 置空", manifest and #manifest.providers.system.partial_chapters == 0
        and #manifest.providers.system.failed_chapters == 0)
end

do
    case_no = case_no + 1
    local area = string.format("%s/%02d_%s", ROOT, case_no, "migrate_missing_book")
    os.execute('mkdir -p "' .. area .. '"')
    local book = area .. "/gone.epub"
    local dir = Store.bookDir(book, "zh-Hans")
    os.execute('mkdir -p "' .. dir .. '"')
    seedV2(dir, { provider = "system" })
    local manifest = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("书文件读不到 → size/mtime=0", manifest and manifest.book_size == 0
        and manifest.book_mtime == 0)
    check("spine 读不到 = 0", manifest and manifest.spine_count == 0)
end

do
    local area, book, dir = setupMigration("migrate_dedup")
    seedV2(dir, { provider = "system", entries = {
        entry("p[1]", "一"), entry("p[1]", "重复"), entry("p[2]", "二"),
        { selector = "", translation = "无定位" },
    } })
    local manifest = Store.migrateBookIfNeeded(book, "zh-Hans", stub_cache)
    check("translated_count 唯一 selector", manifest and manifest.providers.system.translated_count == 2,
        manifest and tostring(manifest.providers.system.translated_count))
    local doc = Overlay.loadEntries(dir, "system")
    check("空 selector 条目被过滤", #doc.entries == 3)
    check("条目保留 source/xpointer 字段形状", doc.entries[1].source == "src")
end

do
    local dir = newDir("migrate_none")
    check("无 v2 overlay 返回 nil", Store.migrateBookIfNeeded(dir .. "/x.epub", "zh-Hans", stub_cache) == nil)
    local result, err = Store.migrateBookIfNeeded(nil, "zh-Hans", stub_cache)
    check("缺参数报错", result == nil and err ~= nil)
end

-- ============================================================
print("== 7. bookDir 与 Reader 目录身份一致 ==")
do
    local book, lang = "/books/Pride.epub", "zh-Hans"
    local expected = data_dir .. "/cache/dualtranslate/books/"
        .. Tools.stable_path_hash(book .. "|" .. lang)
    check("bookDir 复用同一 hash 配方", Store.bookDir(book, lang) == expected)
    check("语言参与身份", Store.bookDir(book, "ja") ~= expected)
end

print(string.format("\n==== Overlay v3 测试：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
    for _, line in ipairs(warnings) do print("  log:", line) end
end
os.exit(failed == 0 and 0 or 1)