-- Small EPUB reader/writer used by DualTranslate's chapter mode.
-- It intentionally handles XHTML as text: the original markup is preserved and
-- only translated block paragraphs are inserted after their source element.

local Epub = {}
local Archiver = require("ffi/archiver")
local Overlay = require("dualtranslate_overlay")
local Coverage = require("dualtranslate_coverage")
local ListIndent = require("dualtranslate_listindent")
local Tools = require("dualtranslate_tools")
local DataStorage = require("datastorage")
local socket_url = require("socket.url")
local Lock = require("dualtranslate_lock")
local lfs = require("libs/libkoreader-lfs")

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, data)
    local file = io.open(path, "wb")
    if not file then return false end
    file:write(data)
    file:close()
    return true
end

local function attr(tag, name)
    local escaped_name = name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    local pattern = escaped_name .. "%s*=%s*[\"']([^\"']+)[\"']"
    return tag:match(pattern)
end

local function normalize_path(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    return table.concat(parts, "/")
end

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or ""
end

local function html_to_text(html)
    -- CDATA is text, not markup.  InDesign and several Chinese EPUB
    -- converters wrap TOC labels as <![CDATA[Chapter One]]>; stripping tags
    -- first would delete the whole label and the outline would fall back to
    -- "第 N 节".
    html = html:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    -- Ruby readings are metadata for the base Japanese text, not additional
    -- words to send to the translator.  Keeping <rt> content used to turn e.g.
    -- 素人 into "素人 しろうと", which confused sentence translation and
    -- produced the apparently missing/broken clauses seen in the reader.
    html = html:gsub("<[rR][tT][^>]*>.-</[rR][tT]%s*>", "")
    html = html:gsub("<br%s*/?>", "\n")
    html = html:gsub("<[^>]+>", " ")
    html = html:gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&#39;", "'")
    return html:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function html_escape(text)
    return tostring(text)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
end

-- Throttled progress writer.  Whole-book runs call this once per paragraph,
-- which on a several-thousand-paragraph book means thousands of open/write/
-- close cycles; batching the writes to ~4/s keeps the progress dialog smooth
-- without the file I/O storm.  The watchdog keys off modification time with
-- a 10-minute window, so throttling is invisible to it.  os.clock() is
-- monotonic within this subprocess, so a fresh worker starts at 0.
local progress_last_write = 0
local function write_progress(path, current, total, translated, failed, chapter, chapters)
    if not path then return end
    local now = os.clock()
    -- The first call always writes (progress_last_write starts at 0), so the
    -- initial "0/total" marker and the file itself are created immediately.
    if progress_last_write > 0 and now - progress_last_write < 0.25 then return end
    progress_last_write = now
    local file = io.open(path, "w")
    if not file then return end
    file:write(string.format("%d|%d|%d|%d|%d|%d\n",
        current or 0, total or 0, translated or 0, failed or 0,
        chapter or 0, chapters or 0))
    file:close()
end

local function looks_translatable(text)
    -- A paragraph is worth sending to the translator when it carries at
    -- least one letter (ASCII) or one non-ASCII rune (CJK, kana, Cyrillic,
    -- accented Latin...).  Pure digits/punctuation-only paragraphs (page
    -- numbers, list markers, decorative separators) are skipped.
    if not text or text == "" then return false end
    if text:match("%a") then return true end
    -- UTF-8: any byte >= 0x80 implies a non-ASCII character.
    return text:match("[\128-\255]") ~= nil
end

-- resolve() and outline() share these so the spine index (chapter identity,
-- design 6.5) is derived from one set of manifest/spine rules.
local function container_opf_path(container)
    -- EPUBs may use a namespace prefix (for example container:rootfile),
    -- and some put rootfiles/rootfile on separate formatting lines.
    local opf_path
    for rootfile_tag in container:gmatch("<[^>]*rootfile[^>]*>") do
        opf_path = attr(rootfile_tag, "full-path")
        if opf_path then break end
    end
    if not opf_path then return nil end
    return normalize_path(socket_url.unescape(opf_path))
end

local function parse_package(opf, opf_path)
    local base = dirname(opf_path)
    local manifest, items = {}, {}
    for item in opf:gmatch("<[%w_%-]*:?item[^>]*>") do
        local id = attr(item, "id")
        local href = attr(item, "href")
        if id and href then
            local entry = {
                id = id,
                href = normalize_path(base .. "/" .. socket_url.unescape(href:gsub("#.*$", ""))),
                media_type = attr(item, "media-type"),
                properties = attr(item, "properties"),
            }
            manifest[id] = entry
            items[#items + 1] = entry
        end
    end

    local spine = {}
    for itemref in opf:gmatch("<[%w_%-]*:?itemref[^>]*>") do
        local idref = attr(itemref, "idref")
        if idref and manifest[idref] then
            table.insert(spine, manifest[idref].href)
        end
    end

    local toc_id
    for spine_tag in opf:gmatch("<[%w_%-]*:?spine[^>]*>") do
        toc_id = attr(spine_tag, "toc")
        if toc_id then break end
    end

    return {
        manifest = manifest,
        items = items,
        spine = spine,
        toc_id = toc_id,
    }
end

-- Publisher stylesheets in manifest order (later rules win in the cascade,
-- which is what the list-indent matcher expects).  read(href) returns the
-- file text or nil; extract paths differ, so the caller owns the lookup.
local function package_stylesheets(package, read)
    local styles = {}
    for _, item in ipairs(package and package.items or {}) do
        local media_type = tostring(item.media_type or ""):lower()
        if media_type:find("css", 1, true) then
            local text = read(item.href)
            if text and text ~= "" then styles[#styles + 1] = text end
        end
    end
    return styles
end

function Epub:resolve(book_path, work_dir, fragment)
    local container = read_file(work_dir .. "/META-INF/container.xml")
    if not container then return nil, "找不到 META-INF/container.xml" end
    local opf_path = container_opf_path(container)
    if not opf_path then return nil, "找不到 OPF 路径" end
    local opf = read_file(work_dir .. "/" .. opf_path)
    if not opf then return nil, "找不到 OPF 文件" end

    local package = parse_package(opf, opf_path)
    local spine = package.spine

    -- fragment is either a plain spine index (preferred: the reader resolves
    -- the current chapter index because CREngine xpointers carry no
    -- DocFragment index), an xpointer with an explicit DocFragment[N] index,
    -- or anything else (fall back to the first spine item).
    local index = tonumber(fragment)
    if not index then
        index = tonumber(tostring(fragment or ""):match("DocFragment%[(%d+)%]")) or 1
    end
    local relative = spine[index] or spine[1]
    if not relative then return nil, "找不到可读取的 spine 项" end
    return {
        relative = relative,
        absolute = work_dir .. "/" .. relative,
        index = index,
        spine_count = #spine,
        spine = spine,
        styles = package_stylesheets(package, function(href)
            return read_file(work_dir .. "/" .. href)
        end),
    }
end

-- One place for temp unpacking: sweeps leftovers from killed runs, then makes
-- a fresh overlay_/outline_/job_/spine_/anchor_ directory.
local WORK_PREFIXES = { "overlay_", "outline_", "job_", "spine_", "anchor_" }
local WORK_MAX_AGE = 6 * 3600

local function new_work_dir(prefix)
    local base = DataStorage:getDataDir() .. "/cache/dualtranslate"
    -- Tests stub Tools with a minimal table; the sweep is an enhancement, not
    -- a prerequisite for unpacking.
    if type(Tools.sweep_temp_dirs) == "function" then
        Tools.sweep_temp_dirs(base, WORK_PREFIXES, WORK_MAX_AGE)
    end
    local nonce = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    local dir = base .. "/" .. prefix .. nonce
    if not Tools.mkdir_p(dir) then return nil end
    return dir
end

local overlay_target_tags = {
    p = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    figcaption = true, dt = true, dd = true,
    -- List items are paragraphs too; leaving them out silently skipped every
    -- bullet in the book (both google_free and MCP had no text for them).
    li = true,
    -- Quoted blocks are paragraphs too: a bare <blockquote>text</blockquote>
    -- has no child paragraph to attach to and was skipped entirely.
    blockquote = true,
}

-- A target element is skipped only when its own text belongs to child
-- candidates that are collected separately.  Containers that are not targets
-- (div, table, pre, ...) own no candidate, so a quote wrapping them is still
-- the paragraph to translate and must be kept.
local block_child_tags = overlay_target_tags

local void_tags = {
    area = true, base = true, br = true, col = true, embed = true, hr = true,
    img = true, input = true, link = true, meta = true, param = true,
    source = true, track = true, wbr = true,
}

local function css_attribute(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

-- Whether the raw inner markup holds a block-level target element.  Scanned
-- as text because the child may sit several levels down.  Prefixes are
-- stripped like the main parser does (html:p is a p), comments and CDATA are
-- not markup, and a tag name only counts when followed by whitespace, ">"
-- or "/" so "partition" in prose is not a <p>.
local function contains_block_child(inner)
    local markup = inner:lower()
        :gsub("<!%-%-.-%-%->", " ")
        :gsub("<!%[CDATA%[.-%]%]>", " ")
    for tag in markup:gmatch("<%s*([%w_:%-]+)[%s/>]") do
        if block_child_tags[tag:gsub("^.-:", "")] then return true end
    end
    return false
end

-- Build selectors from the original XHTML tree.  These selectors address
-- CREngine's internal DocFragment nodes, so generated text is laid out in the
-- open source EPUB while the archive itself stays byte-for-byte untouched.
local function element_info(raw, name)
    local classes = {}
    local class_attr = attr(raw, "class")
    if class_attr then
        for class in class_attr:gmatch("%S+") do classes[class] = true end
    end
    return { tag = name, id = attr(raw, "id"), classes = classes }
end

-- Ancestor chain (outermost first, the element itself excluded) for the
-- list-indent matcher: selectors such as "#toc > ol" need to know which
-- container a list actually sits in.
local function ancestor_chain(stack)
    local ancestors = {}
    for index = 2, #stack do ancestors[#ancestors + 1] = stack[index].info end
    return ancestors
end

local function collect_overlay_candidates(document, relative, fragment_index, div_fallback, styles)
    local targets = div_fallback and { div = true } or overlay_target_tags
    local sheet = ListIndent.resolve(styles)
    -- Per-chapter <style> blocks override the book stylesheet (they are last
    -- in the cascade for this document).
    local chapter_css = {}
    for css in document:gmatch("<[sS][tT][yY][lL][eE][^>]*>(.-)</[sS][tT][yY][lL][eE]>") do
        chapter_css[#chapter_css + 1] = css
    end
    if #chapter_css > 0 then
        sheet = ListIndent.extend(sheet, table.concat(chapter_css, "\n"))
    end
    local root = { counts = {}, in_body = false, path = "", xpath = "",
        info = { tag = "#root", classes = {} } }
    local stack = { root }
    local candidates = {}
    local position = 1
    while true do
        local tag_start, tag_end = document:find("<[^>]*>", position)
        if not tag_start then break end
        local raw = document:sub(tag_start, tag_end)
        position = tag_end + 1
        if not raw:match("^<%s*[!?]") then
            local closing = raw:match("^<%s*/") ~= nil
            local name = raw:match("^<%s*/?%s*([%w_:%-]+)")
            if name then
                name = name:lower():gsub("^.-:", "")
                if closing then
                    local found
                    for index = #stack, 2, -1 do
                        if stack[index].name == name then found = index; break end
                    end
                    if found then
                        local node = stack[found]
                        if node.target and node.inner_start then
                            local inner = document:sub(node.inner_start, tag_start - 1)
                            local pseudo, anchor_path
                            if name == "li" then
                                local lowered = inner:lower()
                                local nested = lowered:find("<%s*[ou]l[%s>]")
                                if nested then
                                    -- The parent's text belongs between the
                                    -- item's own text and its child list.  CSS
                                    -- can only attach generated content to the
                                    -- start or the end of an element's content,
                                    -- so "::after" lands below the whole list
                                    -- and "::before" above the item's text.
                                    -- The one insertion point that sits where
                                    -- we want it is the child list itself:
                                    -- attaching there puts the translation
                                    -- after the parent's text and before the
                                    -- first child.  That box inherits the list
                                    -- indent, which append_rule cancels with a
                                    -- negative margin.
                                    inner = inner:sub(1, nested - 1)
                                    pseudo = "::before"
                                    anchor_path = node.child_list_path
                                end
                            end
                            -- Any target that holds another target block owns
                            -- only the text those children leave behind: a
                            -- quote inside a list item or definition, a quote
                            -- wrapping paragraphs, a definition holding one
                            -- paragraph per sense.  Translating the parent as
                            -- well would put the same sentence on screen
                            -- twice (and pay for it twice).  The div pass is
                            -- excluded: a div may be the paragraph that wraps
                            -- a quote, and collect_chapter_candidates merges
                            -- those two by position instead.
                            if not div_fallback and contains_block_child(inner) then
                                inner = ""
                            end
                            local source = html_to_text(inner)
                            if looks_translatable(source) then
                                -- The negative margin that pulls the layer back
                                -- to the parent's text must match the indent
                                -- this book actually gives the child list; it
                                -- comes from the book's own stylesheet below.
                                local list_indent
                                if pseudo == "::before" and node.child_list then
                                    list_indent = ListIndent.indent(sheet, node.child_list)
                                end
                                table.insert(candidates, {
                                    order = node.inner_start,
                                    -- End of the element (closing tag), used by
                                    -- range slicing: an anchor inside this
                                    -- element still belongs to its paragraph.
                                    span_end = tag_end,
                                    tag = name,
                                    source = source,
                                    list_indent = list_indent,
                                    selector = 'DocFragment[Source="' .. css_attribute(relative)
                                        .. '"] > body' .. (anchor_path or node.path) .. (pseudo or ""),
                                    xpointer = "/body/DocFragment"
                                        .. (fragment_index > 1
                                            and ("[" .. tostring(fragment_index) .. "]") or "")
                                        .. "/body" .. node.xpath,
                                })
                            end
                        end
                        for index = #stack, found, -1 do table.remove(stack) end
                    end
                else
                    local parent = stack[#stack]
                    parent.counts[name] = (parent.counts[name] or 0) + 1
                    local in_body = parent.in_body or name == "body"
                    local path = parent.path
                    local xpath = parent.xpath
                    if name == "body" then
                        path = ""
                        xpath = ""
                    elseif in_body then
                        path = path .. " > " .. name .. ":nth-of-type("
                            .. tostring(parent.counts[name]) .. ")"
                        xpath = xpath .. "/" .. name
                            .. (parent.counts[name] > 1
                                and ("[" .. tostring(parent.counts[name]) .. "]") or "")
                    end
                    -- Remember where a nested list sits, so the parent <li>
                    -- can attach its translation to the list (the only spot
                    -- between its own text and the first child item).
                    local node = {
                        name = name,
                        counts = {},
                        in_body = in_body,
                        path = path,
                        xpath = xpath,
                        inner_start = tag_end + 1,
                        info = element_info(raw, name),
                        target = in_body and targets[name] == true,
                    }
                    -- The list itself is what the indent depends on (its
                    -- margin/padding, marker style and item count), so it is
                    -- recorded once and attached to the parent <li> that will
                    -- host the translation layer.
                    if (name == "ul" or name == "ol") and in_body then
                        node.list_info = {
                            element = {
                                tag = name,
                                id = node.info.id,
                                classes = node.info.classes,
                                ancestors = ancestor_chain(stack),
                            },
                            item_count = 0,
                            start = tonumber(attr(raw, "start")) or 1,
                            style_attr = attr(raw, "style"),
                        }
                        if parent.name == "li" and not parent.child_list_path and path ~= "" then
                            parent.child_list_path = path
                            parent.child_list = node.list_info
                        end
                    elseif name == "li" and parent.list_info then
                        parent.list_info.item_count = parent.list_info.item_count + 1
                        -- CREngine measures each item's own marker, so an item
                        -- rule such as ".calibre3 { list-style-type: none }"
                        -- collapses the list padding to 0 even when the list
                        -- itself still says "decimal".
                        if not parent.list_info.first_li then
                            parent.list_info.first_li = {
                                tag = "li",
                                id = node.info.id,
                                classes = node.info.classes,
                                ancestors = ancestor_chain(stack),
                            }
                        end
                    end
                    local self_closing = raw:match("/%s*>$") ~= nil or void_tags[name]
                    if not self_closing then table.insert(stack, node) end
                end
            end
        end
    end
    -- Candidates are appended when their element closes, so a nested <li>
    -- would otherwise come before its parent (and shift every id/prev/next).
    table.sort(candidates, function(a, b) return (a.order or 0) < (b.order or 0) end)
    return candidates
end

-- Exposed like slice_candidates/normalize_* so tests can assert the raw
-- parser.  The overlay and the job export both call collect_chapter_candidates
-- below, which runs this pass and then merges the div fallback.
Epub.collect_candidates = collect_overlay_candidates

-- A chapter written as <div> paragraphs has no recognised target tag, so the
-- whole file is parsed again with divs as targets.  A quote is recognised
-- now, and it must not silence that fallback for the divs around it: merge
-- the two passes.  A div inside a quote is redundant (the quote covers it).
-- A div that merely wraps a quote is the paragraph: it also owns the text
-- around the quote, so the quote is dropped in its favour instead of losing
-- that text.
local function collect_chapter_candidates(document, relative, fragment_index, styles)
    local candidates = collect_overlay_candidates(document, relative,
        fragment_index, false, styles)
    local has_paragraph = false
    for _, candidate in ipairs(candidates) do
        if candidate.tag ~= "blockquote" then has_paragraph = true; break end
    end
    if has_paragraph then return candidates end
    local divs = collect_overlay_candidates(document, relative, fragment_index,
        true, styles)
    if #divs == 0 then return candidates end
    local quotes = candidates
    local kept_divs = {}
    for _, div in ipairs(divs) do
        local inside_quote = false
        for _, quote in ipairs(quotes) do
            if div.order and div.span_end and quote.order and quote.span_end
                and quote.order <= div.order
                and div.span_end <= quote.span_end then
                inside_quote = true
                break
            end
        end
        if not inside_quote then kept_divs[#kept_divs + 1] = div end
    end
    local dropped = {}
    for _, div in ipairs(kept_divs) do
        for _, quote in ipairs(quotes) do
            if div.order and div.span_end and quote.order and quote.span_end
                and div.order <= quote.span_end
                and quote.order <= div.span_end then
                dropped[quote] = true
            end
        end
    end
    local merged = {}
    for _, quote in ipairs(quotes) do
        if not dropped[quote] then merged[#merged + 1] = quote end
    end
    for _, div in ipairs(kept_divs) do merged[#merged + 1] = div end
    table.sort(merged, function(a, b) return (a.order or 0) < (b.order or 0) end)
    return merged
end

-- 7.3: filter non-numbers / out-of-range / duplicates, then sort.  Spine
-- indexes are 1-based integers (6.5).
local function normalize_indexes(list, spine_count)
    local seen, out = {}, {}
    for _, value in ipairs(type(list) == "table" and list or {}) do
        local n = tonumber(value)
        if n and n == math.floor(n) and n >= 1 and n <= spine_count and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    table.sort(out)
    return out
end
Epub.normalize_indexes = normalize_indexes

-- Chapter ranges (7.3, anchor granularity): {index, from, to} means "the spine
-- file at `index`, from the element whose id is `from` (inclusive) up to `to`
-- (exclusive)".  Both edges may be nil, so {index = n} is the whole file and a
-- TOC entry becomes {index, from = entry.anchor, to = next_entry.anchor}.
--
-- Invalid entries are dropped rather than guessed at: an index outside the
-- spine cannot be translated.  A range with identical edges is widened below
-- instead of dropped, because dropping it would empty the whole selection.
local function normalize_ranges(ranges, spine_count)
    local out, seen = {}, {}
    for position, range in ipairs(type(ranges) == "table" and ranges or {}) do
        if type(range) == "table" then
            local index = tonumber(range.index)
            local from, to = range.from, range.to
            if type(from) ~= "string" or from == "" then from = nil end
            if type(to) ~= "string" or to == "" then to = nil end
            -- Adjacent TOC entries can share one anchor.  Such a range cannot
            -- express "one chapter": widen it to the end of the file instead
            -- of dropping the selection (an empty list used to mean "export
            -- the whole book").
            if from and to and from == to then to = nil end
            if index and index == math.floor(index) and index >= 1 and index <= spine_count then
                local key = string.format("%d\0%s\0%s", index, from or "", to or "")
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1] = { index = index, from = from, to = to,
                        sequence = position }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.index ~= b.index then return a.index < b.index end
        return a.sequence < b.sequence
    end)
    return out
end
Epub.normalize_ranges = normalize_ranges

-- First and last byte offset of each requested id in the chapter text.  Old
-- EPUB2 files anchor with <a name="..."> instead of id, so both count.  A
-- duplicated id (bad converters emit them) needs both ends: a range start
-- takes the first occurrence, a range end the last, so the slice only ever
-- grows.  Missing ids are absent from the result.
local function tag_anchor_id(raw)
    -- `[%s]id=` rather than plain `id=`: data-id and its cousins are not ids.
    -- Markup is case-insensitive (ID=) and EPUB3 XHTML also uses xml:id, so
    -- both spellings count; `name=` is the EPUB2 anchor and also matches
    -- unrelated attributes (a meta generator), which can only widen the slice.
    return raw:match("[%s][Ii][Dd]%s*=%s*[\"']([^\"']+)[\"']")
        or raw:match("[%s][Xx][Mm][Ll]:[Ii][Dd]%s*=%s*[\"']([^\"']+)[\"']")
        or raw:match("[%s][Nn][Aa][Mm][Ee]%s*=%s*[\"']([^\"']+)[\"']")
end
Epub.tag_anchor_id = tag_anchor_id

local function anchor_offsets(document, wanted)
    local offsets = {}
    if next(wanted) == nil then return offsets end
    local position = 1
    while true do
        local tag_start, tag_end = document:find("<[^>]*>", position)
        if not tag_start then break end
        local raw = document:sub(tag_start, tag_end)
        position = tag_end + 1
        if not raw:match("^<%s*[!?/]") then
            local id = tag_anchor_id(raw)
            if id and wanted[id] then
                local seen = offsets[id]
                if seen then
                    seen.last = tag_start
                else
                    offsets[id] = { first = tag_start, last = tag_start }
                end
            end
        end
    end
    return offsets
end
Epub.anchor_offsets = anchor_offsets

-- Keep the candidates that overlap one of the chapter's ranges, erring wide:
-- an element that starts before the range but is still open at the start
-- anchor owns the chapter's first words, and a TOC whose anchor is missing
-- from the XHTML must translate too much, never nothing.  Anchors are
-- normalised by the outline parser, so they carry no %XX escapes and match
-- the ids in the file.
-- Each kept candidate remembers which range kept it (`range_group`), because
-- the checkpoint records one outcome per range: that is what lets the picker
-- say "this chapter is translated" instead of "part of this file is".
local function slice_range_groups(candidates, ranges, document)
    if #candidates == 0 or #ranges == 0 then return nil end
    local logger = require("logger")
    local wanted, whole = {}, false
    for _, range in ipairs(ranges) do
        -- Callers already skip whole-file chapters; this keeps direct callers
        -- (and tests) from slicing them by accident.
        if not range.from and not range.to then whole = true end
        if range.from then wanted[range.from] = true end
        if range.to then wanted[range.to] = true end
    end
    if whole then return nil end
    local offsets = anchor_offsets(document, wanted)
    for anchor in pairs(wanted) do
        if not offsets[anchor] then
            logger.warn("dualtranslate: range anchor missing from the chapter, widening:", anchor)
        end
    end
    local edges = {}
    for _, range in ipairs(ranges) do
        -- Start takes the first occurrence and end the last, so a duplicated
        -- id can only widen the slice.
        local from = range.from and offsets[range.from] and offsets[range.from].first or nil
        local to = range.to and offsets[range.to] and offsets[range.to].last or nil
        if from and to and from >= to then
            -- The TOC lists the end before the start.  Translating to the end
            -- of the file is recoverable; an empty slice silently loses text.
            logger.warn("dualtranslate: range anchors out of order, widening:", range.from, range.to)
            to = nil
        end
        edges[#edges + 1] = { from = from, to = to }
    end
    local groups = {}
    for position = 1, #edges do
        local edge, original = edges[position], ranges[position]
        -- Record what the slice really did: a missing or out-of-order end
        -- anchor widened the slice to the end of the file, so the checkpoint
        -- must not claim the original (narrower) end or the coverage map would
        -- mark nothing for a range that translated to EOF.
        local from, to = original.from, original.to
        if from and not edge.from then from = nil end
        if to and not edge.to then to = nil end
        groups[position] = {
            range = { index = original.index, from = from, to = to },
            candidates = {},
        }
    end
    local seen = {}
    for _, candidate in ipairs(candidates) do
        local order = candidate.order or 0
        for position, edge in ipairs(edges) do
            -- `order` is the element's inner start; an anchor on an inline
            -- element inside a paragraph sits after it.  A candidate that
            -- merely starts before the anchor but ends after it still owns
            -- the chapter's first words, so it counts as inside.
            local after_start = not edge.from or order >= edge.from
                or (candidate.span_end or 0) > edge.from
            if after_start and (not edge.to or order < edge.to) then
                if not seen[candidate.selector] then
                    seen[candidate.selector] = true
                    candidate.range_group = position
                    local group = groups[position]
                    group.candidates[#group.candidates + 1] = candidate
                end
                break
            end
        end
    end
    return groups
end

local function slice_candidates(candidates, ranges, document)
    local groups = slice_range_groups(candidates, ranges, document)
    -- Whole-file range (or nothing to slice): every candidate stays.
    if not groups then return candidates end
    local kept = {}
    for _, group in ipairs(groups) do
        for _, candidate in ipairs(group.candidates) do
            kept[#kept + 1] = candidate
        end
    end
    return kept
end
Epub.slice_candidates = slice_candidates

-- 7.3: span must reuse Epub.resolve (the fragment may be an xpointer, not a
-- number); selection carries explicit ranges, with the pre-range
-- chapter_indexes shape still accepted for queued jobs from older versions.
local function resolve_ranges(opts, book_path, work_dir, spine)
    local mode = opts.mode or "all"
    -- Anchor ranges win over the mode: "translate the current chapter" is a
    -- span job narrowed to the entry the page is in.  The fragment is not
    -- consulted then — it only names the starting chapter for a plain span.
    local explicit = normalize_ranges(opts.chapter_ranges, #spine)
    if #explicit > 0 then return explicit end
    local ranges = {}
    if mode == "all" then
        for index = 1, #spine do ranges[#ranges + 1] = { index = index } end
        return ranges
    elseif mode == "span" then
        local chapter = Epub:resolve(book_path, work_dir, opts.fragment)
        local start = chapter and chapter.index or 1
        local span_count = math.max(1, tonumber(opts.span) or 1)
        for index = start, math.min(start + span_count - 1, #spine) do
            ranges[#ranges + 1] = { index = index }
        end
        return ranges
    elseif mode == "selection" then
        local ranged = normalize_ranges(opts.chapter_ranges, #spine)
        if #ranged > 0 then return ranged end
        for _, index in ipairs(normalize_indexes(opts.chapter_indexes, #spine)) do
            ranges[#ranges + 1] = { index = index }
        end
    end
    return ranges
end

function Epub.translate_overlay(opts, ...)
    -- Accept both Epub.translate_overlay{...} and Epub:translate_overlay{...}.
    if opts == Epub then opts = ... end
    opts = opts or {}
    local book_path = opts.book_path
    local mode = opts.mode or "all"
    local fragment = opts.fragment
    local source_lang = opts.source_lang
    local target_lang = opts.target_lang
    local provider = opts.provider
    local translate = opts.translate
    local translate_batch = opts.translate_batch
    local progress_path = opts.progress_path
    local cancel_path = opts.cancel_path
    local output_dir = opts.output_dir
    if not book_path or not book_path:lower():match("%.epub$") then
        return nil, "整书翻译目前仅支持 EPUB"
    end
    -- P0: the provider is part of the overlay identity.  Without it a
    -- provider switch can silently reuse the previous service's entries.
    if not provider or provider == "" then
        return nil, "缺少翻译服务标识"
    end
    if mode ~= "all" and mode ~= "span" and mode ~= "selection" then
        return nil, "未知的翻译范围"
    end
    if type(translate) ~= "function" then
        return nil, "缺少翻译函数"
    end
    local work_dir = new_work_dir("overlay_")
    if not work_dir then
        return nil, "无法创建临时目录"
    end
    local function cleanup()
        Tools.rmtree(work_dir)
        if progress_path then os.remove(progress_path) end
    end
    if not Tools.unzip_to(book_path, work_dir) then
        cleanup()
        return nil, "无法解包 EPUB（可能受 DRM 保护）"
    end
    local resolved, err = Epub:resolve(book_path, work_dir, fragment)
    if not resolved then cleanup(); return nil, err end
    local spine = resolved.spine
    local spine_count = resolved.spine_count or #spine
    local ranges = resolve_ranges(opts, book_path, work_dir, spine)
    if #ranges == 0 then cleanup(); return nil, "没有可翻译的章节" end
    -- Group the ranges by file: a chapter read once, sliced once per range.
    -- `whole` records whether any range covers the entire file, which is what
    -- decides between "已翻译" and "部分" for the manifest below.
    local ranges_by_index, chapter_order = {}, {}
    for _, range in ipairs(ranges) do
        local bucket = ranges_by_index[range.index]
        if not bucket then
            bucket = {}
            ranges_by_index[range.index] = bucket
            chapter_order[#chapter_order + 1] = range.index
        end
        bucket[#bucket + 1] = range
    end
    local chapters = {}
    for _, index in ipairs(chapter_order) do
        local relative = spine[index]
        if relative then
            local bucket = ranges_by_index[index]
            local whole = false
            for _, range in ipairs(bucket) do
                if not range.from and not range.to then whole = true end
            end
            chapters[#chapters + 1] = { index = index, relative = relative,
                absolute = work_dir .. "/" .. relative, ranges = bucket,
                whole = whole }
        end
    end

    local chapter_candidates = {}
    local unreadable = {}
    local total = 0
    local unreadable_chapters = 0
    -- Compile the book stylesheet once; per-chapter <style> blocks are layered
    -- on top inside the extractor.
    local styles = ListIndent.compile(resolved.styles)
    for _, current in ipairs(chapters) do
        local document = read_file(current.absolute)
        if not document then
            unreadable[current.index] = true
            unreadable_chapters = unreadable_chapters + 1
        end
        local candidates = document and collect_chapter_candidates(document,
            current.relative, current.index, styles) or {}
        if document and #candidates > 0 and not current.whole then
            local total_before = #candidates
            local groups = slice_range_groups(candidates, current.ranges, document)
            if groups then
                local kept = {}
                for _, group in ipairs(groups) do
                    for _, candidate in ipairs(group.candidates) do
                        kept[#kept + 1] = candidate
                    end
                end
                candidates = kept
                -- Missing anchors widen a range to the file edges; when that
                -- (or a one-paragraph chapter) keeps every candidate, the file
                -- really is fully translated and must not stay "partial".
                if #candidates == total_before then
                    current.whole = true
                else
                    current.groups = groups
                end
            end
        end
        chapter_candidates[current.index] = candidates
        total = total + #candidates
    end

    if not Tools.mkdir_p(output_dir) then
        cleanup(); return nil, "无法创建本书翻译缓存目录"
    end
    local output = output_dir .. "/manifest.json"
    local legacy_path = output_dir .. "/overlay.json"
    local entries, entry_index = {}, {}
    local previous
    local legacy_consumed = false
    local prior_state
    local manifest = Overlay.loadManifest(output_dir)
    if manifest and manifest.book_path == book_path
        and (manifest.source_lang == source_lang
            or manifest.source_lang == nil or manifest.source_lang == "") then
        previous = Overlay.loadEntries(output_dir, provider)
    end
    if previous then
        for _, entry in ipairs(previous.entries or {}) do
            if entry.selector and entry.translation then
                entries[#entries + 1] = entry
                entry_index[entry.selector] = #entries
            end
        end
        prior_state = manifest.providers and manifest.providers[provider]
    else
        -- v1.2.11 overlays have no provider field.  Accept them once as the
        -- currently configured provider so an upgrade does not discard a
        -- finished book; the next checkpoint stamps the actual provider.
        local legacy = Overlay.load(legacy_path)
        if legacy
            and legacy.book_path == book_path
            and legacy.source_lang == source_lang
            and legacy.target_lang == target_lang
            and (legacy.provider == provider or legacy.provider == nil) then
            legacy_consumed = true
            for _, entry in ipairs(legacy.entries or {}) do
                if entry.selector and entry.translation then
                    entries[#entries + 1] = entry
                    entry_index[entry.selector] = #entries
                end
            end
            prior_state = { chapters = legacy.chapters }
        end
    end
    local function provider_kind(pid)
        if pid == "system" then return "builtin" end
        if pid == "microsoft_free" then return "http" end
        if pid == "legacy" then return "legacy" end
        return "mcp"
    end
    local function count_unique(list)
        local seen, count = {}, 0
        for _, entry in ipairs(list) do
            local selector = entry.selector
            if selector and selector ~= "" and not seen[selector] then
                seen[selector] = true
                count = count + 1
            end
        end
        return count
    end
    local function merge_entries(target, index, list)
        for _, entry in ipairs(list or {}) do
            if entry.selector and entry.selector ~= "" then
                local at = index[entry.selector]
                if at then target[at] = entry
                else
                    target[#target + 1] = entry
                    index[entry.selector] = #target
                end
            end
        end
    end
    local function upsert_provider_state(manifest, pid, state)
        manifest.providers[pid] = state
        manifest.last_used_at = manifest.last_used_at or {}
        manifest.last_used_at[pid] = os.time()
        manifest.fallback_order = manifest.fallback_order or {}
        for _, existing in ipairs(manifest.fallback_order) do
            if existing == pid then return end
        end
        manifest.fallback_order[#manifest.fallback_order + 1] = pid
    end
    local function fresh_manifest()
        return {
            version = 3, revision = 0, book_path = book_path,
            source_lang = source_lang, target_lang = target_lang,
            spine_count = spine_count,
            book_size = lfs.attributes(book_path, "size") or 0,
            book_mtime = lfs.attributes(book_path, "modification") or 0,
            display_mode = "auto", display_fallback = true,
            last_used_at = {}, fallback_order = {}, providers = {},
        }
    end
    -- Per-chapter outcome of this run, keyed by spine index.  Seeded from the
    -- previous provider state and overridden for every chapter actually
    -- entered below, so a re-run upgrades failed/partial chapters to done.
    local chapter_stats = {}
    local function classify_chapters()
        local status = {}
        local function seed(list, kind)
            for _, value in ipairs(type(list) == "table" and list or {}) do
                local index = tonumber(value)
                if index and index >= 1 and index <= spine_count then
                    status[index] = kind
                end
            end
        end
        if prior_state then
            seed(prior_state.chapters, "done")
            seed(prior_state.partial_chapters, "partial")
            seed(prior_state.failed_chapters, "failed")
        end
        for index, st in pairs(chapter_stats) do
            if st.entered then
                if st.unreadable then
                    -- M2/R2: an unreadable chapter must never be "done".
                    -- Marking it done (0 candidates looked like an empty
                    -- chapter) also left complete=true, so page-turn follow
                    -- skipped the missing chapter forever.
                    status[index] = "failed"
                elseif status[index] == "done" then
                    -- Entries are only ever added or replaced, so a range run
                    -- can only fill a file in, never empty it out.
                elseif st.cancelled then
                    status[index] = "partial"
                elseif st.candidates == 0 then
                    -- An empty whole file is done (image-only chapter); an
                    -- empty slice says nothing about the rest of the file.
                    status[index] = st.whole and "done" or (status[index] or "partial")
                elseif st.success == st.candidates and st.failed == 0 then
                    -- A finished range is still only a fraction of the file.
                    status[index] = st.whole and "done" or "partial"
                elseif st.success > 0 then
                    status[index] = "partial"
                else
                    status[index] = "failed"
                end
            end
        end
        local done, partial, failed = {}, {}, {}
        for index = 1, spine_count do
            local kind = status[index]
            if kind == "done" then done[#done + 1] = index
            elseif kind == "partial" then partial[#partial + 1] = index
            elseif kind == "failed" then failed[#failed + 1] = index end
        end
        return done, partial, failed
    end
    -- Per-file list of the ranges that came back, {from, to, done}.  Seeded
    -- from the manifest so a failed re-run (or a narrower selection) never
    -- erases an earlier chapter's coverage; a file that is now whole drops its
    -- list, `chapters` already says all of it is translated.
    local function entry_coverage(done_indexes)
        local covered = {}
        if prior_state and type(prior_state.entry_ranges) == "table" then
            for index, list in pairs(prior_state.entry_ranges) do
                if type(list) == "table" then
                    -- Keep the key even when the list is empty: it marks the
                    -- file as entry-tracked, which is what stops the file-level
                    -- "partial" from being painted on every row.
                    local key = tostring(index)
                    covered[key] = Coverage.merge_ranges(covered[key], list)
                end
            end
        end
        for index, st in pairs(chapter_stats) do
            if st.entered and not st.whole and st.range_stats then
                local key = tostring(index)
                local additions = {}
                for _, stat in pairs(st.range_stats) do
                    -- Nothing succeeded: the range is not covered at all, and
                    -- recording it as partial would mark chapters this run
                    -- never touched.
                    if stat.total > 0 and stat.success > 0 then
                        additions[#additions + 1] = {
                            from = stat.range.from, to = stat.range.to,
                            done = stat.success >= stat.total or nil,
                        }
                    end
                end
                if #additions > 0 then
                    covered[key] = Coverage.merge_ranges(covered[key], additions)
                elseif covered[key] == nil and not st.cancelled then
                    -- The range held no text (an image-only chapter) or every
                    -- paragraph failed.  Keep an empty list: it tells the
                    -- picker this file is tracked per entry, so the file-level
                    -- "partial" must not spill onto rows that were never in
                    -- the request.  A cancelled file is excluded: it may
                    -- already have a file-level partial from an earlier run,
                    -- and hiding that would under-report.
                    covered[key] = {}
                end
            end
        end
        for _, index in ipairs(done_indexes) do covered[tostring(index)] = nil end
        return covered
    end
    local function save_checkpoint(complete, allow_empty)
        -- Never replace an existing overlay with an empty one.  When the
        -- provider changed and every request failed, writing an empty
        -- checkpoint would erase the previous provider's finished entries.
        -- An empty book (allow_empty) still records its done chapters.
        if #entries == 0 and not allow_empty then return true end
        local ok, saved = pcall(Lock.withBookLock, output_dir, function()
            -- Re-read under the lock and union by selector: another writer
            -- (MCP import, a concurrent run) may have landed entries since
            -- the last read, and they must not be clobbered (14.1).
            local merged, merged_index = {}, {}
            local disk = Overlay.loadEntries(output_dir, provider)
            merge_entries(merged, merged_index, disk and disk.entries)
            merge_entries(merged, merged_index, entries)
            local legacy_doc = Overlay.load(legacy_path)
            local legacy_pid
            if legacy_doc then
                legacy_pid = legacy_doc.provider
                if not legacy_pid or legacy_pid == "" then
                    -- An unmarked overlay already reused as this provider
                    -- (P0 compat) must not be double-attributed to "legacy".
                    legacy_pid = legacy_consumed and provider or "legacy"
                end
                if legacy_pid == provider then
                    merge_entries(merged, merged_index, legacy_doc.entries)
                end
            end
            if #merged == 0 and not allow_empty then return true end
            -- One paragraph, one entry: an overlay written by 3.1.x still holds
            -- the <li>/::before shape next to this run's child-list anchor, and
            -- both would be drawn (3.2.0).  Dedupe before counting so the
            -- manifest's translated_count matches the file.
            merged = Overlay.dedupeEntries(merged)
            local manifest = Overlay.loadManifest(output_dir) or fresh_manifest()
            manifest.providers = manifest.providers or {}
            local existing = manifest.providers[provider]
            local done, partial, failed = classify_chapters()
            local range_coverage = entry_coverage(done)
            -- Only a whole-book run that finished every spine chapter may be
            -- complete; span/selection runs always leave it incomplete (7.4).
            local is_complete = complete == true and mode == "all"
                and spine_count >= 1 and #partial == 0 and #failed == 0
                and #done == spine_count
            upsert_provider_state(manifest, provider, {
                display_name = existing and existing.display_name or provider,
                kind = existing and existing.kind or provider_kind(provider),
                model_name = existing and existing.model_name,
                confirmed = existing == nil or existing.confirmed ~= false,
                chapters = done,
                partial_chapters = partial,
                failed_chapters = failed,
                -- Which chapter inside a shared file finished; the picker's
                -- （已翻译）/（部分） marks read this before partial_chapters.
                entry_ranges = next(range_coverage) and range_coverage or nil,
                complete = is_complete,
                translated_count = count_unique(merged),
                updated_at = os.time(),
            })
            -- A leftover v2 overlay (queue resumed before any book open) is
            -- absorbed so its entries are never stranded, then retired.
            if legacy_pid and legacy_pid ~= provider then
                local lmerged, lindex = {}, {}
                local ldisk = Overlay.loadEntries(output_dir, legacy_pid)
                merge_entries(lmerged, lindex, ldisk and ldisk.entries)
                merge_entries(lmerged, lindex, legacy_doc.entries)
                lmerged = Overlay.dedupeEntries(lmerged)
                if #lmerged > 0 then
                    local lexisting = manifest.providers[legacy_pid]
                    local legacy_chapters = legacy_pid ~= "legacy"
                        and type(legacy_doc.chapters) == "table"
                        and legacy_doc.chapters or {}
                    upsert_provider_state(manifest, legacy_pid, {
                        display_name = lexisting and lexisting.display_name or legacy_pid,
                        kind = lexisting and lexisting.kind or provider_kind(legacy_pid),
                        model_name = lexisting and lexisting.model_name,
                        confirmed = lexisting == nil or lexisting.confirmed ~= false,
                        chapters = legacy_chapters,
                        partial_chapters = {}, failed_chapters = {},
                        complete = false,
                        translated_count = count_unique(lmerged),
                        updated_at = os.time(),
                    })
                    if not Overlay.saveEntries(output_dir, legacy_pid,
                        { target_lang = target_lang, entries = lmerged }) then
                        return false
                    end
                end
            end
            if not Overlay.saveEntries(output_dir, provider,
                { target_lang = target_lang, entries = merged }) then
                return false
            end
            if not Overlay.saveManifest(output_dir, manifest) then return false end
            -- A whole-book run is the in-process equivalent of an MCP import:
            -- precompile once at the end (not on every checkpoint) so the next
            -- cold open does not pay the entries decode.
            if is_complete and Overlay.warmCssTemplate then
                -- Best effort: a test stub or an unwritable cache must not turn
                -- a successful translation into a failed save.  `merged` is the
                -- exact array just written, so no second decode is needed.
                pcall(Overlay.warmCssTemplate, output_dir, merged, provider)
            end
            if legacy_doc then
                os.rename(legacy_path, output_dir .. "/overlay.v2.bak")
            end
            return true
        end)
        return ok and saved == true
    end
    local processed, translated_count, failed_count = 0, 0, 0
    local first_error
    local cancelled = false
    -- A dead network (or an engine that cannot reach its endpoint) fails every
    -- segment; walking the rest of a 600-chapter book only multiplies the
    -- timeout.  Stop after a run of consecutive failures and let the reader
    -- offer another engine - one success resets the counter, so a few bad
    -- paragraphs never abort a healthy run.
    local consecutive_failures = 0
    local engine_down = false
    local engine_failure_threshold = math.max(1,
        tonumber(opts.engine_failure_threshold) or 5)
    local last_processed_index = 0
    local function cancel_requested()
        if not cancel_path then return false end
        local file = io.open(cancel_path, "rb")
        if file then file:close() return true end
        return false
    end
    write_progress(progress_path, 0, total, 0, 0, 0, #chapters)
    -- Checkpoint cadence.  A checkpoint re-reads the provider file and rewrites
    -- it whole under the book lock (PW2: 5,000 entries ≈ 0.63 s load + 0.94 s
    -- save), so saving after every 48-segment batch costs minutes of pure I/O
    -- on a large book.  Every 5th batch (or 60 s, whichever comes first) keeps
    -- the crash loss bounded: those segments are already in SQLite, so a resume
    -- re-reads them as cache hits and never re-requests them.
    local checkpoint_every_batches = 5
    local checkpoint_interval = 60
    local batches_since_checkpoint = 0
    local last_checkpoint_at = os.time()
    local chapter_pos = 0
    for _, current in ipairs(chapters) do
        if cancel_requested() then cancelled = true; break end
        last_processed_index = current.index
        chapter_pos = chapter_pos + 1
        local candidates = chapter_candidates[current.index] or {}
        local st = { candidates = #candidates, success = 0, failed = 0,
            entered = true, cancelled = false, whole = current.whole == true,
            unreadable = unreadable[current.index] == true }
        -- One outcome per requested range, so the manifest can record the
        -- chapters inside this file that actually finished.
        if current.groups then
            st.range_stats = {}
            for position, group in ipairs(current.groups) do
                st.range_stats[position] = { range = group.range,
                    total = #group.candidates, success = 0 }
            end
        end
        chapter_stats[current.index] = st
        -- Release the collected source text of this chapter as soon as its
        -- batch loop finishes.  On a several-hundred-chapter book the full
        -- candidate list would otherwise stay resident for the whole run,
        -- needlessly raising the subprocess memory watermark.
        local function release_chapter()
            chapter_candidates[current.index] = nil
        end
        local batch_size = 48
        for first = 1, #candidates, batch_size do
            if cancel_requested() then cancelled = true; st.cancelled = true; break end
            local last = math.min(first + batch_size - 1, #candidates)
            local sources, translations = {}, {}
            local pending_sources, pending_offsets, pending_contexts = {}, {}, {}
            for index = first, last do
                local candidate = candidates[index]
                local offset = #sources + 1
                sources[offset] = candidate.source
                local old_index = entry_index[candidate.selector]
                local old = old_index and entries[old_index]
                if old and old.source == candidate.source and old.translation ~= "" then
                    translations[offset] = old.translation
                else
                    pending_sources[#pending_sources + 1] = candidate.source
                    pending_offsets[#pending_offsets + 1] = offset
                    pending_contexts[#pending_contexts + 1] = {
                        selector = candidate.selector,
                        xpointer = candidate.xpointer,
                        chapter_index = current.index,
                        chapter_title = current.title,
                    }
                end
            end
            if translate_batch and #pending_sources > 0 then
                local ok, values, batch_err = pcall(translate_batch, pending_sources, pending_contexts)
                if ok and values then
                    for index = 1, #pending_offsets do
                        translations[pending_offsets[index]] = values[index]
                    end
                else first_error = first_error or ((not ok and values) or batch_err) end
            end
            for offset, source in ipairs(sources) do
                local candidate = candidates[first + offset - 1]
                local translated = translations[offset]
                if not translated or translated == "" then
                    local ok, value, single_err = pcall(translate, source, {
                        selector = candidate.selector,
                        xpointer = candidate.xpointer,
                        chapter_index = current.index,
                        chapter_title = current.title,
                    })
                    if ok then translated = value else first_error = first_error or value end
                    first_error = first_error or single_err
                end
                processed = processed + 1
                if translated and translated ~= "" then
                    local entry = { selector = candidate.selector,
                        xpointer = candidate.xpointer, chapter_index = current.index,
                        source = source, translation = translated,
                        list_indent = candidate.list_indent,
                        created_at = os.time() }
                    local existing = entry_index[entry.selector]
                    if existing then
                        entries[existing] = entry
                    else
                        entries[#entries + 1] = entry
                        entry_index[entry.selector] = #entries
                    end
                    translated_count = translated_count + 1
                    st.success = st.success + 1
                    if candidate.range_group and st.range_stats then
                        local stat = st.range_stats[candidate.range_group]
                        if stat then stat.success = stat.success + 1 end
                    end
                    consecutive_failures = 0
                else
                    failed_count = failed_count + 1
                    st.failed = st.failed + 1
                    consecutive_failures = consecutive_failures + 1
                    if consecutive_failures >= engine_failure_threshold then
                        engine_down = true
                        st.cancelled = true
                        break
                    end
                end
                write_progress(progress_path, processed, total, translated_count,
                    failed_count, chapter_pos, #chapters)
            end
            -- Atomic JSON replacement provides a real restart point even when
            -- KOReader or the book closes, but it is throttled (see the
            -- cadence constants above) so a large book does not spend minutes
            -- rewriting the same file.
            batches_since_checkpoint = batches_since_checkpoint + 1
            if batches_since_checkpoint >= checkpoint_every_batches
                or os.time() - last_checkpoint_at >= checkpoint_interval then
                save_checkpoint(false)
                batches_since_checkpoint = 0
                last_checkpoint_at = os.time()
            end
            if engine_down then break end
        end
        release_chapter()
        if engine_down then break end
    end
    -- The engine stopped answering: keep what was translated and report it as
    -- its own outcome, so the reader can offer another provider instead of
    -- showing "N segments failed" for a book that never had a chance.
    if engine_down then
        save_checkpoint(false)
        cleanup()
        return {
            output = output,
            overlay = true,
            chapters = #chapters,
            translated = translated_count,
            failed = failed_count,
            cancelled = false,
            engine_down = true,
            last_chapter = false,
            error = type(first_error) == "table" and first_error.message
                or tostring(first_error or ""),
        }
    end
    -- total == 0 is a success only when every chapter was readable and really
    -- had no translatable text (image-only books).  An unreadable chapter
    -- means the EPUB text could not be parsed at all; reporting "0 段成功"
    -- would silently mark a broken book as translated.
    if translated_count == 0 and not cancelled then
        if total == 0 and unreadable_chapters > 0 then
            cleanup()
            return nil, "无法读取本书章节内容（EPUB 文本可能已损坏）"
        elseif total > 0 then
            cleanup()
            return nil, type(first_error) == "table" and first_error.message
                or tostring(first_error or "翻译服务没有返回译文")
        end
    end
    -- Only a whole-book run may mark the overlay complete; span/selection
    -- runs leave it incomplete so page-turn scheduling keeps working (7.4).
    -- An empty book (total == 0, all chapters readable) still records its
    -- chapters as done.
    local saved = save_checkpoint(not cancelled, total == 0)
    cleanup()
    if not saved then return nil, "无法保存本书翻译缓存" end
    return {
        output = output,
        overlay = true,
        chapters = #chapters,
        translated = translated_count,
        failed = failed_count,
        cancelled = cancelled,
        last_chapter = last_processed_index >= spine_count,
    }
end

-- EPUB outline (design 7.2): the chapter list behind the picker.  A job's
-- identity is the spine index (the file it translates); `entries` adds the
-- anchor of every TOC entry so a file that holds several chapters can still
-- be listed chapter by chapter (design 6.5, titles are display-only).

local function parse_elements(text)
    local root = { name = "#root", children = {} }
    local stack = { root }
    local position = 1
    while true do
        local tag_start, tag_end = text:find("<[^>]*>", position)
        if not tag_start then break end
        local raw = text:sub(tag_start, tag_end)
        position = tag_end + 1
        if not raw:match("^<%s*[!?]") then
            local closing = raw:match("^<%s*/") ~= nil
            local name = raw:match("^<%s*/?%s*([%w_:%-]+)")
            if name then
                name = name:lower():gsub("^.-:", "")
                if closing then
                    for index = #stack, 2, -1 do
                        if stack[index].name == name then
                            stack[index].inner = text:sub(stack[index].inner_start, tag_start - 1)
                            for drop = #stack, index, -1 do table.remove(stack) end
                            break
                        end
                    end
                else
                    local node = { name = name, raw = raw, children = {}, inner_start = tag_end + 1 }
                    local parent = stack[#stack]
                    parent.children[#parent.children + 1] = node
                    if raw:match("/%s*>$") or void_tags[name] then
                        node.inner = ""
                    else
                        table.insert(stack, node)
                    end
                end
            end
        end
    end
    return root
end

local function direct_child(node, name)
    for _, child in ipairs(node.children) do
        if child.name == name then return child end
    end
    return nil
end

local function collect_elements(node, name, out)
    for _, child in ipairs(node.children) do
        if child.name == name then out[#out + 1] = child end
        collect_elements(child, name, out)
    end
    return out
end

local function element_title(node)
    return html_to_text(node and node.inner or "")
end

-- EPUB2: navMap/navPoint, recursively (nested navPoints carry the level).
local function ncx_toc(tree)
    local navmaps = collect_elements(tree, "navmap", {})
    if #navmaps == 0 then return nil end
    local entries = {}
    local function walk(node, level)
        for _, child in ipairs(node.children) do
            if child.name == "navpoint" then
                local label = direct_child(child, "navlabel")
                local content = direct_child(child, "content")
                entries[#entries + 1] = {
                    title = element_title(label and direct_child(label, "text")),
                    href = content and attr(content.raw, "src"),
                    level = level,
                }
                walk(child, level + 1)
            end
        end
    end
    walk(navmaps[1], 0)
    return entries
end

-- EPUB3: nav[epub:type=toc] -> ol/li/a, nested ol one level deeper.
local function nav_toc(tree)
    local navs = collect_elements(tree, "nav", {})
    local chosen
    for _, node in ipairs(navs) do
        local kind = attr(node.raw, "type") or ""
        if (" " .. kind .. " "):find(" toc ", 1, true) then chosen = node; break end
    end
    if not chosen then
        -- Books that omit epub:type entirely still have a single reading-order
        -- nav; landmarks/page-list navs must never be mistaken for the TOC.
        for _, node in ipairs(navs) do
            local kind = attr(node.raw, "type")
            if not kind or kind == "" then chosen = node; break end
        end
    end
    if not chosen then return nil end
    local entries = {}
    local function walk_list(list, level)
        for _, item in ipairs(list.children) do
            if item.name == "li" then
                local anchor = direct_child(item, "a")
                if anchor then
                    entries[#entries + 1] = {
                        title = element_title(anchor),
                        href = attr(anchor.raw, "href"),
                        level = level,
                    }
                end
                for _, child in ipairs(item.children) do
                    if child.name == "ol" then walk_list(child, level + 1) end
                end
            end
        end
    end
    -- The TOC list is normally a direct child of <nav>, but real-world EPUB3
    -- files wrap it (<nav epub:type="toc"><div><ol>); only looking at direct
    -- children turned those books into a spine-only outline ("第 N 节").
    -- collect_elements walks depth-first, so [1] is the outer list.
    local list = collect_elements(chosen, "ol", {})[1]
    if list then walk_list(list, 0) end
    return entries
end

-- The file path and the in-file anchor are returned separately: the path
-- identifies the spine file (the translation unit), the fragment identifies
-- the chapter inside it.  `file.xhtml#` and `file.xhtml` mean the same thing,
-- so an empty fragment is not an anchor.
local function toc_href(base, href)
    if not href or href == "" then return nil end
    local path, fragment = href:match("^([^#]*)#?(.*)$")
    if fragment == "" then fragment = nil end
    if path == "" then return nil, fragment end
    path = socket_url.unescape(path)
    if fragment then fragment = socket_url.unescape(fragment) end
    if path:sub(1, 1) == "/" then return normalize_path(path), fragment end
    return normalize_path(base .. "/" .. path), fragment
end

local function build_spine_lookup(spine)
    local exact, lowered = {}, {}
    for index, href in ipairs(spine) do
        if not exact[href] then exact[href] = index end
        local key = href:lower()
        local bucket = lowered[key]
        if not bucket then
            lowered[key] = { index = index, href = href, count = 1 }
        elseif bucket.href ~= href then
            bucket.count = bucket.count + 1
        end
    end
    return exact, lowered
end

local function map_to_spine(href, spine, exact, lowered)
    local index = exact[href]
    if index then return index, spine[index] end
    local bucket = lowered[href:lower()]
    -- Zip member names are case sensitive: a case-insensitive guess is only
    -- safe when exactly one spine file answers to it (design 7.2 step 5).
    if bucket and bucket.count == 1 then return bucket.index, bucket.href end
    return nil
end

local function spine_chapters(spine)
    local chapters = {}
    for index = 1, #spine do
        chapters[index] = { index = index, title = string.format("第 %d 节", index),
            href = spine[index], level = 0 }
    end
    return chapters
end

local function remember_alias(chapter, title)
    if not title or title == "" or title == chapter.title then return end
    chapter.aliases = chapter.aliases or {}
    for _, existing in ipairs(chapter.aliases) do
        if existing == title then return end
    end
    chapter.aliases[#chapter.aliases + 1] = title
end

-- Per-entry view of the TOC (7.2): one record per TOC entry, keeping the
-- anchor that locates the chapter inside its spine file.  Scanned and
-- PDF-converted EPUBs put dozens of chapters in one XHTML and anchor every
-- navPoint inside it; without the anchor the picker can only show the file.
-- Entries whose file is not in the spine are skipped exactly once here.
local function toc_entries(entries, base, spine, exact, lowered, logger)
    local list = {}
    for _, entry in ipairs(entries) do
        local href, fragment = toc_href(base, entry.href)
        local index, original
        if href then index, original = map_to_spine(href, spine, exact, lowered) end
        if not index then
            logger.warn("dualtranslate: outline entry not in spine, skipped:",
                tostring(entry.href))
        else
            local title = entry.title
            if not title or title == "" then title = string.format("第 %d 节", index) end
            list[#list + 1] = {
                index = index,
                href = original,
                anchor = fragment,
                title = title,
                level = tonumber(entry.level) or 0,
            }
        end
    end
    return list
end

-- One row per spine file, which stays the unit of work for a translation
-- job.  Several TOC entries on one file collapse into the shallowest title,
-- the rest become aliases.  Derived from the entry list above so the two
-- views can never disagree about which file an entry belongs to.
local function toc_chapters(entries)
    local chapters, by_index = {}, {}
    for _, entry in ipairs(entries) do
        local index = entry.index
        local title, level = entry.title, entry.level
        local kept = by_index[index]
        if not kept then
            kept = { index = index, title = title, href = entry.href, level = level }
            by_index[index] = kept
            chapters[#chapters + 1] = kept
        elseif level < kept.level then
            local previous = kept.title
            kept.title, kept.level = title, level
            remember_alias(kept, previous)
        else
            remember_alias(kept, title)
        end
    end
    return chapters
end

-- Priority: NCX (EPUB2) -> properties="nav" XHTML (EPUB3) -> OPF spine toc.
local function outline_candidates(package)
    local ncx, nav
    for _, item in ipairs(package.items) do
        local media = (item.media_type or ""):lower()
        if media == "application/x-dtbncx+xml" then
            if not ncx or item.href:lower():match("[^/]+$") == "toc.ncx" then ncx = item end
        end
        if not nav and (" " .. (item.properties or "") .. " "):find(" nav ", 1, true) then
            nav = item
        end
    end
    local spine_toc = package.toc_id and package.manifest[package.toc_id]
    local candidates, seen = {}, {}
    local function add(item)
        if item and item.href ~= "" and not seen[item.href] then
            seen[item.href] = true
            candidates[#candidates + 1] = item.href
        end
    end
    add(ncx)
    add(nav)
    add(spine_toc)
    return candidates
end

local function parse_outline(book_path, work_dir)
    local logger = require("logger")
    -- Three on-demand passes instead of one full unzip: each iterate() only
    -- walks the central directory, so image-heavy books cost nothing extra.
    local first = Tools.extract_entries(book_path, work_dir,
        { ["META-INF/container.xml"] = true })
    if not first then return nil, "无法解包 EPUB（可能受 DRM 保护）" end
    local container = first["META-INF/container.xml"]
        and read_file(first["META-INF/container.xml"])
    if not container then return nil, "找不到 META-INF/container.xml" end
    local opf_path = container_opf_path(container)
    if not opf_path then return nil, "找不到 OPF 路径" end

    local second = Tools.extract_entries(book_path, work_dir, { [opf_path] = true })
    local opf = second and second[opf_path] and read_file(second[opf_path])
    if not opf then return nil, "找不到 OPF 文件" end
    local package = parse_package(opf, opf_path)
    if #package.spine == 0 then return nil, "找不到可读取的 spine 项" end

    local candidates = outline_candidates(package)
    local wanted = {}
    for _, href in ipairs(candidates) do wanted[href] = true end
    local third = next(wanted) and Tools.extract_entries(book_path, work_dir, wanted) or {}
    local base = dirname(opf_path)
    local exact, lowered = build_spine_lookup(package.spine)
    for _, href in ipairs(candidates) do
        local text = third[href] and read_file(third[href])
        if text then
            local tree = parse_elements(text)
            local entries, source = ncx_toc(tree), "ncx"
            if not entries or #entries == 0 then
                entries, source = nav_toc(tree), "nav"
            end
            local chapters = {}
            local entry_list = entries
                and toc_entries(entries, base, package.spine, exact, lowered, logger) or {}
            if #entry_list > 0 then chapters = toc_chapters(entry_list) end
            if #chapters > 0 then
                return { source = source, spine_count = #package.spine,
                    chapters = chapters, entries = entry_list }
            end
        end
    end
    return { source = "spine", spine_count = #package.spine,
        chapters = spine_chapters(package.spine), entries = {} }
end

local function outline_cache_file(book_path)
    return DataStorage:getDataDir() .. "/cache/dualtranslate/outline/"
        .. Tools.stable_path_hash(book_path) .. ".json"
end

-- v2 stores the per-entry `entries` list next to the file-level chapters.
-- A v1 cache has no anchors, so it is rejected and reparsed once: keeping it
-- would silently show the old file-granularity list for every cached book.
local OUTLINE_CACHE_VERSION = 2

local function load_outline_cache(book_path, size, mtime)
    local raw = read_file(outline_cache_file(book_path))
    if not raw then return nil end
    local JSON = require("json")
    local ok, doc = pcall(JSON.decode, raw)
    if not ok or type(doc) ~= "table" or doc.version ~= OUTLINE_CACHE_VERSION then
        return nil
    end
    -- size/mtime are part of the key: a replaced or edited book must reparse.
    if doc.book_path ~= book_path or doc.book_size ~= size or doc.book_mtime ~= mtime then
        return nil
    end
    if doc.source ~= "ncx" and doc.source ~= "nav" and doc.source ~= "spine" then return nil end
    if type(doc.spine_count) ~= "number" or type(doc.chapters) ~= "table" then return nil end
    local chapters = {}
    for _, chapter in ipairs(doc.chapters) do
        if type(chapter) ~= "table" or type(chapter.index) ~= "number"
            or type(chapter.title) ~= "string" or type(chapter.href) ~= "string"
            or chapter.index < 1 or chapter.index > doc.spine_count then
            return nil
        end
        chapters[#chapters + 1] = {
            index = chapter.index,
            title = chapter.title,
            href = chapter.href,
            level = tonumber(chapter.level) or 0,
            aliases = type(chapter.aliases) == "table" and chapter.aliases or nil,
        }
    end
    if #chapters == 0 then return nil end
    -- Entries are optional only in the sense that a spine-only outline has
    -- none; a v2 cache without the list is malformed, not a valid old file.
    if type(doc.entries) ~= "table" then return nil end
    local entries = {}
    for _, entry in ipairs(doc.entries) do
        if type(entry) ~= "table" or type(entry.index) ~= "number"
            or type(entry.title) ~= "string" or type(entry.href) ~= "string"
            or entry.index < 1 or entry.index > doc.spine_count then
            return nil
        end
        entries[#entries + 1] = {
            index = entry.index,
            title = entry.title,
            href = entry.href,
            level = tonumber(entry.level) or 0,
            anchor = type(entry.anchor) == "string" and entry.anchor ~= ""
                and entry.anchor or nil,
        }
    end
    return { source = doc.source, spine_count = doc.spine_count,
        chapters = chapters, entries = entries }
end

local function save_outline_cache(book_path, size, mtime, outline)
    local logger = require("logger")
    local JSON = require("json")
    local path = outline_cache_file(book_path)
    local ok, encoded = pcall(JSON.encode, {
        version = OUTLINE_CACHE_VERSION, book_path = book_path,
        book_size = size, book_mtime = mtime,
        source = outline.source, spine_count = outline.spine_count,
        chapters = outline.chapters, entries = outline.entries or {},
    })
    if not ok then
        logger.warn("dualtranslate: outline cache encode failed:", tostring(encoded))
        return false
    end
    if not Tools.mkdir_p(path:match("^(.*)/[^/]+$")) then
        logger.warn("dualtranslate: outline cache dir unavailable:", path)
        return false
    end
    local temporary = path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then
        logger.warn("dualtranslate: outline cache write failed:", path)
        return false
    end
    local written = file:write(encoded)
    local closed = file:close()
    if not written or not closed or not os.rename(temporary, path) then
        os.remove(temporary)
        logger.warn("dualtranslate: outline cache write failed:", path)
        return false
    end
    return true
end

function Epub.outline(book_path, ...)
    -- Design 7.2 spells this Epub.outline(path); also accept the module's usual
    -- colon style so a caller cannot hand us self as the book path.
    local before_parse
    if type(book_path) == "table" then
        book_path, before_parse = ...
    else
        before_parse = ...
    end
    if type(book_path) ~= "string" or book_path == "" then return nil, "缺少书路径" end
    if not book_path:lower():match("%.epub$") then
        return nil, "目录解析目前仅支持 EPUB"
    end
    local size = lfs.attributes(book_path, "size")
    local mtime = lfs.attributes(book_path, "modification") or 0
    if not size then return nil, "找不到书文件" end
    local cached = load_outline_cache(book_path, size, mtime)
    if cached then return cached end
    -- Parsing blocks for seconds; the caller uses this hook to paint a message
    -- first.  Called after both cache paths, so a cache hit never flashes it.
    if before_parse then before_parse() end

    local work_dir = new_work_dir("outline_")
    if not work_dir then return nil, "无法创建临时目录" end
    -- pcall keeps the cleanup unconditional: a parse error must not leave an
    -- outline_<nonce> directory behind (design 7.2).
    local ok, result, err = pcall(parse_outline, book_path, work_dir)
    Tools.rmtree(work_dir)
    if not ok then return nil, tostring(result) end
    if not result then return nil, err end
    save_outline_cache(book_path, size, mtime, result)
    return result
end

-- ---------------------------------------------------------------------------
-- Page -> TOC entry (current chapter at entry granularity)
--
-- A TOC entry is an anchor, and CREngine can tell the page an element starts
-- on if the element is addressed the way its own xpointers are: a path of tag
-- names with sibling indices ("/body/div[2]/h1").  Parsing the chapter once
-- yields that path for every anchor, so mapping the page costs one parse per
-- chapter, not one per page turn, and no text is re-requested.
-- ---------------------------------------------------------------------------

-- Spine hrefs, cached per book: resolving one chapter needs the OPF, and a
-- page turn must not unpack the container again.
local spine_cache
function Epub.spine(book_path)
    local size = lfs.attributes(book_path, "size")
    local mtime = lfs.attributes(book_path, "modification") or 0
    if spine_cache and spine_cache.book_path == book_path
        and spine_cache.size == size and spine_cache.mtime == mtime then
        return spine_cache.spine
    end
    local work_dir = new_work_dir("spine_")
    if not work_dir then return nil end
    local ok, spine = pcall(function()
        local first = Tools.extract_entries(book_path, work_dir,
            { ["META-INF/container.xml"] = true })
        local container = first and first["META-INF/container.xml"]
            and read_file(first["META-INF/container.xml"])
        local opf_path = container and container_opf_path(container)
        if not opf_path then return nil end
        local second = Tools.extract_entries(book_path, work_dir, { [opf_path] = true })
        local opf_file = second and second[opf_path]
        local opf = opf_file and read_file(opf_file)
        if not opf then return nil end
        return parse_package(opf, opf_path).spine
    end)
    Tools.rmtree(work_dir)
    if not ok or type(spine) ~= "table" or #spine == 0 then return nil end
    -- size/mtime in the key, same as the outline cache: the same path can be
    -- replaced by a new edition, and its spine is not this book's spine.
    spine_cache = { book_path = book_path, size = size, mtime = mtime,
        spine = spine }
    return spine
end

-- Anchor id -> element path under body ("/body/div[2]/h1"), for one spine
-- item.  Only the page the user is reading is parsed, but keeping a single
-- entry re-unpacked the file every time the reader crossed a chapter
-- boundary and turned back (chapter mode follows the page, so "last page of
-- the chapter, then its first again" is a normal reading pattern).  Three
-- slots hold the chapter being read plus its neighbours; the fourth oldest
-- is dropped, which costs one unpack the next time it is entered.
local ANCHOR_PATH_CACHE_SLOTS = 3
local anchor_path_cache = {}

-- Most recently used first, so the eviction at the tail is the chapter the
-- reader left longest ago.
local function anchor_path_cache_get(book_path, index, size, mtime)
    for position, entry in ipairs(anchor_path_cache) do
        if entry.book_path == book_path and entry.index == index
            and entry.size == size and entry.mtime == mtime then
            if position > 1 then
                table.remove(anchor_path_cache, position)
                table.insert(anchor_path_cache, 1, entry)
            end
            return entry.paths
        end
    end
end

local function anchor_path_cache_put(entry)
    -- A replaced file leaves an entry whose size/mtime can never match again.
    -- Drop it rather than let it hold one of the three slots.
    for position = #anchor_path_cache, 1, -1 do
        local existing = anchor_path_cache[position]
        if existing.book_path == entry.book_path and existing.index == entry.index then
            table.remove(anchor_path_cache, position)
        end
    end
    table.insert(anchor_path_cache, 1, entry)
    while #anchor_path_cache > ANCHOR_PATH_CACHE_SLOTS do
        table.remove(anchor_path_cache)
    end
end

function Epub.chapter_anchor_paths(book_path, index)
    index = tonumber(index)
    if not index then return nil end
    -- A replaced file must not reuse the previous copy's element paths.
    local size = lfs.attributes(book_path, "size")
    local mtime = lfs.attributes(book_path, "modification")
    local cached = anchor_path_cache_get(book_path, index, size, mtime)
    if cached then return cached end
    local spine = Epub.spine(book_path)
    local relative = spine and spine[index]
    if not relative then return nil end
    local work_dir = new_work_dir("anchor_")
    if not work_dir then return nil end
    local ok, paths = pcall(function()
        local extracted = Tools.extract_entries(book_path, work_dir, { [relative] = true })
        local path
        for _, value in pairs(extracted or {}) do path = value end
        local document = path and read_file(path)
        if not document then return nil end
        local tree = parse_elements(document)
        local root = direct_child(tree, "html") or tree
        local body = direct_child(root, "body") or root
        local map = {}
        local function walk(node, prefix)
            local counts = {}
            for _, child in ipairs(node.children) do
                local count = (counts[child.name] or 0) + 1
                counts[child.name] = count
                -- Same spelling as collect_overlay_candidates: the index is
                -- omitted for the first element of its type, which is also
                -- what CREngine writes back.  An explicit [1] parses too, but
                -- two spellings for one address invite drift.
                local child_path = prefix .. "/" .. child.name
                    .. (count > 1 and ("[" .. count .. "]") or "")
                local id = tag_anchor_id(child.raw)
                -- The first occurrence wins, same as the slicer's range start.
                if id and not map[id] then map[id] = child_path end
                walk(child, child_path)
            end
        end
        walk(body, "/body")
        return map
    end)
    Tools.rmtree(work_dir)
    if not ok or type(paths) ~= "table" then return nil end
    anchor_path_cache_put({ book_path = book_path, index = index, paths = paths,
        size = size, mtime = mtime })
    return paths
end

-- ---------------------------------------------------------------------------
-- MCP job extraction (design 10.2)
--
-- The device exports the job because selectors must match CREngine's own
-- DocFragment tree: a PC-side EPUB parser would drift and paste translations
-- onto the wrong paragraphs.  Candidates therefore come from
-- collect_chapter_candidates (collect_overlay_candidates plus the div
-- fallback), the exact parser the overlay uses.
--
-- Long paragraphs are split at max_chars so no agent receives a 10k-character
-- segment; every part keeps the parent's selector/xpointer and carries
-- part/parent_total so the importer can stitch them back in order (10.2).
--
-- 3.2.0: the walk is a session (begin_segment_export + step + finish) because a
-- whole book is ~600 chapters / 16k segments.  Doing it in one call froze the
-- UI thread for tens of seconds with no progress and no way to cancel;
-- collect_segments keeps the one-shot contract for dtctl and the tests by
-- driving the same session to completion.
-- ---------------------------------------------------------------------------
local ExportSession = {}
ExportSession.__index = ExportSession

function ExportSession:chapter_count()
    return #self.chapter_order
end

function ExportSession:processed()
    return self.position
end

-- Parse chapters until the CPU budget is spent (or the selection is done) and
-- return how many chapters are processed.  The budget is CPU time, not wall
-- time: a slow SD card must not stretch one slice into a visible freeze.
function ExportSession:step(seconds)
    local budget = tonumber(seconds) or 0.2
    local started = os.clock()
    local total = #self.chapter_order
    while self.position < total do
        self:_next_chapter()
        if os.clock() - started >= budget then break end
    end
    return self.position
end

function ExportSession:_next_chapter()
    self.position = self.position + 1
    local index = self.chapter_order[self.position]
    local relative = self.spine[index]
    local document = relative and self.third[relative] and read_file(self.third[relative])
    if not document then
        self.unreadable = self.unreadable + 1
        return
    end
    local candidates = collect_chapter_candidates(document, relative, index, self.sheet)
    local whole = self.whole_by_index[index] == true
    local groups
    if #candidates > 0 and not whole then
        local total_before = #candidates
        groups = slice_range_groups(candidates, self.ranges_by_index[index], document)
        if groups then
            local kept = {}
            for _, group in ipairs(groups) do
                for _, candidate in ipairs(group.candidates) do
                    kept[#kept + 1] = candidate
                end
            end
            -- Same rule as the translation path: a slice that kept every
            -- candidate covered the whole file, so the export may say
            -- "not partial".
            if #kept == total_before then
                whole = true
                self.whole_by_index[index] = true
                groups = nil
            else
                candidates = kept
            end
        end
    end
    -- A range that kept no text at all (image-only span, anchors pointing into
    -- an empty region) has nothing to export.  Shipping a partial chapter with
    -- zero segments would make the importer file it as failed/partial and the
    -- picker paint the whole file, so skip it instead.
    if #candidates == 0 and not whole then return end
    local title = self.titles[index] or string.format("第 %d 章", index)
    -- `partial` is what keeps the importer from marking a whole file done
    -- when only one chapter inside it was exported.
    local chapter = { index = index, title = title }
    if not whole then
        chapter.partial = true
        -- Which chapters inside this file the job carries: the importer
        -- records them, so the picker can mark the entries that were exported
        -- instead of calling the whole file partly translated.  The bounds are
        -- the ones the slice really used (an anchor missing from the XHTML
        -- widens to the file edge), not the requested ones — otherwise the
        -- importer would mark a narrower range than was translated.
        local ranges = {}
        if groups then
            for _, group in ipairs(groups) do
                if #group.candidates > 0 then
                    ranges[#ranges + 1] = { from = group.range.from, to = group.range.to }
                end
            end
        else
            for _, range in ipairs(self.ranges_by_index[index] or {}) do
                ranges[#ranges + 1] = { from = range.from, to = range.to }
            end
        end
        if #ranges > 0 then chapter.ranges = ranges end
    end
    self.chapters[#self.chapters + 1] = chapter
    for _, candidate in ipairs(candidates) do
        local parts = Tools.split_text(candidate.source, self.max_chars)
        if #parts == 0 then parts = { candidate.source } end
        local parent_id = string.format("s%06d", #self.segments + 1)
        for part_index, part_text in ipairs(parts) do
            self.segments[#self.segments + 1] = {
                id = string.format("s%06d", #self.segments + 1),
                parent_id = parent_id,
                part = part_index,
                parent_total = #parts,
                chapter_index = index,
                chapter_title = title,
                selector = candidate.selector,
                xpointer = candidate.xpointer,
                list_indent = candidate.list_indent,
                source = part_text,
            }
        end
    end
end

-- Release the extraction directory.  Safe to call twice.
function ExportSession:cleanup()
    if self.work_dir then
        Tools.rmtree(self.work_dir)
        self.work_dir = nil
    end
end

function ExportSession:abort()
    self:cleanup()
    self.aborted = true
end

-- The table collect_segments used to build directly, assembled from the
-- chapters this session actually walked (a cancelled run never gets here).
function ExportSession:finish()
    self:cleanup()
    if #self.segments == 0 then
        if self.unreadable > 0 then
            return nil, "无法读取所选章节内容（EPUB 文本可能已损坏）"
        end
        return nil, "所选章节没有可导出的段落"
    end
    return {
        book_path = self.book_path,
        spine_count = self.spine_count,
        chapters = self.chapters,
        segments = self.segments,
        unreadable = self.unreadable,
        max_chars_per_segment = self.max_chars,
    }
end

-- Open the archive, resolve the spine and extract the selected chapters.  This
-- is the only blocking part of an export (three archive passes); everything
-- after it is sliced by ExportSession:step.
function Epub.begin_segment_export(opts)
    opts = opts or {}
    local book_path = opts.book_path
    if type(book_path) ~= "string" or book_path == "" then return nil, "缺少书路径" end
    if not book_path:lower():match("%.epub$") then
        return nil, "MCP 任务导出目前仅支持 EPUB"
    end
    local max_chars = math.max(200, tonumber(opts.max_chars) or 4500)
    local work_dir = new_work_dir("job_")
    if not work_dir then return nil, "无法创建临时目录" end
    local function cleanup() Tools.rmtree(work_dir) end

    local first = Tools.extract_entries(book_path, work_dir,
        { ["META-INF/container.xml"] = true })
    local container_path = first and first["META-INF/container.xml"]
    local container = container_path and read_file(container_path)
    if not container then
        cleanup()
        return nil, "无法解包 EPUB（可能受 DRM 保护）"
    end
    local opf_path = container_opf_path(container)
    if not opf_path then cleanup(); return nil, "找不到 OPF 路径" end
    local second = Tools.extract_entries(book_path, work_dir, { [opf_path] = true })
    local opf_file = second and second[opf_path]
    local opf = opf_file and read_file(opf_file)
    if not opf then cleanup(); return nil, "找不到 OPF 文件" end
    local package = parse_package(opf, opf_path)
    local spine = package.spine
    if #spine == 0 then cleanup(); return nil, "找不到可读取的 spine 项" end

    -- An explicit range list that normalises to nothing must fail, not fall
    -- back to "the caller chose nothing, so export the whole book": that fall
    -- back would write the entire book to a PC-readable job file after the
    -- privacy notice promised a selection.
    local ranges_provided = type(opts.chapter_ranges) == "table"
    local ranges = normalize_ranges(opts.chapter_ranges, #spine)
    if #ranges == 0 and not ranges_provided then
        local chapter_indexes
        if type(opts.chapter_indexes) == "table" and #opts.chapter_indexes > 0 then
            chapter_indexes = normalize_indexes(opts.chapter_indexes, #spine)
        else
            chapter_indexes = {}
            for index = 1, #spine do chapter_indexes[#chapter_indexes + 1] = index end
        end
        for _, index in ipairs(chapter_indexes) do
            ranges[#ranges + 1] = { index = index }
        end
    end
    if #ranges == 0 then cleanup(); return nil, "所选范围没有可导出的章节" end
    local ranges_by_index, chapter_order, whole_by_index = {}, {}, {}
    for _, range in ipairs(ranges) do
        local bucket = ranges_by_index[range.index]
        if not bucket then
            bucket = {}
            ranges_by_index[range.index] = bucket
            chapter_order[#chapter_order + 1] = range.index
        end
        bucket[#bucket + 1] = range
        if not range.from and not range.to then whole_by_index[range.index] = true end
    end

    local wanted = {}
    for _, index in ipairs(chapter_order) do
        if spine[index] then wanted[spine[index]] = true end
    end
    local third = Tools.extract_entries(book_path, work_dir, wanted)
    if not third then cleanup(); return nil, "无法读取章节文件" end

    -- The list indent comes from the publisher stylesheets, so they are
    -- extracted alongside the chapters (one extra archive pass, only for the
    -- CSS entries the manifest declares).
    local css_wanted, css_order = {}, {}
    for _, item in ipairs(package.items) do
        if tostring(item.media_type or ""):lower():find("css", 1, true) then
            css_wanted[item.href] = true
            css_order[#css_order + 1] = item.href
        end
    end
    local styles = {}
    if #css_order > 0 then
        local css_files = Tools.extract_entries(book_path, work_dir, css_wanted) or {}
        for _, href in ipairs(css_order) do
            local text = css_files[href] and read_file(css_files[href])
            if text and text ~= "" then styles[#styles + 1] = text end
        end
    end
    return setmetatable({
        book_path = book_path,
        spine_count = #spine,
        spine = spine,
        third = third,
        sheet = ListIndent.compile(styles),
        max_chars = max_chars,
        titles = type(opts.titles) == "table" and opts.titles or {},
        chapter_order = chapter_order,
        ranges_by_index = ranges_by_index,
        whole_by_index = whole_by_index,
        chapters = {},
        segments = {},
        unreadable = 0,
        position = 0,
        work_dir = work_dir,
    }, ExportSession)
end

function Epub.collect_segments(opts)
    local session, err = Epub.begin_segment_export(opts)
    if not session then return nil, err end
    -- One slice, no yielding: headless callers have no event loop to feed.
    session:step(math.huge)
    return session:finish()
end

return Epub
