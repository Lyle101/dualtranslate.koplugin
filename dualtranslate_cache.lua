local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
-- Lua 5.2+ moved unpack into table; LuaJIT (5.1) keeps the global.  Both
-- forms are identical on every target this plugin runs on.
local unpack = table.unpack or unpack
local logger = require("logger")

local DB_FILENAME = "dualtranslate_cache.sqlite3"
local SCHEMA_VERSION = 3

local PROVIDERS_DDL = [[
    CREATE TABLE IF NOT EXISTS providers (
        provider_id   TEXT PRIMARY KEY,
        kind          TEXT NOT NULL CHECK(kind IN ('builtin','http','mcp','legacy')),
        display_name  TEXT NOT NULL,
        model_name    TEXT,
        engine        TEXT,
        confirmed     INTEGER NOT NULL DEFAULT 1,
        metadata_json TEXT,
        created_at    INTEGER NOT NULL,
        last_used_at  INTEGER NOT NULL
    );
]]

-- selector is part of the key: the same paragraph can appear at several
-- places in a book and every position needs its own locator row.
local BOOK_TRANSLATIONS_BODY = [[
    book_path       TEXT NOT NULL,
    source_lang     TEXT NOT NULL,
    target_lang     TEXT NOT NULL,
    source_text     TEXT NOT NULL,
    translated_text TEXT NOT NULL,
    provider        TEXT NOT NULL,
    model_name      TEXT,
    selector        TEXT NOT NULL DEFAULT '',
    xpointer        TEXT,
    chapter_index   INTEGER,
    created_at      INTEGER NOT NULL,
    last_used_at    INTEGER NOT NULL,
    use_count       INTEGER DEFAULT 1,
    PRIMARY KEY (book_path, source_lang, target_lang, provider, source_text, selector)
]]

local BOOK_TRANSLATIONS_INDEXES = [[
    CREATE INDEX IF NOT EXISTS idx_bt_book_provider
        ON book_translations(book_path, target_lang, provider);
    CREATE INDEX IF NOT EXISTS idx_bt_lookup
        ON book_translations(book_path, source_lang, target_lang, provider, source_text);
    CREATE INDEX IF NOT EXISTS idx_bt_book_chapter
        ON book_translations(book_path, target_lang, chapter_index);
]]

-- Shared selected-text table; both schema paths keep it untouched.
local LEGACY_TRANSLATIONS_DDL = [[
    CREATE TABLE IF NOT EXISTS translations (
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
    CREATE INDEX IF NOT EXISTS idx_translations_lookup
        ON translations(source_lang, target_lang, source_text);
    CREATE INDEX IF NOT EXISTS idx_translations_book
        ON translations(book_path);
]]

-- Seeded on every schema path so the menu has names before the first translation.
local BUILTIN_PROVIDER_SEED = [[
    INSERT OR IGNORE INTO providers
        (provider_id, kind, display_name, model_name, engine, confirmed,
         metadata_json, created_at, last_used_at)
    VALUES
        ('system', 'builtin', 'KOReader 内置（Google）', NULL, 'google', 1,
         NULL, strftime('%s','now'), strftime('%s','now')),
        ('microsoft_free', 'http', 'Microsoft Edge（免费）', NULL, 'microsoft_edge', 1,
         NULL, strftime('%s','now'), strftime('%s','now'));
]]

local LEGACY_PROVIDER_SEED = [[
    INSERT OR IGNORE INTO providers
        (provider_id, kind, display_name, model_name, engine, confirmed,
         metadata_json, created_at, last_used_at)
    SELECT DISTINCT
        COALESCE(provider, 'legacy'),
        CASE COALESCE(provider, 'legacy')
            WHEN 'system' THEN 'builtin'
            WHEN 'microsoft_free' THEN 'http'
            WHEN 'legacy' THEN 'legacy'
            ELSE 'mcp'
        END,
        CASE COALESCE(provider, 'legacy')
            WHEN 'system' THEN 'KOReader 内置（Google）'
            WHEN 'microsoft_free' THEN 'Microsoft Edge（免费）'
            WHEN 'legacy' THEN '旧版译文'
            ELSE COALESCE(provider, 'legacy')
        END,
        NULL, NULL, 1, NULL, strftime('%s','now'), strftime('%s','now')
    FROM book_translations;
]]

local MIGRATION_SQL = {
    "BEGIN IMMEDIATE;",
    PROVIDERS_DDL,
    -- A previous run may have died mid-migration and left the shadow table.
    "DROP TABLE IF EXISTS book_translations_v3;",
    "CREATE TABLE book_translations_v3 (" .. BOOK_TRANSLATIONS_BODY .. ");",
    [[
        INSERT OR IGNORE INTO book_translations_v3
            (book_path, source_lang, target_lang, source_text, translated_text,
             provider, model_name, selector, xpointer, chapter_index,
             created_at, last_used_at, use_count)
        SELECT
            book_path, source_lang, target_lang, source_text, translated_text,
            COALESCE(provider, 'legacy'), NULL, '', NULL, NULL,
            created_at, last_used_at, use_count
        FROM book_translations;
    ]],
    "DROP TABLE book_translations;",
    "ALTER TABLE book_translations_v3 RENAME TO book_translations;",
    BOOK_TRANSLATIONS_INDEXES,
    BUILTIN_PROVIDER_SEED,
    LEGACY_PROVIDER_SEED,
    "PRAGMA user_version = " .. SCHEMA_VERSION .. ";",
    "COMMIT;",
}

local Cache = {}

function Cache:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Cache:getDbPath()
    return DataStorage:getDataDir() .. "/" .. DB_FILENAME
end

-- db:exec leaves a failed statement open, and an open statement makes every
-- later COMMIT/ROLLBACK fail with "SQL statements in progress" — which would
-- break the caller's busy retry on the same connection.  Always finalize.
local function withStmt(db, sql, fn)
    local stmt = db:prepare(sql)
    local ok, result = pcall(fn, stmt)
    stmt:close()
    if not ok then error(result, 0) end
    return result
end

local function execSql(db, sql)
    for command in sql:gmatch("[^;]+") do
        if command:find("%S") then
            -- One step runs DDL/DML/PRAGMA to completion; no result draining.
            withStmt(db, command, function(stmt) stmt:step() end)
        end
    end
end

local function dbScalar(db, sql, ...)
    local args, arg_count = { ... }, select("#", ...)
    local ok, value = pcall(withStmt, db, sql, function(stmt)
        stmt:bind(unpack(args, 1, arg_count))
        local row = stmt:step()
        return row and tonumber(row[1]) or nil
    end)
    if not ok then return nil, tostring(value) end
    return value
end

-- ljsqlite3 reports either the numeric code or its lowercase name
-- ("ljsqlite3[26] ..." / "ljsqlite3[notadb] file is not a database").
-- SQLITE_NOTADB (26) and SQLITE_CORRUPT (11) mean the file itself is
-- damaged; anything else (busy, cantopen, ...) must keep degrading to nil.
local function is_corruption_error(err)
    local message = tostring(err)
    return message:find("not a database", 1, true) ~= nil
        or message:find("database disk image is malformed", 1, true) ~= nil
        or message:find("ljsqlite3%[notadb%]") ~= nil
        or message:find("ljsqlite3%[corrupt%]") ~= nil
        or message:find("ljsqlite3%[26%]") ~= nil
        or message:find("ljsqlite3%[11%]") ~= nil
end

local function remove_db_files(db_path)
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
end

local function setup_pragmas(db)
    execSql(db, "PRAGMA journal_mode=WAL;")
    execSql(db, "PRAGMA busy_timeout=5000;")
    execSql(db, "PRAGMA synchronous=NORMAL;")
end

local function copyFile(source_path, target_path)
    local input = io.open(source_path, "rb")
    if not input then return nil, "cannot read " .. source_path end
    local output, open_err = io.open(target_path, "wb")
    if not output then
        input:close()
        return nil, tostring(open_err)
    end
    while true do
        local chunk = input:read(65536)
        if not chunk then break end
        local written, write_err = output:write(chunk)
        if not written then
            input:close()
            output:close()
            return nil, tostring(write_err)
        end
    end
    input:close()
    local closed, close_err = output:close()
    if not closed then return nil, tostring(close_err) end
    return true
end

-- Every accessor runs through these helpers so SQLite errors (corrupt
-- db, bad bind) degrade to a cache miss instead of crashing the worker.
-- prepare/bind/step/close are the only ljsqlite3 calls in the module.
-- The explicit vararg count keeps NULL binds: #{...} stops at the first nil,
-- which would silently drop every parameter after an optional column.
function Cache:_query(sql, ...)
    local args, arg_count = { ... }, select("#", ...)
    local db = self:open()
    if not db then return nil end
    local ok, row = pcall(withStmt, db, sql, function(stmt)
        stmt:bind(unpack(args, 1, arg_count))
        return stmt:step()
    end)
    if not ok then return nil end
    return row
end

function Cache:_queryAll(sql, ...)
    local args, arg_count = { ... }, select("#", ...)
    local db = self:open()
    if not db then return {} end
    local ok, rows = pcall(withStmt, db, sql, function(stmt)
        stmt:bind(unpack(args, 1, arg_count))
        local out = {}
        while true do
            local row = stmt:step()
            if not row then break end
            out[#out + 1] = row
        end
        return out
    end)
    if not ok then return {} end
    return rows
end

function Cache:_execute(sql, ...)
    local args, arg_count = { ... }, select("#", ...)
    local db = self:open()
    if not db then return false end
    local ok, err = pcall(withStmt, db, sql, function(stmt)
        stmt:bind(unpack(args, 1, arg_count))
        stmt:step()
    end)
    if not ok then
        logger.warn("dualtranslate: cache write error:", tostring(err))
        return false
    end
    return true
end

function Cache:_connect()
    local db_path = self:getDbPath()
    -- A cache database corrupted by a crash/power loss must not take the
    -- plugin down: SQLite throws on open/prepare of a damaged file.  Try to
    -- recreate the database instead, and fall back to a nil handle so every
    -- caller degrades to a cache miss instead of crashing.
    local ok, db = pcall(SQ3.open, db_path)
    if not ok or not db then
        logger.warn("dualtranslate: cache db corrupt, recreating:", db_path)
        remove_db_files(db_path)
        ok, db = pcall(SQ3.open, db_path)
        if not ok or not db then
            logger.err("dualtranslate: cannot recreate cache db:", db)
            return nil
        end
    end
    local setup_ok, setup_err = pcall(setup_pragmas, db)
    if not setup_ok and is_corruption_error(setup_err) then
        -- ljsqlite3 opens a damaged header lazily: "file is not a database"
        -- only surfaces on the first exec/prepare (9.3).  Delete the db and
        -- its WAL sidecars and reopen a fresh file.
        logger.warn("dualtranslate: cache db corrupt, recreating:", db_path)
        pcall(function() db:close() end)
        remove_db_files(db_path)
        ok, db = pcall(SQ3.open, db_path)
        if ok and db then
            setup_ok, setup_err = pcall(setup_pragmas, db)
        end
    end
    if not setup_ok then
        logger.warn("dualtranslate: cache db setup failed:", setup_err)
        if ok and db then pcall(function() db:close() end) end
        return nil
    end
    return db
end

function Cache:open()
    if self.db then return self.db end
    local db = self:_connect()
    if not db then return nil end
    self.db = db
    local ok, err = self:initSchema()
    if not ok then
        logger.warn("dualtranslate: cache schema init failed:", err)
        self:close()
        return nil
    end
    -- Migration reconnects after the backup, so the handle may have changed.
    return self.db
end

-- Single DDL entry point: open() only connects, so a fresh install can never
-- create the v2 table first and then run the migration on it.
-- A corruption-class failure (9.3) deletes the db and rebuilds fresh once;
-- any other error keeps degrading to nil so callers fall back to cache miss.
function Cache:initSchema()
    local ok, err = self:_initSchemaOnce()
    if ok then return true end
    if is_corruption_error(err) then
        logger.warn("dualtranslate: cache db corrupt, recreating:", self:getDbPath())
        self:close()
        remove_db_files(self:getDbPath())
        ok, err = self:_initSchemaOnce()
        if ok then return true end
    end
    self:close()
    return nil, err
end

function Cache:_initSchemaOnce()
    local db = self.db
    if not db then
        db = self:_connect()
        if not db then return nil, "cannot open cache db" end
        self.db = db
    end
    local version, version_err = dbScalar(db, "PRAGMA user_version")
    if not version then
        return nil, version_err or "cannot read cache schema version"
    end
    if version >= SCHEMA_VERSION then return true end
    local has_book_table = dbScalar(db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
        "book_translations") == 1
    if has_book_table then
        return self:_migrateToV3(db)
    end
    return self:_createFreshSchema(db)
end

function Cache:_createFreshSchema(db)
    -- Atomic: a half-created schema with user_version still 0 would be
    -- mistaken for a v2 database on the next start.
    local ok, err = pcall(function()
        execSql(db, "BEGIN IMMEDIATE;")
        execSql(db, LEGACY_TRANSLATIONS_DDL)
        execSql(db, PROVIDERS_DDL)
        execSql(db, "CREATE TABLE IF NOT EXISTS book_translations ("
            .. BOOK_TRANSLATIONS_BODY .. ");")
        execSql(db, BOOK_TRANSLATIONS_INDEXES)
        execSql(db, BUILTIN_PROVIDER_SEED)
        execSql(db, "PRAGMA user_version = " .. SCHEMA_VERSION .. ";")
        execSql(db, "COMMIT;")
    end)
    if not ok then
        pcall(execSql, db, "ROLLBACK;")
        return nil, tostring(err)
    end
    return true
end

function Cache:_migrateToV3(db)
    local db_path = self:getDbPath()
    -- The busy flag is a result row, so it needs prepare+step (db:exec drops
    -- rows); non-zero means the WAL still holds data the copy would miss.
    local busy = dbScalar(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    if busy ~= 0 then
        busy = dbScalar(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    end
    if busy ~= 0 then
        return nil, "cache db checkpoint failed, close the reader and retry"
    end
    local closed, close_err = pcall(function() db:close() end)
    self.db = nil
    if not closed then return nil, tostring(close_err) end
    local copied, copy_err = copyFile(db_path, db_path .. ".bak")
    if not copied then return nil, copy_err end
    local reopened = self:_connect()
    if not reopened then return nil, "cannot reopen cache db after backup" end
    self.db = reopened
    local ok, err = pcall(function()
        for _, sql in ipairs(MIGRATION_SQL) do
            execSql(reopened, sql)
        end
    end)
    if not ok then
        pcall(execSql, reopened, "ROLLBACK;")
        return nil, tostring(err)
    end
    local legacy_ok, legacy_err = pcall(execSql, reopened, LEGACY_TRANSLATIONS_DDL)
    if not legacy_ok then return nil, tostring(legacy_err) end
    return true
end

function Cache:lookupForBook(book_path, source_lang, target_lang, source_text, provider)
    if not book_path or not provider or provider == "" then return nil end
    local row = self:_query([[
        SELECT translated_text, provider FROM book_translations
        WHERE book_path = ? AND source_lang = ? AND target_lang = ? AND source_text = ?
          AND provider = ?
        ORDER BY last_used_at DESC
        LIMIT 1
    ]], book_path, source_lang, target_lang, source_text, provider)
    if not row then return nil end
    self:_execute([[
        UPDATE book_translations SET last_used_at = ?, use_count = use_count + 1
        WHERE book_path = ? AND source_lang = ? AND target_lang = ? AND source_text = ?
          AND provider = ?
    ]], os.time(), book_path, source_lang, target_lang, source_text, provider)
    return { translated_text = row[1], provider = row[2], cached = true }
end

function Cache:storeForBook(book_path, source_lang, target_lang, source_text,
        translated_text, provider, meta)
    if not book_path then return false end
    meta = meta or {}
    local now = os.time()
    -- Upsert instead of INSERT OR REPLACE: REPLACE deletes the row first and
    -- would reset created_at/use_count on every retranslation.
    return self:_execute([[
        INSERT INTO book_translations
            (book_path, source_lang, target_lang, source_text, translated_text,
             provider, model_name, selector, xpointer, chapter_index,
             created_at, last_used_at, use_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(book_path, source_lang, target_lang, provider, source_text, selector)
        DO UPDATE SET translated_text = excluded.translated_text,
                      last_used_at = excluded.last_used_at,
                      use_count = use_count + 1
    ]], book_path, source_lang, target_lang, source_text, translated_text, provider,
        meta.model_name, meta.selector or "", meta.xpointer, meta.chapter_index, now, now)
end

-- A cache hit skips storeForBook, so the locator row for this position has to
-- be added separately; an existing row is never rewritten.
function Cache:insertLocationRow(book_path, source_lang, target_lang, source_text,
        translated_text, provider, meta)
    if not book_path then return false end
    meta = meta or {}
    local now = os.time()
    return self:_execute([[
        INSERT INTO book_translations
            (book_path, source_lang, target_lang, source_text, translated_text,
             provider, model_name, selector, xpointer, chapter_index,
             created_at, last_used_at, use_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(book_path, source_lang, target_lang, provider, source_text, selector)
        DO NOTHING
    ]], book_path, source_lang, target_lang, source_text, translated_text, provider,
        meta.model_name, meta.selector or "", meta.xpointer, meta.chapter_index, now, now)
end

function Cache:deleteProviderForBook(book_path, target_lang, provider)
    if not book_path or not target_lang or not provider or provider == "" then
        return nil, "book_path, target_lang and provider are required"
    end
    local db = self:open()
    if not db then return nil, "cache db unavailable" end
    local ok, count = pcall(function()
        withStmt(db, [[
            DELETE FROM book_translations
            WHERE book_path = ? AND target_lang = ? AND provider = ?
        ]], function(stmt)
            stmt:bind(book_path, target_lang, provider)
            stmt:step()
        end)
        -- ljsqlite3 exposes no changes() binding; read it back on the same
        -- connection, before any other statement can reset the counter.
        return withStmt(db, "SELECT changes()", function(stmt)
            local row = stmt:step()
            return row and tonumber(row[1]) or 0
        end)
    end)
    if not ok then
        logger.warn("dualtranslate: cache delete error:", tostring(count))
        return nil, tostring(count)
    end
    return count
end

function Cache:getProvider(provider_id)
    if not provider_id or provider_id == "" then return nil end
    local row = self:_query([[
        SELECT provider_id, kind, display_name, model_name, engine, confirmed,
               metadata_json, created_at, last_used_at
        FROM providers WHERE provider_id = ?
    ]], provider_id)
    if not row then return nil end
    return {
        provider_id = row[1],
        kind = row[2],
        display_name = row[3],
        model_name = row[4],
        engine = row[5],
        confirmed = tonumber(row[6]) == 1,
        metadata_json = row[7],
        created_at = tonumber(row[8]),
        last_used_at = tonumber(row[9]),
    }
end

function Cache:upsertProvider(meta)
    if type(meta) ~= "table" or not meta.provider_id or meta.provider_id == "" then
        return false
    end
    local now = os.time()
    local confirmed = 1
    if meta.confirmed ~= nil then confirmed = meta.confirmed and 1 or 0 end
    local display_name = meta.display_name
    if not display_name then
        -- Keep a name the user already edited; only a brand-new provider falls
        -- back to the id placeholder (same rule as the migration seed).
        local existing = self:getProvider(meta.provider_id)
        display_name = existing and existing.display_name or meta.provider_id
    end
    -- confirmed and created_at are deliberately absent from DO UPDATE: the
    -- user's model confirmation must survive later imports.
    return self:_execute([[
        INSERT INTO providers
            (provider_id, kind, display_name, model_name, engine, confirmed,
             metadata_json, created_at, last_used_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(provider_id) DO UPDATE SET
            kind = excluded.kind,
            display_name = excluded.display_name,
            model_name = COALESCE(excluded.model_name, providers.model_name),
            engine = COALESCE(excluded.engine, providers.engine),
            metadata_json = COALESCE(excluded.metadata_json, providers.metadata_json),
            last_used_at = excluded.last_used_at
    ]], meta.provider_id, meta.kind, display_name,
        meta.model_name, meta.engine, confirmed, meta.metadata_json,
        now, meta.last_used_at or now)
end

-- Row count is diagnostic only; the segment count comes from overlay entries.
function Cache:listProvidersForBook(book_path, target_lang)
    if not book_path or not target_lang then return {} end
    local rows = self:_queryAll([[
        SELECT b.provider, p.display_name, p.kind, p.model_name, p.confirmed,
               COUNT(*) AS row_count
        FROM book_translations b
        LEFT JOIN providers p ON p.provider_id = b.provider
        WHERE b.book_path = ? AND b.target_lang = ?
        GROUP BY b.provider
        ORDER BY MAX(b.last_used_at) DESC, b.provider
    ]], book_path, target_lang)
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = {
            provider_id = row[1],
            display_name = row[2],
            kind = row[3],
            model_name = row[4],
            confirmed = tonumber(row[5]) == 1,
            row_count = tonumber(row[6]) or 0,
        }
    end
    return out
end

-- ljsqlite3 reports either the numeric code or its lowercase name
-- ("ljsqlite3[5] ..." / "ljsqlite3[busy] ..."), depending on the call site.
function Cache:_transactionError(err)
    local message = tostring(err):match("^[^\n]*") or tostring(err)
    local token = message:match("ljsqlite3%[([^%]]+)%]")
    local code = "other"
    if token == "5" or token == "busy" then
        code = "SQLITE_BUSY"
    elseif token == "6" or token == "locked" then
        code = "SQLITE_LOCKED"
    end
    return { code = code, message = message }
end

-- Retry policy belongs to the caller (Store); this only exposes the code.
function Cache:withTransaction(fn)
    local db = self:open()
    if not db then
        return nil, { code = "other", message = "cache db unavailable" }
    end
    local begun, begin_err = pcall(execSql, db, "BEGIN IMMEDIATE;")
    if not begun then return nil, self:_transactionError(begin_err) end
    local ran, err = pcall(fn)
    if not ran then
        pcall(execSql, db, "ROLLBACK;")
        return nil, self:_transactionError(err)
    end
    local committed, commit_err = pcall(execSql, db, "COMMIT;")
    if not committed then
        pcall(execSql, db, "ROLLBACK;")
        return nil, self:_transactionError(commit_err)
    end
    return true
end

function Cache:close()
    if self.db then
        self.db:close()
        self.db = nil
    end
end

function Cache:clear()
    local db = self:open()
    if not db then return end
    local ok, err = pcall(function()
        execSql(db, "DELETE FROM translations;")
        execSql(db, "DELETE FROM book_translations;")
        execSql(db, "VACUUM;")
    end)
    if not ok then logger.warn("dualtranslate: cache clear error:", err) end
end

function Cache:clearForBook(book_path)
    if not book_path then return end
    self:_execute("DELETE FROM book_translations WHERE book_path = ?", book_path)
    -- Older builds also stored whole-book rows in the shared table with a
    -- NULL book_path; they are unreachable now (book lookups use the
    -- book_translations table), so a plain removal of this book's rows is
    -- enough.  The overlay-driven per-paragraph repair loop from older
    -- versions is gone.
    self:_execute("DELETE FROM translations WHERE book_path = ?", book_path)
end

return Cache
