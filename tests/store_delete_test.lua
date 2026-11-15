-- ============================================================
-- Store 删除编排（真实 SQLite）：按 provider 删除 / fallback 选择 /
-- intent 崩溃收尾 / reconcile 孤儿规则 / 显示切换 / 幂等
-- Run: luajit tests/store_delete_test.lua
-- 依赖 KOReader 自带 lfs / json / lua-ljsqlite3（KO_ROOT 可覆盖）；
-- 缺失时跳过。
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

local ROOT = "/tmp/dt_store_delete_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local data_dir = ROOT
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
package.preload["util"] = function()
    return { makePath = function(path)
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
    end }
end
package.preload["ffi/archiver"] = function()
    return { Reader = { new = function()
        return { open = function() return false end, close = function() end }
    end } }
end
package.preload["lua-ljsqlite3/init"] = function() return SQ3 end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Cache = dofile(script_dir .. "/../dualtranslate_cache.lua")
local Overlay = dofile(script_dir .. "/../dualtranslate_overlay.lua")
local Store = dofile(script_dir .. "/../dualtranslate_store.lua")

local case_no = 0
local cache, db
local function newCase(label)
    case_no = case_no + 1
    data_dir = string.format("%s/%02d_%s", ROOT, case_no, label)
    os.execute('mkdir -p "' .. data_dir .. '"')
    if cache then cache:close() end
    cache = Cache:new()
    db = cache:open()
    Store.setCache(cache)
    return cache, db
end

local function fileExists(path)
    local handle = io.open(path, "rb")
    if handle then handle:close(); return true end
    return false
end

local function dbCount(book, lang, provider)
    local rows = cache:_queryAll([[SELECT COUNT(*) FROM book_translations
        WHERE book_path = ? AND target_lang = ? AND provider = ?]], book, lang, provider)
    return tonumber(rows[1] and rows[1][1]) or 0
end

-- 建一本完整的 v3 书：DB 行 + entries + manifest 三者一致
local function seedV3Book(book, lang, specs)
    local dir = Store.bookDir(book, lang)
    local manifest = {
        version = 3, revision = 0, book_path = book, source_lang = "auto",
        target_lang = lang, spine_count = 0, book_size = 0, book_mtime = 0,
        display_mode = "manual", display_provider = specs[1].id,
        display_fallback = true, last_used_at = {}, fallback_order = {},
        providers = {},
    }
    for index, spec in ipairs(specs) do
        local entries = {}
        for j = 1, (spec.count or 1) do
            local selector = spec.id .. ":p[" .. j .. "]"
            entries[j] = { selector = selector, source = "src" .. j,
                translation = spec.id .. "译" .. j }
            cache:storeForBook(book, "auto", lang, "src" .. j, spec.id .. "译" .. j,
                spec.id, { selector = selector })
        end
        manifest.providers[spec.id] = {
            display_name = spec.display_name or spec.id,
            kind = spec.kind or "mcp",
            chapters = spec.chapters or {},
            partial_chapters = {}, failed_chapters = {},
            complete = spec.complete == true,
            translated_count = spec.count or 1,
            updated_at = 100 + index,
            confirmed = true,
        }
        manifest.last_used_at[spec.id] = 100 + index
        manifest.fallback_order[#manifest.fallback_order + 1] = spec.id
        assert(Overlay.saveEntries(dir, spec.id, { target_lang = lang, entries = entries }))
    end
    if specs.display then manifest.display_provider = specs.display end
    if specs.fallback_order then manifest.fallback_order = specs.fallback_order end
    assert(Overlay.saveManifest(dir, manifest))
    -- 追平 entries revision，模拟正常收尾后的稳定状态
    assert(Overlay.saveManifest(dir, Overlay.loadManifest(dir)))
    return dir, Overlay.loadManifest(dir)
end

local BOOK, LANG = "/books/pride.epub", "zh-Hans"

-- ============================================================
print("== 1. deleteProvider 只删目标（DB + entries + manifest） ==")
do
    newCase("delete_target")
    local dir = seedV3Book(BOOK, LANG, {
        { id = "microsoft_free", count = 3, kind = "http" },
        { id = "system", count = 2, kind = "builtin" },
        { id = "mcp:gpt-5", count = 1 },
    })
    -- 干扰项：其他语言 / 其他书
    cache:storeForBook(BOOK, "auto", "ja", "src", "JA", "microsoft_free")
    cache:storeForBook("/books/other.epub", "auto", LANG, "src", "OTHER", "microsoft_free")
    local before = Overlay.loadManifest(dir)

    local result, err = Store.deleteProvider(BOOK, LANG, "microsoft_free")
    check("删除成功", result ~= nil, tostring(err))
    check("deleted = DB 行数", result and result.deleted == 3, result and tostring(result.deleted))
    check("目标 DB 行清空", dbCount(BOOK, LANG, "microsoft_free") == 0)
    check("同书其他 provider 保留", dbCount(BOOK, LANG, "system") == 2
        and dbCount(BOOK, LANG, "mcp:gpt-5") == 1)
    check("其他语言保留", dbCount(BOOK, "ja", "microsoft_free") == 1)
    check("其他书保留", dbCount("/books/other.epub", LANG, "microsoft_free") == 1)
    check("目标 entries 删除", not fileExists(Overlay.entriesPath(dir, "microsoft_free")))
    check("其他 entries 保留", fileExists(Overlay.entriesPath(dir, "system"))
        and fileExists(Overlay.entriesPath(dir, "mcp:gpt-5")))
    local manifest = Overlay.loadManifest(dir)
    check("manifest 摘除 provider", manifest and manifest.providers.microsoft_free == nil
        and manifest.providers.system and manifest.providers["mcp:gpt-5"])
    check("fallback_order 摘除", manifest and #manifest.fallback_order == 2
        and manifest.fallback_order[1] == "system")
    check("last_used_at 摘除", manifest and manifest.last_used_at.microsoft_free == nil)
    check("revision +1", manifest and manifest.revision == before.revision + 1,
        manifest and tostring(manifest.revision))
    check("intent 已清", Overlay.loadIntent(dir) == nil)
    check("锁已释放", lfs.attributes(dir .. "/.lock", "mode") == nil)

    -- 删除显示中的 provider → fallback_order 选下一个有译文的
    check("显示自动切换", result and result.display_provider == "system",
        result and tostring(result.display_provider))
    check("切换后 manual", manifest and manifest.display_mode == "manual"
        and manifest.display_provider == "system")
    local css = Overlay.buildCss(dir .. "/manifest.json", { translation_visible = true })
    check("CSS 只显示剩余 provider", css:find("system译", 1, true) ~= nil
        and css:find("microsoft_free译", 1, true) == nil)
end

-- ============================================================
print("== 2. fallback 选择跳过零译文 provider ==")
do
    newCase("fallback_skip")
    local dir = seedV3Book(BOOK, LANG, {
        { id = "mcp:a", count = 2 },
        { id = "mcp:empty", count = 1 },
        { id = "system", count = 1, kind = "builtin" },
    })
    local m = Overlay.loadManifest(dir)
    m.providers["mcp:empty"].translated_count = 0
    m.fallback_order = { "mcp:a", "mcp:empty", "system" }
    m.display_provider = "mcp:a"
    Overlay.saveManifest(dir, m)
    local result = Store.deleteProvider(BOOK, LANG, "mcp:a")
    check("跳过零译文选 system", result and result.display_provider == "system",
        result and tostring(result.display_provider))
end

-- ============================================================
print("== 3. 删最后一个 provider → manifest 移除 / 幂等 ==")
do
    newCase("delete_last")
    local dir = seedV3Book(BOOK, LANG, { { id = "system", count = 2, kind = "builtin" } })
    local result = Store.deleteProvider(BOOK, LANG, "system")
    check("删除成功", result and result.deleted == 2)
    check("manifest 移除", Overlay.loadManifest(dir) == nil)
    check("display_provider 为 nil", result and result.display_provider == nil)
    check("entries 删除", not fileExists(Overlay.entriesPath(dir, "system")))
    check("DB 清空", dbCount(BOOK, LANG, "system") == 0)
    check("loadBookIndex 为 nil", Overlay.loadBookIndex(dir) == nil)
    check("CSS 为空", Overlay.buildCss(dir .. "/manifest.json", { translation_visible = true }) == "")

    local again, err = Store.deleteProvider(BOOK, LANG, "system")
    check("重复删除幂等 deleted=0", again and again.deleted == 0, tostring(err))
    local third = Store.deleteProvider(BOOK, LANG, "mcp:none")
    check("删不存在的 provider 幂等", third and third.deleted == 0)
    local bad, bad_err = Store.deleteProvider(BOOK, LANG, "")
    check("空 provider 报错", bad == nil and bad_err ~= nil)
end

-- ============================================================
print("== 4. DB 删除失败：清 intent，不动 entries/manifest ==")
do
    newCase("db_failure")
    local dir = seedV3Book(BOOK, LANG, { { id = "system", count = 1, kind = "builtin" } })
    local manifest_before = Overlay.loadManifest(dir)
    Store.setCache({
        deleteProviderForBook = function() return nil, "db down" end,
    })
    local result, err = Store.deleteProvider(BOOK, LANG, "system")
    check("返回 nil + 错误", result == nil and err == "db down", tostring(err))
    check("intent 已清", Overlay.loadIntent(dir) == nil)
    check("entries 未动", fileExists(Overlay.entriesPath(dir, "system")))
    local manifest = Overlay.loadManifest(dir)
    check("manifest 未动", manifest and manifest.providers.system
        and manifest.revision == manifest_before.revision)
    check("锁已释放", lfs.attributes(dir .. "/.lock", "mode") == nil)
    Store.setCache(cache)
end

-- ============================================================
print("== 4b. intent 写失败：中止删除，不动 DB/entries/manifest ==")
do
    newCase("intent_failure")
    local dir = seedV3Book(BOOK, LANG, { { id = "system", count = 2, kind = "builtin" } })
    local manifest_before = Overlay.loadManifest(dir)
    -- Store 内部用的是 require 缓存的 Overlay 实例；模拟满盘写意图失败
    local StoreOverlay = assert(package.loaded["dualtranslate_overlay"])
    local real_saveIntent = StoreOverlay.saveIntent
    StoreOverlay.saveIntent = function() return false end
    local result, err = Store.deleteProvider(BOOK, LANG, "system")
    StoreOverlay.saveIntent = real_saveIntent
    check("返回 nil + 错误", result == nil and type(err) == "string", tostring(err))
    check("DB 行未删（崩溃后不会被当孤儿补回）", dbCount(BOOK, LANG, "system") == 2)
    check("entries 未动", fileExists(Overlay.entriesPath(dir, "system")))
    local manifest = Overlay.loadManifest(dir)
    check("manifest 未动", manifest and manifest.providers.system
        and manifest.revision == manifest_before.revision)
    check("无 intent 残留", Overlay.loadIntent(dir) == nil)
    check("锁已释放", lfs.attributes(dir .. "/.lock", "mode") == nil)
    local recovered = Store.deleteProvider(BOOK, LANG, "system")
    check("恢复后删除正常", recovered ~= nil and dbCount(BOOK, LANG, "system") == 0)
end

-- ============================================================
print("== 4c. entries 删除失败：不摘 manifest、保留 intent（M1） ==")
do
    newCase("entries_failure")
    local dir = seedV3Book(BOOK, LANG, {
        { id = "system", count = 2, kind = "builtin" },
        { id = "microsoft_free", count = 1, kind = "http" },
    })
    local manifest_before = Overlay.loadManifest(dir)
    local StoreOverlay = assert(package.loaded["dualtranslate_overlay"])
    local real_delete = StoreOverlay.deleteEntries
    StoreOverlay.deleteEntries = function() return false end
    local result, err = Store.deleteProvider(BOOK, LANG, "microsoft_free")
    StoreOverlay.deleteEntries = real_delete
    check("返回 nil + 错误", result == nil and type(err) == "string", tostring(err))
    local manifest = Overlay.loadManifest(dir)
    check("manifest 未摘除该 provider", manifest and manifest.providers.microsoft_free ~= nil)
    check("manifest revision 未变", manifest and manifest.revision == manifest_before.revision)
    check("intent 保留供 reconcile 重试", Overlay.loadIntent(dir) ~= nil)
    check("entries 仍在", fileExists(Overlay.entriesPath(dir, "microsoft_free")))
    check("锁已释放", lfs.attributes(dir .. "/.lock", "mode") == nil)

    -- 下一条打开路径的 reconcile 会重试删除，而不是把孤儿条目补回 manifest
    local summary = Store.reconcile(BOOK, LANG, cache, { light = true })
    local repaired = Overlay.loadManifest(dir)
    check("reconcile 完成删除", summary and summary.completed == "microsoft_free")
    check("reconcile 不复活 provider",
        repaired and repaired.providers.microsoft_free == nil)
    check("reconcile 清空 intent", Overlay.loadIntent(dir) == nil)
    check("entries 已删除", not fileExists(Overlay.entriesPath(dir, "microsoft_free")))
end

-- ============================================================
print("== 5. intent 崩溃模拟（reconcile 收尾） ==")
do
    newCase("intent_rollback")
    local dir = seedV3Book(BOOK, LANG, {
        { id = "system", count = 2, kind = "builtin" },
        { id = "mcp:gpt-5", count = 1 },
    })
    -- 崩溃在删 DB 之前：intent 在、DB 仍有行 → 回滚删除
    Overlay.saveIntent(dir, { op = "delete_provider", provider = "system",
        target_lang = LANG, started_at = os.time() })
    local summary, err = Store.reconcile(BOOK, LANG, cache)
    check("reconcile 成功", summary ~= nil, tostring(err))
    check("回滚：provider 保留", summary and summary.rolled_back == "system")
    check("intent 清除", Overlay.loadIntent(dir) == nil)
    check("DB 行保留", dbCount(BOOK, LANG, "system") == 2)
    check("entries 保留", fileExists(Overlay.entriesPath(dir, "system")))
    check("manifest 保留", Overlay.loadManifest(dir).providers.system ~= nil)
end

do
    newCase("intent_finish")
    local dir = seedV3Book(BOOK, LANG, {
        { id = "microsoft_free", count = 2, kind = "http" },
        { id = "system", count = 1, kind = "builtin" },
    })
    -- 崩溃在删 DB 之后、删 entries 之前：DB 无行 → 继续收尾
    cache:deleteProviderForBook(BOOK, LANG, "microsoft_free")
    Overlay.saveIntent(dir, { op = "delete_provider", provider = "microsoft_free",
        target_lang = LANG, started_at = os.time() })
    local summary = Store.reconcile(BOOK, LANG, cache)
    check("收尾：completed", summary and summary.completed == "microsoft_free")
    check("entries 补删", not fileExists(Overlay.entriesPath(dir, "microsoft_free")))
    local manifest = Overlay.loadManifest(dir)
    check("manifest 摘除", manifest and manifest.providers.microsoft_free == nil)
    check("显示切换", manifest and manifest.display_provider == "system")
    check("intent 清除", Overlay.loadIntent(dir) == nil)
    check("其他 provider 不受影响", dbCount(BOOK, LANG, "system") == 1)
end

do
    newCase("intent_no_manifest")
    local dir = Store.bookDir(BOOK, LANG)
    os.execute('mkdir -p "' .. dir .. '"')
    cache:storeForBook(BOOK, "auto", LANG, "src", "译", "system")
    cache:deleteProviderForBook(BOOK, LANG, "system")
    Overlay.saveIntent(dir, { op = "delete_provider", provider = "system",
        target_lang = LANG, started_at = os.time() })
    local summary = Store.reconcile(BOOK, LANG, cache)
    check("无 manifest 也能收尾", summary ~= nil and Overlay.loadIntent(dir) == nil)
end

-- ============================================================
print("== 6. reconcile 孤儿 entries 规则 ==")
do
    newCase("orphan_db_rows")
    local dir = seedV3Book(BOOK, LANG, { { id = "system", count = 1, kind = "builtin" } })
    -- 孤立 entries：DB 有行 → 补 manifest
    cache:storeForBook(BOOK, "auto", LANG, "srcX", "MCP译", "mcp:gpt-5", { selector = "x[1]" })
    cache:storeForBook(BOOK, "auto", LANG, "srcY", "MCP译2", "mcp:gpt-5", { selector = "x[2]" })
    Overlay.saveEntries(dir, "mcp:gpt-5", { entries = {
        { selector = "x[1]", source = "srcX", translation = "MCP译" },
        { selector = "x[2]", source = "srcY", translation = "MCP译2" },
    } })
    local summary = Store.reconcile(BOOK, LANG, cache)
    local manifest = Overlay.loadManifest(dir)
    check("DB 有行 → 补 manifest", summary and #summary.patched == 1
        and manifest.providers["mcp:gpt-5"] ~= nil)
    check("补全 translated_count", manifest.providers["mcp:gpt-5"].translated_count == 2)
    check("补全 fallback_order（追加不重排）", manifest.fallback_order[1] == "system"
        and manifest.fallback_order[2] == "mcp:gpt-5")
    check("补全 last_used_at", manifest.last_used_at["mcp:gpt-5"] ~= nil)
    check("entries 未动", fileExists(Overlay.entriesPath(dir, "mcp:gpt-5")))
    check("complete=false（无法推断）", manifest.providers["mcp:gpt-5"].complete == false)
end

do
    newCase("orphan_no_db_fresh")
    local dir = seedV3Book(BOOK, LANG, { { id = "system", count = 1, kind = "builtin" } })
    -- DB 无行 + 新鲜 mtime：不能判为删除残留（DB 写失败/重建库都留合法孤儿）
    Overlay.saveEntries(dir, "mcp:ghost", { entries = {
        { selector = "g[1]", source = "s", translation = "幽灵译文" },
    } })
    warnings = {}
    local summary = Store.reconcile(BOOK, LANG, cache)
    local manifest = Overlay.loadManifest(dir)
    check("无 DB 行但新鲜 → 保留并补 manifest", manifest.providers["mcp:ghost"] ~= nil)
    check("entries 保留", fileExists(Overlay.entriesPath(dir, "mcp:ghost")))
    check("logger.warn 提示", #warnings > 0 and warnings[1]:find("mcp:ghost", 1, true) ~= nil,
        warnings[1])
end

do
    newCase("orphan_no_db_old")
    local dir = seedV3Book(BOOK, LANG, { { id = "system", count = 1, kind = "builtin" } })
    Overlay.saveEntries(dir, "mcp:old", { entries = {
        { selector = "o[1]", source = "s", translation = "旧孤儿" },
    } })
    local path = Overlay.entriesPath(dir, "mcp:old")
    local old = os.time() - 31 * 24 * 3600
    lfs.touch(path, old, old)
    local summary = Store.reconcile(BOOK, LANG, cache)
    check("无 DB 行 + 超 30 天 → 删除", not fileExists(path))
    check("不补 manifest", Overlay.loadManifest(dir).providers["mcp:old"] == nil)
    check("removed 记录", summary and #summary.removed == 1)

    -- 29 天仍保留
    Overlay.saveEntries(dir, "mcp:edge", { entries = {
        { selector = "e[1]", source = "s", translation = "边界" },
    } })
    local edge_path = Overlay.entriesPath(dir, "mcp:edge")
    local edge = os.time() - 29 * 24 * 3600
    lfs.touch(edge_path, edge, edge)
    Store.reconcile(BOOK, LANG, cache)
    check("29 天不删", fileExists(edge_path))
end

do
    newCase("orphan_no_manifest")
    local dir = Store.bookDir(BOOK, LANG)
    os.execute('mkdir -p "' .. dir .. '"')
    cache:storeForBook(BOOK, "auto", LANG, "src", "译", "system", { selector = "p[1]" })
    Overlay.saveEntries(dir, "system", { entries = {
        { selector = "p[1]", source = "src", translation = "译" },
    } })
    local summary = Store.reconcile(BOOK, LANG, cache)
    local manifest = Overlay.loadManifest(dir)
    check("无 manifest 时补建", manifest ~= nil and manifest.providers.system ~= nil)
    check("补建 display_mode=auto", manifest and manifest.display_mode == "auto")
end

-- ============================================================
print("== 7. reconcile：缺失 entries / revision 补齐 ==")
do
    newCase("missing_entries")
    local dir = seedV3Book(BOOK, LANG, {
        { id = "system", count = 1, kind = "builtin" },
        { id = "mcp:gpt-5", count = 1 },
    })
    os.remove(Overlay.entriesPath(dir, "mcp:gpt-5"))
    local summary = Store.reconcile(BOOK, LANG, cache)
    local manifest = Overlay.loadManifest(dir)
    check("缺失 entries 的 provider 被摘除", manifest
        and manifest.providers["mcp:gpt-5"] == nil and manifest.providers.system)
    check("显示修复", manifest and manifest.display_provider == "system")
end

do
    newCase("revision_catchup")
    local dir = seedV3Book(BOOK, LANG, { { id = "system", count = 1, kind = "builtin" } })
    -- 模拟崩溃：entries 已写（revision 领先），manifest 未更新
    Overlay.saveEntries(dir, "system", { entries = {
        { selector = "p[1]", source = "src", translation = "新译文" },
    } })
    local entries_rev = Overlay.loadEntries(dir, "system").revision
    local manifest_rev = Overlay.loadManifest(dir).revision
    check("前置：entries 领先", entries_rev > manifest_rev)
    Store.reconcile(BOOK, LANG, cache)
    local after = Overlay.loadManifest(dir)
    check("manifest revision 补齐 >= entries", after.revision >= entries_rev,
        tostring(after.revision))
    check("内容不变", after.providers.system.translated_count == 1)
end

-- ============================================================
print("== 8. setDisplayProvider（D9：不改 fallback_order） ==")
do
    newCase("set_display")
    local dir = seedV3Book(BOOK, LANG, {
        { id = "system", count = 1, kind = "builtin" },
        { id = "mcp:gpt-5", count = 1 },
    })
    local before = Overlay.loadManifest(dir)
    local order_before = table.concat(before.fallback_order, ",")
    local manifest, err = Store.setDisplayProvider(BOOK, LANG, "mcp:gpt-5")
    check("切换成功", manifest ~= nil, tostring(err))
    check("manual + display_provider", manifest and manifest.display_mode == "manual"
        and manifest.display_provider == "mcp:gpt-5")
    check("last_used_at 更新", manifest and manifest.last_used_at["mcp:gpt-5"] >= os.time() - 5)
    check("revision +1", manifest and manifest.revision == before.revision + 1)
    check("fallback_order 不变（D9）", manifest
        and table.concat(manifest.fallback_order, ",") == order_before)
    check("落盘一致", Overlay.loadManifest(dir).display_provider == "mcp:gpt-5")

    local auto = Store.setDisplayProvider(BOOK, LANG, "auto")
    check("auto 模式", auto and auto.display_mode == "auto" and auto.display_provider == nil)
    check("auto 也 revision +1", auto and auto.revision == manifest.revision + 1)

    local unknown, unknown_err = Store.setDisplayProvider(BOOK, LANG, "mcp:none")
    check("未知 provider 报错", unknown == nil and unknown_err ~= nil)
    local empty_dir = Store.bookDir("/books/empty.epub", LANG)
    local no_manifest, no_err = Store.setDisplayProvider("/books/empty.epub", LANG, "system")
    check("无 manifest 报错", no_manifest == nil and no_err ~= nil)
end

-- ============================================================
print("== 9. listProviders / deleteAllProviders ==")
do
    newCase("list")
    seedV3Book(BOOK, LANG, {
        { id = "system", count = 2, kind = "builtin", display_name = "KOReader 内置（Google）",
            complete = true },
        { id = "mcp:gpt-5", count = 1, display_name = "MCP · GPT-5" },
    })
    local list = Store.listProviders(BOOK, LANG)
    check("列出两个 provider", #list == 2)
    local by_id = {}
    for _, item in ipairs(list) do by_id[item.id] = item end
    check("形状 {id, display_name, count, complete, confirmed}", by_id.system
        and by_id.system.display_name == "KOReader 内置（Google）"
        and by_id.system.count == 2 and by_id.system.complete == true
        and by_id.system.confirmed == true)
    check("count 用 translated_count", by_id["mcp:gpt-5"] and by_id["mcp:gpt-5"].count == 1)
    check("空书返回空表", #Store.listProviders("/books/none.epub", LANG) == 0)

    -- v2 兼容：未迁移的书也能列出
    local v2_dir = Store.bookDir("/books/v2.epub", LANG)
    os.execute('mkdir -p "' .. v2_dir .. '"')
    Overlay.save(v2_dir .. "/overlay.json", {
        version = 2, complete = false, provider = "microsoft_free",
        book_path = "/books/v2.epub", source_lang = "auto", target_lang = LANG,
        entries = { { selector = "p[1]", source = "s", translation = "旧" } },
    })
    local v2_list = Store.listProviders("/books/v2.epub", LANG)
    check("v2 兼容列出", #v2_list == 1 and v2_list[1].id == "microsoft_free"
        and v2_list[1].count == 1)
end

do
    newCase("delete_all")
    local dir = seedV3Book(BOOK, LANG, {
        { id = "system", count = 2, kind = "builtin" },
        { id = "mcp:gpt-5", count = 3 },
    })
    local result, err = Store.deleteAllProviders(BOOK, LANG)
    check("全部删除成功", result ~= nil, tostring(err))
    check("汇总段数", result and result.deleted == 5, result and tostring(result.deleted))
    check("汇总 provider", result and #result.removed == 2)
    check("manifest 移除", Overlay.loadManifest(dir) == nil)
    check("DB 清空", dbCount(BOOK, LANG, "system") == 0 and dbCount(BOOK, LANG, "mcp:gpt-5") == 0)
    local again = Store.deleteAllProviders(BOOK, LANG)
    check("重复全删幂等", again and again.deleted == 0)
end

do
    newCase("delete_all_v2")
    local dir = Store.bookDir(BOOK, LANG)
    os.execute('mkdir -p "' .. dir .. '"')
    Overlay.save(dir .. "/overlay.json", {
        version = 2, complete = false, provider = "system",
        book_path = BOOK, source_lang = "auto", target_lang = LANG,
        entries = { { selector = "p[1]", source = "s", translation = "旧译文" } },
    })
    cache:storeForBook(BOOK, "auto", LANG, "s", "旧译文", "system", { selector = "p[1]" })
    local result, err = Store.deleteAllProviders(BOOK, LANG)
    check("v2 书先迁移再全删", result and result.deleted == 1, tostring(err))
    check("bak 保留", fileExists(dir .. "/overlay.v2.bak"))
    check("manifest 已移除", Overlay.loadManifest(dir) == nil)
end

-- ============================================================
print("== 10. migrateIfNeeded / bookDir ==")
do
    newCase("migrate_db")
    check("fresh DB 初始化成功", Store.migrateIfNeeded(cache) == true)
    local rows = cache:_queryAll("PRAGMA user_version")
    check("user_version = 3", tonumber(rows[1][1]) == 3)
    local ok, err = Store.migrateIfNeeded({ initSchema = function() return nil, "boom" end })
    check("错误透传", ok == nil and err == "boom", tostring(err))
end

-- ============================================================
print("== 11. 打开书路径：锁等待可配置（M3） ==")
do
    newCase("open_lock_timeout")
    local book = "/books/locked.epub"
    local dir = Store.bookDir(book, LANG)
    os.execute('mkdir -p "' .. dir .. '"')
    local handle = io.open(dir .. "/overlay.json", "w")
    handle:write('{"version":2,"book_path":"/books/locked.epub",'
        .. '"target_lang":"zh-Hans","entries":[]}')
    handle:close()
    -- 模拟 worker 正在 checkpoint：锁已被占用
    assert(lfs.mkdir(dir .. "/.lock"))
    local util = require("ffi/util")
    local started = util.getTimestamp()
    local migrated, err = Store.migrateBookIfNeeded(book, LANG, cache,
        { lock_timeout = 0.2 })
    local elapsed = util.getTimestamp() - started
    lfs.rmdir(dir .. "/.lock")
    check("持锁时返回失败", migrated == nil and type(err) == "string", tostring(err))
    check("等待受 lock_timeout 限制", elapsed < 2,
        string.format("%.2fs", elapsed))
    local retried = Store.migrateBookIfNeeded(book, LANG, cache,
        { lock_timeout = 0.2 })
    check("锁释放后迁移成功", retried ~= nil)
end

print(string.format("\n==== Store 删除测试：%d 通过，%d 失败 ====", passed, failed))
if cache then cache:close() end
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
    for _, line in ipairs(warnings) do print("  log:", line) end
end
os.exit(failed == 0 and 0 or 1)