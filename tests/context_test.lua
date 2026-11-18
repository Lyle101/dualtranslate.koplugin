-- ============================================================
-- P1-c 7.3 context passthrough:
--   Epub -> translate/translate_batch context contract
--   Reader cache meta / hit insertLocationRow / split stores once
-- Run: luajit tests/context_test.lua
-- ============================================================
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

-- ============================================================
-- 1. Epub builds context per candidate and threads it through
-- ============================================================
print("== 1. Epub context contract ==")
do
    local TEST_DIR = "/tmp/dt_context_epub"
    local DATA_DIR = "/tmp/dt_context_data"
    os.execute("rm -rf " .. TEST_DIR .. " " .. DATA_DIR)
    os.execute("mkdir -p " .. TEST_DIR .. "/META-INF " .. TEST_DIR .. "/OEBPS")
    local function write(p, c)
        local f = assert(io.open(TEST_DIR .. "/" .. p, "w")); f:write(c); f:close()
    end
    write("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]])
    write("OEBPS/content.opf", [[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest><item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="c1"/></spine>
</package>]])
    write("OEBPS/chap1.xhtml", [[<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>First para.</p><p>Second para.</p></body></html>]])

    local saved_entries, saved_manifest
    package.preload["ffi/archiver"] = function() return {} end
    package.preload["datastorage"] = function()
        return { getDataDir = function() return DATA_DIR end }
    end
    package.preload["socket.url"] = function()
        return { escape = function(s) return s end, unescape = function(s) return s end }
    end
    package.preload["dualtranslate_tools"] = function()
        return {
            mkdir_p = function(p) os.execute('mkdir -p "' .. p .. '"') return true end,
            unzip_to = function(_, dest)
                os.execute('rm -rf "' .. dest .. '" && mkdir -p "' .. dest .. '"')
                os.execute('cp -r "' .. TEST_DIR .. '/." "' .. dest .. '/"')
                return true
            end,
            rmtree = function(p) os.execute('rm -rf "' .. p .. '"') return true end,
            stable_path_hash = function() return "ctxhash" end,
            -- Reader:splitTranslationText delegates chunking to Tools (P3);
            -- this module stays loaded for section 2d.
            split_text = function(text, limit)
                if #text <= limit then return { text } end
                local chunks, rest = {}, text
                while #rest > limit do
                    chunks[#chunks + 1] = rest:sub(1, limit)
                    rest = rest:sub(limit + 1)
                end
                if rest ~= "" then chunks[#chunks + 1] = rest end
                return chunks
            end,
        }
    end
    package.preload["dualtranslate_overlay"] = function()
        return {
            load = function() return nil end,
            loadManifest = function() return nil end,
            loadEntries = function() return nil end,
            exists = function() return false end,
            saveEntries = function(_, pid, doc) saved_entries = doc.entries return true end,
            saveManifest = function(_, m) saved_manifest = m return true end,
            -- 3.2.0: checkpoint 去重后计数；样例无重复形态，桩原样返回
            dedupeEntries = function(entries) return entries end,
        }
    end
    package.preload["dualtranslate_lock"] = function()
        return { withBookLock = function(_, fn) return fn() end }
    end
    package.preload["libs/libkoreader-lfs"] = function()
        return { attributes = function() return nil end }
    end
    local Epub = dofile("dualtranslate_epub.lua")

    -- batch success: contexts array must align with sources
    local batch_contexts, single_calls
    local out_dir = DATA_DIR .. "/out_batch"
    local result, err = Epub:translate_overlay({
        book_path = "/books/ctx.epub", mode = "all", fragment = "1",
        source_lang = "auto", target_lang = "zh-Hans", provider = "system",
        progress_path = "/tmp/dt_ctx_prog.txt", output_dir = out_dir,
        translate = function(text, context)
            single_calls = single_calls or {}
            single_calls[#single_calls + 1] = { text = text, context = context }
            return "S:" .. text
        end,
        translate_batch = function(texts, contexts)
            batch_contexts = contexts
            local out = {}
            for i, t in ipairs(texts) do out[i] = "B:" .. t end
            return out
        end,
    })
    check("batch run ok", result ~= nil, tostring(err))
    check("batch contexts aligned", batch_contexts and #batch_contexts == 2)
    check("context selector", batch_contexts and batch_contexts[1]
        and batch_contexts[1].selector:find("p:nth%-of%-type%(1%)") ~= nil,
        batch_contexts and batch_contexts[1] and batch_contexts[1].selector)
    check("context xpointer", batch_contexts and batch_contexts[1]
        and batch_contexts[1].xpointer == "/body/DocFragment/body/p")
    check("context chapter_index", batch_contexts and batch_contexts[1]
        and batch_contexts[1].chapter_index == 1)
    check("entries carry chapter_index", saved_entries and saved_entries[1]
        and saved_entries[1].chapter_index == 1)
    check("manifest provider recorded", saved_manifest
        and saved_manifest.providers.system ~= nil)

    -- batch failure -> single fallback still receives context
    batch_contexts, single_calls = nil, nil
    local out_dir2 = DATA_DIR .. "/out_single"
    local result2, err2 = Epub:translate_overlay({
        book_path = "/books/ctx.epub", mode = "all", fragment = "1",
        source_lang = "auto", target_lang = "zh-Hans", provider = "system",
        progress_path = "/tmp/dt_ctx_prog2.txt", output_dir = out_dir2,
        translate = function(text, context)
            single_calls = single_calls or {}
            single_calls[#single_calls + 1] = { text = text, context = context }
            return "S:" .. text
        end,
        translate_batch = function() return nil, { message = "batch down" } end,
    })
    check("single fallback run ok", result2 ~= nil, tostring(err2))
    check("single fallback got contexts", single_calls and #single_calls == 2
        and single_calls[1].context and single_calls[1].context.chapter_index == 1
        and single_calls[2].context.selector:find("nth%-of%-type%(2%)") ~= nil)
    os.execute("rm -rf " .. TEST_DIR .. " " .. DATA_DIR)
end

-- ============================================================
-- 2. Reader cache meta / hit locator / split-once / batch meta
-- ============================================================
print("== 2. Reader context cache contract ==")
do
    local warns = {}
    local stubs = {
        ["logger"] = { warn = function(...) warns[#warns + 1] = table.concat({ ... }, " ") end,
            err = function() end, info = function() end },
        ["gettext"] = function(s) return s end,
        ["datastorage"] = { getDataDir = function() return "/tmp/dt_ctx_reader" end },
        ["util"] = { makePath = function() return true end,
            trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
        ["ffi/util"] = { template = function(s) return s end },
        ["ffi/archiver"] = {},
        ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } },
        ["libs/libkoreader-lfs"] = { attributes = function() return nil end,
            dir = function() return function() return nil end end },
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
        ["dualtranslate_tools"] = { stable_path_hash = function() return "x" end,
            mkdir_p = function() return true end, rmtree = function() return true end,
            -- The reader delegates chunking to Tools (P3); a simple byte split
            -- is enough for the "long text" fixture in section 2d.
            split_text = function(text, limit)
                if #text <= limit then return { text } end
                local chunks, rest = {}, text
                while #rest > limit do
                    chunks[#chunks + 1] = rest:sub(1, limit)
                    rest = rest:sub(limit + 1)
                end
                if rest ~= "" then chunks[#chunks + 1] = rest end
                return chunks
            end },
        ["dualtranslate_providers"] = {
            list = {}, getProviderName = function() return "x" end,
            translate = function(_, text) return { translated_text = "T:" .. text } end,
            -- Batch capability is advertised per engine now, so the stub has to
            -- answer has_batch/batch_limits/split_groups as the real module does.
            has_batch = function(id) return id == "microsoft_free" end,
            batch_limits = function() return { items = 12, bytes = 4000 } end,
            split_groups = function(texts)
                local groups, current = {}, {}
                for index = 1, #texts do
                    current[#current + 1] = index
                    if #current >= 12 then
                        groups[#groups + 1], current = current, {}
                    end
                end
                if #current > 0 then groups[#groups + 1] = current end
                return groups
            end,
            translate_batch = function(_, texts)
                local out = {}
                for i, t in ipairs(texts) do out[i] = "B:" .. t end
                return out
            end,
        },
    }
    for k, v in pairs(stubs) do package.preload[k] = function() return v end end
    local Reader = dofile("dualtranslate_reader.lua")

    local stores, locators, lookups = {}, {}, {}
    local hit_text
    local plugin = {
        getSetting = function(_, _, default) return default end,
        getMode = function() return "system" end,
        getSourceLang = function() return "auto" end,
        getTargetLang = function() return "zh-Hans" end,
        isCacheEnabled = function() return true end,
        getTranslationChunkLimit = function() return 20 end,
        _active_translation_book = "/books/ctx.epub",
        cache = {
            lookupForBook = function(_, book, sl, tl, text, mode)
                lookups[#lookups + 1] = text
                if hit_text and text == hit_text then return { translated_text = "HIT:" .. text } end
                return nil
            end,
            storeForBook = function(_, book, sl, tl, source, translated, mode, meta)
                stores[#stores + 1] = { source = source, translated = translated, meta = meta }
            end,
            insertLocationRow = function(_, book, sl, tl, source, translated, mode, meta)
                locators[#locators + 1] = { source = source, meta = meta }
            end,
        },
    }
    Reader.attach(plugin)

    -- 2a. miss stores meta from context
    local ctx = { selector = "s[1]", xpointer = "/x", chapter_index = 3 }
    local translated, err = plugin:translateTextForEpub("hello", ctx)
    check("miss translated", translated == "T:hello", tostring(err))
    check("miss stored once with meta", #stores == 1 and stores[1].meta
        and stores[1].meta.selector == "s[1]" and stores[1].meta.chapter_index == 3)

    -- 2b. hit records locator row, no provider call / no store
    stores, locators = {}, {}
    hit_text = "cached"
    local hit, hit_err = plugin:translateTextForEpub("cached", ctx)
    check("hit returns cached", hit == "HIT:cached", tostring(hit_err))
    check("hit inserts location row", #locators == 1 and locators[1].meta
        and locators[1].meta.selector == "s[1]")
    check("hit does not store", #stores == 0)
    hit_text = nil

    -- 2c. no-context compat: stores with nil meta, warns once
    stores, warns = {}, {}
    plugin:translateTextForEpub("noctx1")
    plugin:translateTextForEpub("noctx2")
    check("no-context stores nil meta", #stores == 2 and stores[1].meta == nil)
    check("no-context warns once", #warns == 1, tostring(#warns))

    -- 2d. long text splits: chunks skip_store, parent stored once with meta
    stores, locators = {}, {}
    local long = string.rep("word ", 12) -- > 20 bytes, several chunks
    local combined, cerr = plugin:translateTextForEpub(long, ctx)
    check("split translated", combined ~= nil, tostring(cerr))
    check("split stores parent exactly once", #stores == 1 and stores[1].source == long
        and stores[1].meta and stores[1].meta.selector == "s[1]",
        "stores=" .. tostring(#stores))

    -- 2e. batch threads contexts; hit inserts locator; miss stores meta
    plugin.getMode = function() return "microsoft_free" end
    stores, locators = {}, {}
    local ctxs = { { selector = "b[1]", chapter_index = 1 }, { selector = "b[2]", chapter_index = 1 } }
    local results, berr = plugin:translateTextBatchForEpub({ "aa", "bb" }, ctxs)
    check("batch results", results and results[1] == "B:aa" and results[2] == "B:bb", tostring(berr))
    check("batch stores per-item meta", #stores == 2 and stores[1].meta.selector == "b[1]"
        and stores[2].meta.selector == "b[2]")
    stores, locators = {}, {}
    hit_text = "aa"
    plugin:translateTextBatchForEpub({ "aa", "bb" }, ctxs)
    check("batch hit inserts locator", #locators == 1 and locators[1].meta.selector == "b[1]")
    check("batch hit stores only miss", #stores == 1 and stores[1].source == "bb")
    hit_text = nil

    -- 2f. 没有批量端点的引擎（system）不在包装层串行循环：直接回 nil，让
    -- translate_overlay 的逐段路径去翻、去数连续失败。否则 48 段 × 5 s 会把
    -- 界面卡在 0% 四分钟，引擎降级永远看不到第一次失败。
    plugin.getMode = function() return "system" end
    stores = {}
    -- Wrap the per-paragraph path so "did the wrapper translate anything"
    -- is measured directly, not inferred from the absence of DB writes.
    local single_calls = 0
    local real_single = plugin.translateTextForEpub
    plugin.translateTextForEpub = function(first, ...)
        single_calls = single_calls + 1
        return real_single(first, ...)
    end
    local r2, b2 = plugin:translateTextBatchForEpub({ "cc" }, { { selector = "c[1]", chapter_index = 2 } })
    plugin.translateTextForEpub = real_single
    -- 也不返回错误串：translate_overlay 只保留第一个错误，这里编一条
    -- 「该引擎不支持批量翻译」会盖掉真正的逐段失败（超时 / 429）。
    check("无批量端点回 nil 且不伪造错误", r2 == nil and b2 == nil, tostring(b2))
    check("包装层没有偷偷逐段翻译", single_calls == 0, tostring(single_calls))
    check("也没有写库", #stores == 0, tostring(#stores))
end

print(string.format("\n==== context 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)