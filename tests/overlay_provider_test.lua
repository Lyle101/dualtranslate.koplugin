-- P0 regression: overlay resume must be provider-aware, but a v1.2.11
-- overlay without a provider field must still be reusable once.
--
-- Run: luajit tests/overlay_provider_test.lua
local TEST_DIR = "/tmp/dualtranslate_overlay_provider_test"
local DATA_DIR = "/tmp/dualtranslate_overlay_provider_data"
os.execute("rm -rf " .. TEST_DIR .. " " .. DATA_DIR)
os.execute("mkdir -p " .. TEST_DIR .. "/META-INF " .. TEST_DIR .. "/OEBPS")

local function write(path, content)
    local file = assert(io.open(TEST_DIR .. "/" .. path, "w"))
    file:write(content)
    file:close()
end

write("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]])
write("OEBPS/content.opf", [[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest>
    <item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>]])
write("OEBPS/chap1.xhtml", [[<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Hello world.</p></body></html>]])

local saved_data
local previous_overlay

package.preload["ffi/archiver"] = function() return {} end
package.preload["datastorage"] = function()
    return { getDataDir = function() return DATA_DIR end }
end
package.preload["socket.url"] = function()
    return { escape = function(s) return s end, unescape = function(s) return s end }
end
package.preload["dualtranslate_tools"] = function()
    return {
        mkdir_p = function(path) os.execute('mkdir -p "' .. path .. '"') return true end,
        unzip_to = function(_, dest)
            os.execute('rm -rf "' .. dest .. '" && mkdir -p "' .. dest .. '"')
            os.execute('cp -r "' .. TEST_DIR .. '/." "' .. dest .. '/"')
            return true
        end,
        rmtree = function(path) os.execute('rm -rf "' .. path .. '"') return true end,
        stable_path_hash = function() return "bookhash" end,
    }
end
package.preload["dualtranslate_overlay"] = function()
    return {
        load = function() return previous_overlay end,
        save = function(_, data) saved_data = data return true end,
        exists = function() return previous_overlay ~= nil end,
    }
end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Epub = dofile(script_dir .. "/../dualtranslate_epub.lua")

local function run(provider, previous)
    previous_overlay = previous
    saved_data = nil
    local batch_calls = 0
    local output_dir = DATA_DIR .. "/out_" .. tostring(provider) .. "_" .. tostring(previous and previous.provider or "none")
    os.execute('rm -rf "' .. output_dir .. '"')
    local result, err = Epub:translate_overlay(
        "/books/test.epub", "1", "zh-Hans", "auto",
        function(text) return "single:" .. text end,
        true,
        "/tmp/dt_overlay_provider_progress.txt",
        function(texts)
            batch_calls = batch_calls + 1
            local out = {}
            for index, text in ipairs(texts) do out[index] = "batch:" .. text end
            return out
        end,
        output_dir,
        nil,
        nil,
        provider
    )
    assert(result, tostring(err))
    return result, batch_calls
end

-- 1. First run: no previous overlay, provider system.
local first, first_batches = run("system", nil)
assert(first_batches == 1, "first run should call the batch provider")
assert(saved_data and saved_data.provider == "system", "checkpoint must record provider")
assert(saved_data.entries and #saved_data.entries == 1, "checkpoint must contain one entry")
local first_checkpoint = saved_data

-- 2. Same provider: previous checkpoint must be reused, no network call.
local second, second_batches = run("system", first_checkpoint)
assert(second_batches == 0, "same provider must reuse previous entries")
assert(saved_data.provider == "system", "reused checkpoint keeps provider")

-- 3. Different provider: previous entries must not be reused.
local third, third_batches = run("microsoft_free", first_checkpoint)
assert(third_batches == 1, "different provider must not reuse previous entries")
assert(saved_data.provider == "microsoft_free", "new checkpoint records new provider")

-- 4. Legacy v1.2.11 overlay without provider: accept once, stamp current.
local legacy = {
    book_path = "/books/test.epub",
    source_lang = "auto",
    target_lang = "zh-Hans",
    entries = first_checkpoint.entries,
    chapters = first_checkpoint.chapters,
}
local fourth, fourth_batches = run("system", legacy)
assert(fourth_batches == 0, "legacy overlay should be reusable once")
assert(saved_data.provider == "system", "legacy overlay must be stamped with current provider")

-- 5. A provider switch whose requests all fail must not overwrite the old
-- overlay with an empty checkpoint.
previous_overlay = first_checkpoint
saved_data = nil
local failed_ok, failed_err = Epub:translate_overlay(
    "/books/test.epub", "1", "zh-Hans", "auto",
    function() return nil, { message = "offline" } end,
    true,
    "/tmp/dt_overlay_provider_failed_progress.txt",
    function() return { false } end,
    DATA_DIR .. "/out_failed",
    nil,
    nil,
    "microsoft_free"
)
assert(not failed_ok and failed_err, "all-failed run should return an error")
assert(saved_data == nil, "all-failed provider switch must not write an empty checkpoint")

-- 6. Missing provider is rejected before doing any work.
local missing_ok, missing_err = Epub:translate_overlay(
    "/books/test.epub", "1", "zh-Hans", "auto",
    function(text) return text end, true, "/tmp/p.txt",
    function(texts) return texts end, "/tmp/out_missing", nil, nil, nil)
assert(not missing_ok and missing_err and missing_err:find("翻译服务") ~= nil,
    "missing provider must be rejected")

os.execute("rm -rf " .. TEST_DIR .. " " .. DATA_DIR)
print("PASS: overlay provider resume")
