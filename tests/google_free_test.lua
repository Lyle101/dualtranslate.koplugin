-- ============================================================
-- google_free provider: request shape, the three response shapes, batching
-- and the 429 path.  Pure Lua with a fake HTTP layer (no KOReader, no network).
-- Run: luajit tests/google_free_test.lua
-- ============================================================
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("  PASS:\t" .. name)
    else
        failed = failed + 1
        print("  FAIL:\t" .. name .. (detail and ("  ← " .. tostring(detail)) or ""))
    end
end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
package.path = script_dir .. "/../?.lua;" .. package.path

-- ---- fake HTTP layer -------------------------------------------------------
-- Each request pops one queued response.  `payload` is handed to json.decode as
-- if it had been parsed from the body, so the tests can describe the response
-- the way Google actually shapes it.
local requests, queue, payload = {}, {}, nil
local function respond(status, body)
    queue[#queue + 1] = { status = status, body = body }
end

package.preload["socket.http"] = function()
    return { request = function(req)
        requests[#requests + 1] = { url = req.url, body = req.source, headers = req.headers }
        local resp = table.remove(queue, 1) or { status = 200, body = {} }
        payload = resp.body
        if type(resp.body) == "string" then
            req.sink(resp.body)
        end
        req.sink(nil)
        return 1, resp.status, {}, "HTTP " .. tostring(resp.status)
    end }
end
package.preload["ltn12"] = function()
    return {
        source = { string = function(s) return s end },
        sink = { table = function(t)
            return function(chunk) if chunk then t[#t + 1] = chunk end end
        end },
    }
end
package.preload["json"] = function()
    return {
        encode = function() return "" end,
        decode = function() return payload end,
    }
end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end }
end
package.preload["socket"] = function() return { sleep = function() end } end
package.preload["socket.url"] = function()
    return { escape = function(value)
        return (tostring(value):gsub("[^%w%-%._~]", function(c)
            return string.format("%%%02X", string.byte(c))
        end))
    end }
end
package.preload["logger"] = function()
    return { warn = function() end, err = function() end, info = function() end }
end
package.preload["gettext"] = function() return function(s) return s end end

local Providers = dofile(script_dir .. "/../dualtranslate_providers.lua")

-- ============================================================
print("== 1. 请求形状 ==")
do
    respond(200, { { "你好世界。", "en" } })
    local res, err = Providers.translate("google_free", "Hello world.", "en", "zh-Hans")
    check("单段返回译文", res and res.translated_text == "你好世界。", tostring(err and err.message))
    check("provider 字段为 google_free", res and res.provider == "google_free")

    local req = requests[#requests]
    check("POST 到 translate_a/t", req.body ~= nil)
    check("URL 带 client=gtx 与 dt=t",
        req.url:find("client=gtx", 1, true) ~= nil and req.url:find("dt=t", 1, true) ~= nil,
        req.url)
    check("sl 归一化后为 en", req.url:find("&sl=en", 1, true) ~= nil, req.url)
    check("tl 归一化 zh-Hans → zh", req.url:find("&tl=zh", 1, true) ~= nil, req.url)
    check("q= 走 body 且已转义", req.body == "q=Hello%20world.", req.body)
    check("Content-Type 为表单",
        req.headers and req.headers["Content-Type"] == "application/x-www-form-urlencoded")
end

-- ============================================================
print("== 2. 响应三态 ==")
do
    local cases = {
        { name = "[译文, 语言] 数组对", body = { { "甲", "en" } }, want = "甲" },
        { name = "[译文] 单元素数组", body = { { "乙" } }, want = "乙" },
        { name = "裸字符串", body = { "丙" }, want = "丙" },
        -- 单段被压平成 ["译文", "en"]（不再包一层），严格数条会把它判成 2 ≠ 1
        { name = "压平的 [译文, 语言]", body = { "丁", "en" }, want = "丁" },
    }
    for _, case in ipairs(cases) do
        respond(200, case.body)
        local out = Providers.translate_google_free("x", "auto", "zh-Hans")
        check("解析" .. case.name, out and out.translated_text == case.want,
            out and out.translated_text)
    end

    respond(200, { { "" } })
    local empty = Providers.translate_google_free("x", "auto", "zh-Hans")
    check("空译文视为失败", empty == nil)

    respond(200, { { "一", "en" }, { "二", "en" } })
    local mismatch, mismatch_err = Providers.translate_google_free("x", "auto", "zh-Hans")
    check("条数不符整组失败", mismatch == nil
        and mismatch_err and mismatch_err.message:find("条数", 1, true) ~= nil,
        mismatch_err and mismatch_err.message)

    respond(200, "not json at all")
    local broken = Providers.translate_google_free("x", "auto", "zh-Hans")
    check("非 JSON 报错", broken == nil)
end

-- ============================================================
print("== 3. 429：退避一次后重试 ==")
do
    requests = {}
    respond(429, "<html>Sorry...</html>")
    respond(200, { { "你好", "en" } })
    local out, err = Providers.translate_google_free_batch({ "hello" }, "en", "zh-Hans",
        { retry_delay = 0 })
    check("429 后重试成功", out and out[1] == "你好", tostring(err and err.message))
    check("429 恰好重试一次", #requests == 2, tostring(#requests))

    requests = {}
    respond(429, "<html>Sorry...</html>")
    respond(429, "<html>Sorry...</html>")
    local limited, limited_err = Providers.translate_google_free_batch({ "hello" }, "en", "zh-Hans",
        { retry_delay = 0 })
    check("连续 429 返回错误", limited == nil)
    check("错误码 429", limited_err and limited_err.code == 429, limited_err and limited_err.code)
    check("提示限流并指路 Edge",
        limited_err and limited_err.message:find("限流", 1, true) ~= nil
            and limited_err.message:find("Edge", 1, true) ~= nil,
        limited_err and limited_err.message)
    check("不会无限重试", #requests == 2, tostring(#requests))

    requests = {}
    respond(500, "boom")
    local failed500, err500 = Providers.translate_google_free_batch({ "hello" }, "en", "zh-Hans",
        { retry_delay = 0 })
    check("500 不重试", failed500 == nil and #requests == 1, tostring(#requests))
    check("500 报 HTTP 状态", err500 and err500.message:find("500", 1, true) ~= nil,
        err500 and err500.message)
end

-- ============================================================
print("== 4. 切组边界 ==")
do
    local limits = Providers.batch_limits("google_free")
    check("google_free 声明支持批量", Providers.has_batch("google_free"))
    check("system 不支持批量", not Providers.has_batch("system"))
    check("限额 12 段 / 4000 字节", limits and limits.items == 12 and limits.bytes == 4000)

    local many = {}
    for index = 1, 13 do many[index] = "t" end
    local groups = Providers.split_groups(many, limits)
    check("13 段切成 12 + 1", #groups == 2 and #groups[1] == 12 and #groups[2] == 1,
        #groups .. ":" .. tostring(groups[2] and #groups[2]))

    local big = { string.rep("a", 2000), string.rep("a", 2000), string.rep("a", 2000) }
    local big_groups = Providers.split_groups(big, limits)
    check("4 KB 按字节切组", #big_groups == 2 and #big_groups[1] == 2 and #big_groups[2] == 1,
        #big_groups)

    local one_huge = { string.rep("a", 9000) }
    local huge_groups = Providers.split_groups(one_huge, limits)
    check("超长单段自成一组", #huge_groups == 1 and #huge_groups[1] == 1)

    respond(200, { { "一", "en" }, { "二", "en" } })
    local batched = Providers.translate_batch("google_free", { "aa", "bb" }, "en", "zh-Hans")
    check("translate_batch 分发到 google_free",
        type(batched) == "table" and batched[1] == "一" and batched[2] == "二")
    check("批量 body 带两个 q=", requests[#requests].body == "q=aa&q=bb",
        requests[#requests].body)

    local unsupported = Providers.translate_batch("system", { "a" }, "en", "zh")
    check("不支持批量的引擎返回 nil", unsupported == nil)
end

-- ============================================================
print("== 5. 引擎列表 ==")
do
    local ids = {}
    for _, provider in ipairs(Providers.list) do ids[#ids + 1] = provider.id end
    check("列表含四个引擎", #ids == 4 and ids[1] == "system" and ids[2] == "microsoft_free"
        and ids[3] == "google_free" and ids[4] == "mcp_external", table.concat(ids, ","))
    local google = Providers.getProviderById("google_free")
    check("google_free 有菜单提示", google and type(google.hint) == "string" and #google.hint > 0)
    check("菜单名保持简短", google and google.name == "Google（免费）", google and google.name)
    -- 菜单行放不下就会截断成「需…」，system 那行压到最短可用形式
    local system = Providers.getProviderById("system")
    check("system 提示已压短", system and system.hint == "跟随 KOReader 设置 · 需 Google",
        system and system.hint)
end

print(string.format("\n==== google_free 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
