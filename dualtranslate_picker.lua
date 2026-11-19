-- ChapterPickerDialog (design 7.1 / 12.3): multi-select over the EPUB outline.
-- Rows are TOC entries when several chapters live in one XHTML (each entry
-- keeps its anchor), otherwise spine files.  Selection is per book, lives
-- only in this dialog's state and is handed to the queue as `mode =
-- "selection"` (7.3); nothing is persisted as a setting.  A selection becomes
-- chapter ranges: rows sharing a file own the slice between their anchors, and
-- selecting a whole file sends it without anchors.
--
-- Layout note: the chapter list uses the native Menu pagination instead of a
-- hard 30-per-page slice.  Menu's per-page count also drives its item font
-- size (Menu.getItemFontSize); pinning 30 rows would shrink small-screen text
-- to an unreadable size, so the dialog keeps the reader's own page size.
local _ = require("gettext")
local Tools = require("dualtranslate_tools")
local TranslationUI = require("dualtranslate_ui")

local Picker = {}

Picker.TITLE_MAX_CHARS = 40

-- Byte length of the UTF-8 character that starts with `byte` (7.1: titles are
-- truncated by characters, never by bytes, or a Chinese title gets chopped).
-- One implementation lives in Tools, shared with the MCP prev/next slices.
local utf8_char_len = Tools.utf8_char_len

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
-- spine item (cover, title page, colophon).  Without a TOC the picker falls
-- back to one row per spine file so nothing disappears from the list.
--
-- Two granularities.  When the TOC puts several chapters in one XHTML (the
-- scanned / PDF-converted shape: 790 entries over 331 files) each entry gets
-- its own row, numbered `file.sub`, instead of 331 merged rows.  A TOC with
-- one entry per file is already the file list, and a coarse TOC must not hide
-- the chapters between its few entries, so those books keep one row per spine
-- file with gaps filled by "第 N 节".
--
-- In entry mode files no TOC entry points at get no row.  In a book of this
-- shape they are assumed to be the continuation of a chapter anchored earlier
-- (the reader's TOC hides them too); an unlisted standalone file (cover,
-- colophon) is therefore also unreachable from this dialog, while whole-book
-- translation still covers it.
--
-- `key` is the row's position and the only thing `state.selected` is keyed
-- by; `index` is the spine file the selection resolves to.  `toc_entries` is
-- how many TOC labels landed on that file (1 = just the title, >1 = the file
-- holds several chapters).
function Picker.chapters(outline)
    if type(outline) ~= "table" then return {} end
    local entries = type(outline.entries) == "table" and outline.entries or {}
    local chapters = {}
    -- Group by file so the rows that share one translation unit sit
    -- together, and walk the files in spine order.
    local by_index, order, entry_count, has_anchor = {}, {}, 0, false
    for _, entry in ipairs(entries) do
        local index = tonumber(entry.index)
        if index and index >= 1 and index == math.floor(index) then
            entry_count = entry_count + 1
            if entry.anchor then has_anchor = true end
            local bucket = by_index[index]
            if not bucket then
                bucket = { entries = {} }
                by_index[index] = bucket
                order[#order + 1] = index
            end
            bucket.entries[#bucket.entries + 1] = entry
        end
    end
    -- Only a TOC that puts several chapters in one file needs the entry view,
    -- and only if it can say where inside the file each one starts.  A
    -- one-entry-per-file TOC is already the file list, a coarse TOC (a few
    -- parts over a hundred files) must not hide the chapters between them,
    -- and repeated entries without anchors would just drop every other file.
    if #order < entry_count and has_anchor then
        table.sort(order)
        -- `ordinal` is the number the user sees, starting at 1 for the first
        -- file the TOC covers; the spine index stays the job's identity but
        -- would leave gaps (a cover file, files no entry points at) and make
        -- the list look like it starts in the middle of the book.
        local ordinal = 0
        for _, index in ipairs(order) do
            ordinal = ordinal + 1
            local bucket = by_index[index]
            local total = #bucket.entries
            for sub, entry in ipairs(bucket.entries) do
                chapters[#chapters + 1] = {
                    key = #chapters + 1,
                    ordinal = ordinal,
                    index = index,
                    -- A single-entry file keeps the plain "12" numbering.
                    sub = total > 1 and sub or nil,
                    toc_entries = total,
                    anchor = entry.anchor,
                    title = entry.title,
                    level = tonumber(entry.level) or 0,
                }
            end
        end
        return chapters
    end
    local by_chapter = {}
    local count = tonumber(outline.spine_count) or 0
    for _, chapter in ipairs(outline.chapters or {}) do
        local index = tonumber(chapter.index)
        if index and index >= 1 and index == math.floor(index) then
            if not by_chapter[index] then by_chapter[index] = chapter end
            if index > count then count = index end
        end
    end
    for index = 1, count do
        local chapter = by_chapter[index]
        local aliases = chapter and chapter.aliases
        chapters[#chapters + 1] = {
            key = #chapters + 1,
            -- One row per file, so the display number is the spine index.
            ordinal = index,
            index = index,
            title = chapter and chapter.title or string.format(_("第 %d 节"), index),
            level = chapter and chapter.level or 0,
            toc_entries = chapter and (1 + (type(aliases) == "table" and #aliases or 0)) or 0,
        }
    end
    return chapters
end

function Picker.new_state(outline, coverage)
    local chapters = Picker.chapters(outline)
    -- Count TOC labels per file, not per row: in entry mode every row of a
    -- file repeats its `toc_entries`, and summing rows would report 790
    -- chapters as 1976.
    local toc_total, files = 0, {}
    local file_count = 0
    for _, chapter in ipairs(chapters) do
        if not files[chapter.index] then
            files[chapter.index] = true
            file_count = file_count + 1
            toc_total = toc_total + (chapter.toc_entries or 0)
        end
    end
    local state = { chapters = chapters, selected = {}, toc_total = toc_total,
        file_count = file_count,
        -- One row per TOC entry rather than per file; the label and status
        -- wording switch on this instead of re-deriving it from the numbers.
        entry_mode = file_count > 0 and file_count < #chapters }
    -- Coverage comes from the engine selected in the menu (12.2), not from
    -- whatever happens to be displayed on the page.
    if coverage then
        state.full = coverage.full
        state.partial = coverage.partial
        state.engine_label = coverage.label
    end
    return state
end

-- How many spine files carry a finished translation.  In entry mode one file
-- contributes several rows, so counting rows would report a single translated
-- file as a dozen translated chapters.
function Picker.translated_files(state)
    local seen, total = {}, 0
    for _, chapter in ipairs(state.chapters or {}) do
        if state.full and state.full[chapter.index] and not seen[chapter.index] then
            seen[chapter.index] = true
            total = total + 1
        end
    end
    return total
end

-- Which chapters already carry a translation from the engine the menu has
-- selected.  A chapter counts as 已翻译 only when that engine's entries cover
-- it whole; partial_chapters render as 部分.  MCP jobs register one provider
-- per model (mcp:<model>) while the menu offers a single "mcp_external"
-- engine, so every model of that engine counts there.
function Picker.coverage(plugin, book_path, engine)
    if not book_path or type(plugin.getBookCacheDirectory) ~= "function" then
        return nil
    end
    local mode = engine
    if not mode then
        if type(plugin.getMode) ~= "function" then return nil end
        mode = plugin:getMode()
    end
    local Overlay = require("dualtranslate_overlay")
    -- loadBookIndex also answers for a book still on the v2 overlay (migration
    -- blocked by a lock, for one), so its finished chapters are not silently
    -- shown as untranslated.
    if not mode or type(Overlay.loadBookIndex) ~= "function" then return nil end
    local index = Overlay.loadBookIndex(plugin:getBookCacheDirectory(book_path))
    if type(index) ~= "table" or type(index.providers) ~= "table" then
        return nil
    end
    local full, partial, matched, first_name = {}, {}, 0, nil
    for provider_id, provider in pairs(index.providers) do
        local matches = provider_id == mode
        if mode == "mcp_external" then
            matches = tostring(provider_id):sub(1, 4) == "mcp:"
        end
        if matches and type(provider) == "table" then
            matched = matched + 1
            -- Device engines store the provider id in display_name (Store
            -- resolves the human name from the DB on demand), so an id is not
            -- a label; the engine registry below supplies the real one.
            local name = provider.display_name
            if type(name) == "string" and name ~= "" and name ~= provider_id then
                first_name = first_name or name
            end
            if type(provider.chapters) == "table" then
                for _, value in ipairs(provider.chapters) do
                    local number = tonumber(value)
                    if number then full[number] = true end
                end
            end
            if type(provider.partial_chapters) == "table" then
                for _, value in ipairs(provider.partial_chapters) do
                    local number = tonumber(value)
                    if number then partial[number] = true end
                end
            end
        end
    end
    if matched == 0 then return nil end
    -- A chapter that any model finished is 已翻译 even if another model left
    -- it partial: full always wins.
    for chapter_index in pairs(full) do partial[chapter_index] = nil end
    local label
    if mode == "mcp_external" then
        label = matched == 1 and first_name or _("MCP 外部翻译")
    else
        local Providers = require("dualtranslate_providers")
        -- getProviderName answers "未知翻译服务" for ids it does not know;
        -- that is not a label, so the registry entry is checked first.
        if type(Providers.getProviderById) == "function"
            and Providers.getProviderById(mode)
            and type(Providers.getProviderName) == "function" then
            label = Providers.getProviderName(mode)
        end
        if type(label) ~= "string" or label == "" or label == mode then
            label = first_name or mode
        end
    end
    return { full = full, partial = partial, label = label }
end

function Picker.count(state)
    local total = 0
    for _, chapter in ipairs(state.chapters or {}) do
        if state.selected[chapter.key] then total = total + 1 end
    end
    return total
end

function Picker.toggle(state, key)
    if not key then return end
    if state.selected[key] then
        state.selected[key] = nil
    else
        state.selected[key] = true
    end
end

function Picker.select_all(state)
    for _, chapter in ipairs(state.chapters or {}) do
        state.selected[chapter.key] = true
    end
end

function Picker.select_none(state)
    state.selected = {}
end

function Picker.invert(state)
    local inverted = {}
    for _, chapter in ipairs(state.chapters or {}) do
        if not state.selected[chapter.key] then inverted[chapter.key] = true end
    end
    state.selected = inverted
end

-- Row keys are list positions; keys that do not exist (a page size that
-- changed between frames) are dropped rather than stored as phantom rows.
function Picker.select_rows(state, keys)
    local valid = {}
    for _, chapter in ipairs(state.chapters or {}) do valid[chapter.key] = true end
    for _, key in ipairs(keys or {}) do
        if valid[key] then state.selected[key] = true end
    end
end

-- The job's unit: one range per contiguous run of selected TOC entries in a
-- file.  Selecting every entry of a file yields a whole-file range (no
-- anchors), which is what keeps the manifest's 已翻译 flag honest; a run that
-- reaches a file edge leaves that side open (nil).  Boundary anchors that the
-- file does not carry are widened: too much text is recoverable, too little
-- is a silent hole.
function Picker.selected_ranges(state)
    local ranges = {}
    local by_file, order = {}, {}
    for _, chapter in ipairs(state.chapters or {}) do
        local bucket = by_file[chapter.index]
        if not bucket then
            bucket = {}
            by_file[chapter.index] = bucket
            order[#order + 1] = chapter.index
        end
        bucket[#bucket + 1] = chapter
    end
    -- The entry that ends a run is the next one whose anchor is not already
    -- used inside the run: an anchor equal to one of them would describe an
    -- empty slice (adjacent TOC entries sometimes share one), and slicing
    -- stops *before* the end anchor, so reusing it would drop a chapter.
    local function anchor_from(rows, position, stops)
        for probe = position, #rows do
            local row = rows[probe]
            if row and row.anchor and not stops[row.anchor] then return row.anchor end
        end
        return nil
    end
    local function anchor_before(rows, position)
        for probe = position - 1, 1, -1 do
            local row = rows[probe]
            if row and row.anchor then return row.anchor end
        end
        return nil
    end
    for _, index in ipairs(order) do
        local rows = by_file[index]
        local picked = 0
        for _, row in ipairs(rows) do
            if state.selected[row.key] then picked = picked + 1 end
        end
        if picked == #rows then
            ranges[#ranges + 1] = { index = index }
        elseif picked > 0 then
            local run_start
            for position = 1, #rows + 1 do
                local row = rows[position]
                local selected = row and state.selected[row.key]
                if selected and not run_start then
                    run_start = position
                elseif run_start and not selected then
                    local first = rows[run_start]
                    -- The first entry of a file may still carry an anchor; it
                    -- is not used as the start (content before it belongs to
                    -- the file's opening, and skipping it would lose text).
                    -- A run starting mid-file does start at its own anchor:
                    -- anything before it is the previous chapter, and
                    -- reaching back would translate that chapter too.
                    local own = first.anchor
                    local from = run_start > 1
                        and (own or anchor_before(rows, run_start)) or nil
                    -- Every anchor the run already covers is a stop: the next
                    -- unselected entry may share one of them, and ending the
                    -- slice there would cut the run short.
                    local stops = {}
                    for probe = run_start, position - 1 do
                        local row = rows[probe]
                        if row and row.anchor then stops[row.anchor] = true end
                    end
                    if from then stops[from] = true end
                    ranges[#ranges + 1] = {
                        index = index,
                        from = from,
                        to = anchor_from(rows, position, stops),
                    }
                    run_start = nil
                end
            end
        end
    end
    return ranges
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
function Picker.visible_row_keys(item_table, page, perpage)
    local keys = {}
    perpage = math.max(1, tonumber(perpage) or 1)
    local first = (math.max(1, tonumber(page) or 1) - 1) * perpage + 1
    for position = first, first + perpage - 1 do
        local item = item_table and item_table[position]
        if item and item.row_key then
            keys[#keys + 1] = item.row_key
        end
    end
    return keys
end

-- The number the user sees: "12" for a file row, "5.2" for the second chapter
-- of the fifth file the TOC covers (so the rows sharing one translation unit
-- stay grouped).  No trailing dot — on a 600 px row it only ate width the
-- title needs, and the space already separates the number from the title.
function Picker.row_number(chapter)
    local ordinal = chapter.ordinal or chapter.index
    if chapter.sub then return string.format("%d.%d", ordinal, chapter.sub) end
    return tostring(ordinal)
end

-- 7.1: the row carries that number as well as the (truncated) title, or
-- identically named chapters cannot be told apart.  The full title stays on
-- the item for the long-press detail.  The checkbox is a geometric-shape
-- glyph rather than "[x]"/"[ ]": on a 758 px screen the ASCII pair collapses
-- into "[]", and an empty box stops reading as a box.
function Picker.chapter_label(state, chapter)
    local prefix = state.selected[chapter.key] and "▣ " or "▢ "
    -- The mark sits right after the index: appending it to the title would
    -- put it exactly where the row truncates on a 600 px screen.
    local mark = ""
    if state.full and state.full[chapter.index] then
        mark = _("（已翻译）")
    elseif state.partial and state.partial[chapter.index] then
        mark = _("（部分）")
    end
    return string.format("%s%s%s %s", prefix, Picker.row_number(chapter), mark,
        Picker.truncate_title(chapter.title))
end

function Picker.build_item_table(state, handlers, opts)
    handlers = handlers or {}
    opts = opts or {}
    local selected = Picker.count(state)
    local translated = Picker.translated_files(state)
    local files = state.file_count or 0
    local entry_mode = state.entry_mode == true
    -- When several TOC labels share one spine item and the list shows them
    -- separately, say both numbers instead of looking like a wrong count.
    -- The translated count sits before the selected count: the tail of a long
    -- status line is what gets cut.
    local status_text, unit_word
    if entry_mode then
        status_text = string.format(_("共 %d 条 · %d 文件"), #state.chapters, files)
        -- A row is one chapter, so the selected count speaks in 章 even though
        -- the total speaks in TOC entries.
        unit_word = _("章")
    elseif (state.toc_total or 0) > #state.chapters then
        status_text = string.format(_("共 %d 段 · 目录 %d 条"),
            #state.chapters, state.toc_total)
        unit_word = _("章")
    else
        status_text = string.format(_("共 %d 章"), #state.chapters)
        unit_word = _("章")
    end
    if translated > 0 then
        status_text = status_text .. string.format(_(" · 已译 %d"), translated)
    end
    status_text = status_text .. string.format(_(" · 已选 %d %s"), selected, unit_word)
    -- P3: the same picker exports an MCP job, so the confirm row's wording
    -- comes from the caller; the default stays the translation one.  It now
    -- counts chapters (rows), because a row translates its own range.
    local start_label = opts.start_text or _("开始翻译（%d 章）")
    local items = {
        {
            text = string.format(start_label, selected),
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
            text = status_text,
            select_enabled = false,
        },
    }
    for _, chapter in ipairs(state.chapters) do
        items[#items + 1] = {
            text = Picker.chapter_label(state, chapter),
            row_key = chapter.key,
            chapter_index = chapter.index,
            number = Picker.row_number(chapter),
            sub_index = chapter.sub,
            full_title = chapter.title,
            toc_entries = chapter.toc_entries,
            anchor = chapter.anchor,
            callback = function()
                if handlers.on_toggle then handlers.on_toggle(chapter.key) end
            end,
        }
    end
    -- The action block only exists on the list's first page, so a paginated
    -- list gets a trailing confirm row: pick chapters at the end of a long
    -- book, tap once, done.  A single-page book skips it, otherwise two
    -- identical buttons sit on screen at the same time.
    if opts.trailing then
        items[#items + 1] = {
            text = string.format(start_label, selected),
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

-- opts.on_start(ranges) overrides the default translate action; opts.start_text
-- changes the confirm row (e.g. "导出任务（%d 章）").  MCP export reuses the
-- picker unchanged so chapter identity is chosen by exactly one implementation.
function Picker.show(plugin, opts)
    opts = opts or {}
    local book_path = plugin.currentBookPath and plugin:currentBookPath()
        or (plugin.ui and plugin.ui.document and plugin.ui.document.file)
    if not book_path then return end
    local outline, err = plugin:getBookOutline(book_path)
    if not outline then
        TranslationUI.showInfo(_("目录解析失败：") .. tostring(err or ""))
        return
    end
    local state = Picker.new_state(outline,
        Picker.coverage(plugin, book_path, opts.engine))
    if #state.chapters == 0 then
        TranslationUI.showInfo(_("本书没有可选择的章节"))
        return
    end

    local Menu = require("ui/widget/menu")
    local UIManager = require("ui/uimanager")
    local menu, handlers

    local function build_items()
        return Picker.build_item_table(state, handlers, {
            trailing = state.trailing_confirm == true,
            start_text = opts.start_text,
        })
    end

    local function rebuild()
        local items = build_items()
        local target = menu.item_table
        for index = #target, 1, -1 do target[index] = nil end
        for index, item in ipairs(items) do target[index] = item end
        menu:updateItems()
    end

    handlers = {
        on_toggle = function(key)
            Picker.toggle(state, key)
            rebuild()
        end,
        on_select_all = function()
            Picker.select_all(state)
            rebuild()
        end,
        on_select_page = function()
            Picker.select_rows(state,
                Picker.visible_row_keys(menu.item_table, menu.page, menu.perpage))
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
            local ranges = Picker.selected_ranges(state)
            if #ranges == 0 then return end
            UIManager:close(menu)
            if opts.on_start then
                opts.on_start(ranges)
            else
                plugin:translateSelectedChapters(ranges)
            end
        end,
    }

    menu = Menu:new{
        title = _("选择章节"),
        subtitle = book_display_name(book_path),
        item_table = Picker.build_item_table(state, handlers,
            { start_text = opts.start_text }),
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

    -- Long-press detail: the complete title, the file's entry count and the
    -- anchor.  A toast cuts anything wider than the screen with "…", and TOC
    -- labels are routinely longer than the 40 characters a row keeps, so the
    -- detail goes through InfoMessage, which wraps instead of truncating.
    function menu:onMenuHold(item)
        if type(item) == "table" and item.chapter_index then
            local text = string.format("%s %s", item.number
                or tostring(item.chapter_index), item.full_title or "")
            if (item.toc_entries or 0) > 1 then
                text = text .. string.format(
                    _("\n该文件共 %d 条目录"), item.toc_entries)
            end
            if item.anchor then
                text = text .. string.format(_("\n锚点：%s"), item.anchor)
            end
            -- Say which engine the （已翻译） mark came from: the menu's engine
            -- selector and this list must agree on what "已翻译" means.  The
            -- mark is per file, so a row sharing its file says 该文件.
            local engine = state.engine_label
            local subject = item.sub_index and _("该文件") or _("本章")
            if engine and state.full and state.full[item.chapter_index] then
                text = text .. string.format(_("\n%s已有「%s」的译文"), subject, engine)
            elseif engine and state.partial and state.partial[item.chapter_index] then
                text = text .. string.format(_("\n%s已有「%s」的部分译文"), subject, engine)
            end
            -- Keep the menu's title bar (and its close button) uncovered: the
            -- detail sits right below it, not on top of it.
            local bar_height = menu.title_bar
                and tonumber(menu.title_bar:getHeight()) or 0
            TranslationUI.showDetail(text, { below = bar_height })
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
    plugin.showChapterPicker = function(self, opts)
        return Picker.show(self, opts)
    end
end

return Picker
