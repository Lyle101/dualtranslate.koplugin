-- ============================================================
-- 列表缩进：从书的 CSS / 内联 style 计算父项译文的负 margin
-- Run: luajit tests/listindent_test.lua
-- ============================================================
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

package.loaded["dualtranslate_listindent"] = nil
local ListIndent = dofile("dualtranslate_listindent.lua")

local function element(tag, id, classes, ancestors)
    local map = {}
    for _, class in ipairs(classes or {}) do map[class] = true end
    return { tag = tag, id = id, classes = map, ancestors = ancestors or {} }
end

local BODY = { tag = "body", classes = {} }
local TOC = { tag = "div", id = "toc", classes = {} }

local function list(tag, options)
    options = options or {}
    local element_in_builder = options.element or element(tag, nil, nil, { BODY })
    local first_li = options.first_li
    if first_li then
        first_li.ancestors = first_li.ancestors or { BODY, element_in_builder }
    end
    return {
        element = element_in_builder,
        item_count = options.item_count or 3,
        start = options.start or 1,
        style_attr = options.style_attr,
        first_li = first_li,
    }
end

-- ============================================================
print("== 1. 无出版商样式：CREngine 默认值 ==")
do
    local sheet = ListIndent.compile({})
    -- 1em（epub.css 的 margin-left）+ decimal "1." + 后缀空白
    check("ol 默认缩进", ListIndent.indent(sheet, list("ol")) == "2.23em",
        tostring(ListIndent.indent(sheet, list("ol"))))
    -- bullet 是整宽字形 + 后缀空白
    check("ul 默认缩进", ListIndent.indent(sheet, list("ul")) == "1.95em",
        tostring(ListIndent.indent(sheet, list("ul"))))
    check("nil sheet 回落默认", ListIndent.indent(nil, list("ol")) == "2.23em")
end

-- ============================================================
print("== 2. 书内 CSS 覆盖 ==")
do
    local sheet = ListIndent.compile({
        [[
        #toc > ol { padding-left: 0; }
        ol.tight { margin: 0 0 0 2em; }
        ul { padding: 0 0 0 3em; }
        .bare > ol { padding-left: -cr-special; }
        ]],
    })
    local in_toc = element("ol", nil, nil, { BODY, TOC })
    check("#toc > ol 命中 -> 1em", ListIndent.indent(sheet, list("ol", { element = in_toc })) == "1em",
        tostring(ListIndent.indent(sheet, list("ol", { element = in_toc }))))
    -- 同样带 #toc 选择器，但列表不在 #toc 里：规则不得生效
    check("#toc 不匹配时不生效",
        ListIndent.indent(sheet, list("ol")) == "2.23em",
        tostring(ListIndent.indent(sheet, list("ol"))))
    check("class 命中 margin 简写",
        ListIndent.indent(sheet, list("ol", {
            element = element("ol", nil, { "tight" }, { BODY }),
        })) == "3.23em")
    check("padding 简写取 left 分量",
        ListIndent.indent(sheet, list("ul")) == "4em")
    check("-cr-special 仍按 marker 计算",
        ListIndent.indent(sheet, list("ol", {
            element = element("ol", nil, nil, { BODY, { tag = "div", classes = { bare = true } } }),
        })) == "2.23em")
end

-- ============================================================
print("== 3. marker 形态 ==")
do
    local sheet = ListIndent.compile({})
    check("list-style-type none -> 仅 margin",
        ListIndent.indent(sheet, {
            element = element("ul", nil, nil, { BODY }), item_count = 2, start = 1,
        }) == "1.95em")
    local none = ListIndent.compile({ "li { list-style-type: none; }" })
    check("li 上的 none 不改变 ul 的 marker", ListIndent.indent(none, list("ul")) == "1.95em")
    local inside = ListIndent.compile({ "ul { list-style-position: inside; }" })
    check("inside -> padding 0", ListIndent.indent(inside, list("ul")) == "1em")

    local bullet_none = ListIndent.compile({ "ul { list-style-type: none; }" })
    check("ul 自身 none -> 1em", ListIndent.indent(bullet_none, list("ul")) == "1em")

    check("两位数 marker 更宽",
        ListIndent.indent(sheet, list("ol", { start = 98, item_count = 2 })) == "2.78em",
        tostring(ListIndent.indent(sheet, list("ol", { start = 98, item_count = 2 }))))
    check("字母 marker",
        ListIndent.indent(sheet, list("ol", { element = element("ol", nil, nil, { BODY }) }))
            == "2.23em")
    local alpha = ListIndent.compile({ "ol { list-style-type: upper-alpha; }" })
    check("upper-alpha 宽度",
        ListIndent.indent(alpha, list("ol", { item_count = 3 })) == "2.18em",
        tostring(ListIndent.indent(alpha, list("ol", { item_count = 3 }))))

    -- calibre 转换的书把 marker 关在 <li> 上：容器仍是 decimal，条目却是
    -- none，CREngine 因此算出 0 padding。
    local calibre = ListIndent.compile({
        ".calibre2 { list-style-type: decimal; }",
        ".calibre3 { list-style-type: none; }",
    })
    check("li 上 none 取消 marker",
        ListIndent.indent(calibre, list("ol", {
            element = element("ol", nil, { "calibre2" }, { BODY }),
            first_li = element("li", nil, { "calibre3" }),
        })) == "1em",
        tostring(ListIndent.indent(calibre, list("ol", {
            element = element("ol", nil, { "calibre2" }, { BODY }),
            first_li = element("li", nil, { "calibre3" }),
        }))))
    check("li 未设时用容器的 marker",
        ListIndent.indent(calibre, list("ol", {
            element = element("ol", nil, { "calibre2" }, { BODY }),
            first_li = element("li", nil, nil),
        })) == "2.23em")
end

-- ============================================================
print("== 4. 单位与内联 style ==")
do
    local px = ListIndent.compile({ "ol { padding-left: 16px; }" })
    check("px 折算 em", ListIndent.indent(px, list("ol")) == "2em",
        tostring(ListIndent.indent(px, list("ol"))))
    local pt = ListIndent.compile({ "ol { padding-left: 12pt; }" })
    check("pt 折算 em", ListIndent.indent(pt, list("ol")) == "2em",
        tostring(ListIndent.indent(pt, list("ol"))))
    local pct = ListIndent.compile({ "ol { padding-left: 10%; }" })
    check("% 回落 marker", ListIndent.indent(pct, list("ol")) == "2.23em")

    local base = ListIndent.compile({ "ol { padding-left: 0; }" })
    check("内联 style 覆盖样式表",
        ListIndent.indent(base, list("ol", { style_attr = "padding-left: 2em" })) == "3em",
        tostring(ListIndent.indent(base, list("ol", { style_attr = "padding-left: 2em" }))))
end

-- ============================================================
print("== 5. @media 与本章 <style> ==")
do
    local media = ListIndent.compile({ "@media screen { ol { padding-left: 0; } }" })
    check("@media 内规则生效", ListIndent.indent(media, list("ol")) == "1em")
    local extended = ListIndent.extend(ListIndent.compile({}),
        "ol { margin-left: 0; padding-left: 0; }")
    check("extend 追加本章样式", ListIndent.indent(extended, list("ol")) == nil,
        tostring(ListIndent.indent(extended, list("ol"))))
end

-- ============================================================
print("== 6. 选择器匹配 ==")
do
    local parts = ListIndent._split_selector("#toc > ol > li")
    check("拆分组合器", parts and #parts == 3 and parts[1].child == true
        and parts[2].child == true and parts[3].child == false)
    check("兄弟组合器丢弃", ListIndent._split_selector("h2 + ol") == nil)
    local element_in_toc = element("ol", nil, nil, { BODY, TOC })
    check("后代匹配", ListIndent._selector_matches(
        ListIndent._split_selector("#toc ol"), element_in_toc) ~= nil)
    check("直接子级不匹配孙级", ListIndent._selector_matches(
        ListIndent._split_selector("#toc > ol"), element("ol", nil, nil,
            { BODY, TOC, { tag = "li", classes = {} } })) == nil)
end

print(string.format("\n==== 列表缩进结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
