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
          xpointer = "/body/DocFragment/body/p[1]", source = "Part one" },
        { id = "s000002", parent_id = "s000001", part = 2, parent_total = 2,
          chapter_index = 1, chapter_title = "One", selector = "sel-a",
          xpointer = "/body/DocFragment/body/p[1]", source = "part two" },
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
    check("reload.signal seq 与 revision 一致", signal and signal.seq == manifest.revision)
    check("reload.signal op=import", signal and signal.op == "import"
        and signal.provider == "mcp:gpt-5" and signal.count == 2)

    local provider_row = cache:getProvider("mcp:gpt-5")
    check("providers 表写入", provider_row and provider_row.model_name == "gpt-5")
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
    -- Restore the original size for the remaining cases.
    local trim = io.open(BOOK, "wb")
    trim:write(string.rep("x", 4096))
    trim:close()
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
print("== 7. inbox → job 目录归档 ==")
do
    local inbox = Mcp.inboxDir()
    Tools.mkdir_p(inbox)
    local result = make_result({
        { id = "s000001", text = "a" }, { id = "s000002", text = "b" },
        { id = "s000003", text = "c" },
    })
    local inbox_path = inbox .. "/" .. JOB_ID .. ".json"
    writeJson(inbox_path, result)
    check("pendingResults 发现 inbox", #Mcp.pendingResults() == 1)
    local summary, err = Mcp.importFile(inbox_path, { allow_partial = false })
    check("importFile 成功", summary ~= nil, tostring(err))
    check("inbox 已清空", lfs.attributes(inbox_path, "mode") == nil)
    check("result 归档到 job 目录", lfs.attributes(job_dir .. "/result.json", "mode") ~= nil)
    local state = Mcp.loadState(JOB_ID)
    check("state committed", state and state.status == "committed"
        and state.provider_id == "mcp:gpt-5")
    check("已提交任务不再待导入", #Mcp.pendingResults() == 0)
end

-- ============================================================
print("== 8. 删除本书时清理任务 ==")
do
    check("清理一本书的 job", Mcp.cleanupBookJobs(BOOK) == 1)
    check("job 目录已删除", lfs.attributes(job_dir, "mode") == nil)
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
