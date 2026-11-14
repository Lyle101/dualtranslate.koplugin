-- ============================================================
-- State 第二层：loadConfig 迁移 + loadQueue 边界
-- ============================================================
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local DATA = "/tmp/dt_state_test"
os.execute("rm -rf " .. DATA)
os.execute("mkdir -p " .. DATA .. "/cache/dualtranslate")
os.execute("mkdir -p " .. DATA .. "/settings")

local settings_store = {}
package.preload["datastorage"] = function() return { getDataDir = function() return DATA end } end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(p, m)
            if m == "mode" then
                local f = io.open(p, "rb")
                if f then f:close(); return "file" end
                local d = io.open(p .. "/.", "rb")
                if d then d:close(); return "directory" end
                return nil
            end
            if m == "modification" then return os.time() end
            return nil
        end,
        mkdir = function() return true end, rmdir = function() return true end,
        remove = function() return true end, dir = function() end,
    }
end
package.preload["dump"] = function() return function(t)
    -- serialize minimal: "[n]=name"
    local parts = {}
    for i, v in ipairs(t) do parts[i] = string.format("[%d]={book_path=%q,status=%q}", i - 1, v.book_path, v.status) end
    return "{" .. table.concat(parts, ",") .. "}"
end end
package.preload["logger"] = function() return { warn = function() end, err = function() end, info = function() end } end
package.preload["ui/uimanager"] = function() return { show = function() end, close = function() end, setDirty = function() end } end
package.preload["ui/widget/notification"] = function() return { Notification = {} } end
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["device"] = function() return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } } end
package.preload["dualtranslate_tools"] = function()
    return { mkdir_p = function() return true end, rmtree = function() return true end,
        stable_path_hash = function() return "h" end }
end
_G.G_reader_settings = {
    readSetting = function(self, key) return settings_store[key] end,
    saveSetting = function(self, key, value) settings_store[key] = value end,
}
local State = dofile("dualtranslate_state.lua")

-- ============================================================
-- 1. loadConfig 迁移
-- ============================================================
print("== 1. loadConfig ==")
do
    -- 场景 A：新设置文件（settings/dualtranslate.lua）迁移 + 改名
    local f = io.open(DATA .. "/settings/dualtranslate.lua", "w")
    f:write("return { mode = 'microsoft_free', source_lang = 'en', target_lang = 'zh-Hans', unknown_key = 42 }")
    f:close()
    settings_store = {}
    State.loadConfig({ path = DATA .. "/plugin" })
    check("迁移 mode", settings_store["dualtranslate_mode"] == "microsoft_free")
    check("迁移 source_lang", settings_store["dualtranslate_source_lang"] == "en")
    check("迁移 target_lang", settings_store["dualtranslate_target_lang"] == "zh-Hans")
    check("迁移全部键", settings_store["dualtranslate_unknown_key"] == 42)
    local renamed = io.open(DATA .. "/settings/dualtranslate.lua.migrated", "rb")
    check("旧文件改名", renamed ~= nil)
    if renamed then renamed:close() end
    -- 场景 B：已存在的设置不覆盖
    settings_store["dualtranslate_mode"] = "system"
    local f2 = io.open(DATA .. "/settings/dualtranslate.lua", "w")
    f2:write("return { mode = 'microsoft_free' }")
    f2:close()
    State.loadConfig({ path = DATA .. "/plugin" })
    check("不覆盖已有键", settings_store["dualtranslate_mode"] == "system")
    -- 场景 C：损坏配置不崩溃、仍改名
    local f3 = io.open(DATA .. "/settings/dualtranslate.lua", "w")
    f3:write("this is not lua ===")
    f3:close()
    local ok = pcall(State.loadConfig, { path = DATA .. "/plugin" })
    check("损坏配置不崩溃", ok == true)
    check("损坏配置仍改名", io.open(DATA .. "/settings/dualtranslate.lua.migrated", "rb") ~= nil)
    -- 场景 D：无文件时无操作
    os.remove(DATA .. "/settings/dualtranslate.lua.migrated")
    local ok2 = pcall(State.loadConfig, { path = DATA .. "/plugin" })
    check("无文件无操作", ok2 == true)
end

-- ============================================================
-- 2. loadQueue 边界
-- ============================================================
print("== 2. loadQueue ==")
do
    -- 正常条目
    local f = io.open(State.getQueuePath(), "w")
    f:write([[
return {
    { book_path = "/b1.epub", status = "queued", all_chapters = true, current = 1, total = 2 },
    { book_path = "/b2.epub", status = "active", all_chapters = true, current = 1, total = 2 },
    { book_path = "/b3.epub", status = "failed", all_chapters = true, current = 1, total = 2, retry_count = 1 },
    { book_path = "/b4.epub", status = "failed", all_chapters = true, current = 1, total = 2, retry_count = 5 },
    { book_path = "/b5.epub", status = "failed", all_chapters = false, current = 1, total = 2 },
    { book_path = "/b6.epub", status = "done", all_chapters = true, current = 2, total = 2 },
    "corrupted entry",
    nil,
    { book_path = "/b1.epub", status = "failed", all_chapters = true, current = 1, total = 2, retry_count = 1 },
}
]])
    f:close()
    local queue = State.loadQueue()
    check("active→queued", queue[2] ~= nil and queue[2].status == "queued")
    -- 损坏条目丢弃
    local has_corrupt = false
    for _, item in ipairs(queue) do
        if type(item) ~= "table" then has_corrupt = true end
    end
    check("损坏条目丢弃", not has_corrupt)
    -- failed 整书 retry_count<2 重入队
    local b3 = nil
    for _, item in ipairs(queue) do
        if item.book_path == "/b3.epub" then b3 = item end
    end
    check("b3 重入队", b3 ~= nil and b3.status == "queued" and b3.retry_count == 1)
    -- retry_count>=2 保持 failed
    local b4 = nil
    for _, item in ipairs(queue) do
        if item.book_path == "/b4.epub" then b4 = item end
    end
    check("b4 保持 failed", b4 ~= nil and b4.status == "failed")
    -- 章节 failed 不自动重试
    local b5 = nil
    for _, item in ipairs(queue) do
        if item.book_path == "/b5.epub" then b5 = item end
    end
    check("b5 章节失败不重试", b5 ~= nil and b5.status == "failed")
    -- done 丢弃
    local has_done = false
    for _, item in ipairs(queue) do
        if item.book_path == "/b6.epub" then has_done = true end
    end
    check("done 丢弃", not has_done)
    -- 同书同模式的重复 failed 只重试一个
    local b1_count = 0
    for _, item in ipairs(queue) do
        if item.book_path == "/b1.epub" then b1_count = b1_count + 1 end
    end
    check("重复条目只保留一个", b1_count == 1)
    -- 文件不存在
    os.remove(State.getQueuePath())
    local empty = State.loadQueue()
    check("无文件返回空表", type(empty) == "table" and #empty == 0)
    -- 文件损坏
    local f2 = io.open(State.getQueuePath(), "w")
    f2:write("not lua at all {{{")
    f2:close()
    local empty2 = State.loadQueue()
    check("损坏文件返回空表", type(empty2) == "table" and #empty2 == 0)
end

-- ============================================================
-- 3. loadQueue 旧队列回填（13.4）
-- ============================================================
print("== 3. loadQueue 旧队列回填 ==")
do
    local f = io.open(State.getQueuePath(), "w")
    f:write([[
return {
    { book_path = "/old1.epub", status = "queued", fragment = "3", span = 2 },
    { book_path = "/old2.epub", status = "queued", all_chapters = true, fragment = "9", span = 4 },
    { book_path = "/old3.epub", status = "queued" },
    { book_path = "/old4.epub", status = "active", all_chapters = false, fragment = "2" },
    { book_path = "/old5.epub", status = "queued", all_chapters = true, provider = "system" },
    { book_path = "/old6.epub", status = "queued", all_chapters = false, fragment = "1", provider = "" },
    { book_path = "/old7.epub", status = "queued", chapter_indexes = { 2, 1 } },
}
]])
    f:close()
    local queue = State.loadQueue()
    local by_path = {}
    for _, item in ipairs(queue) do by_path[item.book_path] = item end
    local old1 = by_path["/old1.epub"]
    check("无 mode 有 fragment → span 任务", old1 ~= nil
        and old1.mode == "span" and old1.span == 2 and old1.fragment == "3"
        and old1.all_chapters == nil)
    check("无 provider 保持 nil（不回填当前 mode）", old1 ~= nil and old1.provider == nil)
    local old2 = by_path["/old2.epub"]
    check("整书任务清理 fragment/span", old2 ~= nil and old2.mode == "all"
        and old2.fragment == nil and old2.span == nil and old2.chapter_indexes == nil)
    local old3 = by_path["/old3.epub"]
    check("无法推断范围 → failed 并带错误提示", old3 ~= nil and old3.status == "failed"
        and type(old3.error) == "string" and #old3.error > 0)
    local old4 = by_path["/old4.epub"]
    check("章节任务缺 span 补默认 1", old4 ~= nil and old4.status == "queued"
        and old4.mode == "span" and old4.span == 1)
    local old5 = by_path["/old5.epub"]
    check("已有 provider 原样保留", old5 ~= nil and old5.provider == "system")
    local old6 = by_path["/old6.epub"]
    check("空串 provider 归一为 nil", old6 ~= nil and old6.provider == nil)
    local old7 = by_path["/old7.epub"]
    check("有 chapter_indexes → selection 任务", old7 ~= nil and old7.mode == "selection"
        and type(old7.chapter_indexes) == "table" and #old7.chapter_indexes == 2)
    os.remove(State.getQueuePath())
end

print(string.format("\n==== State 第二层结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
