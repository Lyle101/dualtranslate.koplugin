-- ============================================================
-- Overlay v3 按章 CSS：chapter_index 过滤 / 无 chapter_index 的历史行 /
-- 缓存键按章隔离
-- Run: luajit tests/overlay_chapter_test.lua
-- 需要真实文件系统语义，用 KOReader 自带 lfs + json；缺失时跳过。
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
package.path = KO .. "/common/?.lua;" .. KO .. "/common/?/init.lua;" .. package.path
package.cpath = KO .. "/?.so;" .. KO .. "/?.dylib;" .. package.cpath
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_json, JSON = pcall(require, "json")
if not ok_lfs or not ok_json then
    print("SKIP: libkoreader-lfs / json unavailable"); os.exit(0)
end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local ROOT = "/tmp/dt_overlay_chapter_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local data_dir = ROOT .. "/data"
os.execute('mkdir -p "' .. data_dir .. '"')
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
    end }
end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Overlay = dofile(script_dir .. "/../dualtranslate_overlay.lua")

local PROVIDER = "mcp:bench-a"
local dir = ROOT .. "/book"
local manifest = {
    version = 3, revision = 0, book_path = ROOT .. "/book.epub",
    source_lang = "en", target_lang = "zh-Hans",
    spine_count = 3, book_size = 1, book_mtime = 0,
    display_mode = "manual", display_provider = PROVIDER,
    display_fallback = false,
    last_used_at = {}, fallback_order = { PROVIDER },
    providers = {
        [PROVIDER] = {
            display_name = "Bench", kind = "mcp", confirmed = true,
            chapters = {}, partial_chapters = {}, failed_chapters = {},
            complete = false, translated_count = 0, updated_at = 0,
        },
    },
}
check("manifest 写入", Overlay.saveManifest(dir, manifest))

local entries = {}
for chapter = 1, 3 do
    for paragraph = 1, 2 do
        entries[#entries + 1] = {
            selector = string.format(
                'DocFragment[Source="ch%d.xhtml"] > body > p:nth-of-type(%d)',
                chapter, paragraph),
            xpointer = string.format("/body/DocFragment[%d]/body/p[%d]", chapter, paragraph),
            chapter_index = chapter,
            source = string.format("chapter %d paragraph %d", chapter, paragraph),
            translation = string.format("第 %d 章第 %d 段", chapter, paragraph),
        }
    end
end
-- 旧版行没有 chapter_index：任何一章都不能把它藏起来。
entries[#entries + 1] = {
    selector = "/body/DocFragment[1]/body/p[9]",
    xpointer = "/body/DocFragment[1]/body/p[9]",
    source = "legacy paragraph",
    translation = "旧版段落",
}
check("entries 写入", Overlay.saveEntries(dir, PROVIDER, {
    target_lang = "zh-Hans", entries = entries,
}))

local function build(chapter_index)
    return Overlay.buildCss(dir, {
        translation_visible = true,
        translation_provider = PROVIDER,
        provider = PROVIDER,
        fallback = false,
        chapter_index = chapter_index,
    })
end
local function rule_count(css)
    return select(2, css:gsub("content:", ""))
end

local full = build(nil)
check("全书 7 条规则", rule_count(full) == 7, tostring(rule_count(full)))
check("全书含三章译文", full:find("第 1 章", 1, true) ~= nil
    and full:find("第 2 章", 1, true) ~= nil and full:find("第 3 章", 1, true) ~= nil)

local second = build(2)
check("第 2 章 3 条规则（2 + 历史行）", rule_count(second) == 3,
    tostring(rule_count(second)))
check("第 2 章只含本章译文", second:find("第 2 章第 1 段", 1, true) ~= nil
    and second:find("第 2 章第 2 段", 1, true) ~= nil
    and second:find("第 1 章", 1, true) == nil and second:find("第 3 章", 1, true) == nil)
check("历史行始终保留", second:find("旧版段落", 1, true) ~= nil)

local third = build(3)
check("第 3 章与第 2 章不同", third ~= second)
check("第 3 章只含本章译文", third:find("第 3 章", 1, true) ~= nil
    and third:find("第 2 章", 1, true) == nil)

local empty = build(9)
check("无译文章节只剩历史行", rule_count(empty) == 1, tostring(rule_count(empty)))

-- 单槽 css 缓存：先全书、再第 2 章、再全书，第三次必须还是全书。
local again = build(nil)
check("缓存键按章隔离，全书不被按章结果顶掉", rule_count(again) == 7,
    tostring(rule_count(again)))

print(string.format("\n==== overlay chapter 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
