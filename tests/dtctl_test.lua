-- ============================================================
-- P3-d：dtctl headless CLI（真实子进程 + 真实 SQLite）
--   stdout 单行 JSON / list-jobs / put 白名单 / import / list-providers /
--   set-display / touch-reload 的单调 seq / delete-provider /
--   参数与 SSH_ORIGINAL_COMMAND 白名单
-- Run: luajit tests/dtctl_test.lua
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
local ffi = require("ffi")
if not ffi.loadlib then ffi.loadlib = function(name) return ffi.load(name) end end
package.path = KO .. "/?.lua;" .. KO .. "/common/?.lua;" .. KO .. "/common/?/init.lua;" .. package.path
package.cpath = KO .. "/?.so;" .. KO .. "/?.dylib;" .. package.cpath
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_json, JSON = pcall(require, "json")
local ok_sq3 = pcall(require, "lua-ljsqlite3")
if not ok_lfs or not ok_json or not ok_sq3 then
    print("SKIP: lfs / json / lua-ljsqlite3 unavailable"); os.exit(0)
end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local ROOT = "/tmp/dt_dtctl_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')
local DATA = ROOT .. "/data"
local BOOK = ROOT .. "/book.epub"
os.execute('mkdir -p "' .. DATA .. '"')
do
    local file = io.open(BOOK, "wb")
    file:write(string.rep("x", 4096))
    file:close()
end
local BOOK_SIZE = lfs.attributes(BOOK, "size")
local BOOK_MTIME = lfs.attributes(BOOK, "modification")

-- The CLI process needs the same data dir; the test process opens the DB
-- read-only through the same override.
-- io.popen:close() exposes no exit status on this LuaJIT, so redirect stdout
-- to a file and read the wait status from os.execute (512 = exit 2).
local function run(args, extra_env, stdin_path)
    local out_path = ROOT .. "/stdout.txt"
    local env = string.format("KO_ROOT='%s' DT_DATA_DIR='%s'", KO, DATA)
    if extra_env then env = env .. " " .. extra_env end
    local command = string.format("%s luajit tools/dtctl.lua %s > %s 2>/dev/null",
        env, args, out_path)
    if stdin_path then command = command .. " < " .. stdin_path end
    local status = os.execute(command)
    local code = 0
    if status == nil then
        code = 1
    elseif status ~= true then
        code = math.floor((tonumber(status) or 1) / 256)
    end
    local file = io.open(out_path, "rb")
    local out = file and file:read("*a") or ""
    if file then file:close() end
    return out, code
end

local function decode_single_line(out)
    local lines = {}
    for line in out:gmatch("[^\n]+") do lines[#lines + 1] = line end
    if #lines ~= 1 then return nil, "stdout lines: " .. #lines end
    local ok, data = pcall(JSON.decode, lines[1])
    if not ok or type(data) ~= "table" then return nil, "not json: " .. lines[1] end
    return data
end

local function write_file(path, content)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then os.execute('mkdir -p "' .. parent .. '"') end
    local file = io.open(path, "wb")
    file:write(content)
    file:close()
end

local JOB_ID = "20261115_120000_0001"
local JOB_DIR = DATA .. "/cache/dualtranslate/mcp/jobs/" .. JOB_ID
local JOB_PATH = JOB_DIR .. "/job.json"

local job = {
    schema = "dualtranslate.job.v1", job_id = JOB_ID, created_at = os.time(),
    book = { device_path = BOOK, title = "T", source_lang = "en",
        target_lang = "zh-Hans", spine_count = 3,
        file_size = BOOK_SIZE, file_mtime = BOOK_MTIME },
    chapters = { { index = 1, title = "One" } },
    segments = {
        { id = "s000001", parent_id = "s000001", part = 1, parent_total = 1,
          chapter_index = 1, chapter_title = "One", selector = "sel-a",
          xpointer = "/body/DocFragment/body/p[1]", source = "Hello" },
    },
    options = { max_chars_per_segment = 4500, split_long_segments = true },
}
write_file(JOB_PATH, JSON.encode(job))
write_file(JOB_DIR .. "/state.json", JSON.encode({
    schema = "dualtranslate.state.v1", status = "exported", submitted = 0, total = 1 }))

local RESULT = ROOT .. "/result.json"
write_file(RESULT, JSON.encode({
    schema = "dualtranslate.result.v1", job_id = JOB_ID,
    provider = { provider_id = "mcp:gpt-5", kind = "mcp", model_name = "gpt-5",
        display_name = "MCP · GPT-5", confirmed = true },
    translations = { { id = "s000001", text = "你好" } },
}))

-- ============================================================
print("== 1. stdout 单行 JSON ==")
do
    local out, code = run("list-jobs")
    check("list-jobs 退出 0", code == 0, tostring(code))
    local data, err = decode_single_line(out)
    check("严格单行 JSON", data ~= nil, err or out)
    check("jobs 非空", data and #data.jobs == 1 and data.jobs[1].job_id == JOB_ID)
    check("章节数是数字字段", data and data.jobs[1].chapter_count == 1)
    check("未知子命令拒绝", (run("nonsense")) ~= nil)
    local bad, bad_code = run("nonsense")
    local bad_data = decode_single_line(bad)
    check("未知子命令退出 2", bad_code == 2 and bad_data and bad_data.code == "INVALID_ARGUMENT")
end

-- ============================================================
print("== 2. put 白名单 ==")
do
    local out, code = run('put --job ' .. JOB_PATH .. " --name result.json", nil, RESULT)
    local data = decode_single_line(out)
    check("put result.json 成功", code == 0 and data and data.ok == true, out)
    check("文件落盘", lfs.attributes(JOB_DIR .. "/result.json", "mode") ~= nil)

    local evil, evil_code = run('put --job ' .. JOB_PATH .. " --name evil.json", nil, RESULT)
    local evil_data = decode_single_line(evil)
    check("非法文件名校验", evil_code == 2 and evil_data
        and evil_data.code == "INVALID_ARGUMENT")

    local escape, escape_code = run('put --job /etc/passwd --name result.json', nil, RESULT)
    check("job 路径穿越拒绝", escape_code == 2)

    local nameless, nameless_code = run("put --job " .. JOB_PATH, nil, RESULT)
    check("缺 --name 拒绝", nameless_code == 2)
end

-- ============================================================
print("== 3. import ==")
do
    local out, code = run("import --job " .. JOB_PATH)
    local data = decode_single_line(out)
    check("import 退出 0", code == 0 and data and data.ok == true, out)
    check("统计", data and data.imported and data.imported.accepted == 1
        and data.imported.provider_id == "mcp:gpt-5")
    check("rejected 是数组", data and type(data.imported.rejected) == "table"
        and #data.imported.rejected == 0)
    local entries = DATA .. "/cache/dualtranslate/books/"
    local found = false
    local books_dir = entries
    if lfs.attributes(books_dir, "mode") == "directory" then
        for name in lfs.dir(books_dir) do
            if name ~= "." and name ~= ".." then
                local path = books_dir .. "/" .. name .. "/entries/mcp_gpt-5.json"
                if lfs.attributes(path, "mode") then found = true end
            end
        end
    end
    check("entries 文件写入", found)
    local state = JSON.decode((function()
        local file = io.open(JOB_DIR .. "/state.json", "rb")
        local raw = file:read("*a"); file:close(); return raw
    end)())
    check("state 标记 committed", state and state.status == "committed")
end

-- ============================================================
print("== 4. list-providers / set-display / touch-reload / delete ==")
do
    local out = run("list-providers --book " .. BOOK .. " --target zh-Hans")
    local data = decode_single_line(out)
    check("list-providers 命中", data and #data.providers == 1
        and data.providers[1].id == "mcp:gpt-5")

    local display_out = run("set-display --book " .. BOOK
        .. " --target zh-Hans --provider mcp:gpt-5")
    local display = decode_single_line(display_out)
    check("set-display", display and display.display_provider == "mcp:gpt-5")

    local reload_out = run("touch-reload --book " .. BOOK .. " --target zh-Hans")
    local reload = decode_single_line(reload_out)
    check("touch-reload 返回 seq", reload and reload.seq and reload.seq > 0)

    local delete_out = run("delete-provider --book " .. BOOK
        .. " --target zh-Hans --provider mcp:gpt-5")
    local deleted = decode_single_line(delete_out)
    check("delete-provider", deleted and deleted.deleted == 1)
    -- The manifest is gone after the last provider; seq must still grow.
    local signal_seq
    local books_dir = DATA .. "/cache/dualtranslate/books"
    if lfs.attributes(books_dir, "mode") == "directory" then
        for name in lfs.dir(books_dir) do
            if name ~= "." and name ~= ".." then
                local path = books_dir .. "/" .. name .. "/reload.signal"
                if lfs.attributes(path, "mode") then
                    local file = io.open(path, "rb")
                    local raw = file:read("*a"); file:close()
                    signal_seq = JSON.decode(raw).seq
                end
            end
        end
    end
    check("删除后 seq 仍增长", signal_seq and reload and signal_seq > reload.seq,
        tostring(signal_seq) .. " <= " .. tostring(reload and reload.seq))

    local bad_target = run("list-providers --book " .. BOOK .. " --target zz")
    local bad_target_data = decode_single_line(bad_target)
    check("目标语言白名单", bad_target_data and bad_target_data.code == "INVALID_ARGUMENT")
end

-- ============================================================
print("== 5. SSH_ORIGINAL_COMMAND ==")
do
    local out, code = run("", "SSH_ORIGINAL_COMMAND='sftp'")
    local data = decode_single_line(out)
    check("sftp 子系统被拒绝", code == 2 and data and data.code == "INVALID_ARGUMENT")

    local inject, inject_code = run("",
        "SSH_ORIGINAL_COMMAND='list-jobs; rm -rf /'")
    local inject_data = decode_single_line(inject)
    check("shell 元字符被拒绝", inject_code == 2 and inject_data
        and inject_data.code == "INVALID_ARGUMENT")

    local raw_job, raw_job_code = run("", "SSH_ORIGINAL_COMMAND='put --job /etc/x --name a.json'")
    check("forced command 校验路径", raw_job_code == 2)

    local ok_out, ok_code = run("", "SSH_ORIGINAL_COMMAND='list-jobs'")
    local ok_data = decode_single_line(ok_out)
    check("合法 forced command 通过", ok_code == 0 and ok_data and ok_data.ok == true)
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
