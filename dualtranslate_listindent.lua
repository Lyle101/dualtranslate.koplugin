-- Per-book list indentation for the list-parent translation layer.
--
-- A list parent's translation is attached to its child list ("ol:nth-of-type
-- (n)::before"), because that is the only insertion point that sits between
-- the parent item's own text and the first child item.  That box starts at
-- the child items' indent, so the generated rule pulls it back by hand:
--
--     margin-left: -<child list indent>
--
-- The indent is not a constant.  KOReader's epub.css gives every list
-- "margin-left: 1em" plus the user-agent "padding-left" that CREngine
-- resolves dynamically from the widest marker of the list (the "-cr-special"
-- value in html5.css), and a book may override either with anything from
-- "#toc > ol { padding-left: 0 }" to "ol { margin: 0 0 0 2em }".  Hardcoding
-- 1.5em therefore lines up only for books that happen to match it.
--
-- This module reads the book's own stylesheets (plus the inline style
-- attribute of the list) and computes margin-left + padding-left in em, the
-- unit the generated rule uses.  Expressions are kept in the list's own em so
-- the result stays correct when the reader's font size changes; the dynamic
-- marker padding is reproduced from the marker text CREngine would draw
-- (digits/letters/bullets plus the suffix space), which is font independent.
local ListIndent = {}

-- CREngine appends one space to the marker text and measures the whole thing.
local MARKER_SPACE_EM = 0.4
-- epub.css: "ol, ul { margin-left: 1em }" (the KOReader default stylesheet).
local DEFAULT_LIST_MARGIN_EM = 1

local EM_PER_UNIT = {
    em = 1, rem = 1, ex = 0.5, ch = 0.5,
    px = 1 / 16, pt = 4 / 3 / 16, pc = 12 / 16,
    ["in"] = 96 / 16, cm = 96 / 2.54 / 16, mm = 96 / 25.4 / 16,
}

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_length(raw)
    if raw == nil then return nil end
    local value = trim(raw):lower():gsub("%s+", "")
    if value == "" then return nil end
    if value:find("cr%-special") then return { special = true } end
    local number, unit = value:match("^([%-%d%.]+)([%%%a]*)$")
    if not number then return nil end
    local n = tonumber(number)
    if not n then return nil end
    unit = unit or ""
    if unit == "" then
        if n ~= 0 then return nil end
        return { value = 0, unit = "em" }
    end
    return { value = n, unit = unit }
end

local function length_to_em(length)
    if not length or length.special then return nil end
    local factor = EM_PER_UNIT[length.unit]
    if not factor then return nil end
    return length.value * factor
end

-- ---------------------------------------------------------------------------
-- CSS parsing (the small subset the layout depends on)
-- ---------------------------------------------------------------------------

local function strip_comments(css)
    return (tostring(css or ""):gsub("/%*.-%*/", " "))
end

-- Collects "selector { body }" pairs.  @media/@supports wrappers are unwrapped
-- (their rules always apply here -- the alternative, dropping them, loses the
-- publisher's list styling on e-ink sized screens); other at-rules such as
-- @font-face/@page/@keyframes are skipped as a whole.
local function parse_blocks(text, out)
    local position = 1
    while true do
        local open = text:find("{", position, true)
        if not open then break end
        local prelude = text:sub(position, open - 1)
        local depth, closing, index = 1, nil, open + 1
        while index <= #text do
            local char = text:sub(index, index)
            if char == "{" then
                depth = depth + 1
            elseif char == "}" then
                depth = depth - 1
                if depth == 0 then closing = index; break end
            end
            index = index + 1
        end
        if not closing then break end
        local body = text:sub(open + 1, closing - 1)
        local at_rule = prelude:match("^%s*(@[%w%-]+)")
        if not at_rule then
            out[#out + 1] = { selector = prelude, body = body }
        elseif at_rule == "@media" or at_rule == "@supports" or at_rule == "@document" then
            parse_blocks(body, out)
        end
        position = closing + 1
    end
end

-- "padding: 1em 2em 0 3em" -> left component (the 4th, falling back per the
-- box shorthand rules).
local function box_left(values)
    local count = #values
    if count == 0 then return nil end
    if count == 1 then return values[1] end
    if count == 2 or count == 3 then return values[2] end
    return values[4]
end

local function parse_declarations(body)
    local declarations = {}
    for chunk in body:gmatch("[^;]+") do
        local prop, value = chunk:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
        if prop then
            prop = prop:lower()
            local important = false
            if value:find("!%s*important") then
                important = true
                value = value:gsub("!%s*important", "")
            end
            value = trim(value):gsub("%s+", " ")
            if prop == "padding" or prop == "margin" then
                local values = {}
                for part in value:gmatch("%S+") do values[#values + 1] = part end
                local left = box_left(values)
                if left then
                    declarations[#declarations + 1] = {
                        prop = prop .. "-left", value = left, important = important,
                    }
                end
            elseif prop == "padding-inline-start" then
                declarations[#declarations + 1] = {
                    prop = "padding-left", value = value, important = important,
                }
            elseif prop == "margin-inline-start" then
                declarations[#declarations + 1] = {
                    prop = "margin-left", value = value, important = important,
                }
            else
                declarations[#declarations + 1] = {
                    prop = prop, value = value, important = important,
                }
            end
        end
    end
    return declarations
end

local function parse_stylesheet(css, rules, order)
    local blocks = {}
    parse_blocks(strip_comments(css), blocks)
    for _, block in ipairs(blocks) do
        local selectors = {}
        for selector in block.selector:gmatch("[^,]+") do
            selectors[#selectors + 1] = trim(selector)
        end
        if #selectors > 0 then
            order = order + 1
            rules[#rules + 1] = {
                selectors = selectors,
                declarations = parse_declarations(block.body),
                order = order,
            }
        end
    end
    return order
end

-- ---------------------------------------------------------------------------
-- Selector matching
-- ---------------------------------------------------------------------------

-- "div > .chapter ol" -> { {compound="div", child=true}, {compound=".chapter",
-- child=false}, {compound="ol", child=false} }, where child means the next
-- compound must be a direct child of this one.  Sibling combinators (+ ~) are
-- not modelled: a selector using them is dropped.
local function split_selector(selector)
    selector = trim(selector)
    if selector == "" or selector:find("[+~]") then return nil end
    selector = selector:gsub("%s*>%s*", ">")
    local parts, buffer, index = {}, "", 1
    while index <= #selector do
        local char = selector:sub(index, index)
        if char == ">" then
            if buffer ~= "" then
                parts[#parts + 1] = { compound = buffer, child = true }
                buffer = ""
            elseif #parts > 0 then
                parts[#parts].child = true
            end
        elseif char:match("%s") then
            if buffer ~= "" then
                parts[#parts + 1] = { compound = buffer, child = false }
                buffer = ""
            end
        else
            buffer = buffer .. char
        end
        index = index + 1
    end
    if buffer ~= "" then parts[#parts + 1] = { compound = buffer, child = false } end
    if #parts == 0 then return nil end
    return parts
end

local function compound_matches(compound, element)
    if compound == "" or compound == "*" then return true end
    -- Attribute selectors are stripped: the list anchors cannot address them
    -- reliably, and keeping the tag/class part is better than dropping a rule.
    compound = compound:gsub("%[.-%]", "")
    if compound == "" then return true end
    local tag = compound:match("^([%w%-]+)")
    local rest = compound
    if tag then rest = compound:sub(#tag + 1) end
    if tag and tag ~= "*" and tag ~= element.tag then return false end
    for id in rest:gmatch("#([%w%-_]+)") do
        if element.id ~= id then return false end
    end
    for class in rest:gmatch("%.([%w%-_]+)") do
        if not (element.classes and element.classes[class]) then return false end
    end
    -- Pseudo classes/elements (":dir(rtl)", ":first-child", "::before") are
    -- state the extractor cannot evaluate; leaving them unmatched is the
    -- conservative choice.
    if rest:find(":", 1, true) then return false end
    return true
end

local function compound_specificity(compound)
    local ids = select(2, compound:gsub("#", ""))
    local classes = select(2, compound:gsub("%.", ""))
        + select(2, compound:gsub("%[", ""))
        + select(2, compound:gsub(":", ""))
    local tags = compound:match("^[%w%-]+") and 1 or 0
    return ids, classes, tags
end

-- Returns a specificity table when the selector matches, nil otherwise.
local function selector_matches(parts, element)
    local last = parts[#parts]
    if not compound_matches(last.compound, element) then return nil end
    local ids, classes, tags = compound_specificity(last.compound)
    local ancestors = element.ancestors or {}
    local cursor = #ancestors
    for index = #parts - 1, 1, -1 do
        local part = parts[index]
        -- "child" on a part means the next compound must be its direct child.
        local child = part.child
        local match = nil
        if child then
            if cursor >= 1 and compound_matches(part.compound, ancestors[cursor]) then
                match = cursor
            end
        else
            while cursor >= 1 do
                if compound_matches(part.compound, ancestors[cursor]) then
                    match = cursor
                    break
                end
                cursor = cursor - 1
            end
        end
        if not match then return nil end
        local part_ids, part_classes, part_tags = compound_specificity(part.compound)
        ids, classes, tags = ids + part_ids, classes + part_classes, tags + part_tags
        cursor = match - 1
    end
    return { ids = ids, classes = classes, tags = tags }
end

local function cascade(sheet, element, inline_declarations)
    local chosen = {}
    local function consider(declaration, specificity, order)
        local current = chosen[declaration.prop]
        local better = current == nil
        if current then
            if declaration.important ~= current.important then
                better = declaration.important
            elseif specificity.ids ~= current.ids then
                better = specificity.ids > current.ids
            elseif specificity.classes ~= current.classes then
                better = specificity.classes > current.classes
            elseif specificity.tags ~= current.tags then
                better = specificity.tags > current.tags
            else
                better = order >= current.order
            end
        end
        if better then
            chosen[declaration.prop] = {
                value = declaration.value,
                important = declaration.important,
                ids = specificity.ids,
                classes = specificity.classes,
                tags = specificity.tags,
                order = order,
            }
        end
    end
    for _, rule in ipairs(sheet and sheet.rules or {}) do
        for _, selector in ipairs(rule.selectors) do
            local parts = split_selector(selector)
            local specificity = parts and selector_matches(parts, element)
            if specificity then
                for _, declaration in ipairs(rule.declarations) do
                    consider(declaration, specificity, rule.order)
                end
            end
        end
    end
    -- An inline style attribute outranks the stylesheet unless the sheet used
    -- !important; the approximation below only loses that rare case.
    for _, declaration in ipairs(inline_declarations or {}) do
        consider(declaration, { ids = 100, classes = 100, tags = 100 }, math.huge)
    end
    local values = {}
    for prop, entry in pairs(chosen) do values[prop] = entry.value end
    return values
end

-- ---------------------------------------------------------------------------
-- List marker width (the "-cr-special" padding CREngine computes at layout)
-- ---------------------------------------------------------------------------

local LIST_STYLE_TYPES = {
    decimal = true, ["decimal-leading-zero"] = true,
    ["lower-alpha"] = true, ["upper-alpha"] = true,
    ["lower-latin"] = true, ["upper-latin"] = true,
    ["lower-roman"] = true, ["upper-roman"] = true,
    disc = true, circle = true, square = true, none = true,
}

local BULLET_GLYPHS = { disc = "\226\128\162", circle = "\226\151\166", square = "\226\150\170" }

local function alpha_marker(number, upper)
    if number < 1 then number = 1 end
    local letter = string.char((number - 1) % 26 + (upper and 65 or 97))
    local repeat_count = math.floor((number - 1) / 26)
    if repeat_count > 0 then letter = letter:rep(repeat_count + 1) end
    return letter .. "."
end

local ROMAN = {
    { 1000, "m" }, { 900, "cm" }, { 500, "d" }, { 400, "cd" },
    { 100, "c" }, { 90, "xc" }, { 50, "l" }, { 40, "xl" },
    { 10, "x" }, { 9, "ix" }, { 5, "v" }, { 4, "iv" }, { 1, "i" },
}

local function roman_marker(number, upper)
    if number < 1 then number = 1 end
    local out = {}
    local rest = number
    for _, pair in ipairs(ROMAN) do
        while rest >= pair[1] do
            out[#out + 1] = pair[2]
            rest = rest - pair[1]
        end
    end
    local text = table.concat(out) .. "."
    if upper then text = text:upper() end
    return text
end

local function marker_text(kind, number)
    if kind == "disc" or kind == "circle" or kind == "square" then
        return BULLET_GLYPHS[kind] or BULLET_GLYPHS.disc
    elseif kind == "lower-alpha" or kind == "lower-latin" then
        return alpha_marker(number, false)
    elseif kind == "upper-alpha" or kind == "upper-latin" then
        return alpha_marker(number, true)
    elseif kind == "lower-roman" then
        return roman_marker(number, false)
    elseif kind == "upper-roman" then
        return roman_marker(number, true)
    elseif kind == "decimal-leading-zero" then
        return string.format("%02d.", number)
    end
    return tostring(number) .. "."
end

local function glyph_em(char)
    if char:match("%d") then return 0.55 end
    if char == "." or char == "," then return 0.28 end
    if char:match("%a") then return 0.5 end
    return 0.5
end

-- A bullet is a plain symbol, not a full-width CJK ideograph: measured on a
-- device a bullet list indented 0.95em past its container (0.55 glyph + 0.4
-- suffix space), which is what "ul { }" with no publisher override gets.
local BULLET_WIDTH_EM = 0.55

local function text_em(text)
    local width, index = 0, 1
    while index <= #text do
        local byte = text:byte(index)
        if byte < 0x80 then
            width = width + glyph_em(string.char(byte))
            index = index + 1
        else
            local length = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or 2
            local char = text:sub(index, index + length - 1)
            if char == BULLET_GLYPHS.disc or char == BULLET_GLYPHS.circle
                or char == BULLET_GLYPHS.square then
                width = width + BULLET_WIDTH_EM
            elseif byte >= 0xE3 and byte <= 0xE9 then
                -- CJK / kana numbering ("一、") is one full em per character.
                width = width + 1
            else
                width = width + 0.6
            end
            index = index + length
        end
    end
    return width
end

local function list_style_kind(values, tag)
    local shorthand = values["list-style"]
    if shorthand then
        for word in tostring(shorthand):gmatch("%S+") do
            local lower = word:lower()
            if LIST_STYLE_TYPES[lower] then return lower end
        end
    end
    local explicit = values["list-style-type"]
    if explicit then
        local lower = trim(explicit):lower()
        if LIST_STYLE_TYPES[lower] then return lower end
        if lower == "none" then return "none" end
    end
    return tag == "ol" and "decimal" or "disc"
end

-- sheet/list_values: the list container's cascade result.  The items' own
-- rules win where they set one (an item-level "list-style-type: none" removes
-- the marker, so CREngine adds no padding at all).
local function marker_padding_em(sheet, values, list)
    local item_values = {}
    if list.first_li then item_values = cascade(sheet, list.first_li, {}) end
    local function pick(prop)
        return item_values[prop] or values[prop]
    end
    local position = trim(pick("list-style-position") or ""):lower()
    if position == "inside" then return 0 end
    local kind = list_style_kind({
        ["list-style"] = pick("list-style"),
        ["list-style-type"] = pick("list-style-type"),
    }, list.element.tag)
    if kind == "none" then return 0 end
    local start = tonumber(list.start) or 1
    if start < 1 then start = 1 end
    local count = tonumber(list.item_count) or 1
    -- Decimal/alpha/roman markers only grow with the item number, so the last
    -- item is the widest.
    local last = start + math.max(count, 1) - 1
    return text_em(marker_text(kind, last)) + MARKER_SPACE_EM
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Accepts nil, an already compiled sheet, a single stylesheet string or a
-- list of them, so callers can pass whatever their extract path produced.
function ListIndent.resolve(styles)
    if type(styles) == "table" and styles.rules then return styles end
    if styles == nil then return { rules = {} } end
    return ListIndent.compile(styles)
end

function ListIndent.compile(css_texts)
    local rules, order = {}, 0
    if type(css_texts) == "string" then css_texts = { css_texts } end
    for _, css in ipairs(css_texts or {}) do
        order = parse_stylesheet(css, rules, order)
    end
    return { rules = rules }
end

function ListIndent.extend(sheet, css)
    local rules = {}
    for index, rule in ipairs(sheet and sheet.rules or {}) do rules[index] = rule end
    local order = 0
    for _, rule in ipairs(rules) do
        if rule.order > order then order = rule.order end
    end
    parse_stylesheet(css, rules, order)
    return { rules = rules }
end

local function format_em(value)
    local text = string.format("%.2f", value)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    if text == "" then text = "0" end
    return text .. "em"
end

-- list = {
--   element = { tag = "ul", id = "...", classes = { ... }, ancestors = { ... } },
--   item_count = <direct <li> children>,
--   start = <ol start attribute or 1>,
--   style_attr = <raw style="..." or nil>,
-- }
-- Returns e.g. "1.95em": the distance from the parent item's content edge to
-- the child list's content edge, or nil when nothing should be cancelled.
function ListIndent.indent(sheet, list)
    if type(list) ~= "table" or type(list.element) ~= "table" then return nil end
    local inline = {}
    if list.style_attr and list.style_attr ~= "" then
        inline = parse_declarations(list.style_attr)
    end
    local values = cascade(sheet, list.element, inline)
    local margin
    if values["margin-left"] then
        local length = parse_length(values["margin-left"])
        margin = length_to_em(length) or 0
    else
        margin = DEFAULT_LIST_MARGIN_EM
    end
    local padding
    if values["padding-left"] then
        local length = parse_length(values["padding-left"])
        if length and length.special then
            padding = marker_padding_em(sheet, values, list)
        else
            padding = length_to_em(length)
            if padding == nil then padding = marker_padding_em(sheet, values, list) end
        end
    else
        -- No publisher value: CREngine's user-agent "-cr-special" padding.
        padding = marker_padding_em(sheet, values, list)
    end
    local total = margin + padding
    if not total or total <= 0.05 then return nil end
    return format_em(total)
end

ListIndent._parse_length = parse_length
ListIndent._marker_text = marker_text
ListIndent._marker_padding_em = marker_padding_em
ListIndent._selector_matches = selector_matches
ListIndent._split_selector = split_selector

return ListIndent
