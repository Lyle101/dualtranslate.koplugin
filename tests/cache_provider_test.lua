-- P0 regression: book cache lookups must be scoped by provider.
--
-- Run: luajit tests/cache_provider_test.lua
local calls = {}
local M = {}

function M.open(path)
    local db = { path = path, closed = false, exec = function() return true end,
        close = function(self) self.closed = true end }
    return setmetatable(db, { __index = M })
end

local stmt_mt = {}
function stmt_mt.__index(_, key)
    if key == "bind" then
        return function(self, ...) self.binds = { ... } self.bind_count = select("#", ...) return self end
    elseif key == "step" then
        return function(self)
            -- The fake DB is already at schema v3, so initSchema skips the DDL.
            if self.sql:find("user_version", 1, true) then return { 3 } end
            if self.sql:find("SELECT", 1, true) then
                if self.binds and self.binds[5] == "system" then
                    return { "系统译文", "system" }
                end
                return false
            end
            return true
        end
    elseif key == "close" then
        return function() end
    end
    return nil
end

function M.prepare(_, sql)
    local stmt = { sql = sql }
    setmetatable(stmt, stmt_mt)
    calls[#calls + 1] = { sql = sql, stmt = stmt }
    return stmt
end
function M.exec() return true end
function M.close() end

package.preload["lua-ljsqlite3/init"] = function() return M end
package.preload["datastorage"] = function() return { getDataDir = function() return "/data" end } end
package.preload["logger"] = function()
    return { warn = function() end, err = function() end, info = function() end }
end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Cache = dofile(script_dir .. "/../dualtranslate_cache.lua")
local cache = Cache:new()
-- First open probes the schema version; record only the accessor statements.
assert(cache:open())
calls = {}

-- No provider: must be a cache miss without touching SQLite.
assert(cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello") == nil)
assert(#calls == 0, "missing provider must not issue a query")

-- system hit, and the usage update must also be scoped to system.
local hit = cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "system")
assert(hit and hit.translated_text == "系统译文" and hit.provider == "system")
assert(calls[1].sql:find("provider = ?", 1, true), "lookup SQL must filter provider")
assert(calls[1].sql:find("ORDER BY last_used_at DESC", 1, true),
    "lookup must pick the most recently used locator row")
assert(calls[1].stmt.bind_count == 5 and calls[1].stmt.binds[5] == "system")
assert(calls[2].sql:find("UPDATE book_translations", 1, true))
assert(calls[2].sql:find("provider = ?", 1, true), "usage update SQL must filter provider")
assert(calls[2].stmt.bind_count == 6 and calls[2].stmt.binds[6] == "system")

-- A different provider must miss even though the fake DB has a system row.
calls = {}
local miss = cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "microsoft_free")
assert(miss == nil, "microsoft_free must not read a system row")
assert(#calls == 1, "a miss must not run the usage UPDATE")

-- storeForBook upserts 12 columns, with provider still at position 6.
calls = {}
assert(cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system"))
assert(calls[1].stmt.bind_count == 12)
assert(calls[1].stmt.binds[6] == "system")
assert(calls[1].sql:find("ON CONFLICT(book_path, source_lang, target_lang, provider, source_text, selector)", 1, true),
    "store must upsert on the v3 key")
assert(calls[1].sql:find("DO UPDATE SET", 1, true), "store must not INSERT OR REPLACE")
assert(calls[1].stmt.binds[8] == "", "selector defaults to the empty string")

-- Optional meta keeps the old 6-argument call shape and fills the locator columns.
calls = {}
assert(cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system",
    { selector = "p:nth-of-type(2)", xpointer = "/body/p[2]", chapter_index = 3, model_name = "gpt-5" }))
assert(calls[1].stmt.bind_count == 12)
assert(calls[1].stmt.binds[6] == "system")
assert(calls[1].stmt.binds[7] == "gpt-5")
assert(calls[1].stmt.binds[8] == "p:nth-of-type(2)")
assert(calls[1].stmt.binds[9] == "/body/p[2]")
assert(calls[1].stmt.binds[10] == 3)

-- A cache hit adds a locator row without rewriting an existing one.
calls = {}
assert(cache:insertLocationRow("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system",
    { selector = "p:nth-of-type(3)" }))
assert(#calls == 1)
assert(calls[1].sql:find("DO NOTHING", 1, true), "locator rows must not overwrite")
assert(calls[1].stmt.binds[6] == "system" and calls[1].stmt.binds[8] == "p:nth-of-type(3)")

print("PASS: cache provider isolation")
