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

-- 统计 loadEntries 的调用次数（按 provider）：CSS 命中时不应走到 entries
-- 加载；解析缓存自身的命中/失效由 overlay_entries_cache_test 覆盖。
local real_load = Overlay.loadEntries
local load_counts = {}
Overlay.loadEntries = function(dir, provider_id)
    load_counts[provider_id] = (load_counts[provider_id] or 0) + 1
    return real_load(dir, provider_id)
end
local function loads(provider_id) return load_counts[provider_id] or 0 end
local function resetLoads() load_counts = {} end
local function stats() return Overlay.cacheStats() end

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

    resetLoads()
    local css1 = Overlay.buildCss(mpath, VISIBLE)
    check("首次构建读取 entries", loads("system") >= 1)
    check("首次构建含译文", css1:find("第一版", 1, true) ~= nil)
    resetLoads()
    local css2 = Overlay.buildCss(mpath, VISIBLE)
    check("revision 一致且文件未变 → 命中", loads("system") == 0, tostring(loads("system")))
    check("命中返回相同 CSS", css2 == css1)

    -- 模拟导入：entries 先写（revision 领先），manifest 尚未更新。
    -- 同秒同尺寸改写：mtime+size 都不变，必须靠 revision 失效。
    Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "第二版") } })
    check("entries revision 领先 manifest", Overlay.loadEntries(dir, "system").revision
        > Overlay.loadManifest(dir).revision)
    resetLoads()
    local css3 = Overlay.buildCss(mpath, VISIBLE)
    check("revision 不一致 → 失效重建", loads("system") >= 1)
    check("重建后是新译文", css3:find("第二版", 1, true) ~= nil
        and css3:find("第一版", 1, true) == nil)

    -- manifest 追平后内容未变 → 命中
    Overlay.saveManifest(dir, Overlay.loadManifest(dir))
    age(epath)
    Overlay.buildCss(mpath, VISIBLE)
    resetLoads()
    local css4 = Overlay.buildCss(mpath, VISIBLE)
    check("追平后命中", loads("system") == 0 and css4 == css3)
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
    resetLoads()
    Overlay.buildCss(mpath, VISIBLE)
    check("追平且内容未变 → 命中", loads("system") == 0)
    -- 只写 manifest（如显示切换），entries 不动
    Overlay.saveManifest(dir, Overlay.loadManifest(dir))
    resetLoads()
    Overlay.buildCss(mpath, VISIBLE)
    check("manifest revision 变化 → 重建", loads("system") >= 1)
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
    resetLoads()
    local css_mcp = Overlay.buildCss(mpath, { translation_visible = true, provider = "mcp:gpt-5" })
    check("切换 provider → 重建", loads("mcp:gpt-5") >= 1)
    check("切换后只显示新 provider", css_mcp:find("MCP", 1, true) ~= nil
        and css_mcp:find("内置二", 1, true) ~= nil and css_sys ~= css_mcp)

    resetLoads()
    Overlay.buildCss(mpath, { translation_visible = true, provider = "mcp:gpt-5", fallback = false })
    check("fallback 开关影响 key → 重建", loads("mcp:gpt-5") >= 1)
    resetLoads()
    Overlay.buildCss(mpath, { translation_visible = true, provider = "mcp:gpt-5", fallback = false })
    check("fallback 关闭稳定命中", loads("mcp:gpt-5") == 0)
    check("fallback 关闭不加载其他 entries", loads("system") == 0, tostring(loads("system")))

    -- Re-establish the system template, then style-only changes must not
    -- decode the entries again: colour/size/font live in the template
    -- placeholders and are substituted when the file is read.
    Overlay.buildCss(mpath, VISIBLE)
    resetLoads()
    local color_css = Overlay.buildCss(mpath,
        { translation_visible = true, translation_color = "#333333" })
    check("颜色变化走模板，不重解码", loads("system") == 0
        and color_css:find("color:#333333!important", 1, true) ~= nil)
    resetLoads()
    local size_css = Overlay.buildCss(mpath,
        { translation_visible = true, translation_size = "0.8em" })
    check("字号变化走模板，不重解码", loads("system") == 0
        and size_css:find("font-size:0.8em!important", 1, true) ~= nil)
    resetLoads()
    local font_css = Overlay.buildCss(mpath,
        { translation_visible = true, translation_font_family = "serif" })
    check("字体变化走模板，不重解码", loads("system") == 0
        and font_css:find("font-family:serif!important", 1, true) ~= nil)

    Overlay.clearCssCache()
    check("clearCssCache 后内存为空", stats().css_entries == 0)
    resetLoads()
    local rebuilt = Overlay.buildCss(mpath, VISIBLE)
    check("clearCssCache 后由模板重建", loads("system") == 0 and rebuilt == css_sys)
end

-- ============================================================
print("== 4. 每书 1 条 + 全局 8MB LRU ==")
do
    -- 前面的用例把别的书留在 CSS 缓存里；本节的计数从空缓存开始。
    Overlay.clearCssCache()
    -- 每书只保留最新一条：旧选项组合不再占用缓存
    local dir, mpath = newBook("per_book", { "system" }, "system")
    Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "译文") } })
    local epath = Overlay.entriesPath(dir, "system")
    age(epath)
    Overlay.buildCss(mpath, { translation_visible = true, translation_color = "#111111" })
    Overlay.buildCss(mpath, { translation_visible = true, translation_color = "#222222" })
    check("每书只留 1 条 CSS", stats().css_entries == 1, tostring(stats().css_entries))
    resetLoads()
    local again = Overlay.buildCss(mpath,
        { translation_visible = true, translation_color = "#111111" })
    check("回到旧选项由模板重建（不重解码）", loads("system") == 0
        and again:find("color:#111111!important", 1, true) ~= nil)
    check("回到旧选项后仍只有 1 条", stats().css_entries == 1)

    -- 两本大书超过 8MB → LRU 淘汰先前的书。 模板让重建不再解码，
    -- 所以淘汰的结果用 css_entries/css_bytes 断言，而不是 loadEntries 次数。
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
    check("两本大书只留 1 条 CSS", stats().css_entries == 1, tostring(stats().css_entries))
    check("CSS 预算不超", stats().css_bytes <= stats().css_budget)
    resetLoads()
    local css_a2 = Overlay.buildCss(mpath_a, VISIBLE)
    check("最旧的书由模板重建（不重解码）", loads("system") == 0 and css_a2 == css_a)
    check("重建后仍只留 1 条", stats().css_entries == 1)
end

-- ============================================================
print("== 5. 预编译模板：导入后预热 / 命中 / 失效 ==")
do
    Overlay.clearCssCache()
    local dir, mpath = newBook("template", { "system" }, "system")
    Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "模板译文") } })
    local epath = Overlay.entriesPath(dir, "system")
    age(epath)
    check("预热模板", Overlay.warmCssTemplate(dir) == true)
    check("模板文件存在", Overlay.exists(dir .. "/css-template.css"))

    Overlay.clearCssCache()
    Overlay.clearEntriesCache()
    Overlay.clearTemplateCache()
    resetLoads()
    local hits_before = stats().template_hits
    local hot = Overlay.buildCss(mpath, VISIBLE)
    check("冷启动命中模板且不解码", loads("system") == 0
        and hot:find("模板译文", 1, true) ~= nil)
    check("模板命中计数 +1", stats().template_hits == hits_before + 1)

    resetLoads()
    local restyled = Overlay.buildCss(mpath,
        { translation_visible = true, translation_color = "#00ff00" })
    check("样式替换仍命中模板", loads("system") == 0
        and restyled:find("color:#00ff00!important", 1, true) ~= nil)

    check("removeCssTemplate", Overlay.removeCssTemplate(dir))
    Overlay.clearCssCache()
    Overlay.clearEntriesCache()
    resetLoads()
    local cold = Overlay.buildCss(mpath, VISIBLE)
    check("删掉模板后回到解码路径", loads("system") >= 1
        and cold:find("模板译文", 1, true) ~= nil)
    check("重建会写回模板", Overlay.exists(dir .. "/css-template.css"))
end

-- ============================================================
print("== 6. 模板健壮性：大 revision / 损坏 / fallback / 删除 ==")
do
    local dir, mpath = newBook("peek_late", { "system" }, "system")
    local big = {}
    for i = 1, 40 do
        big[#big + 1] = entry("p[" .. i .. "]", string.rep("长译文", 40))
    end
    Overlay.saveEntries(dir, "system", { entries = big })
    local epath = Overlay.entriesPath(dir, "system")
    age(epath)
    check("大 entries 预热模板", Overlay.warmCssTemplate(dir))
    local file = io.open(epath, "rb")
    local raw = file:read("*a")
    file:close()
    check("entries 超过 256 字节", #raw > 512, tostring(#raw))
    Overlay.clearCssCache()
    Overlay.clearEntriesCache()
    Overlay.clearTemplateCache()
    resetLoads()
    local css = Overlay.buildCss(mpath, VISIBLE)
    check("revision 不在头部也能按模板重建", loads("system") == 0
        and css:find("长译文", 1, true) ~= nil)

    local tpath = dir .. "/css-template.css"
    local good = io.open(tpath, "rb")
    local content = good:read("*a")
    good:close()
    local cut = io.open(tpath, "wb")
    cut:write(content:sub(1, math.floor(#content / 2)))
    cut:close()
    Overlay.clearCssCache()
    Overlay.clearEntriesCache()
    Overlay.clearTemplateCache()
    resetLoads()
    local rebuilt = Overlay.buildCss(mpath, VISIBLE)
    check("损坏模板回退解码并重建", loads("system") >= 1
        and rebuilt:find("长译文", 1, true) ~= nil and Overlay.exists(tpath))

    local dir2, mpath2 = newBook("fallback_style", { "system", "mcp:b" }, "system")
    Overlay.saveEntries(dir2, "system", { entries = { entry("p[1]", "主译文") } })
    Overlay.saveEntries(dir2, "mcp:b", { entries = { entry("p[2]", "备译文") } })
    age(Overlay.entriesPath(dir2, "system"))
    age(Overlay.entriesPath(dir2, "mcp:b"))
    Overlay.buildCss(mpath2, VISIBLE)
    resetLoads()
    local styled = Overlay.buildCss(mpath2,
        { translation_visible = true, translation_color = "#123456" })
    check("fallback 样式变化不读任一份 entries", loads("system") == 0
        and loads("mcp:b") == 0
        and styled:find("主译文", 1, true) ~= nil
        and styled:find("备译文", 1, true) ~= nil
        and styled:find("color:#123456!important", 1, true) ~= nil)

    -- A fallback-only change must invalidate the CSS key/template, not just
    -- the primary entries file.
    Overlay.saveEntries(dir2, "mcp:b", { entries = { entry("p[2]", "备译文v2") } })
    resetLoads()
    local updated = Overlay.buildCss(mpath2, VISIBLE)
    check("fallback entries 变化使缓存失效", updated:find("备译文v2", 1, true) ~= nil
        and loads("mcp:b") >= 1)

    check("删除前模板存在", Overlay.exists(tpath))
    Overlay.deleteEntries(dir, "system")
    check("删除 entries 后模板消失", not Overlay.exists(tpath))
end

print(string.format("\n==== revision 缓存测试：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
end
os.exit(failed == 0 and 0 or 1)