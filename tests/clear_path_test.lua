-- P0 regression: "clear this book" must pass the EPUB path, not the cache
-- directory, to Cache:clearForBook.
--
-- Run: luajit tests/clear_path_test.lua
local DATA_DIR = "/tmp/dualtranslate_clear_path_test"
os.execute("rm -rf " .. DATA_DIR .. " && mkdir -p " .. DATA_DIR)

local stubs = {
    ["logger"] = { warn = function() end, err = function() end, info = function() end },
    ["gettext"] = function(text) return text end,
    ["datastorage"] = { getDataDir = function() return DATA_DIR end },
    ["util"] = {
        makePath = function(path) os.execute('mkdir -p "' .. path .. '"') return true end,
        trim = function(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end,
    },
    ["ffi/util"] = { template = function(text) return text end,
        sleep = function() end, usleep = function() end,
        getTimestamp = function() return os.time() end },
    ["ffi/archiver"] = {},
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } },
    ["libs/libkoreader-lfs"] = {
        attributes = function() return nil end,
        dir = function() return function() return nil end end,
        rmdir = function() return true end,
        remove = function() return true end,
    },
    ["json"] = { encode = function() return "{}" end, decode = function() return nil end },
    ["socket.http"] = {}, ["ltn12"] = {}, ["socketutil"] = {},
    ["socket.url"] = { escape = function(s) return s end, unescape = function(s) return s end },
    ["lua-ljsqlite3/init"] = {},
    ["ui/uimanager"] = { show = function() end, close = function() end, setDirty = function() end,
        scheduleIn = function() end, nextTick = function() end },
    ["ui/widget/notification"] = { new = function() return {} end },
    ["ui/widget/buttondialog"] = {}, ["ui/widget/progressbardialog"] = {},
    ["ui/widget/inputdialog"] = {}, ["ui/widget/spinwidget"] = {},
    ["ui/trapper"] = {}, ["ui/event"] = { new = function() return {} end },
    ["document/credocument"] = { engineInit = function() return {} end },
    ["fontlist"] = {}, ["ui/translator"] = {},
    ["dualtranslate_tools"] = {
        stable_path_hash = function(value)
            local hash = 7
            for index = 1, #value do hash = (hash * 131 + value:byte(index)) % 2147483647 end
            return string.format("%08x", hash)
        end,
        mkdir_p = function(path) os.execute('mkdir -p "' .. path .. '"') return true end,
        rmtree = function(path) os.execute('rm -rf "' .. path .. '"') return true end,
    },
    ["dualtranslate_overlay"] = {
        load = function(path)
            local file = io.open(path, "rb")
            if not file then return nil end
            file:close()
            if path:find("/cache/dualtranslate/books/") then
                return { book_path = "/books/pride.epub" }
            end
            return nil
        end,
        loadManifest = function() return nil end,
        exists = function() return true end,
        buildCss = function() return "" end,
    },
}
for name, value in pairs(stubs) do
    package.preload[name] = function() return value end
end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
package.path = script_dir .. "/../?.lua;" .. package.path

local Reader = require("dualtranslate_reader")

local cleared_books = {}
local plugin = {
    getSetting = function(_, _, default) return default end,
    getTargetLang = function() return "zh-Hans" end,
    getSourceLang = function() return "auto" end,
    getMode = function() return "system" end,
    cache = {
        clearForBook = function(_, path) cleared_books[#cleared_books + 1] = path end,
    },
}
Reader.attach(plugin)

local book = "/books/pride.epub"
local cache_dir = plugin:getBookCacheDirectory(book)
os.execute('mkdir -p "' .. cache_dir .. '"')
local file = assert(io.open(cache_dir .. "/overlay.json", "w"))
file:write('{"book_path":"/books/pride.epub","entries":[]}')
file:close()

local removed, second = plugin:clearBookTranslationData(book)
assert(removed == 1, "expected one overlay removed, got " .. tostring(removed))
assert(second == nil, "clearBookTranslationData must not return a path")
assert(io.open(cache_dir .. "/overlay.json", "rb") == nil, "overlay must be removed")
assert(#cleared_books == 1, "clearForBook must be called exactly once")
assert(cleared_books[1] == book,
    "clearForBook must receive the book path, got " .. tostring(cleared_books[1]))
assert(cleared_books[1] ~= cache_dir, "clearForBook must not receive the cache directory")

local removed_again, second_again = plugin:removeTranslationFilesForBook(book)
assert(removed_again == 0, "second clear should find no overlay")
assert(second_again == nil, "removeTranslationFilesForBook must not return a path")

os.execute("rm -rf " .. DATA_DIR)
print("PASS: clear book path")
