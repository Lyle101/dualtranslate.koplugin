-- ============================================================
-- Cache v3：真实 SQLite 下的 fresh schema / v2→v3 迁移 / providers CRUD
-- Run: luajit tests/migration_test.lua
-- 依赖 KOReader 自带的 lua-ljsqlite3（可用 KO_ROOT 覆盖路径）；
-- 缺失时跳过（mock DB 无法验证 DDL 与迁移语义）。
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
local ffi = require("ffi")
if not ffi.loadlib then ffi.loadlib = function(name) return ffi.load(name) end end
package.path = KO.."/?.lua;"..KO.."/common/?.lua;"..KO.."/common/?/init.lua;"..package.path
local ok, SQ3 = pcall(require, "lua-ljsqlite3")
if not ok then print("SKIP: lua-ljsqlite3 unavailable"); os.exit(0) end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local ROOT = "/tmp/dt_migration_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local data_dir = ROOT
local warnings = {}
local function joinArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end
package.preload["datastorage"] = function() return { getDataDir = function() return data_dir end } end
package.preload["logger"] = function()
    return {
        warn = function(...) warnings[#warnings + 1] = joinArgs(...) end,
        err = function(...) warnings[#warnings + 1] = joinArgs(...) end,
        info = function() end,
    }
end
package.preload["lua-ljsqlite3/init"] = function() return SQ3 end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Cache = dofile(script_dir .. "/../dualtranslate_cache.lua")

local case_no = 0
local function newDir(label)
    case_no = case_no + 1
    local dir = string.format("%s/%02d_%s", ROOT, case_no, label)
    os.execute('mkdir -p "' .. dir .. '"')
    data_dir = dir
    return dir
end

local function dbPath(dir) return dir .. "/dualtranslate_cache.sqlite3" end

local function scalar(db, sql)
    local stmt = db:prepare(sql)
    local row = stmt:step()
    stmt:close()
    return row and row[1] or nil
end

local function count(db, sql) return tonumber(scalar(db, sql)) or 0 end

local function allRows(db, sql)
    local stmt = db:prepare(sql)
    local out = {}
    while true do
        local row = stmt:step()
        if not row then break end
        out[#out + 1] = row
    end
    stmt:close()
    return out
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

local function tableColumns(db, name)
    local cols = {}
    for _, row in ipairs(allRows(db, "PRAGMA table_info(" .. name .. ")")) do
        cols[row[2]] = { type = row[3], pk = tonumber(row[6]) }
    end
    return cols
end

local function indexNames(db, table_name)
    local names = {}
    for _, row in ipairs(allRows(db,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = '" .. table_name .. "'")) do
        names[row[1]] = true
    end
    return names
end

local function providerMap(db)
    local map = {}
    for _, row in ipairs(allRows(db,
        "SELECT provider_id, kind, display_name, model_name, engine, confirmed FROM providers")) do
        map[row[1]] = { kind = row[2], display_name = row[3], model_name = row[4],
            engine = row[5], confirmed = tonumber(row[6]) }
    end
    return map
end

local function checkV3Shape(db, label)
    local cols = tableColumns(db, "book_translations")
    check(label .. ": user_version = 3", count(db, "PRAGMA user_version") == 3)
    check(label .. ": 主键含 provider", cols.provider and cols.provider.pk == 4)
    check(label .. ": 主键含 selector", cols.selector and cols.selector.pk == 6)
    check(label .. ": 主键六列", cols.book_path.pk == 1 and cols.source_lang.pk == 2
        and cols.target_lang.pk == 3 and cols.source_text.pk == 5)
    check(label .. ": 定位列齐全", cols.model_name and cols.xpointer and cols.chapter_index)
    local indexes = indexNames(db, "book_translations")
    check(label .. ": 三个索引齐全", indexes.idx_bt_book_provider and indexes.idx_bt_lookup
        and indexes.idx_bt_book_chapter)
    check(label .. ": 旧 translations 表保留", tableColumns(db, "translations").source_text ~= nil)
    local legacy_indexes = indexNames(db, "translations")
    check(label .. ": 旧表两个索引保留", legacy_indexes.idx_translations_lookup
        and legacy_indexes.idx_translations_book)
    local providers = providerMap(db)
    check(label .. ": system 中文显示名", providers.system
        and providers.system.display_name == "KOReader 内置（Google）"
        and providers.system.kind == "builtin" and providers.system.engine == "google",
        providers.system and providers.system.display_name)
    check(label .. ": microsoft_free 中文显示名", providers.microsoft_free
        and providers.microsoft_free.display_name == "Microsoft Edge（免费）"
        and providers.microsoft_free.kind == "http"
        and providers.microsoft_free.engine == "microsoft_edge",
        providers.microsoft_free and providers.microsoft_free.display_name)
end

-- v2（P0）库：旧主键不含 provider/selector。provider列放开 NOT NULL，
-- 以覆盖比 P0 更旧、可能写入 NULL provider 的库。
local V2_BOOK_DDL = [[
CREATE TABLE book_translations (
    book_path TEXT NOT NULL,
    source_lang TEXT NOT NULL,
    target_lang TEXT NOT NULL,
    source_text TEXT NOT NULL,
    translated_text TEXT NOT NULL,
    provider TEXT,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    use_count INTEGER DEFAULT 1,
    PRIMARY KEY(book_path, source_lang, target_lang, source_text)
);
]]

local V2_TRANSLATIONS_DDL = [[
CREATE TABLE translations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_lang TEXT NOT NULL,
    target_lang TEXT NOT NULL,
    source_text TEXT NOT NULL,
    translated_text TEXT NOT NULL,
    provider TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    use_count INTEGER DEFAULT 1,
    book_path TEXT,
    UNIQUE(source_lang, target_lang, source_text)
);
CREATE INDEX idx_translations_lookup ON translations(source_lang, target_lang, source_text);
CREATE INDEX idx_translations_book ON translations(book_path);
]]

local V2_ROWS = {
    { "/b.epub", "auto", "zh-Hans", "Hello", "你好", "system", 1000, 1000, 1 },
    { "/b.epub", "auto", "zh-Hans", "World", "世界", nil, 1002, 1002, 3 },
    { "/b.epub", "auto", "zh-Hans", "Bye", "再见", "mcp:gpt-5", 1003, 1003, 4 },
    { "/b.epub", "auto", "zh-Hans", "Edge", "边缘译文", "microsoft_free", 1004, 1004, 2 },
    { "/other.epub", "auto", "zh-Hans", "Hello", "另一本", "system", 1005, 1005, 1 },
    { "/b.epub", "auto", "ja", "Hello", "こんにちは", "system", 1006, 1006, 1 },
}

local function seedV2(dir, opts)
    opts = opts or {}
    local db = SQ3.open(dbPath(dir))
    db:exec("PRAGMA journal_mode=WAL;")
    db:exec(V2_BOOK_DDL)
    if not opts.no_legacy_table then
        db:exec(V2_TRANSLATIONS_DDL)
        db:exec([[INSERT INTO translations
            (source_lang, target_lang, source_text, translated_text, provider,
             created_at, last_used_at, use_count, book_path)
            VALUES ('auto', 'zh-Hans', 'Selected', '选中译文', 'system', 900, 900, 1, '/b.epub')]])
    end
    local stmt = db:prepare([[INSERT INTO book_translations
        (book_path, source_lang, target_lang, source_text, translated_text, provider,
         created_at, last_used_at, use_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]])
    for _, row in ipairs(V2_ROWS) do
        stmt:bind(row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9])
        stmt:step()
        stmt:reset()
        stmt:clearbind()
    end
    stmt:close()
    if opts.shadow_table then
        db:exec("CREATE TABLE book_translations_v3 (junk TEXT);")
        db:exec("INSERT INTO book_translations_v3 VALUES ('leftover');")
    end
    db:exec("PRAGMA user_version = 0;")
    db:close()
end

-- ============================================================
print("== 1. 全新库走 fresh schema ==")
do
    local dir = newDir("fresh")
    local cache = Cache:new()
    local db = cache:open()
    check("fresh: open 成功", db ~= nil)
    checkV3Shape(db, "fresh")
    check("fresh: 只 seed 两条内置 provider", count(db, "SELECT COUNT(*) FROM providers") == 2)
    check("fresh: 不产生 .bak", not fileExists(dbPath(dir) .. ".bak"))
    check("fresh: book_translations 为空", count(db, "SELECT COUNT(*) FROM book_translations") == 0)

    check("fresh: 写入成功", cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system",
        { selector = "p[1]", xpointer = "/body/p[1]", chapter_index = 1, model_name = "gpt-5" }) == true)
    local hit = cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "system")
    check("fresh: 命中译文", hit and hit.translated_text == "你好" and hit.provider == "system"
        and hit.cached == true)
    local stored = allRows(db, [[SELECT model_name, selector, xpointer, chapter_index,
        typeof(created_at), use_count FROM book_translations]])[1]
    check("fresh: meta 落库", stored[1] == "gpt-5" and stored[2] == "p[1]"
        and stored[3] == "/body/p[1]" and tonumber(stored[4]) == 1, joinArgs(stored[1], stored[2]))
    check("fresh: created_at 是整数", stored[5] == "integer", tostring(stored[5]))
    check("fresh: 缺省 selector 为空串", cache:storeForBook("/b.epub", "auto", "zh-Hans", "NoMeta",
        "无元数据", "system") == true
        and scalar(db, "SELECT selector FROM book_translations WHERE source_text = 'NoMeta'") == "")
    check("fresh: 重复 open 返回同一连接", cache:open() == db)
    cache:close()
    check("fresh: close 后可重开", Cache:new():open() ~= nil)
end

-- ============================================================
print("== 2. v2 → v3 迁移 ==")
do
    local dir = newDir("migrate")
    seedV2(dir)
    local cache = Cache:new()
    local db = cache:open()
    check("migrate: open 成功", db ~= nil)
    checkV3Shape(db, "migrate")
    check("migrate: .bak 已生成", fileExists(dbPath(dir) .. ".bak"))
    check("migrate: 行数不丢", count(db, "SELECT COUNT(*) FROM book_translations") == #V2_ROWS,
        tostring(count(db, "SELECT COUNT(*) FROM book_translations")))
    check("migrate: NULL provider → legacy",
        scalar(db, "SELECT provider FROM book_translations WHERE source_text = 'World'") == "legacy")
    check("migrate: 旧行 selector 为空串",
        count(db, "SELECT COUNT(*) FROM book_translations WHERE selector <> ''") == 0)
    check("migrate: 影子表已清理",
        count(db, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'book_translations_v3'") == 0)

    local preserved = true
    for _, row in ipairs(V2_ROWS) do
        local got = allRows(db, string.format([[SELECT translated_text, created_at, use_count
            FROM book_translations WHERE book_path = '%s' AND source_lang = '%s'
              AND target_lang = '%s' AND source_text = '%s' AND provider = '%s']],
            row[1], row[2], row[3], row[4], row[6] or "legacy"))[1]
        if not got or got[1] ~= row[5] or tonumber(got[2]) ~= row[7] or tonumber(got[3]) ~= row[9] then
            preserved = false
        end
    end
    check("migrate: 译文/created_at/use_count 全部保留", preserved)

    local providers = providerMap(db)
    check("migrate: providers 覆盖旧数据", providers.system and providers.microsoft_free
        and providers.legacy and providers["mcp:gpt-5"])
    check("migrate: legacy 显示名", providers.legacy and providers.legacy.display_name == "旧版译文"
        and providers.legacy.kind == "legacy")
    check("migrate: 未知 id 占位显示名", providers["mcp:gpt-5"]
        and providers["mcp:gpt-5"].display_name == "mcp:gpt-5"
        and providers["mcp:gpt-5"].kind == "mcp")
    check("migrate: 旧 translations 数据保留",
        scalar(db, "SELECT translated_text FROM translations WHERE source_text = 'Selected'") == "选中译文")

    -- 主键升级后同原文可以跨 provider / 跨 selector 共存
    check("migrate: 跨 provider 写入", cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello",
        "你好（Edge）", "microsoft_free") == true)
    check("migrate: 同原文两个 provider 共存",
        count(db, [[SELECT COUNT(*) FROM book_translations
            WHERE source_text = 'Hello' AND book_path = '/b.epub' AND target_lang = 'zh-Hans']]) == 2)
    check("migrate: system 译文未被覆盖",
        cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "system").translated_text == "你好")
    check("migrate: microsoft_free 读到自己的译文",
        cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "microsoft_free").translated_text
            == "你好（Edge）")
    check("migrate: 同 provider 不同 selector 共存",
        cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好（第二处）", "system",
            { selector = "p[2]" }) == true
        and count(db, [[SELECT COUNT(*) FROM book_translations
            WHERE source_text = 'Hello' AND provider = 'system' AND book_path = '/b.epub'
              AND target_lang = 'zh-Hans']]) == 2)

    -- .bak 必须是迁移前的 v2 快照（含 WAL 中最后一个事务）
    local bak = SQ3.open(dbPath(dir) .. ".bak")
    check("bak: 仍是 v2 版本", count(bak, "PRAGMA user_version") == 0)
    check("bak: 行数等于迁移前", count(bak, "SELECT COUNT(*) FROM book_translations") == #V2_ROWS)
    check("bak: 没有 selector 列", tableColumns(bak, "book_translations").selector == nil)
    check("bak: 没有 providers 表",
        count(bak, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'providers'") == 0)
    bak:close()

    -- 幂等：再次启动不得重跑迁移或重写备份
    local bak_before = readFile(dbPath(dir) .. ".bak")
    local rows_before = count(db, "SELECT COUNT(*) FROM book_translations")
    cache:close()
    local again = Cache:new()
    local db2 = again:open()
    check("migrate: 重复打开成功", db2 ~= nil)
    check("migrate: 幂等（行数不变）", count(db2, "SELECT COUNT(*) FROM book_translations") == rows_before)
    check("migrate: 幂等（user_version 仍为 3）", count(db2, "PRAGMA user_version") == 3)
    check("migrate: 幂等（不重写 .bak）", readFile(dbPath(dir) .. ".bak") == bak_before)
    again:close()
end

-- ============================================================
print("== 3. 迁移边界：影子表 / 缺旧表 / checkpoint 失败 ==")
print("   （checkpoint 冲突用例要等 busy_timeout=5000 重试，约 20 秒）")
do
    local dir = newDir("shadow")
    seedV2(dir, { shadow_table = true, no_legacy_table = true })
    local cache = Cache:new()
    local db = cache:open()
    check("shadow: 迁移成功", db ~= nil)
    check("shadow: 残留影子表被丢弃",
        count(db, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'book_translations_v3'") == 0)
    check("shadow: 数据行数正确", count(db, "SELECT COUNT(*) FROM book_translations") == #V2_ROWS)
    check("shadow: 旧 translations 表被补建", tableColumns(db, "translations").source_text ~= nil)
    cache:close()
end
do
    local dir = newDir("checkpoint_busy")
    seedV2(dir)
    -- 最后一个事务只存在于 WAL 中：备份必须先 checkpoint 再复制
    local writer = SQ3.open(dbPath(dir))
    writer:exec([[INSERT INTO book_translations
        (book_path, source_lang, target_lang, source_text, translated_text, provider,
         created_at, last_used_at, use_count)
        VALUES ('/b.epub', 'auto', 'zh-Hans', 'Last', '最后事务', 'system', 1007, 1007, 1)]])
    local total_rows = #V2_ROWS + 1
    -- 另一个连接持有读事务：TRUNCATE checkpoint 必须失败，迁移中止且不留备份
    local blocker = SQ3.open(dbPath(dir))
    blocker:exec("BEGIN;")
    local reader = blocker:prepare("SELECT COUNT(*) FROM book_translations")
    reader:step()
    reader:close()
    local cache = Cache:new()
    check("checkpoint: 迁移中止（open 返回 nil）", cache:open() == nil)
    check("checkpoint: 不复制 .bak", not fileExists(dbPath(dir) .. ".bak"))
    check("checkpoint: 现场保留（仍是 v2）", count(blocker, "PRAGMA user_version") == 0)
    check("checkpoint: 旧表结构未被改动", tableColumns(blocker, "book_translations").selector == nil)
    check("checkpoint: 数据仍在", count(blocker, "SELECT COUNT(*) FROM book_translations") == total_rows)
    check("checkpoint: 降级为 cache miss",
        cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "system") == nil)
    blocker:exec("ROLLBACK;")
    blocker:close()
    local retry = Cache:new()
    local db = retry:open()
    check("checkpoint: 读事务结束后可迁移", db ~= nil and count(db, "PRAGMA user_version") == 3)
    check("checkpoint: 重试后 .bak 生成", fileExists(dbPath(dir) .. ".bak"))
    check("checkpoint: 迁移后行数正确", count(db, "SELECT COUNT(*) FROM book_translations") == total_rows)
    local bak = SQ3.open(dbPath(dir) .. ".bak")
    check("checkpoint: .bak 含 WAL 中最后一个事务",
        count(bak, "SELECT COUNT(*) FROM book_translations") == total_rows
        and scalar(bak, "SELECT translated_text FROM book_translations WHERE source_text = 'Last'")
            == "最后事务")
    bak:close()
    writer:close()
    retry:close()
end

-- ============================================================
print("== 4. upsert / 定位行 / 命中取最近一行 ==")
do
    newDir("upsert")
    local cache = Cache:new()
    local db = cache:open()
    local book = "/b.epub"
    cache:storeForBook(book, "auto", "zh-Hans", "Hello", "第一版", "system")
    db:exec([[UPDATE book_translations SET created_at = 1000, last_used_at = 1000, use_count = 5
        WHERE source_text = 'Hello']])
    check("upsert: 重复写入成功", cache:storeForBook(book, "auto", "zh-Hans", "Hello", "第二版", "system") == true)
    local row = allRows(db, [[SELECT created_at, use_count, translated_text FROM book_translations
        WHERE source_text = 'Hello']])
    check("upsert: 只有一行", #row == 1)
    check("upsert: created_at 不被重置", tonumber(row[1][1]) == 1000, tostring(row[1][1]))
    check("upsert: use_count 递增", tonumber(row[1][2]) == 6, tostring(row[1][2]))
    check("upsert: 译文被更新", row[1][3] == "第二版")

    cache:storeForBook(book, "auto", "zh-Hans", "Dup", "旧位置", "system", { selector = "p[1]" })
    cache:storeForBook(book, "auto", "zh-Hans", "Dup", "新位置", "system", { selector = "p[2]" })
    db:exec("UPDATE book_translations SET last_used_at = 100 WHERE source_text = 'Dup' AND selector = 'p[1]'")
    db:exec("UPDATE book_translations SET last_used_at = 200 WHERE source_text = 'Dup' AND selector = 'p[2]'")
    local hit = cache:lookupForBook(book, "auto", "zh-Hans", "Dup", "system")
    check("lookup: 取 last_used_at 最新的一行", hit and hit.translated_text == "新位置",
        hit and hit.translated_text)
    check("lookup: provider 为空返回 nil", cache:lookupForBook(book, "auto", "zh-Hans", "Dup", "") == nil)
    check("lookup: provider 缺省返回 nil", cache:lookupForBook(book, "auto", "zh-Hans", "Dup") == nil)
    check("lookup: 其他 provider 不命中",
        cache:lookupForBook(book, "auto", "zh-Hans", "Dup", "microsoft_free") == nil)

    local before = count(db, "SELECT COUNT(*) FROM book_translations")
    check("locator: 命中后补定位行", cache:insertLocationRow(book, "auto", "zh-Hans", "Hello", "第二版",
        "system", { selector = "p[9]", xpointer = "/body/p[9]", chapter_index = 4 }) == true)
    check("locator: 行数 +1", count(db, "SELECT COUNT(*) FROM book_translations") == before + 1)
    local added = allRows(db, [[SELECT translated_text, xpointer, chapter_index FROM book_translations
        WHERE source_text = 'Hello' AND selector = 'p[9]']])[1]
    check("locator: 定位信息落库", added[1] == "第二版" and added[2] == "/body/p[9]"
        and tonumber(added[3]) == 4)
    db:exec("UPDATE book_translations SET use_count = 7 WHERE source_text = 'Hello' AND selector = 'p[9]'")
    cache:insertLocationRow(book, "auto", "zh-Hans", "Hello", "冲突译文", "system", { selector = "p[9]" })
    local kept = allRows(db, [[SELECT translated_text, use_count FROM book_translations
        WHERE source_text = 'Hello' AND selector = 'p[9]']])[1]
    check("locator: 冲突时不改写已有行", kept[1] == "第二版" and tonumber(kept[2]) == 7)
    check("locator: 冲突不新增行", count(db, "SELECT COUNT(*) FROM book_translations") == before + 1)
    cache:close()
end

-- ============================================================
print("== 5. deleteProviderForBook ==")
do
    newDir("delete")
    local cache = Cache:new()
    local db = cache:open()
    cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system", { selector = "p[1]" })
    cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system", { selector = "p[2]" })
    cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好（Edge）", "microsoft_free")
    cache:storeForBook("/b.epub", "auto", "ja", "Hello", "こんにちは", "microsoft_free")
    cache:storeForBook("/other.epub", "auto", "zh-Hans", "Hello", "另一本", "microsoft_free")

    local deleted, err = cache:deleteProviderForBook("/b.epub", "zh-Hans", "system")
    check("delete: 返回删除行数（多行）", deleted == 2, joinArgs(deleted, err))
    check("delete: 目标 provider 清空", count(db, [[SELECT COUNT(*) FROM book_translations
        WHERE book_path = '/b.epub' AND target_lang = 'zh-Hans' AND provider = 'system']]) == 0)
    check("delete: 同书其他 provider 保留", count(db, [[SELECT COUNT(*) FROM book_translations
        WHERE book_path = '/b.epub' AND target_lang = 'zh-Hans' AND provider = 'microsoft_free']]) == 1)
    check("delete: 其他目标语言保留", count(db, [[SELECT COUNT(*) FROM book_translations
        WHERE book_path = '/b.epub' AND target_lang = 'ja']]) == 1)
    check("delete: 其他书保留", count(db, [[SELECT COUNT(*) FROM book_translations
        WHERE book_path = '/other.epub']]) == 1)
    check("delete: 幂等返回 0", cache:deleteProviderForBook("/b.epub", "zh-Hans", "system") == 0)
    check("delete: 不存在的 provider 返回 0",
        cache:deleteProviderForBook("/b.epub", "zh-Hans", "mcp:none") == 0)
    local bad, bad_err = cache:deleteProviderForBook("/b.epub", "zh-Hans", "")
    check("delete: 空 provider 报错", bad == nil and bad_err ~= nil)
    local nil_book, nil_err = cache:deleteProviderForBook(nil, "zh-Hans", "system")
    check("delete: 缺书路径报错", nil_book == nil and nil_err ~= nil)
    cache:close()
end

-- ============================================================
print("== 6. providers CRUD ==")
do
    newDir("providers")
    local cache = Cache:new()
    local db = cache:open()
    local system = cache:getProvider("system")
    check("getProvider: 内置 provider", system and system.display_name == "KOReader 内置（Google）"
        and system.kind == "builtin" and system.engine == "google" and system.confirmed == true)
    check("getProvider: created_at/last_used_at 是数字",
        type(system.created_at) == "number" and type(system.last_used_at) == "number")
    check("getProvider: 不存在返回 nil", cache:getProvider("mcp:none") == nil)
    check("getProvider: 空 id 返回 nil", cache:getProvider("") == nil)

    check("upsertProvider: 新建 mcp provider", cache:upsertProvider({
        provider_id = "mcp:gpt-5", kind = "mcp", display_name = "MCP · GPT-5",
        model_name = "gpt-5", confirmed = false, metadata_json = '{"agent":"claude-desktop"}',
    }) == true)
    local created = cache:getProvider("mcp:gpt-5")
    check("upsertProvider: confirmed=false 落库", created and created.confirmed == false)
    check("upsertProvider: metadata_json 落库", created
        and created.metadata_json == '{"agent":"claude-desktop"}')
    db:exec("UPDATE providers SET created_at = 1234, last_used_at = 1234 WHERE provider_id = 'mcp:gpt-5'")
    check("upsertProvider: 再次写入", cache:upsertProvider({
        provider_id = "mcp:gpt-5", kind = "mcp", display_name = "MCP · GPT-5（改名）",
        model_name = "gpt-5-new", metadata_json = '{"agent":"other"}', last_used_at = 4321,
    }) == true)
    local updated = cache:getProvider("mcp:gpt-5")
    check("upsertProvider: 不重置 created_at", updated.created_at == 1234, tostring(updated.created_at))
    check("upsertProvider: 不重置 confirmed", updated.confirmed == false)
    check("upsertProvider: 更新 model_name/display_name/metadata_json",
        updated.model_name == "gpt-5-new" and updated.display_name == "MCP · GPT-5（改名）"
        and updated.metadata_json == '{"agent":"other"}')
    check("upsertProvider: 更新 last_used_at", updated.last_used_at == 4321)
    -- confirmed 只在新建时写入：导入路径不得改写用户的确认状态（§10.6）
    check("upsertProvider: 新建时 confirmed 缺省为 true", cache:upsertProvider({
        provider_id = "mcp:claude", kind = "mcp", display_name = "MCP · Claude",
    }) == true and cache:getProvider("mcp:claude").confirmed == true)
    check("upsertProvider: 已确认不被导入重置", cache:upsertProvider({
        provider_id = "mcp:claude", kind = "mcp", model_name = "claude-sonnet-4.5",
        confirmed = false,
    }) == true and cache:getProvider("mcp:claude").confirmed == true)
    check("upsertProvider: 未确认也不被导入改写", cache:upsertProvider({
        provider_id = "mcp:gpt-5", kind = "mcp", model_name = "gpt-5-new", confirmed = true,
    }) == true and cache:getProvider("mcp:gpt-5").confirmed == false)
    check("upsertProvider: 内置 provider 不被降级", cache:upsertProvider({
        provider_id = "system", kind = "builtin", display_name = "KOReader 内置（Google）",
    }) == true and cache:getProvider("system").engine == "google")
    check("upsertProvider: 缺 provider_id 拒绝", cache:upsertProvider({ kind = "mcp" }) == false)
    check("upsertProvider: 非表参数拒绝", cache:upsertProvider(nil) == false)

    cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system", { selector = "p[1]" })
    cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system", { selector = "p[2]" })
    cache:storeForBook("/b.epub", "auto", "zh-Hans", "Bye", "再见", "mcp:gpt-5")
    cache:storeForBook("/other.epub", "auto", "zh-Hans", "Hello", "另一本", "microsoft_free")
    local list = cache:listProvidersForBook("/b.epub", "zh-Hans")
    local by_id = {}
    for _, item in ipairs(list) do by_id[item.provider_id] = item end
    check("listProviders: 只列出本书本语言的 provider", #list == 2 and by_id.system and by_id["mcp:gpt-5"],
        tostring(#list))
    check("listProviders: 行数不是段数（同原文两处 = 2 行）", by_id.system and by_id.system.row_count == 2,
        by_id.system and tostring(by_id.system.row_count))
    check("listProviders: 带显示名/kind/model_name/confirmed", by_id["mcp:gpt-5"]
        and by_id["mcp:gpt-5"].display_name == "MCP · GPT-5（改名）"
        and by_id["mcp:gpt-5"].kind == "mcp" and by_id["mcp:gpt-5"].model_name == "gpt-5-new"
        and by_id["mcp:gpt-5"].confirmed == false and by_id["mcp:gpt-5"].row_count == 1)
    check("listProviders: 空书返回空表", #cache:listProvidersForBook("/none.epub", "zh-Hans") == 0)
    check("listProviders: 缺参数返回空表", #cache:listProvidersForBook(nil, "zh-Hans") == 0)
    cache:close()
end

-- ============================================================
print("== 7. withTransaction ==")
do
    newDir("transaction")
    local cache = Cache:new()
    local db = cache:open()
    local book = "/b.epub"
    local committed = cache:withTransaction(function()
        cache:storeForBook(book, "auto", "zh-Hans", "Tx", "事务译文", "system")
        cache:upsertProvider({ provider_id = "mcp:tx", kind = "mcp", display_name = "MCP · TX" })
    end)
    check("transaction: 提交返回 true", committed == true)
    check("transaction: 提交后数据可见",
        scalar(db, "SELECT translated_text FROM book_translations WHERE source_text = 'Tx'") == "事务译文"
        and cache:getProvider("mcp:tx") ~= nil)

    local rolled, rolled_err = cache:withTransaction(function()
        cache:storeForBook(book, "auto", "zh-Hans", "TxRollback", "回滚译文", "system")
        error("boom")
    end)
    check("transaction: 抛错返回 nil + 错误表", rolled == nil and type(rolled_err) == "table")
    check("transaction: 普通错误码 other", rolled_err and rolled_err.code == "other",
        rolled_err and rolled_err.code)
    check("transaction: 错误信息保留原因", rolled_err and rolled_err.message:find("boom", 1, true) ~= nil,
        rolled_err and rolled_err.message)
    check("transaction: 回滚后数据不落库",
        count(db, "SELECT COUNT(*) FROM book_translations WHERE source_text = 'TxRollback'") == 0)
    check("transaction: 回滚后连接仍可用",
        cache:storeForBook(book, "auto", "zh-Hans", "After", "后续译文", "system") == true)

    -- 另一个连接持有写锁：BEGIN IMMEDIATE 必须报 SQLITE_BUSY 供上层重试
    local blocker = SQ3.open(dbPath(data_dir))
    blocker:exec("PRAGMA busy_timeout=0;")
    blocker:exec("BEGIN IMMEDIATE;")
    db:exec("PRAGMA busy_timeout=0;")
    local busy, busy_err = cache:withTransaction(function()
        cache:storeForBook(book, "auto", "zh-Hans", "Busy", "忙", "system")
    end)
    check("transaction: 写锁冲突返回 nil", busy == nil)
    check("transaction: 错误码 SQLITE_BUSY", busy_err and busy_err.code == "SQLITE_BUSY",
        busy_err and busy_err.code)
    blocker:exec("ROLLBACK;")
    blocker:close()
    db:exec("PRAGMA busy_timeout=5000;")
    check("transaction: 锁释放后可写入", cache:withTransaction(function()
        cache:storeForBook(book, "auto", "zh-Hans", "Busy", "忙", "system")
    end) == true)

    check("错误码解析: 数字 5 → BUSY", cache:_transactionError("ljsqlite3[5] database is locked").code
        == "SQLITE_BUSY")
    check("错误码解析: 名字 busy → BUSY",
        cache:_transactionError("ljsqlite3[busy] database is locked").code == "SQLITE_BUSY")
    check("错误码解析: 数字 6 → LOCKED",
        cache:_transactionError("ljsqlite3[6] database table is locked").code == "SQLITE_LOCKED")
    check("错误码解析: 名字 locked → LOCKED",
        cache:_transactionError("ljsqlite3[locked] database table is locked").code == "SQLITE_LOCKED")
    check("错误码解析: 其他 → other",
        cache:_transactionError("ljsqlite3[constraint] UNIQUE constraint failed").code == "other")
    cache:close()
end

-- ============================================================
print("== 8. clear / clearForBook / 损坏降级 ==")
do
    newDir("clear")
    local cache = Cache:new()
    local db = cache:open()
    cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system")
    cache:storeForBook("/other.epub", "auto", "zh-Hans", "Hello", "另一本", "system")
    db:exec([[INSERT INTO translations
        (source_lang, target_lang, source_text, translated_text, provider,
         created_at, last_used_at, use_count, book_path)
        VALUES ('auto', 'zh-Hans', 'Selected', '选中译文', 'system', 900, 900, 1, '/b.epub')]])
    cache:clearForBook("/b.epub")
    check("clearForBook: 清掉本书整书行",
        count(db, "SELECT COUNT(*) FROM book_translations WHERE book_path = '/b.epub'") == 0)
    check("clearForBook: 清掉本书旧表行",
        count(db, "SELECT COUNT(*) FROM translations WHERE book_path = '/b.epub'") == 0)
    check("clearForBook: 其他书保留",
        count(db, "SELECT COUNT(*) FROM book_translations WHERE book_path = '/other.epub'") == 1)
    cache:clear()
    check("clear: 两张表都清空", count(db, "SELECT COUNT(*) FROM book_translations") == 0
        and count(db, "SELECT COUNT(*) FROM translations") == 0)
    check("clear: providers 保留", count(db, "SELECT COUNT(*) FROM providers") >= 2)
    cache:close()
end
do
    local dir = newDir("corrupt")
    local handle = assert(io.open(dbPath(dir), "wb"))
    handle:write("this is not a sqlite database at all")
    handle:close()
    local cache = Cache:new()
    check("corrupt: open 降级为 nil", cache:open() == nil)
    check("corrupt: 查询降级为 cache miss",
        cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "system") == nil)
    check("corrupt: 写入降级为 false",
        cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system") == false)
end

-- ============================================================
print("== 9. initSchema 独立入口（Store.migrateIfNeeded 调用口径） ==")
do
    local dir = newDir("init_fresh")
    local cache = Cache:new()
    check("initSchema: 全新库直接初始化", cache:initSchema() == true)
    check("initSchema: 版本已置 3", count(cache.db, "PRAGMA user_version") == 3)
    check("initSchema: 内置 provider 已 seed", count(cache.db, "SELECT COUNT(*) FROM providers") == 2)
    check("initSchema: 不产生 .bak", not fileExists(dbPath(dir) .. ".bak"))
    check("initSchema: 后续 open 复用连接", cache:open() == cache.db)
    check("initSchema: 重复调用幂等", cache:initSchema() == true)
    cache:close()
end
do
    local dir = newDir("init_migrate")
    seedV2(dir)
    local cache = Cache:new()
    check("initSchema: v2 库直接迁移", cache:initSchema() == true)
    check("initSchema: 迁移后版本为 3", count(cache.db, "PRAGMA user_version") == 3)
    check("initSchema: 迁移后行数不丢",
        count(cache.db, "SELECT COUNT(*) FROM book_translations") == #V2_ROWS)
    check("initSchema: 备份已生成", fileExists(dbPath(dir) .. ".bak"))
    check("initSchema: 迁移后可直接读写",
        cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好（新）", "microsoft_free") == true
        and cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "microsoft_free")
            .translated_text == "你好（新）")
    cache:close()
end

print(string.format("\n==== 迁移结果：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
    for _, line in ipairs(warnings) do print("  log:", line) end
end
os.exit(failed == 0 and 0 or 1)
