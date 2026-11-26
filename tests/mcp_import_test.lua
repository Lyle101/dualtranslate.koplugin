-- ============================================================
-- P3-b：MCP 收件箱导入（真实 SQLite + 真实文件）
-- 校验 / 长段 part 拼回 / DB+entries+manifest 双写 / reload.signal /
-- 幂等 / 模型未确认不显示 / 书文件变化拒绝 / inbox → job 目录归档
-- Run: luajit tests/mcp_import_test.lua
-- 依赖 KOReader 自带 lfs / json / lua-ljsqlite3（KO_ROOT 可覆盖）；缺失跳过。
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

local ROOT = "/tmp/dt_mcp_import_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local data_dir = ROOT .. "/data"
package.preload["datastorage"] = function()
    return { getDataDir = function() return data_dir end }
end
package.preload["logger"] = function()
    return { warn = function() end, err = function() end,
        info = function() end, dbg = function() end }
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
    end, trim = function(value)
        return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end, sleep = function() end, usleep = function() end,
        getTimestamp = function() return os.time() end }
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
local Tools = dofile(script_dir .. "/../dualtranslate_tools.lua")
package.loaded["dualtranslate_store"] = Store
package.loaded["dualtranslate_overlay"] = Overlay
package.loaded["dualtranslate_tools"] = Tools
local Mcp = dofile(script_dir .. "/../dualtranslate_mcp.lua")

Tools.mkdir_p(data_dir)
local cache = Cache:new()
Store.setCache(cache)
check("cache 打开", cache:open() ~= nil)

local BOOK = ROOT .. "/books/import.epub"
os.execute('mkdir -p "' .. ROOT .. '/books"')
local book_file = io.open(BOOK, "wb")
book_file:write(string.rep("x", 4096))
book_file:close()
local book_size = lfs.attributes(BOOK, "size")
local book_mtime = lfs.attributes(BOOK, "modification") or 0

local JOB_ID = "20261115_120000_0001"
local job_dir = Mcp.jobDir(JOB_ID)
Tools.mkdir_p(job_dir)

local function writeJson(path, value)
    local file = io.open(path, "wb")
    file:write(JSON.encode(value))
    file:close()
end

local job = {
    schema = "dualtranslate.job.v1",
    job_id = JOB_ID,
    created_at = os.time(),
    book = {
        device_path = BOOK, title = "Import Test", source_lang = "en",
        target_lang = "zh-Hans", spine_count = 5,
        file_size = book_size, file_mtime = book_mtime,
    },
    chapters = { { index = 1, title = "One" }, { index = 2, title = "Two" } },
    segments = {
        { id = "s000001", parent_id = "s000001", part = 1, parent_total = 2,
          chapter_index = 1, chapter_title = "One", selector = "sel-a",
          xpointer = "/body/DocFragment/body/p[1]", source = "Part one",
          list_indent = "2.2em" },
        { id = "s000002", parent_id = "s000001", part = 2, parent_total = 2,
          chapter_index = 1, chapter_title = "One", selector = "sel-a",
          xpointer = "/body/DocFragment/body/p[1]", source = "part two",
          list_indent = "2.2em" },
        { id = "s000003", parent_id = "s000003", part = 1, parent_total = 1,
          chapter_index = 2, chapter_title = "Two", selector = "sel-b",
          xpointer = "/body/DocFragment/body/p[2]", source = "Second chapter" },
    },
    options = { max_chars_per_segment = 4500, split_long_segments = true },
}
writeJson(job_dir .. "/job.json", job)

local function make_result(translations, provider_overrides)
    local provider = {
        provider_id = "mcp:gpt-5", kind = "mcp", model_name = "gpt-5",
        display_name = "MCP · GPT-5", confirmed = true,
    }
    for key, value in pairs(provider_overrides or {}) do provider[key] = value end
    return {
        schema = "dualtranslate.result.v1",
        job_id = JOB_ID,
        provider = provider,
        translations = translations,
    }
end

local function db_rows(provider_id)
    local rows = cache:_queryAll([[SELECT source_text, translated_text, selector
        FROM book_translations WHERE book_path = ? AND provider = ?]],
        BOOK, provider_id or "mcp:gpt-5")
    return rows
end

local function load_manifest()
    return Overlay.loadManifest(Store.bookDir(BOOK, "zh-Hans"))
end

-- ============================================================
print("== 1. 部分结果默认拒绝 ==")
do
    local result = make_result({
        { id = "s000001", text = "第一段" },
        { id = "s000003", text = "第二章" },
    })
    local summary, err = Store.importResult(job, result)
    check("缺 part 拒绝", summary == nil and tostring(err):find("尚未翻译完成") ~= nil, tostring(err))
    check("拒绝时不落库", #db_rows() == 0)
    check("拒绝时不写 manifest", load_manifest() == nil)
end

-- ============================================================
print("== 2. 完整结果导入 ==")
do
    local result = make_result({
        { id = "s000001", text = "第一段上" },
        { id = "s000002", text = "第一段下" },
        { id = "s000003", text = "第二章译文" },
    })
    local summary, err = Store.importResult(job, result, { set_display = true })
    check("导入成功", summary ~= nil, tostring(err))
    check("统计 submitted", summary and summary.submitted == 3)
    check("统计 accepted(parent)", summary and summary.accepted == 2)
    check("DB 两条 parent 行", #db_rows() == 2)
    local rows = db_rows()
    local by_source = {}
    for _, row in ipairs(rows) do by_source[row[1]] = row[2] end
    check("长段按空格拼回原文", by_source["Part one part two"] ~= nil)
    check("长段按空格拼回译文", by_source["Part one part two"] == "第一段上 第一段下")
    check("短段原文/译文", by_source["Second chapter"] == "第二章译文")

    local entries = Overlay.loadEntries(Store.bookDir(BOOK, "zh-Hans"), "mcp:gpt-5")
    check("entries 两条 selector", entries and #entries.entries == 2)
    check("entries 保留 selector", entries and entries.entries[1].selector == "sel-a")
    -- 列表父项的缩进跟着 segment 走，渲染 CSS 时才能算出正确的负 margin
    local indent_entries = {}
    for _, entry in ipairs(entries and entries.entries or {}) do
        indent_entries[entry.selector] = entry.list_indent
    end
    check("导入保留 list_indent", indent_entries["sel-a"] == "2.2em",
        tostring(indent_entries["sel-a"]))
    check("无缩进的条目不加字段", indent_entries["sel-b"] == nil,
        tostring(indent_entries["sel-b"]))

    local manifest = load_manifest()
    check("manifest 存在", manifest ~= nil)
    local provider = manifest and manifest.providers["mcp:gpt-5"]
    check("provider 元数据来自 DB", provider and provider.display_name == "MCP · GPT-5"
        and provider.model_name == "gpt-5" and provider.confirmed == true)
    check("章节 1、2 完成", provider and #provider.chapters == 2
        and provider.chapters[1] == 1 and provider.chapters[2] == 2)
    check("spine_count=5 未完成", provider and provider.complete == false)
    check("translated_count 按 selector", provider and provider.translated_count == 2)
    check("set_display 生效", manifest and manifest.display_mode == "manual"
        and manifest.display_provider == "mcp:gpt-5")

    local signal = Overlay.loadSignal(Store.bookDir(BOOK, "zh-Hans"))
    -- seq is max(revision, previous)+1 so it stays monotonic across deletes; it
    -- is never smaller than the manifest revision it describes.
    check("reload.signal seq ≥ revision", signal and signal.seq >= manifest.revision)
    check("reload.signal op=import", signal and signal.op == "import"
        and signal.provider == "mcp:gpt-5" and signal.count == 2)

    local provider_row = cache:getProvider("mcp:gpt-5")
    check("providers 表写入", provider_row and provider_row.model_name == "gpt-5")

    -- 3.2.2: import prewarms css-template.css.  Simulate the next process:
    -- clear all in-memory caches and build again; it must use the template
    -- without decoding entries.
    local cache_dir = Store.bookDir(BOOK, "zh-Hans")
    Overlay.clearCssCache()
    Overlay.clearEntriesCache()
    Overlay.clearTemplateCache()
    if Overlay.clearRevisionCache then Overlay.clearRevisionCache() end
    local before_stats = Overlay.cacheStats()
    local imported_css = Overlay.buildCss(cache_dir, { translation_visible = true })
    local after_stats = Overlay.cacheStats()
    check("导入后冷构建命中模板且不解码",
        after_stats.entries_loads == before_stats.entries_loads
        and after_stats.template_hits == before_stats.template_hits + 1,
        string.format("loads %d→%d hits %d→%d",
            before_stats.entries_loads, after_stats.entries_loads,
            before_stats.template_hits, after_stats.template_hits))
    check("模板含导入译文", imported_css:find("第二章译文", 1, true) ~= nil)
end

-- ============================================================
print("== 2b. 范围任务只标 partial ==")
do
    local ranged_book = ROOT .. "/books/ranged.epub"
    local handle = io.open(ranged_book, "wb")
    handle:write(string.rep("y", 2048))
    handle:close()
    -- 同一本书只导出了第一章的一个范围：导入后不能把第一章算成整章完成
    local ranged_job = {
        schema = "dualtranslate.job.v1",
        job_id = "20261115_120000_0002",
        created_at = os.time(),
        book = {
            device_path = ranged_book, title = "Ranged", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 5,
            file_size = lfs.attributes(ranged_book, "size"),
            file_mtime = lfs.attributes(ranged_book, "modification") or 0,
        },
        chapters = { { index = 1, title = "One", partial = true,
            ranges = { { from = "p1", to = "p2" } } } },
        segments = {
            { id = "s000001", parent_id = "s000001", part = 1, parent_total = 1,
              chapter_index = 1, chapter_title = "One", selector = "sel-ranged",
              xpointer = "/body/DocFragment/body/p[1]", source = "Ranged paragraph" },
        },
        options = { max_chars_per_segment = 4500, split_long_segments = true },
    }
    local result = make_result({ { id = "s000001", text = "范围段落" } })
    result.job_id = ranged_job.job_id
    local summary, err = Store.importResult(ranged_job, result)
    check("范围任务导入成功", summary ~= nil, tostring(err))
    local manifest = Overlay.loadManifest(Store.bookDir(ranged_book, "zh-Hans"))
    local provider = manifest and manifest.providers["mcp:gpt-5"]
    check("范围任务落 partial_chapters",
        provider and provider.partial_chapters and provider.partial_chapters[1] == 1
        and #(provider.chapters or {}) == 0,
        provider and ("done=" .. #(provider.chapters or {})
            .. " partial=" .. #(provider.partial_chapters or {})))
    check("范围任务不算整本完成", provider and provider.complete == false)
    -- 任务里带的锚点范围落进覆盖表：选择器只给这一条打「已翻译」，
    -- 而不是给同文件的每条都打「部分」。
    local entry_rows = provider and provider.entry_ranges and provider.entry_ranges["1"]
    check("范围任务记录条目覆盖", type(entry_rows) == "table" and #entry_rows == 1
        and entry_rows[1].from == "p1" and entry_rows[1].to == "p2"
        and entry_rows[1].done == true,
        entry_rows and (tostring(entry_rows[1] and entry_rows[1].from) .. "-"
            .. tostring(entry_rows[1] and entry_rows[1].to)))
end

-- ============================================================
print("== 2c. 范围导入不降级已完成的文件 ==")
do
    local done_book = ROOT .. "/books/done.epub"
    local handle = io.open(done_book, "wb")
    handle:write(string.rep("w", 1536))
    handle:close()
    local function job_for(job_id, partial, selector, source)
        return {
            schema = "dualtranslate.job.v1",
            job_id = job_id,
            created_at = os.time(),
            book = {
                device_path = done_book, title = "Done", source_lang = "en",
                target_lang = "zh-Hans", spine_count = 5,
                file_size = lfs.attributes(done_book, "size"),
                file_mtime = lfs.attributes(done_book, "modification") or 0,
            },
            chapters = { { index = 1, title = "One", partial = partial or nil } },
            segments = {
                { id = "s000001", parent_id = "s000001", part = 1, parent_total = 1,
                  chapter_index = 1, chapter_title = "One", selector = selector,
                  xpointer = "/body/DocFragment/body/p[1]", source = source },
            },
            options = { max_chars_per_segment = 4500, split_long_segments = true },
        }
    end
    local whole_job = job_for("20261115_120000_0003", false, "sel-done-1", "Whole")
    local whole_result = make_result({ { id = "s000001", text = "整章" } })
    whole_result.job_id = whole_job.job_id
    check("整章任务先导入", Store.importResult(whole_job, whole_result) ~= nil)

    local partial_job = job_for("20261115_120000_0004", true, "sel-done-2", "Range")
    local partial_result = make_result({ { id = "s000001", text = "范围" } })
    partial_result.job_id = partial_job.job_id
    local summary, err = Store.importResult(partial_job, partial_result)
    check("范围任务导入成功", summary ~= nil, tostring(err))
    local manifest = Overlay.loadManifest(Store.bookDir(done_book, "zh-Hans"))
    local provider = manifest and manifest.providers["mcp:gpt-5"]
    check("已完成的文件不被范围导入降级", provider
        and provider.chapters[1] == 1 and #(provider.partial_chapters or {}) == 0,
        provider and ("done=" .. #(provider.chapters or {})
            .. " partial=" .. #(provider.partial_chapters or {})))
end

-- ============================================================
print("== 2d. 范围内的段落全失败落 failed ==")
do
    local fail_book = ROOT .. "/books/fail.epub"
    local handle = io.open(fail_book, "wb")
    handle:write(string.rep("z", 1024))
    handle:close()
    -- 第一章的范围一段都没回来，第二章正常回传：导入要能继续，但第一章
    -- 必须落 failed_chapters，而不是混进「部分」
    local fail_job = {
        schema = "dualtranslate.job.v1",
        job_id = "20261115_120000_0005",
        created_at = os.time(),
        book = {
            device_path = fail_book, title = "Fail", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 5,
            file_size = lfs.attributes(fail_book, "size"),
            file_mtime = lfs.attributes(fail_book, "modification") or 0,
        },
        chapters = { { index = 1, title = "One", partial = true,
                ranges = { { from = "a", to = "b" } } },
            { index = 2, title = "Two" } },
        segments = {
            { id = "s000001", parent_id = "s000001", part = 1, parent_total = 1,
              chapter_index = 1, chapter_title = "One", selector = "sel-fail",
              xpointer = "/body/DocFragment/body/p[1]", source = "Lost paragraph" },
            { id = "s000002", parent_id = "s000002", part = 1, parent_total = 1,
              chapter_index = 2, chapter_title = "Two", selector = "sel-ok",
              xpointer = "/body/DocFragment[2]/body/p[1]", source = "Fine paragraph" },
        },
        options = { max_chars_per_segment = 4500, split_long_segments = true },
    }
    local result = make_result({ { id = "s000002", text = "正常" } })
    result.job_id = fail_job.job_id
    local summary, err = Store.importResult(fail_job, result, { allow_partial = true })
    check("允许部分导入", summary ~= nil, tostring(err))
    local manifest = Overlay.loadManifest(Store.bookDir(fail_book, "zh-Hans"))
    local provider = manifest and manifest.providers["mcp:gpt-5"]
    -- 设备侧检查点对「一段都没成功」的范围写空表（表示该文件按条目记账、
    -- 但一条都没覆盖），导入必须一致，否则文件级「部分」会溢到没请求过的行。
    check("一段都没回来的范围仍留空覆盖表", provider
        and type(provider.entry_ranges) == "table"
        and type(provider.entry_ranges["1"]) == "table"
        and #provider.entry_ranges["1"] == 0,
        provider and type(provider.entry_ranges))
    check("范围内全失败落 failed_chapters", provider
        and #(provider.failed_chapters or {}) == 1 and provider.failed_chapters[1] == 1
        and #(provider.partial_chapters or {}) == 0,
        provider and ("failed=" .. #(provider.failed_chapters or {})
            .. " partial=" .. #(provider.partial_chapters or {})))
    check("正常回传的章节仍算完成", provider
        and provider.chapters and provider.chapters[1] == 2)
end

-- ============================================================
print("== 3. 幂等与部分更新 ==")
do
    local manifest_before = load_manifest()
    local result = make_result({
        { id = "s000001", text = "第一段上" },
        { id = "s000002", text = "第一段下" },
        { id = "s000003", text = "第二章（新）" },
    })
    local summary, err = Store.importResult(job, result)
    check("重复导入成功", summary ~= nil, tostring(err))
    check("DB 行数不增长", #db_rows() == 2)
    local entries = Overlay.loadEntries(Store.bookDir(BOOK, "zh-Hans"), "mcp:gpt-5")
    check("entries 不重复", entries and #entries.entries == 2)
    local manifest = load_manifest()
    check("revision 递增", manifest.revision > manifest_before.revision)
    local by_source = {}
    for _, row in ipairs(db_rows()) do by_source[row[1]] = row[2] end
    check("译文被更新", by_source["Second chapter"] == "第二章（新）")
end

-- ============================================================
print("== 3b. 删除后重新导入，seq 仍单调 ==")
do
    local dir = Store.bookDir(BOOK, "zh-Hans")
    local before = Overlay.loadSignal(dir).seq
    -- "Delete every translation" removes the manifest, so the next import
    -- starts a fresh manifest at revision 1.  Reproduce that state without
    -- touching the entries the later sections rely on.
    local manifest = load_manifest()
    manifest.revision = 1
    local file = io.open(dir .. "/manifest.json", "wb")
    file:write(JSON.encode(manifest))
    file:close()
    local result = make_result({
        { id = "s000001", text = "第一段上" }, { id = "s000002", text = "第一段下" },
        { id = "s000003", text = "第二章" },
    })
    local summary, err = Store.importResult(job, result)
    local after = Overlay.loadSignal(dir)
    check("重新导入成功", summary ~= nil, tostring(err))
    check("signal 比删除前大", after and after.seq > before,
        tostring(before) .. " -> " .. tostring(after and after.seq))
    check("seq 不小于 revision", after and after.seq >= load_manifest().revision)
end

-- ============================================================
print("== 4. 非法输入 ==")
do
    local result = make_result({
        { id = "s000001", text = "" },
        { id = "s999999", text = "不存在" },
        { id = "s000002", text = "第一段下" },
        { id = "s000003", text = "第二章" },
    })
    local summary, err = Store.importResult(job, result, { allow_partial = true })
    check("部分非法条目被拒绝但仍导入", summary ~= nil, tostring(err))
    check("rejected 记录两条", summary and #summary.rejected == 2)
    check("空译文不入库", #db_rows() == 2)

    local bad = make_result({ { id = "s000001", text = "x" } }, { model_name = "" })
    local summary2, err2 = Store.importResult(job, bad, { allow_partial = true })
    check("缺模型名拒绝", summary2 == nil and tostring(err2):find("模型") ~= nil, tostring(err2))

    local bad_id = make_result({ { id = "s000001", text = "x" } },
        { provider_id = "gpt5" })
    local summary3 = Store.importResult(job, bad_id, { allow_partial = true })
    check("非法 provider_id 拒绝", summary3 == nil)

    local mismatched = make_result({ { id = "s000001", text = "x" } })
    mismatched.job_id = "20261115_120000_9999"
    local summary4 = Store.importResult(job, mismatched, { allow_partial = true })
    check("job_id 不一致拒绝", summary4 == nil)
end

-- ============================================================
print("== 5. 书文件被替换 ==")
do
    local handle = io.open(BOOK, "ab")
    handle:write("y")
    handle:close()
    local result = make_result({
        { id = "s000001", text = "a" }, { id = "s000002", text = "b" },
        { id = "s000003", text = "c" },
    })
    local summary, err = Store.importResult(job, result)
    check("size 变化拒绝", summary == nil and tostring(err):find("已变化") ~= nil, tostring(err))
    -- Restore the original size for the remaining cases.  The job fingerprint
    -- must describe the restored file: mtime has one-second resolution, so a
    -- restore that crosses a second boundary makes every later import fail
    -- with "书文件已变化" (this suite used to go red whenever that happened).
    local trim = io.open(BOOK, "wb")
    trim:write(string.rep("x", 4096))
    trim:close()
    job.book.file_size = lfs.attributes(BOOK, "size")
    job.book.file_mtime = lfs.attributes(BOOK, "modification") or 0
end

-- ============================================================
print("== 6. 模型未确认 ==")
do
    -- A brand-new provider id: an existing row keeps confirmed=1 by design
    -- (10.6: DO UPDATE never resets the user's confirmation).
    local unconfirmed_job = { schema = job.schema, job_id = JOB_ID, book = job.book,
        chapters = job.chapters, segments = job.segments }
    local result = make_result({
        { id = "s000001", text = "a" }, { id = "s000002", text = "b" },
        { id = "s000003", text = "c" },
    }, { provider_id = "mcp:claude-4.5", display_name = "MCP · Claude 4.5",
         model_name = "claude-4.5", confirmed = false })
    local summary, err = Store.importResult(unconfirmed_job, result, { set_display = true })
    check("未确认仍可导入", summary ~= nil, tostring(err))
    check("未确认跳过显示切换", summary and summary.display_skipped == true)
    local manifest = load_manifest()
    local provider = manifest and manifest.providers["mcp:claude-4.5"]
    check("manifest 标记未确认", provider and provider.confirmed == false)
    check("display 未被抢占", manifest and manifest.display_provider ~= "mcp:claude-4.5")
end

-- ============================================================
print("== 7b. entries 丢失后从 SQLite 重建 ==")
do
    local dir = Store.bookDir(BOOK, "zh-Hans")
    local entries_path = Overlay.entriesPath(dir, "mcp:gpt-5")
    os.remove(entries_path)
    check("entries 已删除", not Overlay.exists(entries_path))
    local summary, err = Store.reconcile(BOOK, "zh-Hans", cache)
    check("reconcile 成功", summary ~= nil, tostring(err))
    check("rebuilt 记录该 provider", summary and #summary.rebuilt == 1
        and summary.rebuilt[1] == "mcp:gpt-5", summary and JSON.encode(summary.rebuilt))
    check("entries 已重建", Overlay.exists(entries_path))
    local doc = Overlay.loadEntries(dir, "mcp:gpt-5")
    check("重建条目数", doc and #doc.entries == 2, doc and tostring(#doc.entries))
    local manifest = load_manifest()
    check("manifest 未删 provider", manifest and manifest.providers["mcp:gpt-5"] ~= nil)
    check("translated_count 回填", manifest and manifest.providers["mcp:gpt-5"]
        and manifest.providers["mcp:gpt-5"].translated_count == 2)
end

-- ============================================================
print("== 8. 删除本书时清理任务 ==")
do
    check("清理一本书的 job", Mcp.cleanupBookJobs(BOOK) == 1)
    check("job 目录已删除", lfs.attributes(job_dir, "mode") == nil)
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
