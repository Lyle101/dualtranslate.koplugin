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
-- Spawn dtctl with the interpreter that is running this test and an absolute
-- script path.  `luajit` is not on PATH in CI (the runner uses the KOReader
-- bundle's binary) and the tests do not run from the repo root on every
-- machine; arg[-1] is the interpreter, arg[0] this file.
local LUA = (arg and arg[-1]) or "luajit"
local TEST_DIR = (arg and arg[0] or ""):match("^(.*)/[^/]+$") or "tests"
local DTCTL = TEST_DIR .. "/../tools/dtctl.lua"

local function run(args, extra_env, stdin_path)
    local out_path = ROOT .. "/stdout.txt"
    local env = string.format("KO_ROOT='%s' DT_DATA_DIR='%s'", KO, DATA)
    if extra_env then env = env .. " " .. extra_env end
    local command = string.format("%s '%s' '%s' %s > %s 2>/dev/null",
        env, LUA, DTCTL, args, out_path)
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

    -- B2: a book path containing spaces must survive the command string.
    local spaced_book = ROOT .. "/book with space.epub"
    write_file(spaced_book, string.rep("x", 64))
    local spaced_out, spaced_code = run("",
        "SSH_ORIGINAL_COMMAND='list-providers --book \"" .. spaced_book
        .. "\" --target zh-Hans'")
    local spaced_data = decode_single_line(spaced_out)
    check("引号内空格路径可用", spaced_code == 0 and spaced_data and spaced_data.ok == true,
        spaced_out)

    local unclosed, unclosed_code = run("",
        "SSH_ORIGINAL_COMMAND='list-providers --book \"/tmp/x --target zh-Hans'")
    local unclosed_data = decode_single_line(unclosed)
    check("未闭合引号拒绝", unclosed_code == 2 and unclosed_data
        and unclosed_data.code == "INVALID_ARGUMENT")
end

-- ============================================================
print("== 6. rpc 信封与只读模式 ==")
do
    local function rpc(argv_table, mode)
        local path = ROOT .. "/rpc.json"
        write_file(path, JSON.encode(argv_table))
        return run(mode and ("--mode=" .. mode .. " rpc") or "rpc", nil, path)
    end

    local out, code = rpc({ argv = { "list-jobs" } })
    local data = decode_single_line(out)
    check("rpc list-jobs", code == 0 and data and #data.jobs >= 1, out)

    local status_out = rpc({ argv = { "job-status", "--job", JOB_PATH } })
    local status = decode_single_line(status_out)
    check("rpc job-status", status and status.total == 1
        and status.segment_ids and status.segment_ids[1] == "s000001", status_out)
    -- 17 Q5: a job exported before options.glossary existed still answers
    -- with the fixed shape (empty glossary, empty style guide).
    check("job-status options 形状", status and status.options
        and #status.options.glossary == 0 and status.options.style_guide == ""
        and status.options.max_chars_per_segment == 4500, status_out)
    check("空术语表输出为数组", tostring(status_out):find('"glossary":[]', 1, true) ~= nil,
        status_out)

    local seg_out = rpc({ argv = { "get-segments", "--job", JOB_PATH,
        "--offset", "0", "--limit", "5", "--context" } })
    local seg = decode_single_line(seg_out)
    check("rpc get-segments", seg and #seg.segments == 1
        and seg.segments[1].source == "Hello" and seg.next_offset == nil, seg_out)

    local cat_out = rpc({ argv = { "cat", "--job", JOB_PATH, "--name", "state.json" } })
    local cat = decode_single_line(cat_out)
    check("rpc cat", cat and cat.exists == true
        and tostring(cat.content):find("dualtranslate", 1, true) ~= nil, cat_out)

    local forbidden, forbidden_code = rpc({ argv = { "put", "--job", JOB_PATH,
        "--name", "state.json" }, stdin = "{}" }, "read")
    local forbidden_data = decode_single_line(forbidden)
    check("只读模式拒绝写", forbidden_code ~= 0 and forbidden_data
        and forbidden_data.code == "FORBIDDEN", forbidden)

    local read_ok, read_ok_code = rpc({ argv = { "list-jobs" } }, "read")
    check("只读模式允许读", read_ok_code == 0)

    -- Malformed JSON must come back as a JSON error, not a Lua traceback.
    local bad_path = ROOT .. "/rpc_bad.json"
    write_file(bad_path, "{not json")
    local malformed_out, malformed_code = run("rpc", nil, bad_path)
    local malformed_data = decode_single_line(malformed_out)
    check("畸形载荷返回 JSON 错误", malformed_code == 2 and malformed_data
        and malformed_data.code == "INVALID_ARGUMENT", malformed_out)

    local bad_body, bad_body_code = rpc({ argv = { "list-jobs" }, stdin = 123 })
    local bad_body_data = decode_single_line(bad_body)
    check("非字符串 body 拒绝", bad_body_code == 2 and bad_body_data
        and bad_body_data.code == "INVALID_ARGUMENT", bad_body)

    local write_out, write_code = rpc({ argv = { "put", "--job", JOB_PATH,
        "--name", "state.json" }, stdin = '{"schema":"dualtranslate.state.v1","status":"exported"}' })
    local write_data = decode_single_line(write_out)
    check("rpc 携带 body 上传", write_code == 0 and write_data and write_data.ok == true,
        write_out)
end


-- ============================================================
print("== 7. 索引路径（job.json 不存在） ==")
do
    local function rpc2(argv_table)
        local path = ROOT .. "/rpc.json"
        write_file(path, JSON.encode(argv_table))
        return run("rpc", nil, path)
    end
    local index_job = "20261116_050000_0001"
    local index_dir = DATA .. "/cache/dualtranslate/mcp/jobs/" .. index_job
    os.execute('mkdir -p "' .. index_dir .. '"')
    write_file(index_dir .. "/meta.json", JSON.encode({
        schema = "dualtranslate.job.meta.v1", job_id = index_job,
        created_at = os.time(),
        book = { device_path = BOOK, title = "Index", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 1,
            file_size = BOOK_SIZE, file_mtime = BOOK_MTIME },
        chapter_count = 1, total = 3,
        options = {
            max_chars_per_segment = 4500,
            split_long_segments = true,
            glossary = { { source = "Darcy", target = "达西" } },
            style_guide = "保留段落结构",
        },
    }))
    local lines = {}
    for index = 1, 3 do
        lines[index] = JSON.encode({
            id = string.format("s%06d", index), parent_id = string.format("s%06d", index),
            part = 1, parent_total = 1, chapter_index = 1, chapter_title = "One",
            selector = "p[" .. index .. "]", source = "text " .. index,
        })
    end
    local shell = JSON.encode({
        schema = "dualtranslate.job.v1", job_id = index_job, created_at = 1,
        book = { device_path = BOOK, title = "Index", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 1,
            file_size = BOOK_SIZE, file_mtime = BOOK_MTIME },
        chapters = { { index = 1, title = "One" } },
        options = { max_chars_per_segment = 4500 },
    })
    write_file(index_dir .. "/job.json",
        shell:sub(1, -2) .. ',"segments":[\n' .. table.concat(lines, ",\n") .. "\n]}")
    write_file(index_dir .. "/state.json", JSON.encode({
        schema = "dualtranslate.state.v1", status = "exported", submitted = 0, total = 3 }))

    local index_job_path = index_dir .. "/job.json"
    local status_out = rpc2({ argv = { "job-status", "--job", index_job_path } })
    local status = decode_single_line(status_out)
    check("索引 job-status", status and status.total == 3
        and #status.segment_ids == 3 and status.title == "Index", status_out)
    check("索引 job-status options", status and status.options
        and #status.options.glossary == 1
        and status.options.glossary[1].source == "Darcy"
        and status.options.glossary[1].target == "达西"
        and status.options.style_guide == "保留段落结构", status_out)

    -- A meta.json written before options existed keeps max_chars as a
    -- top-level field; the old job must still answer, with an empty glossary.
    write_file(index_dir .. "/meta.json", JSON.encode({
        schema = "dualtranslate.job.meta.v1", job_id = index_job,
        created_at = os.time(),
        book = { device_path = BOOK, title = "Index", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 1,
            file_size = BOOK_SIZE, file_mtime = BOOK_MTIME },
        chapter_count = 1, total = 3, max_chars_per_segment = 4500,
    }))
    status_out = rpc2({ argv = { "job-status", "--job", index_job_path } })
    status = decode_single_line(status_out)
    check("旧 meta 兼容 max_chars", status and status.options
        and status.options.max_chars_per_segment == 4500
        and #status.options.glossary == 0
        and tostring(status_out):find('"glossary":[]', 1, true) ~= nil, status_out)

    local seg_out = rpc2({ argv = { "get-segments", "--job", index_job_path,
        "--offset", "1", "--limit", "1", "--context" } })
    local seg = decode_single_line(seg_out)
    check("索引 get-segments", seg and #seg.segments == 1
        and seg.segments[1].id == "s000002" and seg.next_offset == 2, seg_out)
    check("索引 context", seg and seg.segments[1].prev == "text 1"
        and seg.segments[1].next == "text 3", seg_out)

    -- New layout: the glossary lives in options.json, so meta.json stays tiny
    -- (the task list decodes one meta per job on every open).
    write_file(index_dir .. "/meta.json", JSON.encode({
        schema = "dualtranslate.job.meta.v1", job_id = index_job,
        created_at = os.time(),
        book = { device_path = BOOK, title = "Index", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 1,
            file_size = BOOK_SIZE, file_mtime = BOOK_MTIME },
        chapter_count = 1, total = 3, max_chars_per_segment = 4500,
    }))
    write_file(index_dir .. "/options.json", JSON.encode({
        schema = "dualtranslate.job.options.v1", job_id = index_job,
        options = {
            max_chars_per_segment = 4500, split_long_segments = true,
            glossary = { { source = "Lizzy", target = "莉齐" } },
            style_guide = "民国白话",
        },
    }))
    status_out = rpc2({ argv = { "job-status", "--job", index_job_path } })
    status = decode_single_line(status_out)
    check("options.json 生效", status and status.options
        and status.options.glossary[1] and status.options.glossary[1].source == "Lizzy"
        and status.options.style_guide == "民国白话", status_out)
    local cat_options = decode_single_line(rpc2({ argv = { "cat", "--job",
        index_job_path, "--name", "options.json" } }))
    check("cat options.json", cat_options and cat_options.exists == true
        and tostring(cat_options.content):find("Lizzy", 1, true) ~= nil)

    os.execute('rm -rf "' .. index_dir .. '"')
end
-- ============================================================
print("== 8. 截断索引不能给出短 id 表 ==")
do
    local function rpc3(argv_table)
        local path = ROOT .. "/rpc.json"
        write_file(path, JSON.encode(argv_table))
        return run("rpc", nil, path)
    end
    local trunc_job = "20261116_050000_0002"
    local trunc_dir = DATA .. "/cache/dualtranslate/mcp/jobs/" .. trunc_job
    os.execute('mkdir -p "' .. trunc_dir .. '"')
    local lines = {}
    for index = 1, 1000 do
        lines[index] = JSON.encode({
            id = string.format("t%06d", index), parent_id = string.format("t%06d", index),
            part = 1, parent_total = 1, chapter_index = 1, chapter_title = "T",
            selector = "p", source = "s" .. index,
        })
    end
    local shell = JSON.encode({
        schema = "dualtranslate.job.v1", job_id = trunc_job, created_at = 1,
        book = { device_path = BOOK, title = "T", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 1,
            file_size = BOOK_SIZE, file_mtime = BOOK_MTIME },
        chapters = {}, options = {},
    })
    write_file(trunc_dir .. "/job.json",
        shell:sub(1, -2) .. ',"segments":[\n' .. table.concat(lines, ",\n") .. "\n]}")
    write_file(trunc_dir .. "/meta.json", JSON.encode({
        schema = "dualtranslate.job.meta.v1", job_id = trunc_job,
        book = { device_path = BOOK, title = "T", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 1,
            file_size = BOOK_SIZE, file_mtime = BOOK_MTIME },
        chapter_count = 0, total = 1000,
    }))
    local handle = io.open(trunc_dir .. "/job.json", "rb")
    local blob = handle:read("*a"); handle:close()
    local keep = math.floor(#blob * 0.6)
    local out_handle = io.open(trunc_dir .. "/job.json", "wb")
    out_handle:write(blob:sub(1, keep)); out_handle:close()

    local out, code = rpc3({ argv = { "job-status", "--job", trunc_dir .. "/job.json" } })
    local data = decode_single_line(out)
    local id_count = 0
    for _ in out:gmatch("t%d%d%d%d%d%d") do id_count = id_count + 1 end
    check("截断任务回退后报错", code ~= 0 and data and data.ok == false
        and data.code ~= nil, out:sub(1, 160))
    check("不再返回短 id 表", id_count == 0, tostring(id_count))
    os.execute('rm -rf "' .. trunc_dir .. '"')
end

-- ============================================================
print("== 9. 导入后清理过期的 committed 任务 ==")
do
    local function make_job(id, status, age_days, submitted, total)
        local dir = DATA .. "/cache/dualtranslate/mcp/jobs/" .. id
        os.execute('mkdir -p "' .. dir .. '"')
        write_file(dir .. "/state.json", JSON.encode({
            schema = "dualtranslate.state.v1", status = status,
            updated_at = os.time() - age_days * 86400,
            submitted = submitted, total = total }))
        return dir
    end
    local expired = make_job("20260101_000000_0801", "committed", 8, 1, 1)
    local fresh = make_job("20260101_000000_0601", "committed", 6, 1, 1)
    local exported = make_job("20260101_000000_0901", "exported", 9, 0, 1)
    local partial = make_job("20260101_000000_0701", "committed", 9, 0, 1)
    local out, code = run("import --job " .. JOB_PATH)
    local data = decode_single_line(out)
    check("再次导入成功", code == 0 and data and data.ok == true, out)
    check("清理计数为 1", data and data.removed_jobs == 1,
        data and tostring(data.removed_jobs))
    check("8 天的 committed 被删", lfs.attributes(expired, "mode") == nil)
    check("6 天的 committed 保留", lfs.attributes(fresh, "mode") ~= nil)
    check("exported 不删", lfs.attributes(exported, "mode") ~= nil)
    check("部分导入不删", lfs.attributes(partial, "mode") ~= nil)
    check("当前任务保留", lfs.attributes(JOB_DIR, "mode") ~= nil)
    os.execute('rm -rf "' .. expired .. '" "' .. fresh .. '" "'
        .. exported .. '" "' .. partial .. '"')
end

-- ============================================================
print("== 10. 手工分批导入：state.submitted 记累计覆盖 ==")
do
    local multi_book = ROOT .. "/multi.epub"
    write_file(multi_book, string.rep("q", 2048))
    local id = "20261115_120000_0010"
    local dir = DATA .. "/cache/dualtranslate/mcp/jobs/" .. id
    os.execute('mkdir -p "' .. dir .. '"')
    local multi_job = {
        schema = "dualtranslate.job.v1", job_id = id, created_at = os.time(),
        book = { device_path = multi_book, title = "Multi", source_lang = "en",
            target_lang = "zh-Hans", spine_count = 1,
            file_size = lfs.attributes(multi_book, "size"),
            file_mtime = lfs.attributes(multi_book, "modification") or 0 },
        chapters = { { index = 1, title = "One" } },
        segments = {
            { id = "s000001", parent_id = "s000001", part = 1, parent_total = 1,
              chapter_index = 1, chapter_title = "One", selector = "sel-d1",
              xpointer = "/body/DocFragment/body/p[1]", source = "A" },
            { id = "s000002", parent_id = "s000002", part = 1, parent_total = 1,
              chapter_index = 1, chapter_title = "One", selector = "sel-d2",
              xpointer = "/body/DocFragment/body/p[2]", source = "B" },
        },
        options = { max_chars_per_segment = 4500, split_long_segments = true },
    }
    write_file(dir .. "/job.json", JSON.encode(multi_job))
    write_file(dir .. "/state.json", JSON.encode({
        schema = "dualtranslate.state.v1", status = "exported",
        submitted = 0, total = 2 }))
    local provider = { provider_id = "mcp:gpt-5", kind = "mcp",
        model_name = "gpt-5", display_name = "MCP · GPT-5", confirmed = true }
    local function write_result(name, translations, provider_override)
        write_file(dir .. "/" .. name, JSON.encode({
            schema = "dualtranslate.result.v1", job_id = id,
            provider = provider_override or provider, translations = translations }))
    end
    local function read_state()
        local file = io.open(dir .. "/state.json", "rb")
        if not file then return nil end
        local raw = file:read("*a")
        file:close()
        return JSON.decode(raw)
    end
    local function write_state(state)
        write_file(dir .. "/state.json", JSON.encode(state))
    end

    write_result("result.partial.json", { { id = "s000001", text = "甲" } })
    local out, code = run("import --job " .. dir .. "/job.json --result "
        .. dir .. "/result.partial.json --allow-partial")
    local data = decode_single_line(out)
    check("第一批部分导入成功", code == 0 and data and data.ok == true, out)
    check("第一批 submitted=1", read_state().submitted == 1,
        tostring(read_state().submitted))

    write_result("result.json", { { id = "s000002", text = "乙" } })
    out, code = run("import --job " .. dir .. "/job.json --result "
        .. dir .. "/result.json")
    data = decode_single_line(out)
    check("第二批不带 allow-partial 成功", code == 0 and data and data.ok == true, out)
    check("第二批 submitted 累计为 2", read_state().submitted == 2,
        tostring(read_state().submitted))

    -- Switching model mid-job must not inherit the previous provider's
    -- ledger: only one of the two segments is in this provider's result, so
    -- the import has to stay partial.
    write_result("result.partial.json", { { id = "s000001", text = "甲" } }, {
        provider_id = "mcp:other", kind = "mcp", model_name = "other",
        display_name = "MCP · Other", confirmed = true })
    out, code = run("import --job " .. dir .. "/job.json --result "
        .. dir .. "/result.partial.json")
    data = decode_single_line(out)
    check("换 provider 不继承旧账本", code ~= 0 and data and data.ok == false
        and tostring(data.message):find("还有 1 段缺失") ~= nil, out)

    -- The real switch path: dt_confirm_model changes state.provider_id before
    -- the next import.  The ledger is keyed by the result's provider, so the
    -- old model's ids must not cover the new one.
    local other_state = read_state()
    other_state.provider_id = "mcp:other"
    other_state.model_name = "other"
    write_state(other_state)
    out, code = run("import --job " .. dir .. "/job.json --result "
        .. dir .. "/result.partial.json --allow-partial")
    data = decode_single_line(out)
    check("确认换 provider 后 partial 只算新 provider", code == 0
        and data and data.ok == true and read_state().submitted == 1,
        tostring(read_state() and read_state().submitted))

    -- Switching back must still see the first provider's two segments.
    local gpt_state = read_state()
    gpt_state.provider_id = "mcp:gpt-5"
    gpt_state.model_name = "gpt-5"
    write_state(gpt_state)
    write_result("result.partial.json", { { id = "s000001", text = "甲" } })
    out, code = run("import --job " .. dir .. "/job.json --result "
        .. dir .. "/result.partial.json")
    data = decode_single_line(out)
    check("换回 provider 仍保留旧账本", code == 0 and data and data.ok == true
        and read_state().submitted == 2, tostring(read_state() and read_state().submitted))
    os.execute('rm -rf "' .. dir .. '"')
end

-- ============================================================
print("== 11. jobs 路径符号链接 ==")
do
    if not lfs.symlinkattributes then
        print("  SKIP: 平台没有 symlinkattributes")
    else
        local jobs_root = DATA .. "/cache/dualtranslate/mcp/jobs"
        local outside = ROOT .. "/outside_job"
        write_file(outside .. "/job.json", JSON.encode(job))
        write_file(outside .. "/state.json", JSON.encode({
            schema = "dualtranslate.state.v1", status = "exported" }))
        local body = ROOT .. "/body.json"
        write_file(body, '{"schema":"dualtranslate.state.v1"}')

        local link_id = "20261115_120000_0011"
        local link_dir = jobs_root .. "/" .. link_id
        os.execute('ln -s "' .. outside .. '" "' .. link_dir .. '"')
        if lfs.symlinkattributes(link_dir, "mode") == "link" then
            local out, code = run("cat --job " .. link_dir .. "/job.json --name job.json")
            local data = decode_single_line(out)
            check("任务目录链接：cat 拒绝", code ~= 0 and data and data.ok == false
                and tostring(data.message):find("symlink") ~= nil, out)
            out, code = run("job-status --job " .. link_dir .. "/job.json")
            data = decode_single_line(out)
            check("任务目录链接：job-status 拒绝", code ~= 0 and data and data.ok == false
                and tostring(data.message):find("symlink") ~= nil, out)
            out, code = run("put --job " .. link_dir .. "/job.json --name state.json",
                nil, body)
            data = decode_single_line(out)
            check("任务目录链接：put 拒绝", code ~= 0 and data and data.ok == false
                and tostring(data.message):find("symlink") ~= nil, out)
            out, code = run("import --job " .. link_dir .. "/job.json")
            data = decode_single_line(out)
            check("任务目录链接：import 拒绝", code ~= 0 and data and data.ok == false
                and tostring(data.message):find("symlink") ~= nil, out)
            os.remove(link_dir)
        else
            print("  SKIP: 符号链接创建失败")
        end

        local real_id = "20261115_120000_0012"
        local real_dir = jobs_root .. "/" .. real_id
        os.execute('mkdir -p "' .. real_dir .. '"')
        write_file(real_dir .. "/job.json", JSON.encode(job))
        os.execute('ln -s "' .. outside .. '/job.json" "' .. real_dir .. '/job.json"')
        if lfs.symlinkattributes(real_dir .. "/job.json", "mode") == "link" then
            local out = run("cat --job " .. real_dir .. "/job.json --name job.json")
            local data = decode_single_line(out)
            check("job.json 链接：cat 拒绝", data and data.ok == false
                and data.message == "job.json is a symlink", out)
            out = run("job-status --job " .. real_dir .. "/job.json")
            data = decode_single_line(out)
            check("job.json 链接：job-status 拒绝", data and data.ok == false
                and data.message == "job.json is a symlink", out)
            os.remove(real_dir .. "/job.json")
        end
        write_file(real_dir .. "/job.json", JSON.encode(job))
        os.execute('ln -s "' .. outside .. '/state.json" "' .. real_dir .. '/state.json"')
        if lfs.symlinkattributes(real_dir .. "/state.json", "mode") == "link" then
            local out = run("job-status --job " .. real_dir .. "/job.json")
            local data = decode_single_line(out)
            check("state.json 链接：job-status 拒绝", data and data.ok == false
                and data.message == "state.json is a symlink", out)
            out = run("cat --job " .. real_dir .. "/job.json --name state.json")
            data = decode_single_line(out)
            check("state.json 链接：cat 拒绝", data and data.ok == false
                and data.message == "state.json is a symlink", out)
            os.remove(real_dir .. "/state.json")
        end
        os.execute('rm -rf "' .. real_dir .. '"')

        -- The root itself: listing must not enumerate the target, and every
        -- job command must refuse before touching it.
        local real_root = jobs_root .. ".real"
        assert(os.rename(jobs_root, real_root))
        os.execute('ln -s "' .. real_root .. '" "' .. jobs_root .. '"')
        if lfs.symlinkattributes(jobs_root, "mode") == "link" then
            local out, code = run("list-jobs")
            local data = decode_single_line(out)
            check("根链接：list-jobs 返回空", code == 0 and data and data.ok == true
                and type(data.jobs) == "table" and #data.jobs == 0, out)
            out, code = run("cat --job " .. JOB_PATH .. " --name job.json")
            data = decode_single_line(out)
            check("根链接：cat 拒绝", code ~= 0 and data and data.ok == false
                and data.message == "jobs root is a symlink", out)
            out, code = run("import --job " .. JOB_PATH)
            data = decode_single_line(out)
            check("根链接：import 拒绝", code ~= 0 and data and data.ok == false
                and data.message == "jobs root is a symlink", out)
        else
            print("  SKIP: 根目录符号链接创建失败")
        end
        os.remove(jobs_root)
        assert(os.rename(real_root, jobs_root))
    end
end

-- ============================================================
print("== 12. 原子写 .tmp / sidecar / cat 缺失任务 ==")
do
    local function read(path)
        local file = io.open(path, "rb")
        if not file then return nil end
        local raw = file:read("*a")
        file:close()
        return raw
    end
    if not lfs.symlinkattributes then
        print("  SKIP: 平台没有 symlinkattributes")
    else
        local outside = ROOT .. "/outside_tmp.txt"
        write_file(outside, "original")
        local body = ROOT .. "/body12.json"
        write_file(body, '{"schema":"dualtranslate.state.v1"}')
        local id = "20261115_120000_0013"
        local dir = DATA .. "/cache/dualtranslate/mcp/jobs/" .. id
        os.execute('mkdir -p "' .. dir .. '"')
        local tmp_job = {}
        for key, value in pairs(job) do tmp_job[key] = value end
        tmp_job.job_id = id
        write_file(dir .. "/job.json", JSON.encode(tmp_job))
        write_file(dir .. "/state.json", JSON.encode({
            schema = "dualtranslate.state.v1", status = "exported",
            submitted = 0, total = 1 }))
        os.execute('ln -s "' .. outside .. '" "' .. dir .. '/state.json.tmp"')
        if lfs.symlinkattributes(dir .. "/state.json.tmp", "mode") == "link" then
            local out, code = run("put --job " .. dir .. "/job.json --name state.json",
                nil, body)
            local data = decode_single_line(out)
            check("put 不跟随 .tmp 链接", code == 0 and data and data.ok == true
                and read(outside) == "original", out .. " / " .. tostring(read(outside)))
        else
            print("  SKIP: 符号链接创建失败")
        end

        -- import writes state.json through Mcp.writeJson, which shares the
        -- same scratch-path rule.
        write_file(dir .. "/result.json", JSON.encode({
            schema = "dualtranslate.result.v1", job_id = id,
            provider = { provider_id = "mcp:gpt-5", kind = "mcp",
                model_name = "gpt-5", display_name = "MCP · GPT-5", confirmed = true },
            translations = { { id = "s000001", text = "最终" } },
        }))
        os.remove(dir .. "/state.json.tmp")
        os.execute('ln -s "' .. outside .. '" "' .. dir .. '/state.json.tmp"')
        local out, code = run("import --job " .. dir .. "/job.json")
        local data = decode_single_line(out)
        check("import 不跟随 .tmp 链接", code == 0 and data and data.ok == true
            and read(outside) == "original", out .. " / " .. tostring(read(outside)))

        -- result.json / meta.json / options.json links are all refused.
        os.remove(dir .. "/result.json")
        os.execute('ln -s "' .. outside .. '" "' .. dir .. '/result.json"')
        out, code = run("cat --job " .. dir .. "/job.json --name result.json")
        data = decode_single_line(out)
        check("result.json 链接：cat 拒绝", code ~= 0 and data and data.ok == false
            and data.message == "result.json is a symlink", out)

        write_file(dir .. "/meta.json", '{"schema":"dualtranslate.job.meta.v1"}')
        os.remove(dir .. "/meta.json")
        os.execute('ln -s "' .. outside .. '" "' .. dir .. '/meta.json"')
        out, code = run("job-status --job " .. dir .. "/job.json")
        data = decode_single_line(out)
        check("meta.json 链接：job-status 拒绝", code ~= 0 and data and data.ok == false
            and data.message == "meta.json is a symlink", out)

        os.remove(dir .. "/meta.json")
        os.execute('ln -s "' .. outside .. '" "' .. dir .. '/options.json"')
        out, code = run("job-status --job " .. dir .. "/job.json")
        data = decode_single_line(out)
        check("options.json 链接：job-status 拒绝", code ~= 0 and data and data.ok == false
            and data.message == "options.json is a symlink", out)
        os.execute('rm -rf "' .. dir .. '"')

        -- A deleted job: cat keeps answering "exists=false" instead of a
        -- path error, which the PC's load_state relies on.
        local missing = DATA .. "/cache/dualtranslate/mcp/jobs/20261115_120000_9999"
        out, code = run("cat --job " .. missing .. "/job.json --name job.json")
        data = decode_single_line(out)
        check("cat 已删除任务返回 exists=false", code == 0 and data and data.ok == true
            and data.exists == false, out)
    end
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
