-- 术语表 / 风格指南（设计 §17 Q5）
-- 解析（空行 / 重复 / 全角等号 / 超长 / 上限）/ 存储（原子写、损坏容错）/
-- 与 manifest、css-template 解耦（编辑术语不碰 overlay 身份）
-- Run: luajit tests/glossary_test.lua
-- 用 KOReader 自带 lfs + json；缺失时跳过。
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
package.path = KO .. "/?.lua;" .. KO .. "/common/?.lua;"
    .. KO .. "/common/?/init.lua;" .. package.path
package.cpath = KO .. "/?.so;" .. KO .. "/?.dylib;" .. package.cpath
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_json = pcall(require, "json")
if not ok_lfs or not ok_json then
    print("SKIP: libkoreader-lfs / json unavailable"); os.exit(0)
end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local ROOT = "/tmp/dt_glossary_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

-- defaultPath / listGlossaryBooks resolve through DataStorage; point it at
-- this test's tree so the default glossary stays outside the book caches.
local data_root = ROOT .. "/data"
package.preload["datastorage"] = function()
    return { getDataDir = function() return data_root end }
end

local warn_count = 0
package.preload["logger"] = function()
    return { warn = function() warn_count = warn_count + 1 end,
        err = function() end, info = function() end, dbg = function() end }
end
package.preload["util"] = function()
    return { makePath = function(path)
        if not path or path == "" then return false end
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
    end, trim = function(value)
        return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end }
end

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Tools = dofile(script_dir .. "/../dualtranslate_tools.lua")
package.loaded["dualtranslate_tools"] = Tools
local Glossary = dofile(script_dir .. "/../dualtranslate_glossary.lua")

local function write(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function exists(path)
    return lfs.attributes(path) ~= nil
end

-- ============================================================
print("== 1. 解析：空行 / 空白 / 全角等号 ==")
do
    local terms, stats = Glossary.parse([[
Darcy=达西

  Netherfield = 内瑟菲尔德
Elizabeth＝伊丽莎白
]])
    check("解析 3 条", #terms == 3, tostring(#terms))
    check("原文去空白", terms[2].source == "Netherfield" and terms[2].target == "内瑟菲尔德",
        terms[2] and (terms[2].source .. "|" .. terms[2].target))
    check("全角等号可解析", terms[3].source == "Elizabeth"
        and terms[3].target == "伊丽莎白",
        terms[3] and (terms[3].source .. "|" .. terms[3].target))
    check("空行不算丢弃", stats.invalid == 0 and stats.lines == 3,
        string.format("invalid=%d lines=%d", stats.invalid, stats.lines))

    -- U+3000 / U+00A0 are invisible on screen but would break the match.
    local wide = Glossary.parse("\227\128\128Darcy\227\128\128=\194\160达西\194\160")
    check("全角/不换行空格被去掉", wide[1] and wide[1].source == "Darcy"
        and wide[1].target == "达西", wide[1] and (wide[1].source .. "|" .. wide[1].target))
end

-- ============================================================
print("== 2. 解析：无效行 / 重复原文 / 值内等号 ==")
do
    local terms, stats = Glossary.parse([[
没有等号
=只有译文
只有原文=
Darcy=达西
Darcy=达西先生
公式= a=b=c
]])
    check("无效行计数", stats.invalid == 3, tostring(stats.invalid))
    check("重复原文合并", stats.duplicate == 1 and #terms == 2,
        string.format("duplicate=%d terms=%d", stats.duplicate, #terms))
    check("重复原文后写覆盖", terms[1].source == "Darcy"
        and terms[1].target == "达西先生", terms[1] and terms[1].target)
    check("只按第一个等号切分", terms[2].target == "a=b=c",
        terms[2] and terms[2].target)

    -- Mixed forms: the earliest separator wins, regardless of width.
    local mixed = Glossary.parse("a＝b=c")
    check("全角在前按全角切分", #mixed == 1 and mixed[1].source == "a"
        and mixed[1].target == "b=c", mixed[1] and mixed[1].target)
end

-- ============================================================
print("== 3. 解析：单条长度与总量上限 ==")
do
    local long_source = string.rep("s", Glossary.MAX_SOURCE_BYTES + 1)
    local long_target = string.rep("t", Glossary.MAX_TARGET_BYTES + 1)
    local terms, stats = Glossary.parse(long_source .. "=x\n" .. "y=" .. long_target)
    check("超长条目被忽略", #terms == 0 and stats.too_long == 2,
        string.format("terms=%d too_long=%d", #terms, stats.too_long))

    local lines = {}
    for index = 1, Glossary.MAX_TERMS + 5 do
        lines[index] = string.format("term%d=译%d", index, index)
    end
    terms, stats = Glossary.parse(table.concat(lines, "\n"))
    check("总量上限", #terms == Glossary.MAX_TERMS and stats.overflow == 5,
        string.format("terms=%d overflow=%d", #terms, stats.overflow))
end

-- ============================================================
print("== 4. format 往返 ==")
do
    local text = "Darcy=达西\nNetherfield=内瑟菲尔德"
    local terms = Glossary.parse(text)
    check("往返一致", Glossary.format(terms) == text, Glossary.format(terms))
    local bad = { { source = "a\nb", target = "c\nd" }, { source = "", target = "x" } }
    check("非法项被清理", Glossary.format(bad) == "a b=c d", Glossary.format(bad))
end

-- ============================================================
print("== 5. 存储：缺失 / 保存 / 读回 ==")
do
    local dir = ROOT .. "/book_a"
    local empty = Glossary.load(dir)
    check("缺失文件返回默认风格指南", #empty.terms == 0
        and empty.style_guide == Glossary.DEFAULT_STYLE_GUIDE,
        empty.style_guide)

    local saved, err = Glossary.save(dir, {
        terms = { { source = "Darcy", target = "达西" },
            { source = "Netherfield", target = "内瑟菲尔德" },
            { source = "Lizzy", target = "莉齐" } },
        style_guide = "用民国白话",
    })
    check("保存成功", saved ~= nil, tostring(err))
    check("没有 tmp 残留", not exists(dir .. "/glossary.json.tmp"))
    local raw = read(dir .. "/glossary.json")
    local ok_decode, decoded = pcall(require("json").decode, raw)
    check("schema 写入", ok_decode and type(decoded) == "table"
        and decoded.schema == Glossary.SCHEMA)
    local loaded = Glossary.load(dir)
    check("读回 3 条", #loaded.terms == 3, tostring(#loaded.terms))
    check("读回风格指南", loaded.style_guide == "用民国白话", loaded.style_guide)
    check("读回顺序稳定", loaded.terms[1].source == "Darcy"
        and loaded.terms[3].source == "Lizzy")

    Glossary.save(dir, { terms = loaded.terms, style_guide = "" })
    check("空风格指南回落默认",
        Glossary.load(dir).style_guide == Glossary.DEFAULT_STYLE_GUIDE)

    -- The schema says terms is an array; an empty table must not become {}.
    local empty_dir = ROOT .. "/book_empty"
    Glossary.save(empty_dir, { terms = {} })
    check("空术语表编码为数组",
        (read(empty_dir .. "/glossary.json") or ""):find('"terms":[]', 1, true) ~= nil,
        read(empty_dir .. "/glossary.json"))

    local nil_save, nil_err = Glossary.save(nil, {})
    check("无目录保存报错", nil_save == nil and nil_err ~= nil)
    check("nil 目录读取不报错", Glossary.load(nil).style_guide
        == Glossary.DEFAULT_STYLE_GUIDE)
end

-- ============================================================
print("== 6. 存储：损坏文件容错 / 风格指南上限 ==")
do
    local dir = ROOT .. "/book_b"
    os.execute('mkdir -p "' .. dir .. '"')
    write(dir .. "/glossary.json", "{not json")
    local loaded = Glossary.load(dir)
    check("损坏文件回落默认", #loaded.terms == 0
        and loaded.style_guide == Glossary.DEFAULT_STYLE_GUIDE)
    check("损坏文件打标", loaded.corrupt == true)
    check("损坏文件留备份", read(dir .. "/glossary.json.corrupt") == "{not json",
        read(dir .. "/glossary.json.corrupt"))
    local before = warn_count
    Glossary.load(dir)
    check("损坏文件只告警一次", warn_count == before and warn_count > 0,
        tostring(warn_count))

    -- A planted link at the .corrupt backup path must not be followed.
    local linked_dir = ROOT .. "/book_corrupt_link"
    Tools.mkdir_p(linked_dir)
    write(linked_dir .. "/glossary.json", "{bad again")
    local outside = ROOT .. "/outside_corrupt.txt"
    write(outside, "original")
    os.execute('ln -s "' .. outside .. '" "'
        .. linked_dir .. '/glossary.json.corrupt"')
    local linked_loaded = Glossary.load(linked_dir)
    check("损坏备份不跟随链接", linked_loaded.corrupt == true
        and read(outside) == "original", tostring(read(outside)))
    check("损坏备份写成普通文件",
        lfs.attributes(linked_dir .. "/glossary.json.corrupt", "mode") == "file")

    local long_style = string.rep("风", 1000) -- 3000 bytes > 2000
    local saved = Glossary.save(dir, { terms = {}, style_guide = long_style })
    check("超长风格指南截断", saved ~= nil
        and #saved.style_guide <= Glossary.MAX_STYLE_GUIDE_BYTES
        and #saved.style_guide > Glossary.MAX_STYLE_GUIDE_BYTES - 4,
        saved and tostring(#saved.style_guide))
    check("截断有标记", saved and saved.stats and saved.stats.style_truncated == true)
    check("截断在 UTF-8 边界", saved ~= nil and #saved.style_guide % 3 == 0,
        saved and tostring(#saved.style_guide))
end

-- ============================================================
print("== 7. 与 manifest / css-template 解耦 ==")
do
    local dir = ROOT .. "/book_c"
    os.execute('mkdir -p "' .. dir .. '"')
    write(dir .. "/manifest.json", '{"version":3,"revision":7}')
    write(dir .. "/css-template.css", "template-bytes")
    -- An old mtime can never collide with "the second the save happened", so
    -- the mtime assertions cannot pass by accident.
    local old = os.time() - 3600
    assert(lfs.touch(dir .. "/manifest.json", old, old))
    assert(lfs.touch(dir .. "/css-template.css", old, old))
    local manifest_before = read(dir .. "/manifest.json")
    local manifest_mtime = lfs.attributes(dir .. "/manifest.json", "modification")
    local template_mtime = lfs.attributes(dir .. "/css-template.css", "modification")
    Glossary.save(dir, {
        terms = { { source = "Darcy", target = "达西" } },
        style_guide = "保留段落结构",
    })
    check("manifest 内容未变", read(dir .. "/manifest.json") == manifest_before)
    check("manifest mtime 未变",
        lfs.attributes(dir .. "/manifest.json", "modification") == manifest_mtime)
    check("模板 mtime 未变",
        lfs.attributes(dir .. "/css-template.css", "modification") == template_mtime)
    check("只新增 glossary.json", exists(dir .. "/glossary.json"))
end

-- ============================================================
print("== 8. 删除译文时的暂存/恢复 ==")
do
    local dir = ROOT .. "/book_stash"
    check("无文件暂存返回 nil", Glossary.stash(dir) == nil)
    Glossary.save(dir, {
        terms = { { source = "Darcy", target = "达西" } },
        style_guide = "风格",
    })
    local stashed = Glossary.stash(dir)
    check("暂存是重命名", stashed ~= nil and stashed.keep == Glossary.keepPath(dir))
    check("目录内文件已移走", not exists(dir .. "/glossary.json"))
    check("暂存文件在旁边", exists(Glossary.keepPath(dir)))

    os.execute('rm -rf "' .. dir .. '"') -- simulate the cache sweep
    check("恢复成功", Glossary.unstash(dir, stashed) == true)
    local loaded = Glossary.load(dir)
    check("恢复后术语还在", #loaded.terms == 1 and loaded.terms[1].source == "Darcy"
        and loaded.style_guide == "风格", loaded.style_guide)

    -- A stale keep from an older crash is replaced by the next stash, not
    -- merged with it.
    local stale = ROOT .. "/book_stale"
    write(Glossary.keepPath(stale), "stale")
    Glossary.save(stale, { terms = { { source = "New", target = "新" } } })
    local replaced = Glossary.stash(stale)
    local kept_raw = read(Glossary.keepPath(stale)) or ""
    check("旧 keep 被覆盖", replaced ~= nil
        and kept_raw:find('"source":"New"', 1, true) ~= nil
        and kept_raw:find("stale", 1, true) == nil, kept_raw)
    check("恢复覆盖后的 keep", Glossary.unstash(stale, replaced) == true
        and Glossary.load(stale).terms[1].source == "New")

    -- A crash between the sweep and the restore must not lose the terms: the
    -- next load puts the orphaned keep file back.
    local orphan = ROOT .. "/book_orphan"
    Glossary.save(orphan, { terms = { { source = "Lizzy", target = "莉齐" } } })
    local moved = Glossary.stash(orphan)
    check("孤儿暂存就位", moved ~= nil and exists(Glossary.keepPath(orphan)))
    os.execute('rm -rf "' .. orphan .. '"')
    local recovered = Glossary.load(orphan)
    check("load 恢复孤儿暂存", #recovered.terms == 1
        and recovered.terms[1].source == "Lizzy", tostring(#recovered.terms))
    check("恢复后不留 keep", not exists(Glossary.keepPath(orphan)))
end

-- ============================================================
print("== 9. 异常文件：目录冒充 / 不可读 / 恢复失败 ==")
do
    -- A directory named glossary.json is not user terms.  Moving it aside
    -- would only make the next load fail on a directory, and recover_stash
    -- must not move a keep *directory* into place either.
    local dir = ROOT .. "/book_dirstash"
    os.execute('mkdir -p "' .. dir .. '/glossary.json"')
    check("目录不暂存", Glossary.stash(dir) == nil)
    check("目录未被改名", lfs.attributes(dir .. "/glossary.json", "mode") == "directory"
        and not exists(Glossary.keepPath(dir)))

    local keepdir = ROOT .. "/book_keepdir"
    os.execute('mkdir -p "' .. keepdir .. '" "' .. Glossary.keepPath(keepdir) .. '/inner"')
    Glossary.load(keepdir)
    check("目录型 keep 不恢复成术语表",
        lfs.attributes(Glossary.keepPath(keepdir), "mode") == "directory"
        and not exists(keepdir .. "/glossary.json"))

    -- A file where a directory is expected: mkdir_p fails, but the in-memory
    -- bytes must still be parked next to it so a later load can recover them.
    local blocked = ROOT .. "/book_blocked"
    write(blocked, "not a directory")
    local raw = '{"schema":"dualtranslate.glossary.v1","terms":[{"source":"A","target":"甲"}]}'
    check("恢复失败返回 false", Glossary.unstash(blocked, { data = raw }) == false)
    check("内存字节停到 keep", read(Glossary.keepPath(blocked)) == raw,
        read(Glossary.keepPath(blocked)))
    check("块状路径读取不报错", Glossary.load(blocked).style_guide
        == Glossary.DEFAULT_STYLE_GUIDE)
    os.remove(Glossary.keepPath(blocked))

    -- The keep path itself can be a stray directory, and the cache path can be
    -- blocked by a file: bytes must fall back to "<keep>.1", not be dropped.
    local occupied = ROOT .. "/book_keep_busy"
    write(occupied, "not a directory")
    os.execute('mkdir -p "' .. Glossary.keepPath(occupied) .. '/x"')
    local raw2 = '{"schema":"dualtranslate.glossary.v1","terms":[{"source":"B","target":"乙"}]}'
    check("keep 被占时返回 false",
        Glossary.unstash(occupied, { data = raw2 }) == false)
    check("字节落到 keep.1", read(Glossary.keepPath(occupied) .. ".1") == raw2,
        read(Glossary.keepPath(occupied) .. ".1"))
    -- Once the paths are usable again, load recovers from the fallback copy.
    os.remove(occupied)
    os.execute('rm -rf "' .. Glossary.keepPath(occupied) .. '"')
    local recovered = Glossary.load(occupied)
    check("load 从 keep.1 恢复", #recovered.terms == 1
        and recovered.terms[1].source == "B", tostring(#recovered.terms))
    check("恢复后不留 keep.1",
        not exists(Glossary.keepPath(occupied) .. ".1"))

    -- Rename cannot succeed (keep is a non-empty directory) and, on a
    -- non-root account, the file itself cannot be read: the caller must be
    -- told "unreadable" so it skips the delete instead of destroying terms.
    local shadow = ROOT .. "/book_unreadable"
    Glossary.save(shadow, { terms = { { source = "Darcy", target = "达西" } } })
    os.execute('mkdir -p "' .. Glossary.keepPath(shadow) .. '/x"')
    os.execute('chmod 000 "' .. shadow .. '/glossary.json"')
    local probe = io.open(shadow .. "/glossary.json", "rb")
    local readable = probe ~= nil
    if probe then probe:close() end
    local stashed, stash_err = Glossary.stash(shadow)
    if readable then
        -- Running as root: chmod 000 does not block the read, so the
        -- in-memory fallback is the correct answer, not "unreadable".
        check("root 下回退为内存副本", stashed ~= nil and stashed.data ~= nil,
            tostring(stash_err))
    else
        check("改名失败且读不出时返回 unreadable",
            stashed == nil and stash_err == "unreadable", tostring(stash_err))
    end
    os.execute('chmod 644 "' .. shadow .. '/glossary.json"')
    os.execute('rm -rf "' .. shadow .. '" "' .. Glossary.keepPath(shadow) .. '"')
    os.execute('rm -rf "' .. dir .. '" "' .. keepdir .. '"')
    os.execute('rm -rf "' .. occupied .. '" "' .. Glossary.keepPath(occupied) .. '"')
end

-- ============================================================
print("== 10. 跨书复用：默认 / 复制列表 / 导出导入 ==")
do
    local books_root = data_root .. "/cache/dualtranslate/books"
    Tools.mkdir_p(books_root)
    check("默认术语表在 books/ 之外",
        Glossary.defaultPath() == data_root .. "/cache/dualtranslate/glossary.default.json")

    local default_saved, default_err = Glossary.saveDefault({
        terms = { { source = "Darcy", target = "达西" },
            { source = "Lizzy", target = "莉齐" } },
        style_guide = "默认风格",
    })
    check("保存默认术语表", default_saved ~= nil, tostring(default_err))
    check("默认文件落盘", exists(Glossary.defaultPath()))
    local default_payload = Glossary.loadDefault()
    check("读回默认术语表", default_payload and #default_payload.terms == 2
        and default_payload.terms[2].source == "Lizzy"
        and default_payload.style_guide == "默认风格",
        default_payload and default_payload.style_guide)
    check("默认保存无 tmp 残留", not exists(Glossary.defaultPath() .. ".tmp"))

    local missing, missing_err = Glossary.loadFile(ROOT .. "/nope.json")
    check("缺文件给出原因", missing == nil and tostring(missing_err):find("找不到") ~= nil)
    write(ROOT .. "/empty.json", "")
    check("空文件拒绝", Glossary.loadFile(ROOT .. "/empty.json") == nil)
    write(ROOT .. "/bad.json", "{oops")
    check("非 JSON 拒绝", Glossary.loadFile(ROOT .. "/bad.json") == nil)
    write(ROOT .. "/nothing.json", '{"schema":"x","terms":[]}')
    local nothing, nothing_err = Glossary.loadFile(ROOT .. "/nothing.json")
    check("没有术语的文件拒绝", nothing == nil
        and tostring(nothing_err):find("没有术语") ~= nil, tostring(nothing_err))
    write(ROOT .. "/style_only.json", '{"terms":[],"style_guide":"只用风格"}')
    local only_style = Glossary.loadFile(ROOT .. "/style_only.json")
    check("只有风格指南也可载入", only_style and #only_style.terms == 0
        and only_style.style_guide == "只用风格")
    write(ROOT .. "/terms_only.json", '{"terms":[{"source":"A","target":"甲"}]}')
    local terms_only = Glossary.loadFile(ROOT .. "/terms_only.json")
    check("缺风格指南回落默认", terms_only and terms_only.style_guide
        == Glossary.DEFAULT_STYLE_GUIDE)

    -- The export is a byte copy: what the user saved is what travels.
    local source_dir = books_root .. "/b1"
    Glossary.save(source_dir, {
        terms = { { source = "Darcy", target = "达西" } }, style_guide = "本书风格" })
    local target = ROOT .. "/export/Book One.dualtranslate-glossary.json"
    local exported, export_err = Glossary.exportFile(source_dir, target)
    check("导出成功", exported ~= nil, tostring(export_err))
    check("导出目录自动创建", exists(target))
    check("导出是原字节", read(target) == read(source_dir .. "/glossary.json"))
    local imported_dir = books_root .. "/b2"
    local imported, import_err = Glossary.importFile(target, imported_dir)
    check("导入成功", imported ~= nil, tostring(import_err))
    local imported_payload = Glossary.load(imported_dir)
    check("导入内容一致", #imported_payload.terms == 1
        and imported_payload.terms[1].source == "Darcy"
        and imported_payload.style_guide == "本书风格")
    write(ROOT .. "/bad_import.json", "{broken")
    local bad_imported, bad_err = Glossary.importFile(ROOT .. "/bad_import.json",
        books_root .. "/b3")
    check("损坏文件不会覆盖本书", bad_imported == nil
        and tostring(bad_err):find("JSON") ~= nil
        and not exists(books_root .. "/b3/glossary.json"), tostring(bad_err))
    check("没有术语表的书不能导出",
        Glossary.exportFile(books_root .. "/b3", ROOT .. "/export/x.json") == nil)

    -- listGlossaryBooks: newest first, skips links and directories named
    -- glossary.json, and reads the title from manifest.json when present.
    local b3 = books_root .. "/b3"
    Glossary.save(b3, { terms = { { source = "B", target = "乙" },
        { source = "C", target = "丙" }, { source = "D", target = "丁" } } })
    local manifest_file = assert(io.open(imported_dir .. "/manifest.json", "wb"))
    manifest_file:write('{"book_path":"/mnt/us/documents/Book Two.epub"}')
    manifest_file:close()
    local now = os.time()
    assert(lfs.touch(imported_dir .. "/glossary.json", now, now))
    assert(lfs.touch(b3 .. "/glossary.json", now - 10, now - 10))
    local dir_as_file = books_root .. "/b4"
    Tools.mkdir_p(dir_as_file .. "/glossary.json")
    local listed = Glossary.listGlossaryBooks(source_dir)
    check("列表排除当前书", #listed == 2, tostring(#listed))
    check("最新在前", listed[1] and listed[1].dir == imported_dir,
        listed[1] and listed[1].dir)
    check("标题取 manifest 文件名", listed[1] and listed[1].title == "Book Two.epub",
        listed[1] and listed[1].title)
    check("条数用于确认覆盖", listed[1] and listed[1].terms == 1,
        listed[1] and tostring(listed[1].terms))
    check("无 manifest 用目录名", listed[2] and listed[2].title == "b3",
        listed[2] and listed[2].title)
    local seen_b4 = false
    for _, item in ipairs(listed) do
        if item.dir == dir_as_file then seen_b4 = true end
    end
    check("目录冒充 glossary.json 不进列表", not seen_b4)
    if lfs.symlinkattributes then
        local link = books_root .. "/linked"
        os.execute('ln -s "' .. b3 .. '" "' .. link .. '"')
        if lfs.symlinkattributes(link, "mode") == "link" then
            local seen_link, seen_b3 = false, false
            for _, item in ipairs(Glossary.listGlossaryBooks(nil)) do
                if item.dir == link then seen_link = true end
                if item.dir == b3 then seen_b3 = true end
            end
            check("符号链接书目录不进列表", not seen_link and seen_b3)
        else
            print("  SKIP: 符号链接创建失败")
        end
    end
end

-- ============================================================
print("== 11. 两副本都损坏时按 mtime 选较新 ==")
do
    local dir = ROOT .. "/book_both_corrupt"
    Tools.mkdir_p(dir)
    local keep = Glossary.keepPath(dir)
    write(keep, "{old and broken")
    write(keep .. ".1", "{new and broken")
    local now = os.time()
    assert(lfs.touch(keep, now - 100, now - 100))
    assert(lfs.touch(keep .. ".1", now - 10, now - 10))
    local loaded = Glossary.load(dir)
    check("恢复较新的 keep.1", read(dir .. "/glossary.json") == "{new and broken",
        read(dir .. "/glossary.json"))
    check("较旧的 keep 被清掉", not exists(keep))
    check("恢复后不留 keep.1", not exists(keep .. ".1"))
    check("损坏内容仍标记并备份", loaded.corrupt == true
        and read(dir .. "/glossary.json.corrupt") == "{new and broken")
end

-- ============================================================
print("== 12. 原子写不跟随 .tmp 链接 ==")
do
    local outside = ROOT .. "/outside_target.txt"
    write(outside, "original")
    local dir = ROOT .. "/book_tmp_link"
    Tools.mkdir_p(dir)
    local tmp_link = dir .. "/glossary.json.tmp"
    os.execute('ln -s "' .. outside .. '" "' .. tmp_link .. '"')
    if lfs.symlinkattributes and lfs.symlinkattributes(tmp_link, "mode") == "link" then
        local saved = Glossary.save(dir, { terms = { { source = "D", target = "丁" } } })
        check("保存不跟随 .tmp 链接", saved ~= nil and read(outside) == "original",
            tostring(read(outside)))
        check("术语表正常写入", #Glossary.load(dir).terms == 1)
    else
        print("  SKIP: 符号链接创建失败")
    end

    local target = ROOT .. "/export_link/book.dualtranslate-glossary.json"
    Tools.mkdir_p(ROOT .. "/export_link")
    os.execute('ln -s "' .. outside .. '" "' .. target .. '.tmp"')
    if lfs.symlinkattributes(target .. ".tmp", "mode") == "link" then
        write(outside, "original")
        local exported = Glossary.exportFile(dir, target)
        check("导出不跟随 .tmp 链接", exported ~= nil and read(outside) == "original")
        check("导出文件已生成", exists(target))
    end

    local default_tmp = Glossary.defaultPath() .. ".tmp"
    Tools.mkdir_p(Glossary.defaultPath():match("^(.*)/[^/]+$"))
    os.execute('ln -s "' .. outside .. '" "' .. default_tmp .. '"')
    if lfs.symlinkattributes(default_tmp, "mode") == "link" then
        write(outside, "original")
        local saved = Glossary.saveDefault({ terms = { { source = "E", target = "戊" } } })
        check("默认术语表不跟随 .tmp 链接", saved ~= nil and read(outside) == "original")
        check("默认术语表正常写入", #Glossary.loadDefault().terms == 1)
    end
end

print(string.format("\n==== 术语表测试：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
end
os.exit(failed == 0 and 0 or 1)
