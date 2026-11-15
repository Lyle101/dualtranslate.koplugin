-- ============================================================
-- Live smoke test: the provider layer over the *real* network.
-- The 800+ assertions in the other suites all run against stubs, so a broken
-- Edge endpoint or a dead built-in engine would only surface on a device.
-- Guarded by DT_LIVE so CI / `make test` stays offline:
--
--   DT_LIVE=1 luajit tests/smoke_live.lua
--   DT_LIVE=1 KO_ROOT=/mnt/us/koreader luajit tests/smoke_live.lua   (on device)
--
-- Needs KOReader's own libraries (luasocket / json / ltn12) via KO_ROOT.
-- Unset DT_LIVE means "don't run it" -> SKIP, exit 0.  Set DT_LIVE=1 means
-- "run it": a KOReader install that cannot be loaded is then a FAILURE, not a
-- skip, so CI can never report a false green.  The built-in engine still only
-- reports SKIP where ui/translator cannot load (headless / macOS SDL build).
-- ============================================================
local SRC, DST = "en", "zh-Hans"
local TEXT = "Hello world."
local TEXT2 = "Good morning."

if os.getenv("DT_LIVE") ~= "1" then
    print("SKIP: live smoke test makes real HTTP calls, set DT_LIVE=1 to run it")
    os.exit(0)
end

-- DT_LIVE=1 was explicit, so an unusable environment must fail loudly.
local function fail_env(message)
    print("FAIL: " .. message)
    print("FAIL: DT_LIVE=1 was requested, so a missing environment is a failure, not a skip")
    os.exit(1)
end

local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"

local function absolute_dir(path)
    if path:sub(1, 1) == "/" then return path end
    local pipe = io.popen("cd '" .. path .. "' 2>/dev/null && pwd")
    local resolved = pipe and pipe:read("*l")
    if pipe then pipe:close() end
    return resolved or path
end

local script_dir = absolute_dir((arg and arg[0] or ""):match("^(.*)/") or ".")
KO = absolute_dir(KO)

-- setupkoenv installs *relative* search paths ("common/?.lua", "common/?.so"),
-- exactly as reader.lua relies on when it runs from the KOReader directory.
local ffi = require("ffi")
ffi.cdef[[int chdir(const char *path);]]
if ffi.C.chdir(KO) ~= 0 then
    fail_env("KOReader install not found at " .. KO .. " (set KO_ROOT)")
end

package.path = script_dir .. "/?.lua;" .. script_dir .. "/../?.lua;"
    .. KO .. "/?.lua;" .. KO .. "/common/?.lua;" .. KO .. "/common/?/init.lua;"
    .. package.path

local ok_setup, setup_err = pcall(require, "setupkoenv")
if not ok_setup then
    fail_env("KOReader libraries not loadable from " .. KO
        .. " (" .. tostring(setup_err) .. ")")
end

-- Headless run: KOReader's shell normally owns these globals.
_G.G_reader_settings = _G.G_reader_settings or {
    readSetting = function() return nil end,
    saveSetting = function() end,
    delSetting = function() end,
    has = function() return false end,
    isTrue = function() return false end,
    nilOrTrue = function() return nil end,
    makeTrue = function() end,
    makeFalse = function() end,
    flush = function() end,
}

local ok_providers, Providers = pcall(require, "dualtranslate_providers")
if not ok_providers then
    -- On the macOS desktop build this is where it stops: providers ->
    -- socketutil -> device -> SDL device without a window.  Run it on a device.
    fail_env("providers module not loadable (" .. tostring(Providers) .. ")")
end

local ok_socket, socket = pcall(require, "socket")
local now = (ok_socket and socket and socket.gettime)
    and function() return socket.gettime() * 1000 end
    or function() return os.clock() * 1000 end

local passed, failed, skipped = 0, 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("  PASS:\t" .. name)
    else
        failed = failed + 1
        print("  FAIL:\t" .. name .. (detail and ("  ← " .. tostring(detail)) or ""))
    end
end

-- A real translation is a non-empty string that is not just an echo.
local function looks_translated(original, translated)
    if type(translated) ~= "string" or translated == "" then return false end
    return translated ~= original
end

print("== provider live smoke (" .. KO .. ") ==")
print(string.format("   src=%s dst=%s text=%q", SRC, DST, TEXT))

local function timed(fn, ...)
    local t0 = now()
    local a, b = fn(...)
    return a, b, now() - t0
end

-- 1) Microsoft Edge free endpoint, single text
do
    local result, err, ms = timed(Providers.translate, "microsoft_free", TEXT, SRC, DST)
    local text = result and result.translated_text
    print(string.format("   microsoft_free single: %.0f ms  %q  %s", ms, tostring(text),
        result and tostring(result.provider) or tostring(err and err.message)))
    check("microsoft_free 返回非空译文", looks_translated(TEXT, text), err and err.message)
    check("microsoft_free provider 字段一致", result and result.provider == "microsoft_free")
end

-- 2) the same endpoint's native batch path (整书翻译实际走这条)
do
    local result, err, ms = timed(Providers.translate_microsoft_free_batch,
        { TEXT, TEXT2 }, SRC, DST)
    print(string.format("   microsoft_free batch : %.0f ms  %s", ms,
        result and table.concat(result, " | ") or tostring(err and err.message)))
    check("批量翻译返回且条数一致", type(result) == "table" and #result == 2,
        err and err.message)
    check("批量译文都非空",
        type(result) == "table" and looks_translated(TEXT, result[1])
            and looks_translated(TEXT2, result[2]))
end

-- 3) KOReader built-in engine (Google by default) through ui/translator.
-- ui/translator pulls in UIManager/TextViewer, so it only loads inside a real
-- reader process; headless runs report SKIP instead of a misleading FAIL.
local ok_translator, translator_err = pcall(require, "ui/translator")
if not ok_translator then
    skipped = skipped + 1
    print("   system          single: SKIP headless（ui/translator 加载失败："
        .. tostring(translator_err) .. "）")
    print("   note: 内置引擎只能在 KOReader 进程内验证（Picker 里选 system 翻一段即可）")
else
    local result, err, ms = timed(Providers.translate, "system", TEXT, SRC, DST)
    local text = result and result.translated_text
    print(string.format("   system          single: %.0f ms  %q  %s", ms, tostring(text),
        result and tostring(result.provider) or tostring(err and err.message)))
    check("system 返回非空译文", looks_translated(TEXT, text), err and err.message)
    check("system provider 字段一致", result and result.provider == "system")
end

-- 4) negative path: an unknown provider must not silently hit the network
do
    local result, err = Providers.translate("nope_not_a_provider", TEXT, SRC, DST)
    check("未知引擎直接报错", result == nil and type(err) == "table" and err.message ~= nil)
end

print(string.format("\n==== live smoke 结果：%d 通过，%d 失败，%d 跳过 ====", passed, failed, skipped))
os.exit(failed == 0 and 0 or 1)
