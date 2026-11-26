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

print(string.format("\n==== 术语表测试：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
end
os.exit(failed == 0 and 0 or 1)
