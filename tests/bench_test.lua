-- ============================================================
-- tools/bench.lua 的 CLI 边界：--work 拒绝、--only 校验、.dtbench 清理、
-- --overlay 冒烟（四段中位数输出）。
-- Run: luajit tests/bench_test.lua
-- 需要 KOReader 运行时（lfs / json / lua-ljsqlite3）；缺失时跳过。
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
package.path = KO .. "/?.lua;" .. KO .. "/common/?.lua;"
    .. KO .. "/common/?/init.lua;" .. package.path
package.cpath = KO .. "/?.so;" .. KO .. "/?.dylib;" .. package.cpath
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_json = pcall(require, "json")
local ok_ffi, ffi = pcall(require, "ffi")
local ok_sqlite = false
if ok_ffi then
    if not ffi.loadlib then ffi.loadlib = function(name) return ffi.load(name) end end
    ok_sqlite = pcall(require, "lua-ljsqlite3")
end
if not ok_lfs or not ok_json or not ok_sqlite then
    print("SKIP: libkoreader-lfs / json / ffi / lua-ljsqlite3 unavailable"); os.exit(0)
end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local ROOT = "/tmp/dt_bench_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local BENCH = script_dir .. "/../tools/bench.lua"
-- arg[-1] is the interpreter this suite is running under; CI invokes
-- $KO_ROOT/luajit explicitly, while a custom layout may place it elsewhere.
local LUAJIT = arg and arg[-1] or (KO .. "/luajit")
local Overlay = dofile(script_dir .. "/../dualtranslate_overlay.lua")

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Bench writes its own exit code after the output so the harness does not
-- depend on Lua 5.1's encoded os.execute() status.
local function run(args)
    local command = quote(LUAJIT) .. " " .. quote(BENCH) .. " " .. args
        .. " 2>&1; echo DT_EXIT:$?"
    local pipe = assert(io.popen(command, "r"))
    local output = pipe:read("*a") or ""
    pipe:close()
    local code = tonumber(output:match("DT_EXIT:(%d+)%s*$")) or -1
    output = output:gsub("DT_EXIT:%d+%s*$", "")
    return code, output
end

local function exists(path)
    return lfs.attributes(path) ~= nil
end

local function mkdir(path)
    os.execute("mkdir -p " .. quote(path))
end

local function write_file(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

mkdir(ROOT .. "/empty")
mkdir(ROOT .. "/foreign")
write_file(ROOT .. "/foreign/keep.txt", "not a bench directory\n")

-- ============================================================
print("== 1. --work 边界 ==")
do
    local code, out = run("--work / --list --list-dir " .. quote(ROOT .. "/empty"))
    check("拒绝根目录 --work", code == 2 and out:find("拒绝 --work", 1, true) ~= nil,
        "code=" .. tostring(code) .. " out=" .. out:sub(1, 120))

    code, out = run("--work " .. quote(KO) .. " --list --list-dir " .. quote(ROOT .. "/empty"))
    check("拒绝与 KO_ROOT 重叠", code == 2 and out:find("拒绝 --work", 1, true) ~= nil,
        "code=" .. tostring(code))

    code, out = run("--work " .. quote(ROOT .. "/foreign") .. " --list --list-dir "
        .. quote(ROOT .. "/empty"))
    check("拒绝非空且无标记的目录", code == 2
        and out:find("没有 .dtbench 标记", 1, true) ~= nil, "code=" .. tostring(code))

    local owned = ROOT .. "/owned"
    mkdir(owned .. "/data/some")
    mkdir(owned .. "/css/some")
    write_file(owned .. "/.dtbench", "dualtranslate bench work dir\n")
    code, out = run("--work " .. quote(owned) .. " --list --list-dir " .. quote(ROOT .. "/empty"))
    check("标记目录允许运行", code == 0, "code=" .. tostring(code) .. " out=" .. out:sub(1, 120))
    check("清理 data/ 与 css/", not exists(owned .. "/data") and not exists(owned .. "/css"))
    check("保留 .dtbench 标记", exists(owned .. "/.dtbench"))

    local kept = ROOT .. "/kept"
    mkdir(kept .. "/data/some")
    mkdir(kept .. "/css/some")
    write_file(kept .. "/.dtbench", "dualtranslate bench work dir\n")
    code = run("--work " .. quote(kept) .. " --list --list-dir " .. quote(ROOT .. "/empty")
        .. " --keep")
    check("--keep 保留夹具", code == 0 and exists(kept .. "/data") and exists(kept .. "/css"))
end

-- ============================================================
print("== 2. --only 校验 ==")
do
    local code, out = run("--only nope")
    check("未知指标退出 2", code == 2 and out:find("未知指标", 1, true) ~= nil,
        "code=" .. tostring(code))

    code, out = run("--only ,")
    check("空指标列表退出 2", code == 2
        and out:find("至少要给一个指标", 1, true) ~= nil, "code=" .. tostring(code))
end

-- ============================================================
print("== 3. --overlay 冒烟 ==")
do
    local directory = ROOT .. "/overlay"
    local manifest = {
        version = 3, book_path = ROOT .. "/book.epub", source_lang = "en",
        target_lang = "zh-Hans", spine_count = 2, book_size = 1, book_mtime = 0,
        display_mode = "manual", display_provider = "mcp:bench",
        display_fallback = false, last_used_at = {}, fallback_order = { "mcp:bench" },
        providers = {
            ["mcp:bench"] = {
                display_name = "Bench", kind = "mcp", confirmed = true,
                chapters = {}, partial_chapters = {}, failed_chapters = {},
                complete = false, translated_count = 3, updated_at = 0,
            },
        },
    }
    assert(Overlay.saveManifest(directory, manifest))
    assert(Overlay.saveEntries(directory, "mcp:bench", {
        target_lang = "zh-Hans",
        entries = {
            { selector = "p[1]", translation = "第一段", source = "one" },
            { selector = "p[2]", translation = "第二段", source = "two" },
            { selector = "p[3]", translation = "第三段", source = "three" },
        },
    }))
    -- Prewarm like an import does, then verify bench restores this exact
    -- production template instead of leaving one built for its own options.
    assert(Overlay.warmCssTemplate(directory))
    local template_path = directory .. "/css-template.css"
    local original_template = read_file(template_path)
    local code, out = run("--overlay " .. quote(directory) .. " --runs 2")
    check("overlay 退出 0", code == 0, "code=" .. tostring(code) .. " out=" .. out:sub(1, 160))
    check("输出四段场景", out:find("冷启动（模板命中）", 1, true) ~= nil
        and out:find("冷构建（无模板，含解码）", 1, true) ~= nil
        and out:find("样式变化（模板替换）", 1, true) ~= nil
        and out:find("同参数命中", 1, true) ~= nil)
    check("报告 3 条规则", out:find("| 3 |", 1, true) ~= nil)
    check("基准后恢复原模板", read_file(template_path) == original_template)

    local empty = ROOT .. "/not_overlay"
    mkdir(empty)
    code, out = run("--overlay " .. quote(empty) .. " --runs 1")
    check("非 v3 目录退出 2", code == 2
        and out:find("不是 v3 overlay 目录", 1, true) ~= nil, "code=" .. tostring(code))
end

-- ============================================================
print("== 5. 验收补齐模式 ==")
do
    local work = ROOT .. "/migrate_work"
    local code, out = run("--migrate --rows 500 --runs 1 --work " .. quote(work))
    check("--migrate 退出 0", code == 0,
        "code=" .. tostring(code) .. " out=" .. out:sub(1, 200))
    check("--migrate 报告行数", out:find("500 行", 1, true) ~= nil)
    check("--migrate 报告备份复制", out:find(".bak 复制约", 1, true) ~= nil)
    check("--migrate 清掉基准库",
        not exists(work .. "/data/dualtranslate_cache.sqlite3"))

    local memory_work = ROOT .. "/memory_work"
    code, out = run("--memory --css-segments 60 --work " .. quote(memory_work))
    check("--memory 退出 0", code == 0,
        "code=" .. tostring(code) .. " out=" .. out:sub(1, 200))
    check("--memory 三种形态", out:find("single", 1, true) ~= nil
        and out:find("fallback-split", 1, true) ~= nil
        and out:find("fallback-full", 1, true) ~= nil)
    check("--memory 清掉夹具", not exists(memory_work .. "/mem"))
end

print(string.format("\n==== bench CLI 测试：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
end
os.exit(failed == 0 and 0 or 1)
