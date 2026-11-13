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
        return function(self, ...) self.binds = { ... } return self end
    elseif key == "step" then
        return function(self)
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

-- No provider: must be a cache miss without touching SQLite.
assert(cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello") == nil)
assert(#calls == 0, "missing provider must not issue a query")

-- system hit, and the usage update must also be scoped to system.
local hit = cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "system")
assert(hit and hit.translated_text == "系统译文" and hit.provider == "system")
assert(calls[1].sql:find("provider = ?", 1, true), "lookup SQL must filter provider")
assert(#calls[1].stmt.binds == 5 and calls[1].stmt.binds[5] == "system")
assert(calls[2].sql:find("UPDATE book_translations", 1, true))
assert(calls[2].sql:find("provider = ?", 1, true), "usage update SQL must filter provider")
assert(#calls[2].stmt.binds == 6 and calls[2].stmt.binds[6] == "system")

-- A different provider must miss even though the fake DB has a system row.
calls = {}
local miss = cache:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello", "microsoft_free")
assert(miss == nil, "microsoft_free must not read a system row")
assert(#calls == 1, "a miss must not run the usage UPDATE")

-- storeForBook still writes 8 columns, with provider at position 6.
calls = {}
assert(cache:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system"))
assert(#calls[1].stmt.binds == 8)
assert(calls[1].stmt.binds[6] == "system")

print("PASS: cache provider isolation")
