-- ============================================================
-- P3-a：MCP 任务导出（设计 §10.2）
-- Tools.split_text 的切分边界 / Epub.collect_segments 的段落与章节抽取 /
-- Mcp.exportJob 的 job.json + state.json / Mcp.listJobs / job_id 校验
-- Run: luajit tests/mcp_job_test.lua
-- 依赖 KOReader 自带 lfs / json（KO_ROOT 可覆盖）；缺失时跳过。
-- ============================================================
local KO = os.getenv("KO_ROOT") or "/Applications/KOReader.app/Contents/koreader"
local ffi = require("ffi")
if not ffi.loadlib then ffi.loadlib = function(name) return ffi.load(name) end end
package.path = KO .. "/?.lua;" .. KO .. "/common/?.lua;" .. KO .. "/frontend/?.lua;"
    .. KO .. "/common/?/init.lua;" .. package.path
package.cpath = KO .. "/?.so;" .. KO .. "/common/?.so;" .. KO .. "/?.dylib;" .. package.cpath
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

local ROOT = "/tmp/dt_mcp_job_test"
os.execute('rm -rf "' .. ROOT .. '"')
os.execute('mkdir -p "' .. ROOT .. '"')

local data_dir = ROOT .. "/data"
package.preload["datastorage"] = function()
    return { getDataDir = function() return data_dir end }
end
package.preload["logger"] = function()
    return { warn = function() end, err = function() end,
        info = function() end, dbg = function() end }
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
package.preload["dualtranslate_overlay"] = function() return {} end
package.preload["dualtranslate_lock"] = function()
    return { withBookLock = function(_, fn) return fn() end }
end
local ok_url, real_url = pcall(require, "socket.url")
if ok_url and type(real_url) == "table" and real_url.unescape then
    package.preload["socket.url"] = function() return real_url end
else
    package.preload["socket.url"] = function()
        return { unescape = function(value) return tostring(value) end }
    end
end

-- archiver stub：内存书，与 outline_test 同一套语义（父目录必须存在）
local stub_books = {}
package.preload["ffi/archiver"] = function()
    return { Reader = { new = function()
        local reader = { err = nil }
        function reader:open(path)
            self.book = stub_books[path]
            self.pos = 0
            if not self.book then self.err = "cannot open " .. tostring(path); return false end
            return true
        end
        function reader:iterate()
            self.pos = 0
            return function()
                self.pos = self.pos + 1
                local name = self.book.ordered[self.pos]
                if not name then return nil end
                return { path = name, mode = "file", size = #(self.book.files[name] or "") }
            end
        end
        function reader:extractToPath(key, dest)
            local content = self.book.files[key]
            if content == nil then self.err = "no such path"; return false end
            local parent = dest:match("^(.*)/[^/]+$")
            if parent and lfs.attributes(parent, "mode") ~= "directory" then
                self.err = "no such directory"; return false
            end
            local file = io.open(dest, "wb")
            if not file then self.err = "cannot write"; return false end
            file:write(content)
            file:close()
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
local Mcp = dofile("dualtranslate_mcp.lua")
package.loaded["dualtranslate_mcp"] = Mcp

local function write_real(path, content)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then os.execute('mkdir -p "' .. parent .. '"') end
    local file = io.open(path, "wb")
    file:write(content)
    file:close()
end

local function stub_book(path, entries)
    local files, ordered = {}, {}
    for _, entry in ipairs(entries) do
        files[entry[1]] = entry[2]
        ordered[#ordered + 1] = entry[1]
    end
    stub_books[path] = { files = files, ordered = ordered }
    write_real(path, "stub-epub:" .. path)
    return path
end

local CONTAINER = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]

local OPF = [[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest>
    <item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chap2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="chap3.xhtml" media-type="application/xhtml+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="c3"/>
  </spine>
</package>]]

local function xhtml(body)
    return '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">'
        .. '<head><title>t</title></head><body>' .. body .. '</body></html>'
end

local long_paragraph = {}
for index = 1, 60 do long_paragraph[#long_paragraph + 1] = "word" .. index end
long_paragraph = table.concat(long_paragraph, " ")

local BOOK = stub_book(ROOT .. "/books/job.epub", {
    { "META-INF/container.xml", CONTAINER },
    { "OEBPS/content.opf", OPF },
    { "OEBPS/chap1.xhtml", xhtml("<h1>One</h1><p>First paragraph.</p><p>Second paragraph.</p>") },
    { "OEBPS/style.css", "ul.tight { padding-left: 0; }\n" },
    { "OEBPS/chap2.xhtml", xhtml("<p>Chapter two content.</p><ul><li>First bullet.</li><li>Second bullet.</li></ul><ul><li>Parent bullet.<ul class=\"tight\"><li>Nested bullet.</li></ul></li></ul>") },
    { "OEBPS/chap3.xhtml", xhtml("<p>" .. long_paragraph .. "</p>") },
})

-- ============================================================
print("== 1. Tools.split_text ==")
do
    local single = Tools.split_text("hello", 100)
    check("短文本单块", #single == 1 and single[1] == "hello")
    local chunks = Tools.split_text(long_paragraph, 120)
    check("长文本多块", #chunks > 1)
    check("切分不丢词", table.concat(chunks, " "):find("word1 ", 1, true) ~= nil
        and table.concat(chunks, " "):find("word60", 1, true) ~= nil)
    local cjk = string.rep("中文测试段落内容", 30)
    local cjk_chunks = Tools.split_text(cjk, 60)
    local boundary_ok = true
    for _, chunk in ipairs(cjk_chunks) do
        local first = chunk:byte(1)
        if first and first >= 128 and first <= 191 then boundary_ok = false end
    end
    check("CJK 不切断 UTF-8", boundary_ok and #cjk_chunks > 1)
    check("空文本", #Tools.split_text("", 10) == 1)
end

local function valid_utf8(text)
    local index = 1
    while index <= #text do
        local byte = text:byte(index)
        local width
        if byte < 0x80 then width = 1
        elseif byte < 0xC0 then return false
        elseif byte < 0xE0 then width = 2
        elseif byte < 0xF0 then width = 3
        else width = 4 end
        if index + width - 1 > #text then return false end
        for offset = 1, width - 1 do
            local cont = text:byte(index + offset)
            if not cont or cont < 0x80 or cont > 0xBF then return false end
        end
        index = index + width
    end
    return true
end

-- ============================================================
print("== 1a. 临时解包目录清扫 ==")
do
    -- A killed run leaves overlay_<nonce> behind; 25 MB per book adds up.
    local base = ROOT .. "/sweep"
    os.execute('rm -rf "' .. base .. '"')
    os.execute('mkdir -p "' .. base .. '/overlay_old" "' .. base
        .. '/outline_new" "' .. base .. '/keep"')
    os.execute('touch -t 200001010000 "' .. base .. '/overlay_old"')
    local removed = Tools.sweep_temp_dirs(base, { "overlay_", "outline_", "job_" }, 6 * 3600)
    check("清扫旧临时目录", removed == 1, tostring(removed))
    check("保留新目录", lfs.attributes(base .. "/outline_new", "mode") == "directory")
    check("保留非前缀目录", lfs.attributes(base .. "/keep", "mode") == "directory")
    check("缺失目录返回 0", Tools.sweep_temp_dirs(base .. "/missing",
        { "overlay_" }, 10) == 0)
    os.execute('rm -rf "' .. base .. '"')
end

-- ============================================================
print("== 1b. UTF-8 安全切片 ==")
do
    local cjk = string.rep("中文测试段落内容", 40)
    local tail = Tools.utf8_tail(cjk, 200)
    local head = Tools.utf8_head(cjk, 200)
    check("tail 长度与边界", #tail <= 200 and #tail > 190 and valid_utf8(tail))
    check("head 长度与边界", #head <= 200 and #head > 190 and valid_utf8(head))
    check("tail 取自末尾", cjk:sub(-#tail) == tail)
    check("head 取自开头", cjk:sub(1, #head) == head)
    local ascii = string.rep("a", 500)
    check("ASCII 原样", #Tools.utf8_tail(ascii, 200) == 200
        and #Tools.utf8_head(ascii, 200) == 200)
    check("短文本原样", Tools.utf8_tail("短", 200) == "短"
        and Tools.utf8_head("短", 200) == "短")
    -- 4 字节字符（emoji）也不能被切断
    local emoji = string.rep("😀", 100)
    check("4 字节字符", valid_utf8(Tools.utf8_tail(emoji, 201))
        and valid_utf8(Tools.utf8_head(emoji, 201)))
end

-- ============================================================
print("== 2. Epub.collect_segments ==")
do
    local extracted, err = Epub.collect_segments{
        book_path = BOOK, chapter_indexes = { 1, 3 }, max_chars = 200,
        titles = { [1] = "第一章", [3] = "第三章" },
    }
    check("collect 成功", extracted ~= nil, tostring(err))
    check("spine_count", extracted and extracted.spine_count == 3)
    check("只导出所选章节", extracted and #extracted.chapters == 2)
    check("章节标题来自 titles", extracted and extracted.chapters[1].title == "第一章")
    local parents, parts = {}, 0
    for _, segment in ipairs(extracted and extracted.segments or {}) do
        check("selector 形状",
            segment.selector:find('^DocFragment%[Source="OEBPS/chap%d%.xhtml"%] > body > ') ~= nil
            and segment.selector:find(":nth%-of%-type%(%d+%)$") ~= nil)
        check("xpointer 形状",
            segment.xpointer:find("^/body/DocFragment%[?%d*%]?/?body/") ~= nil)
        parents[segment.parent_id] = (parents[segment.parent_id] or 0) + 1
        if segment.parent_total > 1 then parts = parts + 1 end
    end
    check("第一章三段（h1+p+p）", parents["s000001"] == 1 and parents["s000002"] == 1
        and parents["s000003"] == 1)

    local list = Epub.collect_segments{
        book_path = BOOK, chapter_indexes = { 2 }, max_chars = 2000,
        titles = { [2] = "第二章" },
    }
    local sources, li_count = {}, 0
    local parent_selector, parent_indent, leaf_selector, leaf_indent
    for _, segment in ipairs(list and list.segments or {}) do
        sources[#sources + 1] = segment.source
        if segment.selector:find("li:nth%-of%-type") then li_count = li_count + 1 end
        if segment.source == "Parent bullet." then
            parent_selector = segment.selector
            parent_indent = segment.list_indent
        end
        if segment.source == "First bullet." then
            leaf_selector = segment.selector
            leaf_indent = segment.list_indent
        end
    end
    check("列表项被抽取", list ~= nil and li_count == 4, tostring(li_count))
    check("列表项文本", sources[1] == "Chapter two content."
        and sources[2] == "First bullet." and sources[3] == "Second bullet."
        and sources[4] == "Parent bullet." and sources[5] == "Nested bullet."
        and #sources == 5, table.concat(sources, " | "))
    -- 父项的译文必须落在子列表之前：selector 自带 ::before
    check("父项用 ::before", parent_selector and parent_selector:sub(-8) == "::before",
        tostring(parent_selector))
    check("叶子项不加伪元素", leaf_selector and leaf_selector:sub(-7) ~= "::after"
        and leaf_selector:sub(-8) ~= "::before", tostring(leaf_selector))
    -- The negative margin must come from the book's own stylesheet:
    -- "ul.tight { padding-left: 0 }" leaves only epub.css's 1em margin.
    check("父项带书的列表缩进", parent_indent == "1em", tostring(parent_indent))
    check("叶子项不带缩进", leaf_indent == nil, tostring(leaf_indent))
    check("长段落被切分", parts > 1)
    -- Every parent's parts must be contiguous and total parent_total.
    local grouped = {}
    for _, segment in ipairs(extracted.segments) do
        grouped[segment.parent_id] = grouped[segment.parent_id] or {}
        table.insert(grouped[segment.parent_id], segment)
    end
    local parts_ok = true
    for _, group in pairs(grouped) do
        for position, segment in ipairs(group) do
            if segment.part ~= position or segment.parent_total ~= #group then
                parts_ok = false
            end
        end
    end
    check("part/parent_total 连续", parts_ok)
    check("第一个 part 的 id 即 parent_id", extracted.segments[1].id == extracted.segments[1].parent_id)
    -- A selection never leaks chapter 2.
    local has_two = false
    for _, chapter in ipairs(extracted.chapters) do
        if chapter.index == 2 then has_two = true end
    end
    check("未选章节不出现", not has_two)
end

-- ============================================================
print("== 3. Mcp.exportJob ==")
do
    local result, err = Mcp.exportJob{
        book_path = BOOK, chapter_indexes = { 1, 2 }, source_lang = "en",
        target_lang = "zh-Hans", titles = { [1] = "第一章", [2] = "第二章" },
    }
    check("export 成功", result ~= nil, tostring(err))
    check("job_id 格式", result and result.job_id:match("^%d%d%d%d%d%d%d%d_%d%d%d%d%d%d_%d%d%d%d$") ~= nil)
    -- Chapters 1 and 2: h1 + 2 paragraphs + 1 paragraph.
    check("段数", result and result.segments == #result.job.segments and result.segments == 8)
    check("job 文件落盘", result and Mcp.readJson(result.dir .. "/job.json") ~= nil)
    local state = Mcp.loadState(result.job_id)
    check("state 初始值", state and state.status == "exported"
        and state.submitted == 0 and state.total == 8)
    local job = Mcp.loadJob(result.job_id)
    check("loadJob schema", job and job.schema == Mcp.JOB_SCHEMA)
    check("book 元数据", job.book.device_path == BOOK and job.book.target_lang == "zh-Hans")
    check("book 文件指纹", job.book.file_size > 0 and job.book.file_mtime > 0)
    check("options 上限", job.options.max_chars_per_segment == 4500
        and job.options.split_long_segments == true)
    check("章节列表", #job.chapters == 2 and job.chapters[2].title == "第二章")

    local list = Mcp.listJobs()
    check("listJobs 命中", #list == 1 and list[1].job_id == result.job_id)
    check("listJobs 字段", list[1].total == 8 and list[1].status == "exported"
        and list[1].book_path == BOOK and list[1].chapter_count == 2)

    -- 索引：meta.json + job.json 里 segments 逐行，供 get-segments/job-status
    check("meta.json 写入", lfs.attributes(result.dir .. "/meta.json", "mode") ~= nil)
    local job_blob = Mcp.slurp(result.dir .. "/job.json")
    check("job.json 段落逐行", job_blob
        and job_blob:find('"segments":[\n', 1, true) ~= nil)
    check("job.json 仍是合法 JSON", Mcp.readJson(result.dir .. "/job.json") ~= nil)
    local meta = Mcp.loadMeta(result.job_id)
    check("meta.total", meta and meta.total == 8 and meta.chapter_count == 2)
    local seg_ids = Mcp.listSegmentIds(result.job_id)
    check("索引 id 数", seg_ids and #seg_ids == 8 and seg_ids[1] == "s000001")
    local page = Mcp.readSegmentPage(result.job_id, 0, 2, true)
    check("索引分页", page and #page.segments == 2 and page.total == 8
        and page.segments[1].id == "s000001")
    check("索引 context", page and page.segments[1].prev == nil
        and page.segments[1].next ~= nil)
    local tail = Mcp.readSegmentPage(result.job_id, 3, 10, false)
    check("索引尾页", tail and #tail.segments == 5 and tail.segments[1].id == "s000004")

    -- 截断（掉电）不能返回 next_offset == offset 的空页，否则客户端空转
    local meta_blob = Mcp.readJson(result.dir .. "/meta.json")
    local short = {
        schema = job.schema, job_id = result.job_id, created_at = job.created_at,
        book = job.book, chapters = job.chapters, options = job.options,
        segments = { job.segments[1], job.segments[2] },
    }
    check("写入短索引", Mcp.writeJobFiles(result.dir, short) == true)
    check("恢复完整 total", Mcp.writeJson(result.dir .. "/meta.json", meta_blob) == true)
    local broken, broken_err = Mcp.readSegmentPage(result.job_id, 3, 1, false)
    check("截断索引拒绝空页", broken == nil
        and tostring(broken_err):find("不完整") ~= nil, tostring(broken_err))
    local restored = assert(io.open(result.dir .. "/job.json", "wb"))
    restored:write(job_blob); restored:close()
    check("恢复 meta", Mcp.writeJson(result.dir .. "/meta.json", meta) == true)

    -- anchors：每 100 行一个字节偏移，末端页不必从头扫
    local big = {
        schema = job.schema, job_id = "20261116_000000_0002", created_at = 1,
        book = job.book, chapters = {}, options = job.options, segments = {},
    }
    for index = 1, 250 do
        big.segments[index] = {
            id = string.format("b%06d", index), parent_id = string.format("b%06d", index),
            part = 1, parent_total = 1, chapter_index = 1, chapter_title = "B",
            selector = "p[" .. index .. "]", source = "big " .. index,
        }
    end
    local big_dir = Mcp.jobDir(big.job_id)
    check("大任务写入", Mcp.writeJobFiles(big_dir, big) == true)
    local big_meta = Mcp.loadMeta(big.job_id)
    check("anchors 每 100 行一个", big_meta and #(big_meta.anchors or {}) == 3)
    local big_page = Mcp.readSegmentPage(big.job_id, 200, 2, false)
    check("anchors 定位", big_page and big_page.segments[1].id == "b000201"
        and big_page.total == 250, big_page and big_page.segments[1].id)
    Tools.rmtree(big_dir)

    -- 损坏的行（别的工具格式化过 / 截断在行中间）必须返回「索引损坏」，
    -- 让调用方回退整份解码，而不是抛 Lua 错误。
    local bad_id = "20261116_000000_0003"
    local bad_dir = Mcp.jobDir(bad_id)
    Tools.mkdir_p(bad_dir)
    local bad_blob = '{"schema":"dualtranslate.job.v1","job_id":"' .. bad_id
        .. '","created_at":1,"book":{"device_path":"/tmp/x.epub"},'
        .. '"chapters":[],"options":{},"segments":[\n'
        .. '{"id":"s1","source":"ok"},\n{bad}\n]}'
    local bad_file = assert(io.open(bad_dir .. "/job.json", "wb"))
    bad_file:write(bad_blob); bad_file:close()
    Mcp.writeJson(bad_dir .. "/meta.json", { schema = Mcp.META_SCHEMA, job_id = bad_id,
        book = { device_path = "/tmp/x.epub" }, chapter_count = 0, total = 2 })
    local bad_page, bad_err = Mcp.readSegmentPage(bad_id, 1, 1, false)
    check("损坏行返回索引错误", bad_page == nil
        and tostring(bad_err):find("损坏") ~= nil, tostring(bad_err))
    Tools.rmtree(bad_dir)

    -- Second export must not reuse the id.
    local second = Mcp.exportJob{ book_path = BOOK, chapter_indexes = { 2 } }
    check("新任务新编号", second and second.job_id ~= result.job_id)
    local ids = {}
    for _, item in ipairs(Mcp.listJobs()) do ids[item.job_id] = true end
    check("listJobs 收全两个任务", #Mcp.listJobs() == 2
        and ids[result.job_id] and ids[second.job_id])
end

-- ============================================================
print("== 4. job_id 校验 ==")
do
    check("非法编号拒绝", Mcp.loadJob("../etc") == nil)
    check("空编号拒绝", Mcp.loadJob("") == nil)
    check("合法编号通过校验", Mcp.validJobId("20261115_120000_0001"))
    check("斜杠拒绝", not Mcp.validJobId("2026/11"))
end

-- ============================================================
print("== 5. 临时目录清理 ==")
do
    local leftovers = {}
    local dir = data_dir .. "/cache/dualtranslate"
    if lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name:match("^job_") then leftovers[#leftovers + 1] = name end
        end
    end
    check("无 job 临时目录残留", #leftovers == 0, table.concat(leftovers, ","))
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
