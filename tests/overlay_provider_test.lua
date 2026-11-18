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
        loadManifest = function() return nil end,
        loadEntries = function() return nil end,
        exists = function() return previous_overlay ~= nil end,
        -- v3 checkpoint shape: entries first, manifest second.  The recorded
        -- saved_data keeps the P0 assertion shape (provider/entries/chapters
        -- plus the book identity the legacy-reuse guard checks).
        saveEntries = function(_, provider, doc)
            saved_data = { provider = provider, entries = doc.entries }
            return true
        end,
        saveManifest = function(_, manifest)
            if saved_data then
                saved_data.book_path = manifest.book_path
                saved_data.source_lang = manifest.source_lang
                saved_data.target_lang = manifest.target_lang
                local state = manifest.providers[saved_data.provider]
                saved_data.chapters = state and state.chapters
                saved_data.complete = state and state.complete
            end
            return true
        end,
        -- 3.2.0: checkpoint 合并后按「归属元素」去重；样例无重复形态
        dedupeEntries = function(entries) return entries end,
    }
end
package.preload["dualtranslate_lock"] = function()
    return { withBookLock = function(_, fn) return fn() end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Epub = dofile(script_dir .. "/../dualtranslate_epub.lua")

local function run(provider, previous)
    previous_overlay = previous
    saved_data = nil
    local batch_calls = 0
    local output_dir = DATA_DIR .. "/out_" .. tostring(provider) .. "_" .. tostring(previous and previous.provider or "none")
    os.execute('rm -rf "' .. output_dir .. '"')
    local result, err = Epub:translate_overlay({
        book_path = "/books/test.epub", mode = "all", fragment = "1",
        source_lang = "auto", target_lang = "zh-Hans", provider = provider,
        progress_path = "/tmp/dt_overlay_provider_progress.txt",
        output_dir = output_dir,
        translate = function(text) return "single:" .. text end,
        translate_batch = function(texts)
            batch_calls = batch_calls + 1
            local out = {}
            for index, text in ipairs(texts) do out[index] = "batch:" .. text end
            return out
        end,
    })
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
local failed_ok, failed_err = Epub:translate_overlay({
    book_path = "/books/test.epub", mode = "all", fragment = "1",
    source_lang = "auto", target_lang = "zh-Hans", provider = "microsoft_free",
    progress_path = "/tmp/dt_overlay_provider_failed_progress.txt",
    output_dir = DATA_DIR .. "/out_failed",
    translate = function() return nil, { message = "offline" } end,
    translate_batch = function() return { false } end,
})
assert(not failed_ok and failed_err, "all-failed run should return an error")
assert(saved_data == nil, "all-failed provider switch must not write an empty checkpoint")

-- 6. Missing provider is rejected before doing any work.
local missing_ok, missing_err = Epub:translate_overlay({
    book_path = "/books/test.epub", mode = "all", fragment = "1",
    source_lang = "auto", target_lang = "zh-Hans",
    progress_path = "/tmp/p.txt", output_dir = "/tmp/out_missing",
    translate = function(text) return text end,
    translate_batch = function(texts) return texts end,
})
assert(not missing_ok and missing_err and missing_err:find("翻译服务") ~= nil,
    "missing provider must be rejected")

os.execute("rm -rf " .. TEST_DIR .. " " .. DATA_DIR)
print("PASS: overlay provider resume")
