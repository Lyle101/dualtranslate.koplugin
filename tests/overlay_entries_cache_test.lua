-- ============================================================
-- entries 解析缓存：命中/失效/预算
-- Run: luajit tests/overlay_entries_cache_test.lua
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

local ROOT = "/tmp/dt_overlay_entries_cache_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Overlay = dofile(script_dir .. "/../dualtranslate_overlay.lua")

local function entry(selector, translation)
    return { selector = selector, translation = translation, source = "src" }
end

local function newBook(label)
    local dir = ROOT .. "/" .. label
    os.execute('mkdir -p "' .. dir .. '"')
    local manifest = {
        version = 3, book_path = "/books/" .. label .. ".epub", source_lang = "auto",
        target_lang = "zh-Hans", spine_count = 0, book_size = 0, book_mtime = 0,
        display_mode = "manual", display_provider = "system",
        display_fallback = false, last_used_at = {}, fallback_order = { "system" },
        providers = {
            system = {
                display_name = "system", kind = "system", chapters = {},
                partial_chapters = {}, failed_chapters = {}, complete = false,
                translated_count = 1, updated_at = 100, confirmed = true,
            },
        },
    }
    assert(Overlay.saveManifest(dir, manifest))
    return dir
end

local function stats()
    return Overlay.cacheStats()
end

-- ============================================================
print("== 1. 命中的是同一个已解析 doc ==")
local dir = newBook("hit")
assert(Overlay.saveEntries(dir, "system", {
    entries = { entry("p[1]", "第一版"), entry("p[2]", "第二段") },
}))
Overlay.clearEntriesCache()
local base = stats()
local first = Overlay.loadEntries(dir, "system")
check("首次调用重新解码", stats().entries_loads == base.entries_loads + 1)
local second = Overlay.loadEntries(dir, "system")
check("第二次命中同一个 table", rawequal(second, first))
check("命中计数增加", stats().entries_hits == base.entries_hits + 1)
check("命中不再解码", stats().entries_loads == base.entries_loads + 1)

-- ============================================================
print("== 2. saveEntries 失效 ==")
local before_save = stats()
assert(Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "第二版") } }))
local updated = Overlay.loadEntries(dir, "system")
check("写后重新解码", not rawequal(updated, first))
check("读到新译文", updated.entries[1].translation == "第二版")
check("解码计数 +1", stats().entries_loads == before_save.entries_loads + 1,
    tostring(stats().entries_loads - before_save.entries_loads))

-- ============================================================
print("== 3. mtime 变化失效（外部改写） ==")
local path = Overlay.entriesPath(dir, "system")
local before_stat = stats()
assert(lfs.touch(path, os.time() - 30, os.time() - 30))
local reloaded = Overlay.loadEntries(dir, "system")
check("mtime 变化后重新解码", not rawequal(reloaded, updated))
check("解码计数 +1", stats().entries_loads == before_stat.entries_loads + 1)

-- ============================================================
print("== 4. deleteEntries / clearEntriesCache ==")
Overlay.deleteEntries(dir, "system")
check("删除后读到 nil", Overlay.loadEntries(dir, "system") == nil)
assert(Overlay.saveEntries(dir, "system", { entries = { entry("p[1]", "重建") } }))
local after_delete = Overlay.loadEntries(dir, "system")
check("重建后可读", after_delete ~= nil)
Overlay.clearEntriesCache()
check("clearEntriesCache 清空占用", stats().entries_bytes == 0)
local before_clear = stats()
Overlay.loadEntries(dir, "system")
check("清空后重新解码", stats().entries_loads == before_clear.entries_loads + 1)

-- ============================================================
print("== 5. 预算淘汰最旧 doc ==")
local big = string.rep("字", 1500000) -- ~4.5 MB UTF-8
local dir_a = newBook("big_a")
local dir_b = newBook("big_b")
assert(Overlay.saveEntries(dir_a, "system", { entries = { entry("p[1]", big) } }))
assert(Overlay.saveEntries(dir_b, "system", { entries = { entry("p[1]", big) } }))
Overlay.clearEntriesCache()
Overlay.loadEntries(dir_a, "system")
Overlay.loadEntries(dir_b, "system")
local budget = stats()
check("两份大 doc 超预算后仍有上限", budget.entries_bytes <= budget.entries_budget,
    tostring(budget.entries_bytes) .. "/" .. tostring(budget.entries_budget))
local before_evict = stats()
Overlay.loadEntries(dir_a, "system")
check("最旧一份被淘汰并重解码", stats().entries_loads == before_evict.entries_loads + 1)
local before_hit = stats()
Overlay.loadEntries(dir_a, "system")
check("重新载入的 doc 命中", stats().entries_loads == before_hit.entries_loads)
local before_b = stats()
Overlay.loadEntries(dir_b, "system")
check("另一份已被挤出并重解码", stats().entries_loads == before_b.entries_loads + 1)

print(string.format("\n==== entries 缓存测试：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
end
os.exit(failed == 0 and 0 or 1)
