-- ============================================================
-- css-template.css 磁盘回收：按 30 天未使用 / 总量上限删除，跳过当前书，
-- 只删模板文件（不动 manifest/entries），并按进程节流。
-- Run: luajit tests/template_gc_test.lua
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

local ROOT = "/tmp/dt_template_gc_test"
local BOOKS = ROOT .. "/books"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. BOOKS .. '"')

local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
local Overlay = dofile(script_dir .. "/../dualtranslate_overlay.lua")

local function write(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

local function mkdir(path)
    os.execute('mkdir -p "' .. path .. '"')
end

local function exists(path)
    return lfs.attributes(path) ~= nil
end

local function book(name)
    local dir = BOOKS .. "/" .. name
    mkdir(dir)
    return dir
end

local function template(dir, bytes)
    local path = dir .. "/css-template.css"
    write(path, string.rep("x", bytes or 128))
    return path
end

local function age(path, days)
    local t = os.time() - math.floor((days or 0) * 86400)
    assert(lfs.touch(path, t, t))
end

-- ============================================================
print("== 1. 过期模板删除，当前书/近期书/entries 保留 ==")
do
    local old = book("old")
    local old_template = template(old, 1024)
    age(old_template, 40)
    write(old .. "/manifest.json", "{}")
    mkdir(old .. "/entries")
    write(old .. "/entries/system.json", "{}")
    write(old .. "/css-template.css.tmp.123", "leftover")

    local recent = book("recent")
    local recent_template = template(recent, 1024)
    age(recent_template, 2)

    local current = book("current")
    local current_template = template(current, 1024)
    age(current_template, 40) -- old, but it is the book being read

    book("empty")

    local report = Overlay.reclaimCssTemplates(BOOKS, current, {
        force = true, max_age_days = 30, max_bytes = 10 * 1024 * 1024,
    })
    check("删除 1 份过期模板", report and report.removed == 1,
        report and tostring(report.removed))
    check("释放字节数", report and report.freed_bytes == 1024,
        report and tostring(report.freed_bytes))
    check("过期书模板已删", not exists(old_template))
    check("过期书的 manifest 保留", exists(old .. "/manifest.json"))
    check("过期书的 entries 保留", exists(old .. "/entries/system.json"))
    check("tmp 残留不误删", exists(old .. "/css-template.css.tmp.123"))
    check("近期书模板保留", exists(recent_template))
    check("当前书模板保留", exists(current_template))
end

-- ============================================================
print("== 2. 总量上限按最久未用删除，当前书永不删 ==")
do
    os.execute('rm -rf "' .. BOOKS .. '"')
    mkdir(BOOKS)
    local dirs = {}
    for i = 1, 4 do
        local dir = book("cap" .. i)
        dirs[i] = dir
        age(template(dir, 20 * 1024), 5 - i) -- 4/3/2/1 天
    end
    local report = Overlay.reclaimCssTemplates(BOOKS, dirs[4], {
        force = true, max_age_days = 3650, max_bytes = 45 * 1024,
    })
    check("超上限删 2 份", report and report.removed == 2,
        report and tostring(report.removed))
    check("总量回落到上限内", report and report.total_bytes <= 45 * 1024,
        report and tostring(report.total_bytes))
    check("保留 2 份", report and report.kept == 2, report and tostring(report.kept))
    check("当前书（最新）保留", exists(dirs[4] .. "/css-template.css"))
    check("次新书保留", exists(dirs[3] .. "/css-template.css"))
    check("最旧书已删", not exists(dirs[1] .. "/css-template.css"))
end

-- ============================================================
print("== 3. 节流与非法根目录 ==")
do
    local report = Overlay.reclaimCssTemplates(BOOKS, nil, {
        max_age_days = 0, max_bytes = 0,
    })
    check("6 小时内节流", report and report.skipped == "throttled",
        report and tostring(report.skipped))

    report = Overlay.reclaimCssTemplates(ROOT .. "/not_books", nil, { force = true })
    check("非 books 根目录拒绝", report and report.skipped == "not_books",
        report and tostring(report.skipped))

    report = Overlay.reclaimCssTemplates(ROOT .. "/missing/books", nil, { force = true })
    check("不存在的根目录不报错", report and report.skipped == "no_books_dir",
        report and tostring(report.skipped))

    report = Overlay.reclaimCssTemplates(nil, nil, { force = true })
    check("空根目录拒绝", report and report.skipped == "no_root",
        report and tostring(report.skipped))
end

-- ============================================================
print("== 4. 边界：恰好等于上限 / 当前书超限 / 单次删除上限 ==")
do
    os.execute('rm -rf "' .. BOOKS .. '"')
    mkdir(BOOKS)
    local a, b = book("eq_a"), book("eq_b")
    age(template(a, 10 * 1024), 2)
    age(template(b, 10 * 1024), 1)
    local report = Overlay.reclaimCssTemplates(BOOKS, b, {
        force = true, max_age_days = 3650, max_bytes = 20 * 1024,
    })
    check("总量恰好等于上限不删", report.removed == 0 and report.kept == 2
        and report.total_bytes == 20 * 1024,
        string.format("removed=%d kept=%d total=%d",
            report.removed, report.kept, report.total_bytes))

    os.execute('rm -rf "' .. BOOKS .. '"')
    mkdir(BOOKS)
    local only = book("only_current")
    template(only, 20 * 1024)
    report = Overlay.reclaimCssTemplates(BOOKS, only, {
        force = true, max_age_days = 3650, max_bytes = 10 * 1024,
    })
    check("当前书单独超上限也保留", report.removed == 0 and report.kept == 1
        and report.total_bytes == 20 * 1024
        and exists(only .. "/css-template.css"),
        string.format("removed=%d total=%d", report.removed, report.total_bytes))

    os.execute('rm -rf "' .. BOOKS .. '"')
    mkdir(BOOKS)
    for i = 1, 5 do
        local dir = book("budget" .. i)
        age(template(dir, 1024), 40)
    end
    report = Overlay.reclaimCssTemplates(BOOKS, nil, {
        force = true, max_age_days = 30, max_bytes = 10 * 1024 * 1024, max_remove = 2,
    })
    check("单次最多删 2 份并标记 deferred", report.removed == 2 and report.deferred == true,
        string.format("removed=%d deferred=%s", report.removed, tostring(report.deferred)))
    report = Overlay.reclaimCssTemplates(BOOKS, nil, {
        force = true, max_age_days = 30, max_bytes = 10 * 1024 * 1024, max_remove = 2,
    })
    check("下一轮继续删 2 份", report.removed == 2)
    report = Overlay.reclaimCssTemplates(BOOKS, nil, {
        force = true, max_age_days = 30, max_bytes = 10 * 1024 * 1024, max_remove = 2,
    })
    check("最后一轮删完且不再 deferred", report.removed == 1 and report.deferred == false,
        string.format("removed=%d deferred=%s", report.removed, tostring(report.deferred)))

    local zero = book("zero_budget")
    local zero_path = template(zero, 1024)
    age(zero_path, 40)
    report = Overlay.reclaimCssTemplates(BOOKS, nil, {
        force = true, max_age_days = 30, max_bytes = 10 * 1024 * 1024, max_remove = 0,
    })
    check("max_remove=0 只报告不删", report.removed == 0 and report.deferred == true
        and exists(zero_path),
        string.format("removed=%d deferred=%s", report.removed, tostring(report.deferred)))
end

-- ============================================================
print("== 5. touch 与符号链接边界 ==")
do
    os.execute('rm -rf "' .. BOOKS .. '"')
    mkdir(BOOKS)
    local dir = book("touched")
    local path = template(dir, 512)
    age(path, 40)
    check("touch 不存在时返回 false 且不建文件", Overlay.touchCssTemplate(
        BOOKS .. "/no_such_book") == false
        and not exists(BOOKS .. "/no_such_book/css-template.css"))
    check("touch 已存在模板", Overlay.touchCssTemplate(dir) == true)
    local mtime = lfs.attributes(path, "modification") or 0
    check("mtime 已更新", mtime >= os.time() - 10, tostring(mtime))
    local report = Overlay.reclaimCssTemplates(BOOKS, nil, {
        force = true, max_age_days = 30, max_bytes = 10 * 1024 * 1024,
    })
    check("touch 后不被过期回收", report.removed == 0 and exists(path))

    if lfs.symlinkattributes then
        local outside = ROOT .. "/outside"
        mkdir(outside)
        local outside_file = outside .. "/css-template.css"
        write(outside_file, "outside")
        local linkdir = BOOKS .. "/linkdir"
        os.execute('ln -s "' .. outside .. '" "' .. linkdir .. '" 2>/dev/null')
        if lfs.symlinkattributes(linkdir, "mode") == "link" then
            report = Overlay.reclaimCssTemplates(BOOKS, nil, {
                force = true, max_age_days = 0, max_bytes = 0,
            })
            check("符号链接目录不跟随", exists(outside_file))
        else
            print("  SKIP: 符号链接目录创建失败")
        end

        local symbook = book("symfile")
        local symfile = symbook .. "/css-template.css"
        os.execute('ln -s "' .. outside_file .. '" "' .. symfile .. '" 2>/dev/null')
        if lfs.symlinkattributes(symfile, "mode") == "link" then
            report = Overlay.reclaimCssTemplates(BOOKS, nil, {
                force = true, max_age_days = 0, max_bytes = 0,
            })
            check("符号链接模板文件不删", exists(outside_file)
                and exists(symfile))
        else
            print("  SKIP: 符号链接文件创建失败")
        end
    end
end

print(string.format("\n==== 模板回收测试：%d 通过，%d 失败 ====", passed, failed))
if failed == 0 then
    os.execute('rm -rf "' .. ROOT .. '"')
else
    print("临时目录保留供排查：" .. ROOT)
end
os.exit(failed == 0 and 0 or 1)
