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

-- ffi/util stub（锁模块依赖 sleep/usleep/getTimestamp）：用 libc 提供
-- 真实亚秒睡眠与墙钟，保持计时断言语义；不依赖 KOReader 的 Lua 树。
local ffi = require("ffi")
pcall(ffi.cdef, [[
    int usleep(unsigned int usec);
    typedef struct { long tv_sec; int tv_usec; } dt_timeval;
    int gettimeofday(dt_timeval *tv, void *tz);
]])
local function wallclock()
    local tv = ffi.new("dt_timeval")
    ffi.C.gettimeofday(tv, nil)
    return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end
package.preload["ffi/util"] = function()
    return {
        sleep = function(sec) ffi.C.usleep(math.floor(sec * 1e6)) end,
        usleep = function(usec) ffi.C.usleep(math.floor(usec)) end,
        getTimestamp = wallclock,
    }
end

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
    local started = wallclock()
    local result, err = Lock.withBookLock(dir, function()
        error("must not run")
    end, { timeout = 0.2, interval = 0.02 })
    local elapsed = wallclock() - started
    check("占用时返回 nil + 错误", result == nil and type(err) == "string", tostring(err))
    check("错误信息含 timeout", err and err:find("timeout", 1, true) ~= nil, tostring(err))
    check("确实等待了（>=0.15s）", elapsed >= 0.15, string.format("%.3f", elapsed))
    check("超时按墙钟累计（<1s，睡眠不拉长超时）", elapsed < 1.0, string.format("%.3f", elapsed))
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
print("== 3b. stale 回收 TOCTOU：rmdir 前/后复检 ==")
do
    -- 场景 A：竞争者在本进程判定 stale 之后、rmdir 之前刷新了锁。
    -- 第二次 mtime 读取已看到新锁 → 绝不能 rmdir 抢占。
    local dir = ROOT .. "/stale_race_a"
    local lockdir = dir .. "/.lock"
    os.execute('mkdir -p "' .. lockdir .. '"')
    local old = os.time() - 301
    lfs.touch(lockdir, old, old)
    local real_attributes = lfs.attributes
    local reads = 0
    lfs.attributes = function(path, req)
        if path == lockdir and req == "modification" then
            reads = reads + 1
            if reads == 2 then
                local now = os.time()
                lfs.touch(lockdir, now, now)
                return now
            end
        end
        return real_attributes(path, req)
    end
    local ran = false
    local result, err = Lock.withBookLock(dir, function() ran = true end,
        { timeout = 0.2, interval = 0.02 })
    lfs.attributes = real_attributes
    check("rmdir 前复检：不抢占刚刷新的锁", not ran and result == nil and err ~= nil, tostring(err))
    check("竞争者的锁保留", isdir(lockdir))
    local mtime = lfs.attributes(lockdir, "modification")
    check("保留的是新锁（mtime 已刷新）", mtime and os.time() - mtime < 5, tostring(mtime))
    lfs.rmdir(lockdir)

    -- 场景 B：本进程 rmdir 成功后，竞争者立刻重建了新锁。
    -- rmdir 后复检发现锁目录又存在 → 回到等待循环直至超时。
    local dir_b = ROOT .. "/stale_race_b"
    local lockdir_b = dir_b .. "/.lock"
    os.execute('mkdir -p "' .. lockdir_b .. '"')
    lfs.touch(lockdir_b, old, old)
    local real_rmdir, real_mkdir = lfs.rmdir, lfs.mkdir
    local raced = false
    lfs.rmdir = function(path)
        local ok = real_rmdir(path)
        if ok and path == lockdir_b and not raced then
            raced = true
            real_mkdir(path)
            local marker = io.open(path .. "/owner", "w")
            marker:write("B")
            marker:close()
        end
        return ok
    end
    local ran_b = false
    local result_b, err_b = Lock.withBookLock(dir_b, function() ran_b = true end,
        { timeout = 0.2, interval = 0.02 })
    lfs.rmdir = real_rmdir
    check("rmdir 后复检：不覆盖竞争者的新锁", not ran_b and result_b == nil and err_b ~= nil, tostring(err_b))
    check("竞争者的新锁仍在（含标记）", isdir(lockdir_b)
        and io.open(lockdir_b .. "/owner", "rb") ~= nil)
    os.remove(lockdir_b .. "/owner")
    lfs.rmdir(lockdir_b)
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