-- ============================================================
-- CSS 缓存与 revision：entries/manifest revision 不一致必须失效重建，
-- 一致命中；provider/显示设置/fallback 切换重建；每书 1 条 + 8MB LRU。
-- Run: luajit tests/overlay_revision_test.lua
-- 用 KOReader 自带 lfs + json（真实 mtime/size）；缺失时跳过。
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

local ROOT = "/tmp/dt_overlay_revision_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Overlay = dofile(script_dir .. "/../dualtranslate_overlay.lua")

-- 统计 entries 文件被打开的次数：命中缓存时不应重新解析大文件
local real_open = io.open
local open_counts = {}
io.open = function(path, mode)
    if type(path) == "string" then
        open_counts[path] = (open_counts[path] or 0) + 1
    end
    return real_open(path, mode)
end
local function opens(path) return open_counts[path] or 0 end
local function resetOpens() open_counts = {} end

local case_no = 0
local function newBook(label, providers, display)
    case_no = case_no + 1
    local dir = string.format("%s/%02d_%s", ROOT, case_no, label)
    os.execute('mkdir -p "' .. dir .. '"')
    local manifest = {
        version = 3, book_path = "/books/x.epub", source_lang = "auto",
        target_lang = "zh-Hans", spine_count = 0, book_size = 0, book_mtime = 0,
        display_mode = "manual", display_provider = display,
        display_fallback = true, last_used_at = {}, fallback_order = {},
        providers = {},
    }
    for _, pid in ipairs(providers) do
        manifest.providers[pid] = {
            display_name = pid, kind = "mcp", chapters = {},
            partial_chapters = {}, failed_chapters = {}, complete = false,
            translated_count = 1, updated_at = 100, confirmed = true,
        }
        manifest.last_used_at[pid] = 100
        manifest.fallback_order[#manifest.fallback_order + 1] = pid
    end
    assert(Overlay.saveManifest(dir, manifest))
    return dir, dir .. "/manifest.json"
end

local function entry(selector, translation)
    return { selector = selector, translation = translation, source = "src" }
end

-- 把 mtime 推到 FAT32 粒度窗口之外，模拟「已稳定」的文件；
-- 窗口内的同尺寸改写必须重读 revision（见 buildCss 实现）。
local function age(path, seconds)
    local t = os.time() - (seconds or 10)
    assert(lfs.touch(path, t, t))
end

local VISIBLE = { translation_visible = true }

-- ============================================================
print("== 1. revision 一致 → 命中；entries 领先 → 重建 ==")
do
    local dir, mpath = newBook("revision", { "system" }, "system")
    Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "第一版") } })
    -- saveEntries 写 manifest.revision+1；再写 manifest 追平（正常收尾）
    local m = Overlay.loadManifest(dir)
    Overlay.saveManifest(dir, m)
    local epath = Overlay.entriesPath(dir, "system")
    check("初始 revision 对齐", Overlay.loadManifest(dir).revision
        == Overlay.loadEntries(dir, "system").revision)
    age(epath)

    resetOpens()
    local css1 = Overlay.buildCss(mpath, VISIBLE)
    check("首次构建读取 entries", opens(epath) >= 1)
    check("首次构建含译文", css1:find("第一版", 1, true) ~= nil)
    resetOpens()
    local css2 = Overlay.buildCss(mpath, VISIBLE)
    check("revision 一致且文件未变 → 命中", opens(epath) == 0, tostring(opens(epath)))
    check("命中返回相同 CSS", css2 == css1)

    -- 模拟导入：entries 先写（revision 领先），manifest 尚未更新。
    -- 同秒同尺寸改写：mtime+size 都不变，必须靠 revision 失效。
    Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "第二版") } })
    check("entries revision 领先 manifest", Overlay.loadEntries(dir, "system").revision
        > Overlay.loadManifest(dir).revision)
    resetOpens()
    local css3 = Overlay.buildCss(mpath, VISIBLE)
    check("revision 不一致 → 失效重建", opens(epath) >= 1)
    check("重建后是新译文", css3:find("第二版", 1, true) ~= nil
        and css3:find("第一版", 1, true) == nil)

    -- manifest 追平后内容未变 → 命中
    Overlay.saveManifest(dir, Overlay.loadManifest(dir))
    age(epath)
    Overlay.buildCss(mpath, VISIBLE)
    resetOpens()
    local css4 = Overlay.buildCss(mpath, VISIBLE)
    check("追平后命中", opens(epath) == 0 and css4 == css3)
end

-- ============================================================
print("== 2. manifest revision 单独推进也失效 ==")
do
    local dir, mpath = newBook("manifest_bump", { "system" }, "system")
    Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "译文") } })
    -- 先追平（max 不变不应触发重建），再单独推进 manifest
    Overlay.saveManifest(dir, Overlay.loadManifest(dir))
    local epath = Overlay.entriesPath(dir, "system")
    age(epath)
    Overlay.buildCss(mpath, VISIBLE)
    resetOpens()
    Overlay.buildCss(mpath, VISIBLE)
    check("追平且内容未变 → 命中", opens(epath) == 0)
    -- 只写 manifest（如显示切换），entries 不动
    Overlay.saveManifest(dir, Overlay.loadManifest(dir))
    resetOpens()
    Overlay.buildCss(mpath, VISIBLE)
    check("manifest revision 变化 → 重建", opens(epath) >= 1)
end

-- ============================================================
print("== 3. provider / 显示设置 / fallback 切换 ==")
do
    local dir, mpath = newBook("switch", { "system", "mcp:gpt-5" }, "system")
    Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "内置"), entry("p[2]", "内置二") } })
    Overlay.saveEntries(dir, "mcp:gpt-5", { entries = { entry("p[1]", "MCP") } })
    local sys_path = Overlay.entriesPath(dir, "system")
    local mcp_path = Overlay.entriesPath(dir, "mcp:gpt-5")
    age(sys_path)
    age(mcp_path)

    local css_sys = Overlay.buildCss(mpath, VISIBLE)
    resetOpens()
    local css_mcp = Overlay.buildCss(mpath, { translation_visible = true, provider = "mcp:gpt-5" })
    check("切换 provider → 重建", opens(mcp_path) >= 1)
    check("切换后只显示新 provider", css_mcp:find("MCP", 1, true) ~= nil
        and css_mcp:find("内置二", 1, true) ~= nil and css_sys ~= css_mcp)

    resetOpens()
    Overlay.buildCss(mpath, { translation_visible = true, provider = "mcp:gpt-5", fallback = false })
    check("fallback 开关影响 key → 重建", opens(mcp_path) >= 1)
    resetOpens()
    Overlay.buildCss(mpath, { translation_visible = true, provider = "mcp:gpt-5", fallback = false })
    check("fallback 关闭稳定命中", opens(mcp_path) == 0)
    check("fallback 关闭不加载其他 entries", opens(sys_path) == 0, tostring(opens(sys_path)))

    resetOpens()
    Overlay.buildCss(mpath, { translation_visible = true, translation_color = "#333333" })
    check("颜色变化 → 重建", opens(sys_path) >= 1)
    resetOpens()
    Overlay.buildCss(mpath, { translation_visible = true, translation_size = "0.8em" })
    check("字号变化 → 重建", opens(sys_path) >= 1)
    resetOpens()
    Overlay.buildCss(mpath, { translation_visible = true, translation_font_family = "serif" })
    check("字体变化 → 重建", opens(sys_path) >= 1)

    Overlay.clearCssCache()
    resetOpens()
    Overlay.buildCss(mpath, VISIBLE)
    check("clearCssCache 强制重建", opens(sys_path) >= 1)
end

-- ============================================================
print("== 4. 每书 1 条 + 全局 8MB LRU ==")
do
    -- 每书只保留最新一条：旧选项组合不再占用缓存
    local dir, mpath = newBook("per_book", { "system" }, "system")
    Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "译文") } })
    local epath = Overlay.entriesPath(dir, "system")
    age(epath)
    Overlay.buildCss(mpath, { translation_visible = true, translation_color = "#111111" })
    Overlay.buildCss(mpath, { translation_visible = true, translation_color = "#222222" })
    resetOpens()
    Overlay.buildCss(mpath, { translation_visible = true, translation_color = "#111111" })
    check("每书 1 条：回到旧选项需重建", opens(epath) >= 1)

    -- 两本大书超过 8MB → LRU 淘汰先前的书
    local big = string.rep("字", 1800000) -- ~5.4MB UTF-8
    local dir_a, mpath_a = newBook("big_a", { "system" }, "system")
    Overlay.saveEntries(dir_a, "system", { entries = { entry("p[1]", big) } })
    local dir_b, mpath_b = newBook("big_b", { "system" }, "system")
    Overlay.saveEntries(dir_b, "system", { entries = { entry("p[1]", big) } })
    local epath_a = Overlay.entriesPath(dir_a, "system")
    age(epath_a)
    age(Overlay.entriesPath(dir_b, "system"))
    local css_a = Overlay.buildCss(mpath_a, VISIBLE)
    check("大书 CSS 生成", #css_a > 5 * 1024 * 1024, tostring(#css_a))
    Overlay.buildCss(mpath_b, VISIBLE)
    resetOpens()
    Overlay.buildCss(mpath_b, VISIBLE)
    check("最近使用的书仍在缓存", opens(Overlay.entriesPath(dir_b, "system")) == 0)
    resetOpens()
    Overlay.buildCss(mpath_a, VISIBLE)
    check("超 8MB 淘汰最旧的书", opens(epath_a) >= 1)
end

print(string.format("\n==== revision 缓存测试：%d 通过，%d 失败 ====", passed, failed))
io.open = real_open
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
end
os.exit(failed == 0 and 0 or 1)