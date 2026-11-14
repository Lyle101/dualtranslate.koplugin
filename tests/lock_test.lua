-- ============================================================
-- Book lock：互斥 / 超时 / stale 回收 / 抛错解锁 / 返回值透传
-- Run: luajit tests/lock_test.lua
-- 需要真实文件系统语义（mkdir/rename/mtime），用 KOReader 自带 lfs；
-- 缺失时跳过。
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
package.cpath = KO .. "/?.so;" .. KO .. "/?.dylib;" .. package.cpath
local ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok then print("SKIP: libkoreader-lfs unavailable"); os.exit(0) end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local ROOT = "/tmp/dt_lock_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Lock = dofile(script_dir .. "/../dualtranslate_lock.lua")

local function isdir(path) return lfs.attributes(path, "mode") == "directory" end

-- ============================================================
print("== 1. 基本持锁 / 返回值透传 ==")
do
    local dir = ROOT .. "/basic/deep/nested"
    local a, b, c = Lock.withBookLock(dir, function()
        check("fn 执行时锁目录存在", isdir(dir .. "/.lock"))
        return 1, nil, "x"
    end)
    check("自动创建多级目录", isdir(dir))
    check("返回值透传（含 nil）", a == 1 and b == nil and c == "x")
    check("结束后锁目录移除", not isdir(dir .. "/.lock"))

    local n = select("#", Lock.withBookLock(dir, function() return nil, nil end))
    check("尾部 nil 不丢", n == 2, tostring(n))

    local no_ret = Lock.withBookLock(dir, function() end)
    check("无返回值返回 nil", no_ret == nil)
end

-- ============================================================
print("== 2. 互斥：锁被占用时等待并超时 ==")
do
    local dir = ROOT .. "/busy"
    os.execute('mkdir -p "' .. dir .. '/.lock"')
    local started = os.clock()
    local result, err = Lock.withBookLock(dir, function()
        error("must not run")
    end, { timeout = 0.2, interval = 0.02 })
    local elapsed = os.clock() - started
    check("占用时返回 nil + 错误", result == nil and type(err) == "string", tostring(err))
    check("错误信息含 timeout", err and err:find("timeout", 1, true) ~= nil, tostring(err))
    check("确实等待了（>=0.15s）", elapsed >= 0.15, string.format("%.3f", elapsed))
    check("不偷锁：锁目录仍在", isdir(dir .. "/.lock"))
    lfs.rmdir(dir .. "/.lock")
    local ran = false
    local after = Lock.withBookLock(dir, function() ran = true return true end,
        { timeout = 0.2, interval = 0.02 })
    check("释放后可获取", ran and after == true)
end

-- ============================================================
print("== 3. stale 回收（300 秒阈值，伪造 mtime） ==")
do
    local dir = ROOT .. "/stale"
    os.execute('mkdir -p "' .. dir .. '/.lock"')
    local old = os.time() - 301
    lfs.touch(dir .. "/.lock", old, old)
    local ran = false
    local result = Lock.withBookLock(dir, function() ran = true return "ok" end,
        { timeout = 0.3, interval = 0.02 })
    check("超过 300s 的锁被回收", ran and result == "ok")
    check("回收后正常释放", not isdir(dir .. "/.lock"))

    os.execute('mkdir -p "' .. dir .. '/.lock"')
    local recent = os.time() - 299
    lfs.touch(dir .. "/.lock", recent, recent)
    local result2, err2 = Lock.withBookLock(dir, function() error("must not run") end,
        { timeout = 0.15, interval = 0.02 })
    check("299s 的锁不算 stale", result2 == nil and err2 ~= nil)
    lfs.rmdir(dir .. "/.lock")

    -- 可配置 stale 阈值：等待中锁变 stale 后获取
    os.execute('mkdir -p "' .. dir .. '/.lock"')
    local edge = os.time() - 2
    lfs.touch(dir .. "/.lock", edge, edge)
    local ran3 = false
    local result3 = Lock.withBookLock(dir, function() ran3 = true return true end,
        { timeout = 1, interval = 0.05, stale_seconds = 1 })
    check("自定义 stale_seconds 生效", ran3 and result3 == true)
end

-- ============================================================
print("== 4. fn 抛错：解锁并透传错误 ==")
do
    local dir = ROOT .. "/error"
    local ok, err = pcall(Lock.withBookLock, dir, function()
        check("抛错前锁存在", isdir(dir .. "/.lock"))
        error("boom")
    end)
    check("错误被透传", not ok and tostring(err):find("boom", 1, true) ~= nil, tostring(err))
    check("抛错后锁已释放", not isdir(dir .. "/.lock"))
    local ran = false
    Lock.withBookLock(dir, function() ran = true end)
    check("抛错后可再次持锁", ran)

    -- 表错误对象也原样透传
    local sentinel = {}
    local ok2, err2 = pcall(Lock.withBookLock, dir, function() error(sentinel) end)
    check("表错误对象原样透传", not ok2 and err2 == sentinel)
end

-- ============================================================
print("== 5. 参数边界 ==")
do
    local result, err = Lock.withBookLock(nil, function() end)
    check("缺目录返回 nil + 错误", result == nil and err ~= nil)
    local result2, err2 = Lock.withBookLock("", function() end)
    check("空目录返回 nil + 错误", result2 == nil and err2 ~= nil)
end

print(string.format("\n==== 锁测试：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
end
os.exit(failed == 0 and 0 or 1)