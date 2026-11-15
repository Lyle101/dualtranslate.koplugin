-- ChapterPickerDialog (design 7.1 / 12.3): multi-select over the EPUB spine.
-- Selection is per book, lives only in this dialog's state and is handed to
-- the queue as `mode = "selection"` (7.3); nothing is persisted as a setting.
--
-- Layout note: the chapter list uses the native Menu pagination instead of a
-- hard 30-per-page slice.  Menu's per-page count also drives its item font
-- size (Menu.getItemFontSize); pinning 30 rows would shrink small-screen text
-- to an unreadable size, so the dialog keeps the reader's own page size.
local _ = require("gettext")
local TranslationUI = require("dualtranslate_ui")

local Picker = {}

Picker.TITLE_MAX_CHARS = 40

-- Byte length of the UTF-8 character that starts with `byte` (7.1: titles are
-- truncated by characters, never by bytes, or a Chinese title gets chopped).
local function utf8_char_len(byte)
    if byte < 0xC0 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    return 4
end

function Picker.truncate_title(title, max_chars)
    if type(title) ~= "string" or title == "" then return "" end
    max_chars = max_chars or Picker.TITLE_MAX_CHARS
    local index, count, last = 1, 0, nil
    while index <= #title do
        local width = utf8_char_len(title:byte(index))
        local char_end = index + width - 1
        -- A malformed trailing sequence is left out rather than cut in half.
        if char_end > #title then break end
        count = count + 1
        if count > max_chars then
            return title:sub(1, last) .. "…"
        end
        last = char_end
        index = char_end + 1
    end
    return title
end

-- 7.2: TOC entries map onto spine indexes, but a TOC rarely covers every
-- spine item (cover, title page, colophon).  The picker must still offer every
-- chapter, so gaps fall back to "第 N 节" instead of disappearing from the list.
function Picker.chapters(outline)
    if type(outline) ~= "table" then return {} end
    local by_index = {}
    local count = tonumber(outline.spine_count) or 0
    for _, chapter in ipairs(outline.chapters or {}) do
        local index = tonumber(chapter.index)
        if index and index >= 1 and index == math.floor(index) then
            if not by_index[index] then by_index[index] = chapter end
            if index > count then count = index end
        end
    end
    local chapters = {}
    for index = 1, count do
        local chapter = by_index[index]
        chapters[#chapters + 1] = {
            index = index,
            title = chapter and chapter.title or string.format(_("第 %d 节"), index),
            level = chapter and chapter.level or 0,
        }
    end
    return chapters
end

function Picker.new_state(outline)
    return { chapters = Picker.chapters(outline), selected = {} }
end

function Picker.count(state)
    local total = 0
    for _, chapter in ipairs(state.chapters or {}) do
        if state.selected[chapter.index] then total = total + 1 end
    end
    return total
end

function Picker.toggle(state, index)
    if not index then return end
    if state.selected[index] then
        state.selected[index] = nil
    else
        state.selected[index] = true
    end
end

function Picker.select_all(state)
    for _, chapter in ipairs(state.chapters or {}) do
        state.selected[chapter.index] = true
    end
end

function Picker.select_none(state)
    state.selected = {}
end

function Picker.invert(state)
    local inverted = {}
    for _, chapter in ipairs(state.chapters or {}) do
        if not state.selected[chapter.index] then inverted[chapter.index] = true end
    end
    state.selected = inverted
end

function Picker.select_indexes(state, indexes)
    for _, index in ipairs(indexes or {}) do
        state.selected[index] = true
    end
end

-- Ascending spine order, which is what the worker expects for a job.
function Picker.selected_indexes(state)
    local indexes = {}
    for _, chapter in ipairs(state.chapters or {}) do
        if state.selected[chapter.index] then indexes[#indexes + 1] = chapter.index end
    end
    return indexes
end

function Picker.page_count(state, page_size)
    page_size = math.max(1, tonumber(page_size) or 1)
    return math.max(1, math.ceil(#(state.chapters or {}) / page_size))
end

function Picker.page_chapters(state, page, page_size)
    page_size = math.max(1, tonumber(page_size) or 1)
    page = math.max(1, tonumber(page) or 1)
    local first = (page - 1) * page_size + 1
    local chapters = {}
    for index = first, math.min(first + page_size - 1, #(state.chapters or {})) do
        chapters[#chapters + 1] = state.chapters[index]
    end
    return chapters
end

-- "全选本页" with native pagination: the visible chapters are the rows that
-- fall inside the menu's current page, not a fixed 30-chapter slice.
function Picker.visible_chapter_indexes(item_table, page, perpage)
    local indexes = {}
    perpage = math.max(1, tonumber(perpage) or 1)
    local first = (math.max(1, tonumber(page) or 1) - 1) * perpage + 1
    for position = first, first + perpage - 1 do
        local item = item_table and item_table[position]
        if item and item.chapter_index then
            indexes[#indexes + 1] = item.chapter_index
        end
    end
    return indexes
end

-- 7.1: the row carries the spine index as well as the (truncated) title, or
-- identically named chapters cannot be told apart.  The full title stays on
-- the item for the long-press detail.  The checkbox is a geometric-shape
-- glyph rather than "[x]"/"[ ]": on a 758 px screen the ASCII pair collapses
-- into "[]", and an empty box stops reading as a box.
function Picker.chapter_label(state, chapter)
    local prefix = state.selected[chapter.index] and "▣ " or "▢ "
    return string.format("%s%d. %s", prefix, chapter.index,
        Picker.truncate_title(chapter.title))
end

function Picker.build_item_table(state, handlers, opts)
    handlers = handlers or {}
    opts = opts or {}
    local selected = Picker.count(state)
    local items = {
        {
            text = string.format(_("开始翻译（%d 章）"), selected),
            bold = true,
            select_enabled = selected > 0,
            callback = handlers.on_start,
        },
        { text = _("全选本书"), callback = handlers.on_select_all },
        { text = _("全选本页"), callback = handlers.on_select_page },
        {
            text = _("全不选"),
            select_enabled = selected > 0,
            callback = handlers.on_select_none,
        },
        { text = _("反选"), callback = handlers.on_invert },
        {
            text = string.format(_("共 %d 章 · 已选 %d 章"), #state.chapters, selected),
            select_enabled = false,
        },
    }
    for _, chapter in ipairs(state.chapters) do
        items[#items + 1] = {
            text = Picker.chapter_label(state, chapter),
            chapter_index = chapter.index,
            full_title = chapter.title,
            callback = function()
                if handlers.on_toggle then handlers.on_toggle(chapter.index) end
            end,
        }
    end
    -- The action block only exists on the list's first page, so a paginated
    -- list gets a trailing confirm row: pick chapters at the end of a long
    -- book, tap once, done.  A single-page book skips it, otherwise two
    -- identical buttons sit on screen at the same time.
    if opts.trailing then
        items[#items + 1] = {
            text = string.format(_("开始翻译（%d 章）"), selected),
            bold = true,
            select_enabled = selected > 0,
            callback = handlers.on_start,
        }
    end
    return items
end

local function book_display_name(book_path)
    local name = book_path:match("([^/]+)$") or book_path
    return (name:gsub("%.[Ee][Pp][Uu][Bb]$", ""))
end

function Picker.show(plugin)
    local book_path = plugin.currentBookPath and plugin:currentBookPath()
        or (plugin.ui and plugin.ui.document and plugin.ui.document.file)
    if not book_path then return end
    local outline, err = plugin:getBookOutline(book_path)
    if not outline then
        TranslationUI.showInfo(_("目录解析失败：") .. tostring(err or ""))
        return
    end
    local state = Picker.new_state(outline)
    if #state.chapters == 0 then
        TranslationUI.showInfo(_("本书没有可选择的章节"))
        return
    end

    local Menu = require("ui/widget/menu")
    local UIManager = require("ui/uimanager")
    local menu, handlers

    local function build_items()
        return Picker.build_item_table(state, handlers,
            { trailing = state.trailing_confirm == true })
    end

    local function rebuild()
        local items = build_items()
        local target = menu.item_table
        for index = #target, 1, -1 do target[index] = nil end
        for index, item in ipairs(items) do target[index] = item end
        menu:updateItems()
    end

    handlers = {
        on_toggle = function(index)
            Picker.toggle(state, index)
            rebuild()
        end,
        on_select_all = function()
            Picker.select_all(state)
            rebuild()
        end,
        on_select_page = function()
            Picker.select_indexes(state,
                Picker.visible_chapter_indexes(menu.item_table, menu.page, menu.perpage))
            rebuild()
        end,
        on_select_none = function()
            Picker.select_none(state)
            rebuild()
        end,
        on_invert = function()
            Picker.invert(state)
            rebuild()
        end,
        on_start = function()
            local indexes = Picker.selected_indexes(state)
            if #indexes == 0 then return end
            UIManager:close(menu)
            plugin:translateSelectedChapters(indexes)
        end,
    }

    menu = Menu:new{
        title = _("选择章节"),
        subtitle = book_display_name(book_path),
        item_table = Picker.build_item_table(state, handlers),
        is_borderless = true,
        is_popout = false,
    }

    -- Every tap is a toggle or an action; the menu must stay open, so bypass
    -- Menu:onMenuSelect's close_callback/onMenuChoice path.  Closing stays
    -- available through the title bar button.
    function menu:onMenuSelect(item)
        if type(item) ~= "table" or item.select_enabled == false then return true end
        if item.callback then item.callback() end
        return true
    end

    -- Separator-like rows and long titles: hold shows the untruncated title
    -- plus the spine index, which is also the job's chapter id (6.5).
    function menu:onMenuHold(item)
        if type(item) == "table" and item.chapter_index then
            TranslationUI.showInfo(string.format(_("第 %d 章：%s"),
                item.chapter_index, item.full_title or ""), 5)
        end
        return true
    end

    UIManager:show(menu)
    -- Only a list that spans several pages needs the trailing confirm row, and
    -- the page size is known only after Menu laid out.  Do this once the menu
    -- is on screen: rebuilding before UIManager:show would issue setDirty for
    -- a widget that is not displayed yet.  The row lives on the last page, so
    -- the first frame is unaffected.
    if menu.perpage and #menu.item_table > menu.perpage then
        state.trailing_confirm = true
        rebuild()
    end
    return menu
end

function Picker.attach(plugin)
    plugin.showChapterPicker = function(self)
        return Picker.show(self)
    end
end

return Picker
