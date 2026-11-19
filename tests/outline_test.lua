-- ============================================================
-- EPUB 目录解析（P2-a / 设计 §7.2）：Tools.extract_entries 按需抽取 /
-- Epub.outline 的 NCX/nav/spine 三来源 / href 归一化与 spine 映射 /
-- 去重 / 失败清理 / outline 磁盘缓存 / 真实 libarchive 端到端 + 100 章性能
-- Run: luajit tests/outline_test.lua
-- 依赖 KOReader 自带 lfs / json（KO_ROOT 可覆盖）；缺失时跳过。
-- 第一部分用 archiver stub（内存书），第二部分用真实 libarchive 造真 EPUB，
-- libarchive 不可用时只跳过第二部分。
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
local ffi = require("ffi")
if not ffi.loadlib then ffi.loadlib = function(name) return ffi.load(name) end end
package.path = KO .. "/?.lua;" .. KO .. "/common/?.lua;" .. KO .. "/frontend/?.lua;"
    .. KO .. "/common/?/init.lua;" .. package.path
package.cpath = KO .. "/?.so;" .. KO .. "/common/?.so;" .. KO .. "/?.dylib;" .. package.cpath
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

local ROOT = "/tmp/dt_outline_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local warnings = {}
local function joinArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end
local function join_list(list)
    return table.concat(list or {}, " ")
end
local function warn_count(pattern)
    local total = 0
    for _, line in ipairs(warnings) do
        if not pattern or line:find(pattern, 1, true) then total = total + 1 end
    end
    return total
end

local current_data_dir = ROOT .. "/data_a"
package.preload["datastorage"] = function()
    return { getDataDir = function() return current_data_dir end }
end
package.preload["logger"] = function()
    return {
        warn = function(...) warnings[#warnings + 1] = joinArgs(...) end,
        err = function(...) warnings[#warnings + 1] = joinArgs(...) end,
        info = function() end,
        dbg = function() end,
    }
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
    end }
end
package.preload["dualtranslate_overlay"] = function() return {} end
package.preload["dualtranslate_lock"] = function()
    return { withBookLock = function(_, fn) return fn() end }
end
-- socket.url：优先用 KOReader 自带的真实实现（%XX 解码必须是真的）
local ok_url, real_url = pcall(require, "socket.url")
if ok_url and type(real_url) == "table" and real_url.unescape then
    package.preload["socket.url"] = function() return real_url end
else
    package.preload["socket.url"] = function()
        return { unescape = function(value)
            return (tostring(value):gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end))
        end }
    end
end

local function write_real(path, content)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then os.execute('mkdir -p "' .. parent .. '"') end
    local file = io.open(path, "wb")
    file:write(content)
    file:close()
end

local function read_real(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function temp_outline_dirs()
    local dir = current_data_dir .. "/cache/dualtranslate"
    local found = {}
    if lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name:match("^outline_") then found[#found + 1] = name end
        end
    end
    return found
end

-- ============================================================
-- archiver stub：内存书 + 与 libarchive 同语义的 extractToPath
-- （父目录必须已存在，否则失败；只解 wanted 的成员）
-- ============================================================
local stub_books = {}
local stats = { passes = 0, opened = 0, extracted = {} }
local function reset_stats()
    stats.passes, stats.opened, stats.extracted = 0, 0, {}
end
package.preload["ffi/archiver"] = function()
    return { Reader = { new = function()
        local reader = { err = nil }
        function reader:open(path)
            stats.opened = stats.opened + 1
            self.book = stub_books[path]
            self.pos = 0
            if not self.book then self.err = "cannot open " .. tostring(path); return false end
            return true
        end
        function reader:iterate()
            stats.passes = stats.passes + 1
            self.pos = 0
            if self.book.boom then error("stub iterate exploded") end
            return function()
                self.pos = self.pos + 1
                local name = self.book.ordered[self.pos]
                if not name then return nil end
                return { path = name, mode = self.book.dirs[name] and "directory" or "file",
                    size = #(self.book.files[name] or "") }
            end
        end
        function reader:extractToPath(key, dest)
            local content = self.book.files[key]
            if content == nil then self.err = "no such path"; return false end
            if self.book.fail_extract then self.err = "extract denied"; return false end
            local parent = dest:match("^(.*)/[^/]+$")
            if parent and lfs.attributes(parent, "mode") ~= "directory" then
                self.err = "no such directory"
                return false
            end
            local file = io.open(dest, "wb")
            if not file then self.err = "cannot write"; return false end
            file:write(content)
            file:close()
            stats.extracted[#stats.extracted + 1] = key
            return true
        end
        function reader:close() end
        return reader
    end } }
end

package.loaded["ffi/archiver"] = nil
local Tools = dofile("dualtranslate_tools.lua")
package.loaded["dualtranslate_tools"] = Tools
local Epub = dofile("dualtranslate_epub.lua")
package.loaded["dualtranslate_epub"] = Epub

local function stub_book(path, entries, marker)
    local files, ordered, dirs = {}, {}, {}
    for _, entry in ipairs(entries) do
        files[entry[1]] = entry[2]
        ordered[#ordered + 1] = entry[1]
        if entry[3] == "dir" then dirs[entry[1]] = true end
    end
    stub_books[path] = { files = files, ordered = ordered, dirs = dirs }
    write_real(path, marker or ("stub-epub:" .. path .. ":" .. #ordered))
    return path
end

local function cache_path(book_path)
    return current_data_dir .. "/cache/dualtranslate/outline/"
        .. Tools.stable_path_hash(book_path) .. ".json"
end

local CONTAINER = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]

local function opf(items, spine_ids, toc_id)
    local parts = { '<?xml version="1.0"?>',
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">', '<manifest>' }
    for _, item in ipairs(items) do parts[#parts + 1] = "    " .. item end
    parts[#parts + 1] = '</manifest>'
    parts[#parts + 1] = toc_id and ('<spine toc="' .. toc_id .. '">') or '<spine>'
    for _, id in ipairs(spine_ids) do
        parts[#parts + 1] = '    <itemref idref="' .. id .. '"/>'
    end
    parts[#parts + 1] = '</spine>'
    parts[#parts + 1] = '</package>'
    return table.concat(parts, "\n")
end

local function xhtml(title)
    return '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>'
        .. title .. '</title></head><body><p>' .. title .. ' content.</p></body></html>'
end

-- ============================================================
print("== 1. Tools.extract_entries 按需抽取 ==")
do
    local dest = ROOT .. "/extract1"
    local book = stub_book(ROOT .. "/books/extract.epub", {
        { "mimetype", "application/epub+zip" },
        { "META-INF/", "", "dir" },
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", "<package/>" },
        { "OEBPS/ch01.xhtml", xhtml("one") },
        { "OEBPS/images/big.png", string.rep("x", 4096) },
        { "../evil.txt", "pwned" },
        { "/absolute.txt", "pwned" },
        { "OEBPS/./ch02.xhtml", xhtml("two") },
    })
    reset_stats()
    local got, err = Tools.extract_entries(book, dest, {
        ["META-INF/container.xml"] = true,
        ["OEBPS/content.opf"] = true,
        ["OEBPS/ch01.xhtml"] = true,
        ["OEBPS/absent.xhtml"] = true,
        ["../evil.txt"] = true,
        ["/absolute.txt"] = true,
        ["META-INF/"] = true,
    })
    check("extract_entries 成功", type(got) == "table", tostring(err))
    got = got or {}
    check("只 iterate 一趟", stats.passes == 1, tostring(stats.passes))
    check("只解 wanted 的三个文件", #stats.extracted == 3, join_list(stats.extracted))
    check("未整本解包（图片未解）", read_real(dest .. "/OEBPS/images/big.png") == nil)
    check("未解 mimetype", read_real(dest .. "/mimetype") == nil)
    check("返回 map 指向真实路径", got["OEBPS/content.opf"] == dest .. "/OEBPS/content.opf")
    check("解出内容正确", read_real(got["OEBPS/ch01.xhtml"]) == xhtml("one"))
    check("缺失成员不在 map 中", got["OEBPS/absent.xhtml"] == nil)
    check("穿越成员被拒绝", got["../evil.txt"] == nil and read_real(ROOT .. "/evil.txt") == nil)
    check("绝对路径成员被拒绝", got["/absolute.txt"] == nil)
    check("目录成员被跳过", got["META-INF/"] == nil)
    check("父目录自动创建", lfs.attributes(dest .. "/OEBPS", "mode") == "directory")

    -- 归一化名匹配（"./" 前缀 / 反斜杠），wanted 用规范名
    reset_stats()
    local got2 = Tools.extract_entries(book, ROOT .. "/extract2", { ["OEBPS/ch02.xhtml"] = true })
    check("规范化成员名可匹配", got2["OEBPS/ch02.xhtml"] ~= nil)
    check("规范化后落盘路径安全", read_real(ROOT .. "/extract2/OEBPS/ch02.xhtml") == xhtml("two"))

    -- 原始名精确匹配
    reset_stats()
    local got3 = Tools.extract_entries(book, ROOT .. "/extract3", { ["OEBPS/./ch02.xhtml"] = true })
    check("原始成员名精确匹配", got3["OEBPS/./ch02.xhtml"] ~= nil)

    reset_stats()
    local empty = Tools.extract_entries(book, ROOT .. "/extract4", {})
    check("空 wanted 返回空表", type(empty) == "table" and next(empty) == nil)
    check("空 wanted 不开档", stats.opened == 0)

    local missing, missing_err = Tools.extract_entries(ROOT .. "/books/nope.epub",
        ROOT .. "/extract5", { ["META-INF/container.xml"] = true })
    check("开档失败返回 nil,err", missing == nil and type(missing_err) == "string")

    stub_books[book].fail_extract = true
    local broken, broken_err = Tools.extract_entries(book, ROOT .. "/extract6",
        { ["META-INF/container.xml"] = true })
    check("抽取失败返回 nil,err", broken == nil and type(broken_err) == "string")
    stub_books[book].fail_extract = nil
end

-- ============================================================
print("== 2. NCX：嵌套 navPoint / 多锚点去重 / aliases ==")
do
    local ncx = [[<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:1"/></head>
  <docTitle><text>Book Title</text></docTitle>
  <navMap>
    <navPoint id="p1" playOrder="1">
      <navLabel><text>Part One</text></navLabel>
      <content src="Text/part1.xhtml"/>
      <navPoint id="p2" playOrder="2">
        <navLabel><text>Chapter &amp; One</text></navLabel>
        <content src="Text/ch01.xhtml#start"/>
      </navPoint>
      <navPoint id="p3" playOrder="3">
        <navLabel><text>Chapter One continued</text></navLabel>
        <content src="Text/ch01.xhtml#sec2"/>
      </navPoint>
    </navPoint>
    <navPoint id="p4" playOrder="4">
      <navLabel><text>Chapter Two</text></navLabel>
      <content src="Text/ch02.xhtml"/>
    </navPoint>
    <navPoint id="p5" playOrder="5">
      <navLabel><text>  Chapter   Three  </text></navLabel>
      <content src="Text/ch03.xhtml"/>
    </navPoint>
  </navMap>
</ncx>]]
    local book = stub_book(ROOT .. "/books/ncx.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="p1" href="Text/part1.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c2" href="Text/ch02.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c3" href="Text/ch03.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c4" href="Text/ch04.xhtml" media-type="application/xhtml+xml"/>',
        }, { "p1", "c1", "c2", "c3", "c4" }, "ncx") },
        { "OEBPS/toc.ncx", ncx },
        { "OEBPS/Text/part1.xhtml", xhtml("part1") },
        { "OEBPS/Text/ch01.xhtml", xhtml("ch01") },
        { "OEBPS/Text/ch02.xhtml", xhtml("ch02") },
        { "OEBPS/Text/ch03.xhtml", xhtml("ch03") },
        { "OEBPS/Text/ch04.xhtml", xhtml("ch04") },
    })
    reset_stats()
    local outline, err = Epub.outline(book)
    check("NCX outline 成功", outline ~= nil, tostring(err))
    check("source=ncx", outline and outline.source == "ncx")
    check("spine_count=5（含未列入目录的章）", outline and outline.spine_count == 5)
    check("目录项去重后 4 条", outline and #outline.chapters == 4,
        tostring(outline and #outline.chapters))
    local c = outline and outline.chapters or {}
    check("嵌套层级 level", c[1] and c[1].level == 0 and c[2] and c[2].level == 1)
    check("spine index 从 1 开始", c[1] and c[1].index == 1 and c[2] and c[2].index == 2)
    check("实体解码标题", c[2] and c[2].title == "Chapter & One", tostring(c[2] and c[2].title))
    check("标题空白归一", c[4] and c[4].title == "Chapter Three", tostring(c[4] and c[4].title))
    check("href 用 manifest 原始路径", c[2] and c[2].href == "OEBPS/Text/ch01.xhtml")
    check("fragment 不参与映射", c[2] and c[2].index == 2)
    check("多锚点同 index 只留一条", c[3] and c[3].index == 3 and c[3].title == "Chapter Two")
    check("后续标题进 aliases", c[2] and c[2].aliases and c[2].aliases[1] == "Chapter One continued")
    check("三趟抽取", stats.passes == 3, tostring(stats.passes))
    check("只解 container/OPF/NCX", #stats.extracted == 3, join_list(stats.extracted))
    check("章节 XHTML 未被解包", join_list(stats.extracted):find("ch01.xhtml") == nil,
        join_list(stats.extracted))
    check("临时目录已清理", #temp_outline_dirs() == 0, join_list(temp_outline_dirs()))
    check("未告警（全部命中 spine）", warn_count("not in spine") == 0)

    -- 条目视图：同一文件的多个 TOC 条目各自保留锚点，供选择器按章出行
    local entries = outline and outline.entries or {}
    check("每条目录一条 entries", #entries == 5, tostring(#entries))
    check("无 fragment 的条目 anchor 为空", entries[1] and entries[1].anchor == nil)
    check("条目保留锚点", entries[2] and entries[2].anchor == "start",
        tostring(entries[2] and entries[2].anchor))
    check("条目锚点互不覆盖", entries[3] and entries[3].anchor == "sec2"
        and entries[3].index == 2)
    check("条目与文件视图同 index", entries[2] and entries[2].index == 2
        and entries[1].index == 1)

    -- 层级最浅者优先：深项先出现，浅项后出现
    local book2 = stub_book(ROOT .. "/books/ncx_shallow.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="p1" href="Text/part1.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
        }, { "p1", "c1" }, "ncx") },
        { "OEBPS/toc.ncx", [[<ncx><navMap>
            <navPoint id="a"><navLabel><text>Part</text></navLabel>
              <content src="Text/part1.xhtml"/>
              <navPoint id="b"><navLabel><text>Deep Section</text></navLabel>
                <content src="Text/ch01.xhtml#deep"/></navPoint>
            </navPoint>
            <navPoint id="c"><navLabel><text>Shallow Chapter</text></navLabel>
              <content src="Text/ch01.xhtml"/></navPoint>
        </navMap></ncx>]] },
    })
    local outline2 = Epub.outline(book2)
    local shallow
    for _, chapter in ipairs(outline2 and outline2.chapters or {}) do
        if chapter.index == 2 then shallow = chapter end
    end
    check("同 index 保留层级最浅标题", shallow and shallow.title == "Shallow Chapter"
        and shallow.level == 0, tostring(shallow and shallow.title))
    check("被替换的深标题进 aliases", shallow and shallow.aliases
        and shallow.aliases[1] == "Deep Section", join_list(shallow and shallow.aliases or {}))
end

-- ============================================================
print("== 3. EPUB3 nav：ol/li/a 嵌套 / landmarks 排除 ==")
do
    local nav = [[<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Nav</title></head>
<body>
  <nav epub:type="landmarks" id="landmarks">
    <ol><li><a href="Text/ch01.xhtml">Begin Reading</a></li></ol>
  </nav>
  <nav epub:type="toc" id="toc">
    <h2>Contents</h2>
    <ol>
      <li><a href="Text/ch01.xhtml">Chapter <span>One</span></a>
        <ol>
          <li><a href="Text/ch01.xhtml#s1">Section 1</a></li>
          <li><a href="Text/ch02.xhtml">Chapter Two</a></li>
        </ol>
      </li>
      <li><a href="Text/ch03.xhtml">Chapter Three</a></li>
      <li><a href="Text/ch04.xhtml">日本語の章</a></li>
    </ol>
  </nav>
  <nav epub:type="page-list">
    <ol><li><a href="Text/ch01.xhtml#p1">1</a></li></ol>
  </nav>
</body>
</html>]]
    local book = stub_book(ROOT .. "/books/nav.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c2" href="Text/ch02.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c3" href="Text/ch03.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c4" href="Text/ch04.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1", "c2", "c3", "c4" }) },
        { "OEBPS/nav.xhtml", nav },
        { "OEBPS/Text/ch01.xhtml", xhtml("ch01") },
        { "OEBPS/Text/ch02.xhtml", xhtml("ch02") },
        { "OEBPS/Text/ch03.xhtml", xhtml("ch03") },
        { "OEBPS/Text/ch04.xhtml", xhtml("ch04") },
    })
    reset_stats()
    local outline, err = Epub.outline(book)
    check("nav outline 成功", outline ~= nil, tostring(err))
    check("source=nav", outline and outline.source == "nav")
    check("spine_count=4", outline and outline.spine_count == 4)
    check("nav 去重后 4 条（Section 1 与第一章同 index）", outline and #outline.chapters == 4,
        tostring(outline and #outline.chapters))
    local c = outline and outline.chapters or {}
    check("嵌套标题剥离 span", c[1] and c[1].title == "Chapter One", tostring(c[1] and c[1].title))
    check("nav 顶层 level=0", c[1] and c[1].level == 0)
    check("nav 嵌套 level=1", c[2] and c[2].level == 1 and c[2].index == 2)
    check("CJK 标题保留", c[4] and c[4].title == "日本語の章", tostring(c[4] and c[4].title))
    check("landmarks/page-list 未被当作目录",
        c[1] and c[1].title ~= "Begin Reading" and #c == 4)
    check("同文件锚点进 aliases", c[1] and c[1].aliases and c[1].aliases[1] == "Section 1")
    check("nav 也是三趟抽取", stats.passes == 3 and #stats.extracted == 3)
    check("临时目录已清理", #temp_outline_dirs() == 0)

    -- NCX 与 nav 同时存在：按设计优先级取 NCX
    local both = stub_book(ROOT .. "/books/both.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1" }, "ncx") },
        { "OEBPS/nav.xhtml", nav },
        { "OEBPS/toc.ncx", [[<ncx><navMap><navPoint id="n1">
            <navLabel><text>NCX wins</text></navLabel><content src="Text/ch01.xhtml"/>
        </navPoint></navMap></ncx>]] },
    })
    local outline_both = Epub.outline(both)
    check("NCX 优先于 nav", outline_both and outline_both.source == "ncx"
        and outline_both.chapters[1].title == "NCX wins")

    -- 只有 spine toc 指向的 NCX（manifest 未标 media-type）
    local toc_only = stub_book(ROOT .. "/books/toc_only.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="legacy" href="toc.ncx"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1" }, "legacy") },
        { "OEBPS/toc.ncx", [[<ncx><navMap><navPoint id="n1">
            <navLabel><text>From spine toc</text></navLabel><content src="Text/ch01.xhtml"/>
        </navPoint></navMap></ncx>]] },
    })
    local outline_toc = Epub.outline(toc_only)
    check("spine toc 指向的 NCX 可用", outline_toc and outline_toc.source == "ncx"
        and outline_toc.chapters[1].title == "From spine toc")

    -- nav 缺 epub:type 时回退到唯一无类型 nav
    local untyped = stub_book(ROOT .. "/books/untyped.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1" }) },
        { "OEBPS/nav.xhtml", '<html><body><nav><ol><li><a href="Text/ch01.xhtml">Untyped</a></li></ol></nav></body></html>' },
    })
    local outline_untyped = Epub.outline(untyped)
    check("无 epub:type 的 nav 回退可用", outline_untyped and outline_untyped.source == "nav"
        and outline_untyped.chapters[1].title == "Untyped")
end

-- ============================================================
print("== 3b. 目录解析回归：CDATA 标题 / div 包裹的 nav ==")
do
    -- <![CDATA[...]]> 里的标题不能被当成标签删除（InDesign、部分中文
    -- EPUB 转换器会这样包裹目录标题）。这里必须用 [=[ ]=] 长括号，
    -- 因为 CDATA 结尾的 "]]>" 会提前终止 [[ ]] 字符串。
    local cdata = stub_book(ROOT .. "/books/ncx_cdata.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c2" href="Text/ch02.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1", "c2" }, "ncx") },
        { "OEBPS/toc.ncx", [=[<ncx><navMap>
            <navPoint id="a"><navLabel><text><![CDATA[Chapter One]]></text></navLabel>
              <content src="Text/ch01.xhtml"/></navPoint>
            <navPoint id="b"><navLabel><text>Chapter Two</text></navLabel>
              <content src="Text/ch02.xhtml"/></navPoint>
        </navMap></ncx>]=] },
    })
    local cdata_outline = Epub.outline(cdata)
    local cdata_title = cdata_outline and cdata_outline.chapters[1]
        and cdata_outline.chapters[1].title
    check("CDATA 标题保留", cdata_title == "Chapter One", tostring(cdata_title))

    -- <nav epub:type="toc"><div><ol> 结构（不规范但真实存在）不能退回
    -- spine 目录，否则整本书的章节标题全变成「第 N 节」。
    local wrapped = stub_book(ROOT .. "/books/nav_wrapped.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c2" href="Text/ch02.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1", "c2" }) },
        { "OEBPS/nav.xhtml", [[<html xmlns="http://www.w3.org/1999/xhtml"
            xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><h2>Contents</h2><div class="toc"><ol>
            <li><a href="Text/ch01.xhtml">Wrapped One</a></li>
            <li><a href="Text/ch02.xhtml">Wrapped Two</a></li>
          </ol></div></nav></body></html>]] },
    })
    local wrapped_outline, wrapped_err = Epub.outline(wrapped)
    check("div 包裹的 nav ol 仍可解析", wrapped_outline ~= nil
        and wrapped_outline.source == "nav" and #wrapped_outline.chapters == 2,
        tostring(wrapped_err))
    local wrapped_title = wrapped_outline and wrapped_outline.chapters[1]
        and wrapped_outline.chapters[1].title
    check("div 包裹的 nav 标题正确", wrapped_title == "Wrapped One", tostring(wrapped_title))
end

-- ============================================================
print("== 4. 无目录：spine 回退 ==")
do
    local book = stub_book(ROOT .. "/books/no_toc.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c2" href="Text/ch02.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c3" href="Text/ch03.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1", "c2", "c3" }) },
        { "OEBPS/Text/ch01.xhtml", xhtml("ch01") },
    })
    reset_stats()
    local outline, err = Epub.outline(book)
    check("无目录 outline 成功", outline ~= nil, tostring(err))
    check("source=spine", outline and outline.source == "spine")
    check("spine_count=3", outline and outline.spine_count == 3)
    check("每章一条", outline and #outline.chapters == 3)
    check("回退标题「第 N 节」", outline and outline.chapters[2].title == "第 2 节",
        tostring(outline and outline.chapters[2].title))
    check("回退 href 为 spine 路径", outline and outline.chapters[3].href == "OEBPS/Text/ch03.xhtml")
    check("回退 index 连续", outline and outline.chapters[1].index == 1
        and outline.chapters[3].index == 3)
    check("无目录只抽两趟", stats.passes == 2, tostring(stats.passes))
    check("临时目录已清理", #temp_outline_dirs() == 0)

    -- 目录存在但全部匹配不到 -> 仍回退 spine（不是 nil）
    local broken_toc = stub_book(ROOT .. "/books/broken_toc.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1" }, "ncx") },
        { "OEBPS/toc.ncx", [[<ncx><navMap><navPoint id="n1">
            <navLabel><text>Ghost</text></navLabel><content src="Text/ghost.xhtml"/>
        </navPoint></navMap></ncx>]] },
    })
    warnings = {}
    local outline_broken = Epub.outline(broken_toc)
    check("目录全不命中回退 spine", outline_broken and outline_broken.source == "spine"
        and #outline_broken.chapters == 1)
    check("全不命中有告警", warn_count("not in spine") >= 1)
end

-- ============================================================
print("== 5. href 编码 / .. 归一化 / 大小写 / 未命中跳过 ==")
do
    local ncx = [[<ncx><navMap>
  <navPoint id="n1"><navLabel><text>Encoded</text></navLabel>
    <content src="Text/ch%2001.xhtml#frag"/></navPoint>
  <navPoint id="n2"><navLabel><text>DotDot</text></navLabel>
    <content src="../Text/ch02.xhtml"/></navPoint>
  <navPoint id="n3"><navLabel><text>CaseUnique</text></navLabel>
    <content src="text/CH03.XHTML"/></navPoint>
  <navPoint id="n4"><navLabel><text>Missing</text></navLabel>
    <content src="Text/ghost.xhtml"/></navPoint>
  <navPoint id="n5"><navLabel><text>AfterMissing</text></navLabel>
    <content src="Text/ch04.xhtml"/></navPoint>
  <navPoint id="n6"><navLabel><text>External</text></navLabel>
    <content src="http://example.com/x.xhtml"/></navPoint>
  <navPoint id="n7"><navLabel><text>SelfFragment</text></navLabel>
    <content src="#only-fragment"/></navPoint>
</navMap></ncx>]]
    local book = stub_book(ROOT .. "/books/href.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="c1" href="Text/ch%2001.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c2" href="../Text/ch02.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c3" href="Text/Ch03.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c4" href="Text/ch04.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1", "c2", "c3", "c4" }, "ncx") },
        { "OEBPS/toc.ncx", ncx },
    })
    warnings = {}
    local outline, err = Epub.outline(book)
    check("href 用例 outline 成功", outline ~= nil, tostring(err))
    local c = outline and outline.chapters or {}
    check("百分号编码命中", c[1] and c[1].index == 1 and c[1].title == "Encoded")
    check("编码 href 输出解码后的 manifest 原值",
        c[1] and c[1].href == "OEBPS/Text/ch 01.xhtml", tostring(c[1] and c[1].href))
    check(".. 归一化命中", c[2] and c[2].index == 2 and c[2].href == "Text/ch02.xhtml",
        tostring(c[2] and c[2].href))
    check("大小写不一致但唯一 -> 接受", c[3] and c[3].index == 3)
    check("大小写命中输出 manifest 原始大小写",
        c[3] and c[3].href == "OEBPS/Text/Ch03.xhtml", tostring(c[3] and c[3].href))
    check("未命中项被跳过（不猜前一个）", c[4] and c[4].title == "AfterMissing"
        and c[4].index == 4, tostring(c[4] and c[4].title))
    check("共 4 条（缺项/外链/纯锚点均跳过）", #c == 4, tostring(#c))
    check("未命中有 logger.warn", warn_count("Text/ghost.xhtml") >= 1)
    check("外链有 logger.warn", warn_count("http://example.com") >= 1)

    -- 大小写不一致且歧义 -> 跳过
    local ambiguous = stub_book(ROOT .. "/books/ambiguous.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="a" href="Text/Ch01.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="b" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
        }, { "a", "b" }, "ncx") },
        { "OEBPS/toc.ncx", [[<ncx><navMap><navPoint id="n1">
            <navLabel><text>Ambiguous</text></navLabel><content src="TEXT/CH01.XHTML"/>
        </navPoint></navMap></ncx>]] },
    })
    warnings = {}
    local outline_amb = Epub.outline(ambiguous)
    check("大小写歧义 -> 回退 spine", outline_amb and outline_amb.source == "spine")
    check("大小写歧义有告警", warn_count("not in spine") >= 1)

    -- 同一文件在 spine 中重复出现：大小写仍视为唯一
    local dup = stub_book(ROOT .. "/books/dup.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="a" href="Text/Ch01.xhtml" media-type="application/xhtml+xml"/>',
        }, { "a", "a" }, "ncx") },
        { "OEBPS/toc.ncx", [[<ncx><navMap><navPoint id="n1">
            <navLabel><text>Dup</text></navLabel><content src="text/ch01.xhtml"/>
        </navPoint></navMap></ncx>]] },
    })
    local outline_dup = Epub.outline(dup)
    check("spine 重复同文件不算歧义", outline_dup and outline_dup.source == "ncx"
        and outline_dup.chapters[1].index == 1 and outline_dup.spine_count == 2)
end

-- ============================================================
print("== 6. 失败路径：nil,err + 临时目录必删 ==")
do
    local cases = {}
    -- 缺 container.xml
    cases[#cases + 1] = { name = "缺 container.xml", path = stub_book(ROOT .. "/books/f1.epub", {
        { "OEBPS/content.opf", opf({}, {}) },
    }), err = "container" }
    -- container 无 rootfile
    cases[#cases + 1] = { name = "container 无 rootfile", path = stub_book(ROOT .. "/books/f2.epub", {
        { "META-INF/container.xml", "<container><rootfiles/></container>" },
    }), err = "OPF" }
    -- OPF 不在包内
    cases[#cases + 1] = { name = "OPF 缺失", path = stub_book(ROOT .. "/books/f3.epub", {
        { "META-INF/container.xml", CONTAINER },
    }), err = "OPF" }
    -- spine 为空
    cases[#cases + 1] = { name = "spine 为空", path = stub_book(ROOT .. "/books/f4.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({ '<item id="c1" href="a.xhtml"/>' }, {}) },
    }), err = "spine" }
    for _, case in ipairs(cases) do
        local result, err = Epub.outline(case.path)
        check(case.name .. " 返回 nil", result == nil)
        check(case.name .. " 错误信息", type(err) == "string" and err:find(case.err, 1, true) ~= nil,
            tostring(err))
        check(case.name .. " 临时目录已清理", #temp_outline_dirs() == 0, join_list(temp_outline_dirs()))
    end

    -- 开档失败（DRM/损坏）
    write_real(ROOT .. "/books/drm.epub", "not a zip at all")
    local drm, drm_err = Epub.outline(ROOT .. "/books/drm.epub")
    check("开档失败返回 nil,err", drm == nil and type(drm_err) == "string")
    check("开档失败临时目录已清理", #temp_outline_dirs() == 0)

    -- 抽取失败
    local fail_book = stub_book(ROOT .. "/books/fail_extract.epub", {
        { "META-INF/container.xml", CONTAINER },
    })
    stub_books[fail_book].fail_extract = true
    local fx, fx_err = Epub.outline(fail_book)
    check("抽取失败返回 nil,err", fx == nil and type(fx_err) == "string")
    check("抽取失败临时目录已清理", #temp_outline_dirs() == 0)
    stub_books[fail_book].fail_extract = nil

    -- iterate 抛错：extract_entries 内部 pcall 兜住，仍是 nil,err + 清理
    local boom_book = stub_book(ROOT .. "/books/boom.epub", {
        { "META-INF/container.xml", CONTAINER },
    })
    stub_books[boom_book].boom = true
    local boom, boom_err = Epub.outline(boom_book)
    check("iterate 异常返回 nil,err", boom == nil and type(boom_err) == "string", tostring(boom_err))
    check("iterate 异常临时目录已清理", #temp_outline_dirs() == 0)
    stub_books[boom_book].boom = nil

    -- 抽取之外的意外异常：outline 的 pcall 仍必须删临时目录
    local real_extract_entries = Tools.extract_entries
    Tools.extract_entries = function() error("outline exploded") end
    local crash, crash_err = Epub.outline(boom_book)
    Tools.extract_entries = real_extract_entries
    check("意外异常返回 nil,err", crash == nil and type(crash_err) == "string"
        and crash_err:find("outline exploded", 1, true) ~= nil, tostring(crash_err))
    check("意外异常临时目录已清理", #temp_outline_dirs() == 0, join_list(temp_outline_dirs()))

    -- 非 EPUB / 空路径 / 文件不存在
    local not_epub, ne_err = Epub.outline(ROOT .. "/books/book.pdf")
    check("非 EPUB 报错", not_epub == nil and ne_err:find("EPUB", 1, true) ~= nil)
    local no_path, np_err = Epub.outline(nil)
    check("空路径报错", no_path == nil and type(np_err) == "string")
    local absent, ab_err = Epub.outline(ROOT .. "/books/absent.epub")
    check("书文件不存在报错", absent == nil and type(ab_err) == "string")
    check("失败路径不留临时目录", #temp_outline_dirs() == 0)

    -- 冒号调用风格也可用（PR-6 接线兼容）
    local ok_book = stub_book(ROOT .. "/books/colon.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({ '<item id="c1" href="a.xhtml"/>' }, { "c1" }) },
    })
    local colon = Epub:outline(ok_book)
    check("Epub:outline 冒号调用可用", colon and colon.source == "spine")
end

-- ============================================================
print("== 7. outline 磁盘缓存：命中 / size,mtime 失效 / 损坏 ==")
do
    local book = stub_book(ROOT .. "/books/cached.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="c1" href="Text/ch01.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="c2" href="Text/ch02.xhtml" media-type="application/xhtml+xml"/>',
        }, { "c1", "c2" }, "ncx") },
        { "OEBPS/toc.ncx", [[<ncx><navMap>
            <navPoint id="n1"><navLabel><text>One</text></navLabel>
                <content src="Text/ch01.xhtml"/></navPoint>
            <navPoint id="n2"><navLabel><text>One alias</text></navLabel>
                <content src="Text/ch01.xhtml#b"/></navPoint>
            <navPoint id="n3"><navLabel><text>Two</text></navLabel>
                <content src="Text/ch02.xhtml"/></navPoint>
        </navMap></ncx>]] },
    })
    local path = cache_path(book)
    os.remove(path)
    reset_stats()
    -- before_parse 只在真的要解析时才回调（选择器靠它先画"正在解析目录…"）
    local before_parse_calls = 0
    local first = Epub.outline(book, function() before_parse_calls = before_parse_calls + 1 end)
    check("首次解析成功", first ~= nil and first.source == "ncx")
    check("冷解析调用 before_parse 一次", before_parse_calls == 1, tostring(before_parse_calls))
    check("首次解析走三趟", stats.passes == 3, tostring(stats.passes))
    check("缓存文件落在 outline/<hash>.json", lfs.attributes(path, "mode") == "file", path)
    local doc = JSON.decode(read_real(path))
    check("缓存记录 book_path", doc.book_path == book)
    check("缓存记录 size", doc.book_size == lfs.attributes(book, "size"))
    check("缓存记录 mtime", doc.book_mtime == lfs.attributes(book, "modification"))
    check("缓存记录 source/spine_count", doc.source == "ncx" and doc.spine_count == 2)
    check("缓存写入条目与锚点", type(doc.entries) == "table" and #doc.entries == 3
        and doc.entries[2].anchor == "b", tostring(doc.entries and #doc.entries))

    reset_stats()
    local second = Epub.outline(book)
    check("二次打开命中缓存（零解包）", stats.passes == 0 and stats.opened == 0,
        tostring(stats.passes))
    check("缓存命中不调用 before_parse", before_parse_calls == 1, tostring(before_parse_calls))
    check("缓存结果与首次一致", second and #second.chapters == #first.chapters
        and second.chapters[1].title == "One" and second.chapters[2].title == "Two")
    check("缓存保留 level", second and second.chapters[1].level == 0)
    check("缓存保留 aliases", second and second.chapters[1].aliases
        and second.chapters[1].aliases[1] == "One alias")
    check("缓存保留 entries 与锚点", second and second.entries and #second.entries == 3
        and second.entries[2].anchor == "b", tostring(second and second.entries
        and #second.entries))
    check("缓存命中不建临时目录", #temp_outline_dirs() == 0)

    -- size 变化 -> 失效
    write_real(book, "stub-epub:changed-size:xxxxxxxxxxxxxxxx")
    reset_stats()
    local after_size = Epub.outline(book)
    check("size 变化后重新解析", stats.passes == 3 and after_size ~= nil, tostring(stats.passes))

    -- 仅 mtime 变化（size 不变）-> 失效
    local size_now = lfs.attributes(book, "size")
    local mtime_now = lfs.attributes(book, "modification")
    lfs.touch(book, os.time(), mtime_now + 17)
    reset_stats()
    local after_mtime = Epub.outline(book)
    check("mtime 变化后重新解析", stats.passes == 3 and after_mtime ~= nil, tostring(stats.passes))
    check("size 未变（确认只改了 mtime）", lfs.attributes(book, "size") == size_now)

    -- 损坏 JSON -> 重新解析且不报错
    reset_stats()
    write_real(path, "{this is not json")
    local after_corrupt = Epub.outline(book)
    check("损坏缓存自动重解析", after_corrupt ~= nil and stats.passes == 3)
    check("损坏缓存被覆盖为合法 JSON", JSON.decode(read_real(path)).book_path == book)

    -- book_path 不符 -> 失效
    local doc2 = JSON.decode(read_real(path))
    doc2.book_path = "/some/other/book.epub"
    write_real(path, JSON.encode(doc2))
    reset_stats()
    check("book_path 不符则失效", Epub.outline(book) ~= nil and stats.passes == 3)

    -- 版本不符 -> 失效
    local doc3 = JSON.decode(read_real(path))
    doc3.version = 99
    write_real(path, JSON.encode(doc3))
    reset_stats()
    check("缓存版本不符则失效", Epub.outline(book) ~= nil and stats.passes == 3)

    -- v1 缓存没有 entries：必须重解析，否则旧书永远只有文件粒度的列表
    local doc_old = JSON.decode(read_real(path))
    doc_old.version = 1
    doc_old.entries = nil
    write_real(path, JSON.encode(doc_old))
    reset_stats()
    local upgraded = Epub.outline(book)
    check("v1 缓存失效并补齐 entries", upgraded ~= nil and stats.passes == 3
        and #(upgraded.entries or {}) == 3, tostring(stats.passes))

    -- 章节形状非法 -> 失效
    local doc4 = JSON.decode(read_real(path))
    doc4.chapters = { { index = "bad", title = 1, href = false } }
    write_real(path, JSON.encode(doc4))
    reset_stats()
    check("缓存章节形状非法则失效", Epub.outline(book) ~= nil and stats.passes == 3)

    -- 另一本书不共用缓存
    local other = stub_book(ROOT .. "/books/cached_other.epub", {
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", opf({ '<item id="c1" href="z.xhtml"/>' }, { "c1" }) },
    })
    reset_stats()
    local other_outline = Epub.outline(other)
    check("不同书各自解析", other_outline and other_outline.spine_count == 1 and stats.passes == 2)
    check("不同书缓存文件不同", cache_path(other) ~= path)

    -- spine 降级书没有 TOC：entries 是空表，v2 缓存必须能原样读回，
    -- 不能因为"缺 entries"又重解析一遍。
    reset_stats()
    local other_again = Epub.outline(other)
    check("spine 降级书 v2 缓存可读回", other_again ~= nil
        and type(other_again.entries) == "table" and #other_again.entries == 0
        and stats.passes == 0, tostring(stats.passes))
end

-- ============================================================
print("== 8. 真实 libarchive：真 EPUB 端到端 + 100 章性能 ==")
package.preload["ffi/archiver"] = nil
package.loaded["ffi/archiver"] = nil
local ok_archiver, RealArchiver = pcall(require, "ffi/archiver")
if not ok_archiver or type(RealArchiver) ~= "table"
    or not RealArchiver.Reader or not RealArchiver.Writer then
    print("  SKIP: ffi/archiver (libarchive) unavailable")
else
    current_data_dir = ROOT .. "/data_b"
    os.execute('mkdir -p "' .. current_data_dir .. '"')
    package.loaded["ffi/archiver"] = RealArchiver
    Tools = dofile("dualtranslate_tools.lua")
    package.loaded["dualtranslate_tools"] = Tools
    Epub = dofile("dualtranslate_epub.lua")
    package.loaded["dualtranslate_epub"] = Epub

    local real_extract_calls = {}
    local real_extract_entries = Tools.extract_entries
    Tools.extract_entries = function(archive_path, dest_dir, wanted)
        local result, err = real_extract_entries(archive_path, dest_dir, wanted)
        local names = {}
        for name in pairs(wanted) do names[#names + 1] = name end
        table.sort(names)
        real_extract_calls[#real_extract_calls + 1] = {
            wanted = names, got = result, err = err,
        }
        return result, err
    end

    -- 用 Writer:addPath 从磁盘树造书（保留真实文件权限；
    -- addFileFromMemory 的 0644 是十进制，解出的文件属主不可读）
    local function build_epub(tree, epub_path)
        os.execute('rm -f "' .. epub_path .. '"')
        os.execute('mkdir -p "' .. epub_path:match("^(.*)/[^/]+$") .. '"')
        local writer = RealArchiver.Writer:new()
        if not writer:open(epub_path, "epub") then return false end
        writer:addPath(".", tree, true)
        writer:close()
        return (lfs.attributes(epub_path, "size") or 0) > 0
    end

    local tree = ROOT .. "/tree100"
    os.execute('rm -rf "' .. tree .. '"')
    os.execute('mkdir -p "' .. tree .. '/META-INF" "' .. tree .. '/OEBPS/Text" "'
        .. tree .. '/OEBPS/images"')
    write_real(tree .. "/mimetype", "application/epub+zip")
    write_real(tree .. "/META-INF/container.xml", CONTAINER)
    local items, spine_ids, navpoints = {}, {}, {}
    for index = 1, 100 do
        local file = index == 1 and "ch 001.xhtml" or string.format("ch%03d.xhtml", index)
        local href = index == 1 and "ch%20001.xhtml" or string.format("ch%03d.xhtml", index)
        items[#items + 1] = string.format(
            '<item id="c%d" href="Text/%s" media-type="application/xhtml+xml"/>', index, href)
        spine_ids[#spine_ids + 1] = "c" .. index
        navpoints[#navpoints + 1] = string.format(
            '<navPoint id="n%d" playOrder="%d"><navLabel><text>Chapter %d</text></navLabel>'
            .. '<content src="Text/%s"/></navPoint>', index, index, index, href)
        write_real(tree .. "/OEBPS/Text/" .. file, xhtml("Chapter " .. index))
    end
    -- 第 10 章下挂一个同文件锚点子项（去重后仍应是 100 条）
    navpoints[10] = navpoints[10]:gsub("</navPoint>$", "")
        .. '<navPoint id="n10b" playOrder="101"><navLabel><text>Chapter 10 detail</text></navLabel>'
        .. '<content src="Text/ch010.xhtml#detail"/></navPoint></navPoint>'
    items[#items + 1] = '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
    write_real(tree .. "/OEBPS/content.opf", opf(items, spine_ids, "ncx"))
    write_real(tree .. "/OEBPS/toc.ncx",
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>'
        .. table.concat(navpoints, "\n") .. '</navMap></ncx>')
    -- 1MB 图片：证明 outline 不会把整本书解出来
    write_real(tree .. "/OEBPS/images/big.png", string.rep("abcdefgh", 131072))
    local epub100 = ROOT .. "/books_real/100.epub"
    check("真实 EPUB 造书成功", build_epub(tree, epub100))

    real_extract_calls = {}
    local outline, err = Epub.outline(epub100)
    check("真书 outline 成功", outline ~= nil, tostring(err))
    check("真书 source=ncx", outline and outline.source == "ncx")
    check("真书 spine_count=100", outline and outline.spine_count == 100,
        tostring(outline and outline.spine_count))
    check("真书 100 条（锚点子项去重）", outline and #outline.chapters == 100,
        tostring(outline and #outline.chapters))
    check("真书首章标题", outline and outline.chapters[1].title == "Chapter 1")
    check("真书首章 index=1", outline and outline.chapters[1].index == 1)
    check("真书末章 index=100", outline and outline.chapters[100].index == 100
        and outline.chapters[100].title == "Chapter 100")
    check("真书百分号编码 href 解码", outline and outline.chapters[1].href
        == "OEBPS/Text/ch 001.xhtml", tostring(outline and outline.chapters[1].href))
    check("真书三趟抽取", #real_extract_calls == 3, tostring(#real_extract_calls))
    local total_extracted = 0
    for _, call in ipairs(real_extract_calls) do
        for _ in pairs(call.got or {}) do total_extracted = total_extracted + 1 end
    end
    check("真书只解 3 个文件（不含 1MB 图片）", total_extracted == 3, tostring(total_extracted))
    check("真书临时目录已清理", #temp_outline_dirs() == 0, join_list(temp_outline_dirs()))

    -- 缓存命中：不再开档
    real_extract_calls = {}
    local cached = Epub.outline(epub100)
    check("真书缓存命中零抽取", #real_extract_calls == 0 and cached
        and #cached.chapters == 100)

    -- 性能：5 次冷解析取中位数（设计 §15.4 目标 <500ms）
    -- 墙钟：KOReader 的 posix_h 已声明 clock_gettime/struct timespec 时直接复用，
    -- 否则自行声明；都不可用时退回 os.clock（CPU 时间）。
    local wall_now
    pcall(function()
        local ts
        if pcall(ffi.typeof, "struct timespec") then
            ts = ffi.new("struct timespec")
        else
            ffi.cdef[[ struct dt_outline_timespec { long tv_sec; long tv_nsec; };
                int clock_gettime(int, struct dt_outline_timespec *); ]]
            ts = ffi.new("struct dt_outline_timespec")
        end
        if ffi.C.clock_gettime(0, ts) == 0 then
            wall_now = function()
                ffi.C.clock_gettime(0, ts)
                return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
            end
        end
    end)
    local clock_label = wall_now and "wall" or "cpu"
    wall_now = wall_now or os.clock
    local cache_file = cache_path(epub100)
    local samples = {}
    for _ = 1, 5 do
        os.remove(cache_file)
        local started = wall_now()
        local result = Epub.outline(epub100)
        samples[#samples + 1] = (wall_now() - started) * 1000
        if not result then samples[#samples] = math.huge end
    end
    table.sort(samples)
    local median = samples[3]
    print(string.format("  INFO: 100 章冷解析中位数 %.1f ms（%s，5 次：%s）目标 <500ms",
        median, clock_label, table.concat({
            string.format("%.1f", samples[1]), string.format("%.1f", samples[2]),
            string.format("%.1f", samples[3]), string.format("%.1f", samples[4]),
            string.format("%.1f", samples[5]) }, "/")))
    check("100 章解析中位数 <500ms（3x 容差硬上限 1500ms）", median < 1500,
        string.format("%.1f ms", median))
    check("100 章解析达到 500ms 目标", median < 500, string.format("%.1f ms", median))

    -- 真书失败路径：截断的 zip 必须 nil,err 且清理临时目录
    local truncated = ROOT .. "/books_real/truncated.epub"
    write_real(truncated, (read_real(epub100) or ""):sub(1, 200))
    local bad, bad_err = Epub.outline(truncated)
    check("损坏真书返回 nil 或 spine 降级", bad == nil or bad.source == "spine",
        tostring(bad_err))
    check("损坏真书临时目录已清理", #temp_outline_dirs() == 0)

    -- 真书无目录：spine 回退
    local tree2 = ROOT .. "/tree_plain"
    os.execute('rm -rf "' .. tree2 .. '"')
    os.execute('mkdir -p "' .. tree2 .. '/META-INF" "' .. tree2 .. '/OEBPS"')
    write_real(tree2 .. "/META-INF/container.xml", CONTAINER)
    write_real(tree2 .. "/OEBPS/content.opf", opf({
        '<item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>',
        '<item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>',
    }, { "a", "b" }))
    write_real(tree2 .. "/OEBPS/a.xhtml", xhtml("a"))
    write_real(tree2 .. "/OEBPS/b.xhtml", xhtml("b"))
    local plain = ROOT .. "/books_real/plain.epub"
    check("无目录真书造书成功", build_epub(tree2, plain))
    local plain_outline = Epub.outline(plain)
    check("无目录真书 source=spine", plain_outline and plain_outline.source == "spine"
        and #plain_outline.chapters == 2)
    check("无目录真书标题「第 N 节」", plain_outline and plain_outline.chapters[2].title == "第 2 节")
    check("无目录真书临时目录已清理", #temp_outline_dirs() == 0)
end

print(string.format("\n==== outline 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)