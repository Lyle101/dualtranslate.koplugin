-- Reader-facing translation, EPUB mapping, and styling operations.
-- Menu, persistence, and provider implementations live in separate modules.
local Notification = require("ui/widget/notification")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local logger = require("logger")
local _ = require("gettext")
local Trapper = require("ui/trapper")
local DataStorage = require("datastorage")
local Cache = require("dualtranslate_cache")
local Providers = require("dualtranslate_providers")
local Overlay = require("dualtranslate_overlay")
local Coverage = require("dualtranslate_coverage")
local Store = require("dualtranslate_store")
local Tools = require("dualtranslate_tools")
local Glossary = require("dualtranslate_glossary")
local TranslationUI = require("dualtranslate_ui")

local Reader = {}

-- 7.3: the no-context compatibility path stores selector='' but warns once.
local missing_context_warned = false

local function context_meta(context)
    if not context then return nil end
    return {
        selector = context.selector,
        xpointer = context.xpointer,
        chapter_index = context.chapter_index,
    }
end

-- One line saying what editorial instructions travel with a job, so the user
-- sees it in the export result and in the task detail instead of having to
-- reopen the editor.  Defaults are not "custom": an empty style guide is
-- stored as the default text, and that must not read as user-authored.
local function glossary_instruction_text(terms, custom)
    local parts = {}
    if terms > 0 then
        parts[#parts + 1] = string.format(_("术语 %d 条"), terms)
    end
    if custom then parts[#parts + 1] = _("风格指南自定义") end
    if #parts == 0 then return nil end
    return table.concat(parts, " · ")
end

local function glossary_summary(options)
    if type(options) ~= "table" then return nil end
    local terms = type(options.glossary) == "table" and #options.glossary or 0
    local guide = options.style_guide
    local custom = type(guide) == "string" and guide ~= ""
        and guide ~= Glossary.DEFAULT_STYLE_GUIDE
    return glossary_instruction_text(terms, custom)
end

function Reader.attach(plugin)
    local dualtranslate = plugin

-- Chunk boundaries live in Tools so the MCP job exporter cuts long
-- paragraphs exactly the way the reader does (design 10.2: parts are stitched
-- back together on import, so one shared rule is required).
function dualtranslate:splitTranslationText(text, limit)
    return Tools.split_text(text, limit)
end

-- Whole-book translation uses DualTranslate's provider registry directly and
-- stores the result in a non-destructive per-book overlay cache.
function dualtranslate:translateTextForEpub(text, context, skip_store)
    local mode = self:getMode()
    local source_lang = self:getSourceLang()
    local target_lang = self:getTargetLang()
    local result, err
    local meta = context_meta(context)
    if not context and not missing_context_warned then
        missing_context_warned = true
        logger.warn("dualtranslate: translateTextForEpub without context; storing empty selector")
    end

    if self:isCacheEnabled() then
        local cached = self.cache:lookupForBook(self._active_translation_book,
            source_lang, target_lang, text, mode)
        if cached and cached.translated_text then
            -- A hit still records the locator of this occurrence (7.3).
            if meta and not skip_store and self.cache.insertLocationRow then
                self.cache:insertLocationRow(self._active_translation_book,
                    source_lang, target_lang, text, cached.translated_text, mode, meta)
            end
            return cached.translated_text, nil
        end
    end

    if mode == "default" then
        return nil, { message = "请先选择 DualTranslate 翻译服务" }
    end

    -- Keep long paragraphs below the selected provider's request limit.  The
    -- recursive calls use the same v19 one-paragraph request path, while the
    -- final result remains one continuous translation in the EPUB.
    local limit = self:getTranslationChunkLimit()
    if #text > limit then
        local translated_parts = {}
        for _, chunk in ipairs(self:splitTranslationText(text, limit)) do
            -- Chunks never store their own rows: only the merged paragraph
            -- is stored once, under the original context (7.3).
            local translated, chunk_err = self:translateTextForEpub(chunk, context, true)
            if not translated then return nil, chunk_err end
            table.insert(translated_parts, translated)
        end
        local combined = table.concat(translated_parts, " ")
        if self:isCacheEnabled() and not skip_store then
            self.cache:storeForBook(self._active_translation_book, source_lang,
                target_lang, text, combined, mode, meta)
        end
        return combined, nil
    end

    -- Keep the v19 request path: one paragraph, one provider request.
    -- The newer chunk/batch path was slower on-device and could turn one
    -- failed request into a failed EPUB generation.
    result, err = Providers.translate(mode, text, source_lang, target_lang)

    if result and result.translated_text and result.translated_text ~= "" then
        if self:isCacheEnabled() and not skip_store then
            self.cache:storeForBook(self._active_translation_book, source_lang,
                target_lang, text, result.translated_text, mode, meta)
        end
        return result.translated_text, nil
    end
    return nil, err or { message = "翻译服务没有返回译文" }
end

function dualtranslate:isEpub()
    return self.ui and self.ui.document and self.ui.document.file
        and self.ui.document.file:lower():match("%.epub$") ~= nil
end

function dualtranslate:isLegacyBilingualEpub(path)
    return path and path:lower():match("_bilingual_[^/]-%.epub$") ~= nil
end

function dualtranslate:getBookCacheDirectory(book_path)
    local data_dir = require("datastorage"):getDataDir()
    return data_dir .. "/cache/dualtranslate/books/"
        .. Tools.stable_path_hash(book_path .. "|" .. self:getTargetLang())
end

function dualtranslate:getTranslationOverlayPath(book_path)
    if not book_path then return nil end
    return self:getBookCacheDirectory(book_path) .. "/manifest.json"
end

function dualtranslate:getEntriesPath(book_path, provider)
    if not book_path or not provider or provider == "" then return nil end
    return Overlay.entriesPath(self:getBookCacheDirectory(book_path), provider)
end

function dualtranslate:hasTranslationOverlay(book_path)
    if not book_path then return false end
    local dir = self:getBookCacheDirectory(book_path)
    if Overlay.exists(dir .. "/manifest.json") then return true end
    if Overlay.exists(dir .. "/overlay.json") then
        -- Lazy v2 -> v3 migration so the display/delete menus stay enabled
        -- right after an upgrade (13.1).  Same short lock wait as
        -- onReadSettings: this runs on the UI thread and must not wait out a
        -- worker's checkpoint lock (M3); the next open retries.
        pcall(Store.migrateBookIfNeeded, book_path, self:getTargetLang(), self.cache,
            { lock_timeout = 0.5 })
        return true
    end
    return false
end

function dualtranslate:toggleTranslationVisible()
    local current = self.ui and self.ui.document and self.ui.document.file
    if not current or not self:hasTranslationOverlay(current) then return end
    self:saveSetting("translation_visible",
        self:getSetting("translation_visible", true) ~= true)
    self:refreshDocumentStyles()
end

-- Remove every artifact this plugin owns for a book: the per-book overlay
-- cache directories (manifest.json + entries/ + any legacy files), across
-- every target language the book has been translated into.  Restrict deletion
-- to the exact DualTranslate books root.
function dualtranslate:removeTranslationFilesForBook(book_path)
    if not book_path then return 0 end
    local lfs = require("libs/libkoreader-lfs")
    local data_dir = DataStorage:getDataDir()
    local books_root = data_dir .. "/cache/dualtranslate/books/"
    local removed, kept = 0, 0
    local function belongs_to_book(dir)
        local manifest = Overlay.loadManifest(dir)
        if manifest then return manifest.book_path == book_path end
        local legacy = Overlay.load(dir .. "/overlay.json")
        return legacy ~= nil and legacy.book_path == book_path
    end
    -- 17 Q5: glossary.json is user-authored editorial data, not translation
    -- output.  The cache directory is swept as a whole, so stash the file next
    -- to it and put it back: "delete every translation" must not throw away
    -- the terms.  If it cannot even be read, the directory is left alone.
    local function take_glossary(dir)
        return Glossary.stash(dir)
    end
    local function put_glossary(dir, stashed)
        if stashed == nil then return true end
        if not Glossary.unstash(dir, stashed) then
            logger.warn("dualtranslate: glossary could not be restored:", dir)
            return false
        end
        return true
    end
    -- 1) Fast path: the directory for the *current* target language.  This
    -- also catches legacy overlays that carry no book metadata.
    local current_dir = self:getBookCacheDirectory(book_path)
    if belongs_to_book(current_dir) then
        removed = removed + 1
    end
    if current_dir:sub(1, #books_root) == books_root
        and #current_dir > #books_root then
        local glossary, unreadable = take_glossary(current_dir)
        if unreadable then
            -- Keep the whole directory: deleting it would destroy the only
            -- copy of the user's terms.
            removed = math.max(0, removed - 1)
            kept = kept + 1
            logger.warn("dualtranslate: glossary unreadable, keep cache dir:",
                current_dir)
        else
            Tools.rmtree(current_dir)
            put_glossary(current_dir, glossary)
        end
    end
    -- 2) Sweep every other language directory whose overlay belongs to this
    -- same book (metadata written since v1.2.11).  Otherwise, if the target
    -- language was changed after a finished whole-book run, the old-language
    -- overlay would survive a "clear" and later trip stale "already done"
    -- checks or resurrect old translations.
    local ok, iterator, state = pcall(lfs.dir, books_root)
    if ok and iterator then
        for name in iterator, state do
            if name ~= "." and name ~= ".." then
                local dir = books_root .. name
                if dir ~= current_dir and belongs_to_book(dir) then
                    local glossary, unreadable = take_glossary(dir)
                    if unreadable then
                        kept = kept + 1
                        logger.warn(
                            "dualtranslate: glossary unreadable, keep cache dir:", dir)
                    else
                        removed = removed + 1
                        Tools.rmtree(dir)
                        put_glossary(dir, glossary)
                    end
                end
            end
        end
    end
    -- kept: directories left in place because their glossary could not be
    -- preserved; the caller must not report a complete wipe.
    return removed, kept > 0 and kept or nil
end

-- Single entry point for "clear this book": overlay files and the SQLite
-- cache must use the same book_path.  Keeping the two calls together makes
-- the argument contract explicit and testable (the old code accidentally
-- passed the cache directory to Cache:clearForBook).
function dualtranslate:clearBookTranslationData(book_path)
    if not book_path then return 0 end
    local removed, kept = self:removeTranslationFilesForBook(book_path)
    if self.cache and self.cache.clearForBook then
        self.cache:clearForBook(book_path)
    end
    return removed, kept
end

-- Best-effort detection of the current spine chapter index.  CREngine
-- xpointers serialize as "/body/DocFragment/body/..." without a fragment
-- index, so Epub.resolve cannot locate the current chapter from a raw
-- xpointer (it would silently fall back to chapter 1).  Probe each
-- DocFragment's first page instead: the current chapter is the last one
-- whose first page is at or before the current page.  Falls back to nil when
-- the probes are unsupported so callers keep their previous behaviour.
--
-- Probing every fragment on every page turn (a 200-chapter book = 200
-- getPageFromXPointer calls per turn) is wasteful.  The spine is monotonic:
-- chapter N+1 starts at or after chapter N.  Cache the last result and probe
-- incrementally from there — page turns forward only probe a handful of
-- chapters, page turns back probe backwards from the cached position, and
-- only a large jump degrades to a full scan (bounded at 4096, far beyond any
-- realistic EPUB spine; a probe returns "not exists" past the real end).
function dualtranslate:currentChapterIndex()
    local document = self.ui and self.ui.document
    if not document
        or not document.isXPointerInDocument
        or not document.getPageFromXPointer
        or not document.getCurrentPage then
        return nil
    end
    local current_page = document:getCurrentPage()
    if not current_page then return nil end
    local cache = self._chapter_index_cache
    if cache and cache.page == current_page then return cache.index end
    local function probe(index)
        local xp = "/body/DocFragment[" .. tostring(index) .. "]/body"
        local ok_in, in_doc = pcall(function()
            return document:isXPointerInDocument(xp)
        end)
        -- Returns page, exists: an empty spine item (in the document but with
        -- no layout, page <= 0) is "exists but no page" and must be skipped
        -- by the scan rather than treated as the end of the spine; only a
        -- missing fragment terminates the scan.
        if not ok_in or not in_doc then return nil, false end
        local ok_page, page = pcall(function()
            return document:getPageFromXPointer(xp)
        end)
        if not ok_page or not page then return nil, false end
        if page <= 0 then return nil, true end
        return page, true
    end
    local best
    local start = (cache and cache.index) or 1
    -- Forward scan from the cached position (page turned forward).
    local index = start
    while index <= 4096 do
        local page, exists = probe(index)
        if not exists then break end
        if page then
            if page <= current_page then
                best = index
            else
                break
            end
        end
        index = index + 1
    end
    -- Page turned back: the cached chapter starts after the current page.
    -- Walk backwards and take the nearest chapter that still starts before
    -- the current page.
    if not best and start > 1 then
        index = start - 1
        while index >= 1 do
            local page, exists = probe(index)
            if not exists then break end
            if page and page <= current_page then
                best = index
                break
            end
            index = index - 1
        end
    end
    if best then
        self._chapter_index_cache = { page = current_page, index = best }
    end
    return best
end

function dualtranslate:getCurrentFragment()
    local document = self.ui.document
    -- Prefer the resolved chapter index (a plain decimal string).  Epub.resolve
    -- accepts it directly; a raw xpointer cannot locate the chapter.
    local index = self:currentChapterIndex()
    if index then return tostring(index) end
    if not document.getXPointer then return nil end
    local ok, xpointer = pcall(function() return document:getXPointer() end)
    return ok and xpointer or nil
end

-- Which TOC entries of `index` start on which page, cached per chapter.  The
-- answer comes from CREngine itself (getPageFromXPointer on the element path
-- the anchor lives at), so it follows the renderer's own pagination; the
-- chapter is parsed once for its paths, never per page turn.
--
-- Three slots, like the anchor path cache in the EPUB module: page-turn
-- follow moves across chapter boundaries, and turning back over one used to
-- re-probe every anchor of the chapter just left.  A remembered failure (no
-- page for some anchor) occupies a slot too: retrying N probes on every page
-- turn would not make CREngine find the anchors.
local ENTRY_PAGE_CACHE_SLOTS = 3

-- Most recently used first; the tail is the chapter left longest ago.
local function entry_page_cache_get(cache, book_path, index)
    for position, entry in ipairs(cache) do
        if entry.book_path == book_path and entry.index == index then
            if position > 1 then
                table.remove(cache, position)
                table.insert(cache, 1, entry)
            end
            return entry
        end
    end
end

local function entry_page_cache_put(cache, entry)
    table.insert(cache, 1, entry)
    while #cache > ENTRY_PAGE_CACHE_SLOTS do table.remove(cache) end
end

function dualtranslate:chapterEntryPages(book_path, index, rows)
    local cache = self._entry_page_cache
    if type(cache) ~= "table" then
        cache = {}
        self._entry_page_cache = cache
    end
    local cached = entry_page_cache_get(cache, book_path, index)
    if cached then
        if #cached.pages == 0 then return nil end
        return cached.pages
    end
    local document = self.ui and self.ui.document
    if not document or not document.getPageFromXPointer then return nil end
    local Epub = self.epub or (self.loadEpubModule and self:loadEpubModule())
    local paths = Epub and Epub.chapter_anchor_paths
        and Epub.chapter_anchor_paths(book_path, index)
    if type(paths) ~= "table" then return nil end
    local pages = {}
    local function page_of(address)
        local ok, value = pcall(document.getPageFromXPointer, document, address)
        if ok and type(value) == "number" and value > 0 then return value end
        return nil
    end
    local missing = {}
    for position, row in ipairs(rows) do
        local anchor = row.anchor
        if anchor then
            local path = paths[anchor]
            -- Same xpointer spelling the overlay uses: [N] only past the
            -- first DocFragment.
            local xp = path and ("/body/DocFragment"
                .. (index > 1 and ("[" .. index .. "]") or "") .. path) or nil
            local page = xp and page_of(xp)
            if not page and xp then
                -- The renderer rebuilt the tree differently (invalid nesting,
                -- an entity inside an attribute), yet the anchor's parent is
                -- still addressable and starts at the same place.  Falling
                -- back to it beats dropping the anchor: a missing page would
                -- attribute this entry's text to the previous one.
                local parent = xp:gsub("/[^/]+$", "")
                if parent ~= xp and parent:sub(-5) ~= "/body" then
                    page = page_of(parent)
                end
            end
            if page then
                -- Keep the address: the page alone cannot tell a chapter
                -- heading at the top of a page from one at the bottom.
                pages[#pages + 1] = { position = position, page = page,
                    anchor = anchor, xp = xp }
            else
                missing[#missing + 1] = anchor
            end
        end
    end
    -- One unlocatable anchor poisons the whole mapping: the entries after it
    -- would be attributed to the previous one, whose range ends exactly at the
    -- missing anchor — that chapter would never be scheduled and page-turn
    -- follow would skip it for good.  Fall back to the file and say why.
    if #pages == 0 or #missing > 0 then
        logger.warn("dualtranslate: chapter", index, "anchors not located:",
            table.concat(missing, ","), "— keeping the whole file")
        entry_page_cache_put(cache, { book_path = book_path, index = index,
            pages = {} })
        return nil
    end
    -- INFO, not dbg: when page-turn follow "does nothing", this line says
    -- whether the anchors were located at all.  Once per chapter change.
    logger.info("dualtranslate: entry pages for chapter", index, #pages, "of",
        #rows, "anchors")
    entry_page_cache_put(cache, { book_path = book_path, index = index,
        pages = pages })
    return pages
end

-- The current TOC entry as a job range.  nil when the chapter cannot be
-- resolved; a whole-file range (no anchors) whenever entry granularity is not
-- available — no outline, no CREngine probing, or a file the TOC lists once.
-- That keeps the old behaviour as the floor: a failed mapping translates the
-- same file it used to.
--
-- `key` identifies the entry for the page-turn guard ("12.3" = third entry of
-- spine file 12), and is the chapter index alone for a whole-file fallback.
function dualtranslate:currentChapterRange()
    local document = self.ui and self.ui.document
    if not document then return nil end
    local index = self:currentChapterIndex()
    if not index then
        -- One line per session: without the chapter index there is no entry to
        -- map, and every page turn would look like a fresh chapter.
        if not self._chapter_index_warned then
            logger.warn("dualtranslate: cannot resolve the current chapter; "
                .. "page-turn follow stays file-based")
            self._chapter_index_warned = true
        end
        return nil
    end
    local book_path = document.file
    local whole = { index = index }
    local outline = self:getBookOutline(book_path)
    local entries = outline and type(outline.entries) == "table" and outline.entries
    if not entries or #entries == 0 then return whole, tostring(index) end
    local rows = {}
    for _, entry in ipairs(entries) do
        if tonumber(entry.index) == index then rows[#rows + 1] = entry end
    end
    -- One entry means the file is the chapter: nothing to narrow.
    if #rows <= 1 then return whole, tostring(index) end
    local pages = self:chapterEntryPages(book_path, index, rows)
    if not pages then return whole, tostring(index) end
    local page = document.getCurrentPage and document:getCurrentPage() or nil
    if not page then return whole, tostring(index) end
    -- The page number alone over-reports at a chapter boundary: a heading
    -- sitting under the last lines of the current chapter shares the page
    -- with it, and "translate what I am reading" must not jump ahead.  Ask
    -- CREngine where the heading actually sits and keep the previous entry
    -- while it is in the lower half of the page.
    local height = self.ui and self.ui.view and self.ui.view.dimen
        and self.ui.view.dimen.h
    local page_position = Coverage.entry_at_page(pages, page)
    local position = Coverage.reading_position(pages, page, height,
        function(item)
            if not item.xp then return nil end
            local ok, value = pcall(document.getScreenPositionFromXPointer,
                document, item.xp)
            if ok then return value end
            return nil
        end)
    if not position then return whole, tostring(index) end
    if page_position and page_position ~= position then
        logger.info("dualtranslate: chapter", index .. "." .. page_position,
            "starts at the page bottom; staying on", index .. "." .. position)
    end
    return Coverage.entry_range(rows, position, index),
        index .. "." .. position, rows
end

-- 7.2: on-demand outline behind the chapter picker.  The EPUB module already
-- caches the parsed result on disk keyed by (path, size, mtime); this keeps one
-- parsed copy in memory for the open book, so reopening the picker or opening
-- it again after closing and reopening the book does not unpack the EPUB.
function dualtranslate:getBookOutline(book_path)
    book_path = book_path
        or (self.ui and self.ui.document and self.ui.document.file)
    if not book_path then return nil, "缺少书路径" end
    if not book_path:lower():match("%.epub$") then
        return nil, "目录解析目前仅支持 EPUB"
    end
    local cached = self._book_outline_cache
    if cached and cached.book_path == book_path then return cached.outline end
    local Epub = self.epub or (self.loadEpubModule and self:loadEpubModule())
    if not Epub or not Epub.outline then return nil, "EPUB 引擎不可用" end
    -- A cold parse unpacks the archive and walks the spine three times: ~1.9 s
    -- on a 38 MB / 646-spine book, which reads as a frozen UI right after the
    -- tap.  The parse stays synchronous by contract, so paint a message before
    -- blocking; Epub.outline calls the hook only when it really has to parse,
    -- so the memory cache above and a disk-cache hit never flash it.
    -- pcall so an exception cannot leave the notice stranded on screen behind
    -- whatever error dialog the caller raises.
    local notice
    local ok, outline, err = pcall(Epub.outline, book_path, function()
        notice = Notification:new{ text = _("正在解析目录…"), timeout = 30 }
        UIManager:show(notice)
        UIManager:forceRePaint()
    end)
    if notice then UIManager:close(notice) end
    if not ok then return nil, tostring(outline) end
    if not outline then return nil, err end
    self._book_outline_cache = { book_path = book_path, outline = outline }
    return outline
end

-- 7.4: the three chapter scopes are decoupled.  Whole-book translation is
-- unconditional and never consults the 逐章模式 preference; that preference
-- only governs whether the current-chapter entry arms page-turn follow.
--
-- The argument shapes are not uniform: translateWholeBook(silent, auto) and
-- translateCurrentChapter(silent, auto) start with `silent`, while
-- translateSelectedChapters(ranges, silent, auto) takes the chapter range
-- list first (a plain index list is still widened to whole files).
-- `silent=true` suppresses the progress dialog and every user-facing notice,
-- and belongs only to a job resumed from an old queue item.  The two chapter
-- entries used to start with `all_chapters`, so a leftover `true` there
-- silently muted a run — menu actions pass `false` explicitly.
function dualtranslate:translateWholeBook(silent, auto)
    if not self:isEpub() then return end
    -- 7.4: with the MCP engine there is no device-side request path; the
    -- equivalent action is exporting the whole book as a job.
    if self:getMode() == "mcp_external" then
        self:confirmMcpExport(nil)
        return
    end
    local book_path = self.ui.document.file
    self:enqueueTranslation({ book_path = book_path, mode = "all",
        silent = silent, auto = auto })
end

-- fallback_key: the caller's own dedupe key (page turns pass one).  When the
-- page cannot be mapped onto a TOC anchor this function has no key of its own,
-- and without one the page-turn guard can never remember that it already
-- scheduled this chapter: every page turn re-queues the same job.
function dualtranslate:translateCurrentChapter(silent, auto, fallback_key)
    if not self:isEpub() then return end
    -- The current entry, not the whole file: a XHTML holding nine chapters
    -- used to hand all nine to the job.  The range falls back to the file when
    -- the page cannot be mapped onto a TOC anchor.
    local range, mapped_key = self:currentChapterRange()
    local key = mapped_key or fallback_key
    if self:getMode() == "mcp_external" then
        local index = self:currentChapterIndex()
        self:confirmMcpExport(range and { range } or (index and { index } or nil))
        return
    end
    local book_path = self.ui.document.file
    local fragment = self:getCurrentFragment()
    -- 逐章模式: translating the current chapter arms follow so page turns keep
    -- scheduling the newly reached chapters (each one still shows the progress
    -- dialog; `auto` only silences the per-chapter completion notice).  The
    -- overlay complete flag must not gate this: chapter runs never write
    -- complete, and a stale flag from an earlier whole-book run (possibly
    -- another language) would block re-translating the current chapter
    -- forever.
    if self:isPageTranslationEnabled() then
        self._page_translation_follow_active = true
        -- An explicit start cancels an earlier "user stopped following".
        self._page_translation_follow_cancelled = nil
    end
    local queued = self:enqueueTranslation({ book_path = book_path, mode = "span",
        fragment = fragment, span = 1, chapter_ranges = range and { range } or nil,
        silent = silent, auto = auto })
    -- Remember the entry only once it really entered the queue: a refused
    -- enqueue (another job for this book) must stay retryable.
    if queued ~= false and key then
        self._page_translation_last_fragment = key
        logger.info("dualtranslate: scheduled entry", key, "range",
            tostring(range and range.from), "->", tostring(range and range.to))
    end
end

-- How many spine files a range list touches.  Ranges are chapters, several of
-- them can sit in one file, and the privacy notice / progress card talk about
-- the files that will be read.  A plain list of spine indexes (the shape
-- before ranges existed) counts one file per entry.
local function range_files(ranges)
    local seen, count = {}, 0
    for _, range in ipairs(type(ranges) == "table" and ranges or {}) do
        local index = type(range) == "table" and tonumber(range.index) or tonumber(range)
        if index and not seen[index] then
            seen[index] = true
            count = count + 1
        end
    end
    return count
end

-- Callers may still hand in the pre-range shape (a list of spine indexes);
-- every job below works on ranges, so widen those to whole-file ranges.
local function chapter_range_list(ranges)
    local list = {}
    for _, value in ipairs(type(ranges) == "table" and ranges or {}) do
        if type(value) == "table" then
            list[#list + 1] = value
        else
            local index = tonumber(value)
            if index then list[#list + 1] = { index = index } end
        end
    end
    return list
end

-- One-shot selection from the chapter picker; never arms follow mode.  The
-- range list is the first argument here — `silent` comes second.  Each range
-- is {index, from, to} (anchors nil at the file edges), so picking one chapter
-- out of a nine-chapter XHTML now translates that chapter only.
function dualtranslate:translateSelectedChapters(ranges, silent, auto, chapter_count)
    if not self:isEpub() then return end
    ranges = chapter_range_list(ranges)
    if self:getMode() == "mcp_external" then
        self:confirmMcpExport(ranges, nil, chapter_count)
        return
    end
    local book_path = self.ui.document.file
    self:enqueueTranslation({ book_path = book_path, mode = "selection",
        chapter_ranges = ranges, silent = silent, auto = auto,
        chapter_count = chapter_count })
end

------------------------------------------------------------------------
-- MCP external translation (P3)
--
-- Export -> PC translates -> import.  The device never talks to the model:
-- it only writes the job and consumes the result (design 10.1).
------------------------------------------------------------------------

-- privacy notice required before the book text leaves the device (10.10).
function dualtranslate:confirmMcpExport(ranges, menu, chapter_count)
    -- Ranges are chapters; several can live in one spine file.  The notice has
    -- to speak in chapters (what the user picked), with the file count only as
    -- a parenthetical when a file is read for more than one chapter.
    local scope = _("整本书")
    if ranges then
        local files = range_files(ranges)
        local chapters = tonumber(chapter_count) or files
        if files > 1 then
            scope = string.format(_("所选 %d 章（%d 个文件）"), chapters, files)
        else
            scope = string.format(_("所选 %d 章"), chapters)
        end
    end
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(
            _("将导出%s的原文到设备缓存（如已填写，术语表与风格指南也会一并写入），供电脑端读取，并可能发送给 AI 模型。"), scope),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("导出"),
                callback = function()
                    UIManager:close(dialog)
                    self:exportMcpJob(ranges, menu)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function dualtranslate:exportMcpJob(ranges, menu)
    -- nil is not an empty selection: it means the whole book (translate
    -- whole book, or a current chapter with no index).  An explicit list is a
    -- selection the exporter must honour or refuse — never silently widen.
    local has_selection = type(ranges) == "table"
    ranges = chapter_range_list(ranges)
    local book_path = self:currentBookPath()
    if not book_path then return end
    local outline = self:getBookOutline(book_path)
    local titles = {}
    for _, chapter in ipairs(outline and outline.chapters or {}) do
        titles[chapter.index] = chapter.title
    end
    local Mcp = require("dualtranslate_mcp")
    local Epub = self.epub or require("dualtranslate_epub")
    if type(Epub) ~= "table" or type(Epub.begin_segment_export) ~= "function" then
        TranslationUI.showInfo(_("导出失败：EPUB 模块未加载"))
        return
    end
    -- Opening the archive is the one blocking step left (three to four passes
    -- over the EPUB; 2.6 s on the 646-chapter book).  The dialog goes up before
    -- it, otherwise the tap looks dead until the first slice is scheduled.  The
    -- chapter walk itself is sliced below: a whole book is ~600 chapters /
    -- 16k segments, and doing it in one call froze the screen for tens of
    -- seconds with no progress and no way out (3.2.0).
    local total_chapters = 0
    local progress_dialog = ProgressbarDialog:new{
        title = _("正在导出 MCP 任务…"),
        subtitle = _("正在打开 EPUB…"),
        progress_max = 100,
        refresh_time_seconds = 0.5,
        dismissable = true,
    }
    -- Hiding the dialog (tap outside) must only hide it; the export keeps
    -- running and its result still lands in the job list.
    local progress_on_close = progress_dialog.onCloseWidget
    function progress_dialog:onCloseWidget()
        self._dualtranslate_hidden = true
        -- Same reason as in _runTranslation: a hide-by-tap must repaint the
        -- page, or the bar stays on screen while the export keeps running.
        UIManager:setDirty(nil, "ui")
        return progress_on_close(self)
    end
    progress_dialog:show()
    if UIManager.forceRePaint then UIManager:forceRePaint() end

    local session, open_err = Epub.begin_segment_export{
        book_path = book_path,
        chapter_ranges = has_selection and ranges or nil,
        titles = titles,
    }
    if not session then
        UIManager:close(progress_dialog, "ui")
        TranslationUI.showInfo(_("导出失败：") .. tostring(open_err))
        return
    end
    total_chapters = session:chapter_count()
    progress_dialog.subtitle = string.format("文件：0/%d", total_chapters)

    local function report(percentage, subtitle)
        if progress_dialog._dualtranslate_hidden then return end
        progress_dialog.title = string.format("%s  %d%%", _("正在导出 MCP 任务…"), percentage)
        progress_dialog.subtitle = subtitle
        pcall(function()
            -- Update the TextWidgets in place; rebuilding the dialog tree on
            -- every slice would allocate a new layout each turn.
            local group = progress_dialog[1] and progress_dialog[1][1]
            if group and group[1] and group[1].setText then
                group[1]:setText(progress_dialog.title)
            end
            if group and group[2] and group[2].setText then
                group[2]:setText(progress_dialog.subtitle)
            end
            progress_dialog:reportProgress(percentage)
            UIManager:setDirty(progress_dialog, "ui")
        end)
    end

    -- The menu stays open under the picker and the progress dialog; rebuild
    -- it so a finished export shows up in the task count without the user
    -- having to leave and re-enter the page.
    local function refresh_menu()
        if menu then self:refreshMenuPage(menu) end
    end

    local function finish_with_error(message)
        UIManager:close(progress_dialog, "ui")
        refresh_menu()
        TranslationUI.showPersistent(tostring(message) .. _("\n\n请轻触屏幕以关闭此消息"))
    end

    local step
    step = function()
        if session.aborted then return end
        -- A malformed chapter must not leave a job_ directory behind, and must
        -- not surface as an unhandled error inside a scheduled task.
        local ok, step_err = pcall(session.step, session, 0.2)
        if not ok then
            session:abort()
            finish_with_error(_("导出失败：") .. tostring(step_err))
            return
        end
        local done = session:processed()
        local percentage = total_chapters > 0
            and math.floor(done * 100 / total_chapters + 0.5) or 0
        if done < total_chapters then
            report(percentage, string.format("文件：%d/%d", done, total_chapters))
            UIManager:scheduleIn(0.01, step)
            return
        end
        local collected, collect_err = session:finish()
        if not collected then
            finish_with_error(_("导出失败：") .. tostring(collect_err))
            return
        end
        -- Encoding job.json walks every segment; label it so the last frame of
        -- the bar does not look like a hang.
        report(100, _("写入任务文件…"))
        if UIManager.forceRePaint then UIManager:forceRePaint() end
        -- pcall: a raise inside the writer used to leave the dialog sitting at
        -- 100% forever, with nothing to tell the user it had failed.
        -- 17 Q5: the per-book glossary/style guide travels with the job so the
        -- PC-side agent can honour the user's terms.  The read is inside the
        -- pcall too: a filesystem error must close the progress dialog instead
        -- of leaving it at 100%.
        local ok_export, result, err = pcall(function()
            local book_glossary = Glossary.load(self:getBookCacheDirectory(book_path))
            return Mcp.exportJob{
                book_path = book_path,
                collected = collected,
                source_lang = self:getSourceLang(),
                target_lang = self:getTargetLang(),
                glossary = book_glossary.terms,
                style_guide = book_glossary.style_guide,
            }
        end)
        if not ok_export then result, err = nil, tostring(result) end
        UIManager:close(progress_dialog, "ui")
        if not result then
            refresh_menu()
            TranslationUI.showPersistent(
                (_("导出失败\n\n%s\n\n请轻触屏幕以关闭此消息")):format(tostring(err)))
            return
        end
        -- The task list is cached for a second; a fresh export must not be
        -- hidden behind a menu the user opened just before it.
        self._mcp_job_menu_cache = nil
        refresh_menu()
        -- A whole-book export takes a minute; a 6-second toast is easy to miss
        -- while the screen repaints, so this one waits for a tap.  The
        -- glossary line is what the agent will actually be told to honour.
        local message = {
            _("导出完成"), "",
            string.format(_("任务：%s"), result.job_id),
            string.format(_("%d 个文件 · %d 段"), result.chapters, result.segments),
        }
        local options_note = glossary_summary(result.job and result.job.options)
        if options_note then
            message[#message + 1] = string.format(_("随任务写入：%s"), options_note)
        end
        local unreadable = tonumber(result.unreadable) or 0
        if unreadable > 0 then
            -- A chapter file that could not be parsed is skipped silently by
            -- the walk; say so, or the job looks complete.
            message[#message + 1] = string.format(
                _("有 %d 个文件读不出正文，未包含在任务里。"), unreadable)
        end
        message[#message + 1] = ""
        message[#message + 1] = _("电脑端可读取 cache/dualtranslate/mcp/jobs/")
        message[#message + 1] = ""
        message[#message + 1] = _("请轻触屏幕以关闭此消息")
        TranslationUI.showPersistent(table.concat(message, "\n"))
    end
    UIManager:scheduleIn(0.1, step)
end

------------------------------------------------------------------------
-- Glossary / style guide (17 Q5)
--
-- Stored per book + target language in the book cache directory, but in its
-- own glossary.json: editing a term must not bump the overlay revision,
-- rebuild css-template.css or trigger a reader reload.  Only the MCP exporter
-- reads it, when it fills the job's options.glossary / options.style_guide.
------------------------------------------------------------------------

function dualtranslate:loadBookGlossary()
    local book_path = self:currentBookPath()
    if not book_path then return nil end
    return Glossary.load(self:getBookCacheDirectory(book_path))
end

-- One line per issue, so the confirmation after Save explains every row that
-- did not make it into the file instead of silently dropping it.
local function glossary_dropped_note(stats)
    local notes = {}
    local skipped = (stats.invalid or 0) + (stats.too_long or 0)
    if skipped > 0 then
        notes[#notes + 1] = string.format(_("忽略 %d 行无效或过长内容"), skipped)
    end
    if (stats.duplicate or 0) > 0 then
        notes[#notes + 1] = string.format(_("合并 %d 条重复原文"), stats.duplicate)
    end
    if (stats.overflow or 0) > 0 then
        notes[#notes + 1] = string.format(_("超出上限 %d 条未保存"), stats.overflow)
    end
    return table.concat(notes, "\n")
end

-- A corrupt file is loaded as "no terms", and saving would replace it.  The
-- reader keeps a .corrupt copy, but the editor must say so: otherwise the
-- user sees an empty list and assumes the terms were never saved.
local function glossary_corrupt_note(current)
    if not (current and current.corrupt) then return nil end
    return _("原术语表文件损坏，已备份为 glossary.json.corrupt；保存会用当前内容覆盖")
end

function dualtranslate:showGlossaryDialog(menu)
    local book_path = self:currentBookPath()
    if not book_path then return end
    local dir = self:getBookCacheDirectory(book_path)
    local current = Glossary.load(dir)
    local description = _("只影响 MCP 导出；删除译文不会删除这里的内容")
    local corrupt_note = glossary_corrupt_note(current)
    if corrupt_note then description = corrupt_note .. "\n" .. description end
    local dialog
    dialog = InputDialog:new{
        title = string.format(_("术语表（每行一条：原文=译文，最多 %d 条）"),
            Glossary.MAX_TERMS),
        description = description,
        input = Glossary.format(current.terms),
        input_hint = _("例如：\nDarcy=达西\nNetherfield=内瑟菲尔德"),
        -- Full-screen text editor: the on-screen keyboard would otherwise
        -- leave three visible lines for a whole glossary.
        fullscreen = true,
        condensed = true,
        allow_newline = true,
        add_nav_bar = true,
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("保存"),
                callback = function()
                    local terms, stats = Glossary.parse(dialog:getInputText())
                    local saved, err = Glossary.save(dir, {
                        terms = terms,
                        style_guide = current.style_guide,
                    })
                    if not saved then
                        -- Keep the editor open: closing it would throw away
                        -- everything the user just typed.
                        TranslationUI.showInfo(_("保存失败：") .. tostring(err))
                        return
                    end
                    UIManager:close(dialog)
                    if menu then self:refreshMenuPage(menu) end
                    local message = string.format(_("已保存 %d 条术语"),
                        #saved.terms)
                    local note = glossary_dropped_note(stats)
                    if note ~= "" then message = message .. "\n" .. note end
                    TranslationUI.showInfo(message)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function dualtranslate:showStyleGuideDialog(menu)
    local book_path = self:currentBookPath()
    if not book_path then return end
    local dir = self:getBookCacheDirectory(book_path)
    local current = Glossary.load(dir)
    local description = _("留空保存会使用默认要求；超长会截断")
    local corrupt_note = glossary_corrupt_note(current)
    if corrupt_note then description = corrupt_note .. "\n" .. description end
    local dialog
    dialog = InputDialog:new{
        title = _("风格指南（发送给翻译模型的统一要求）"),
        description = description,
        input = current.style_guide,
        input_hint = _("留空则使用默认要求：") .. Glossary.DEFAULT_STYLE_GUIDE,
        fullscreen = true,
        condensed = true,
        allow_newline = true,
        add_nav_bar = true,
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("保存"),
                callback = function()
                    local saved, err = Glossary.save(dir, {
                        terms = current.terms,
                        style_guide = dialog:getInputText(),
                    })
                    if not saved then
                        -- Keep the editor open so a failed write does not cost
                        -- the user the whole text.
                        TranslationUI.showInfo(_("保存失败：") .. tostring(err))
                        return
                    end
                    UIManager:close(dialog)
                    if menu then self:refreshMenuPage(menu) end
                    local truncated = saved.stats and saved.stats.style_truncated
                    TranslationUI.showInfo(truncated
                        and _("已保存风格指南（超长部分已截断；留空则使用默认要求）")
                        or _("已保存风格指南（留空则使用默认要求）"))
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Poll the reload signal on page turns (10.7).  The comparison uses the
-- monotonic seq, never the mtime: FAT32 timestamps are ~2 s coarse.
function dualtranslate:checkExternalReload(force)
    local book_path = self:currentBookPath()
    if not book_path then return nil end
    local signal = Overlay.loadSignal(self:getBookCacheDirectory(book_path))
    if not signal then return nil end
    if not force and self._last_reload_signal_seq
        and signal.seq <= self._last_reload_signal_seq then
        return nil
    end
    self._last_reload_signal_seq = signal.seq
    self._page_translation_overlay_state = nil
    -- The import ran in another process (dtctl / MCP server), so this process
    -- cannot have dropped the parsed entries doc from its own write path.  The
    -- signal is the only reliable invalidation: FAT32 mtime is ~2 s coarse and
    -- the new file can have the same size.  A display switch only re-points the
    -- manifest, so it keeps the parsed docs.
    if signal.op ~= "display" then
        Overlay.clearEntriesCache()
        Overlay.clearTemplateCache()
        if Overlay.clearRevisionCache then Overlay.clearRevisionCache() end
    end
    self:refreshDocumentStyles()
    return signal
end

------------------------------------------------------------------------
-- MCP task pages (10.x)
--
-- The task list is where the user works, so it must survive a delete.  Rows
-- therefore set keep_menu_open and hand the menu to the callback; the callback
-- ends with refreshMcpJobMenu(), which rebuilds the page in place.  Closing
-- the menu instead would drop the user back into the book and force a reopen
-- from the top after every single task.
------------------------------------------------------------------------

local MCP_FILTER_KEY = "mcp_only_current_book"

-- state.json is written by dtctl on the PC, so its status words are protocol
-- identifiers.  The list shows what they mean instead.
local JOB_STATUS_LABELS = {
    exported = _("已导出"),
    confirmed = _("已确认模型"),
    submitting = _("翻译中"),
    committed = _("已导入书中"),
}

local function job_status_text(status)
    return JOB_STATUS_LABELS[tostring(status)] or tostring(status)
end

-- Rows are single-line, and a row is how the user picks a book out of the
-- inbox: the title comes first, the export time last (it separates two exports
-- of the same book).  The row truncates at its end, which is exactly where the
-- state and the time sit, so the title is cut first.  The budget is in display
-- columns, not bytes: 30 bytes is ten CJK characters but thirty Latin ones, and
-- a 30-character English title would push the time off a 600 px screen.
local JOB_TITLE_COLUMNS = 22

-- Cut at a UTF-8 boundary; ASCII counts one column, a multi-byte character
-- (CJK, fullwidth punctuation, emoji) two.
local function title_head(title, columns)
    local used, index, length = 0, 1, #title
    while index <= length do
        local byte = title:byte(index)
        local width = byte < 0x80 and 1 or 2
        if used + width > columns then break end
        used = used + width
        if byte < 0x80 then
            index = index + 1
        elseif byte < 0xE0 then
            index = index + 2
        elseif byte < 0xF0 then
            index = index + 3
        else
            index = index + 4
        end
    end
    if index > length then return title end
    return title:sub(1, index - 1) .. "…"
end

local function job_row_text(position, job)
    local title = tostring(job.title or job.job_id)
    -- Same-year stamps drop the year; an old job keeps it, or two tasks from
    -- different years would read alike.
    local created = tonumber(job.created_at) or 0
    local stamp = "-"
    if created > 0 then
        local same_year = os.date("%Y", created) == os.date("%Y")
        stamp = os.date(same_year and "%m-%d %H:%M" or "%Y-%m-%d", created)
    end
    return string.format("%d. %s · %s · %s", position,
        title_head(title, JOB_TITLE_COLUMNS), job_status_text(job.status), stamp)
end

local function job_time_text(seconds)
    local value = tonumber(seconds) or 0
    -- No timestamp (a job directory whose state.json was lost): leave the
    -- line out rather than print a dash the user cannot act on.
    if value <= 0 then return nil end
    return os.date("%Y-%m-%d %H:%M", value)
end

-- Body of the detail dialog.  Deliberately plain text: TextViewer paginates
-- and scrolls it, so a 63-chapter book is readable on a Voyage where a
-- ButtonDialog title would have run off the screen.
local function format_job_detail(job)
    local lines = { string.format(_("任务 %s"), job.job_id), "" }
    local function field(label, value)
        if value and value ~= "" then
            -- tostring: a hand-edited meta.json can hold a table where a
            -- string belongs, and string.format("%s", table) would throw
            -- inside the dialog callback.
            lines[#lines + 1] = string.format("%s：%s", label, tostring(value))
        end
    end
    field(_("书名"), job.title or "-")
    field(_("作者"), job.author)
    field(_("路径"), job.book_path)
    if job.source_lang or job.target_lang then
        field(_("语言"), string.format("%s → %s", tostring(job.source_lang or "?"),
            tostring(job.target_lang or "?")))
    end
    field(_("创建"), job_time_text(job.created_at))
    field(_("更新"), job_time_text(job.updated_at))
    field(_("状态"), job_status_text(job.status))
    local total = tonumber(job.total) or 0
    local submitted = tonumber(job.submitted) or 0
    if total > 0 then
        -- submitted and total come from different files (state.json vs
        -- meta.json); a stale meta must not print 108%.
        local percent = math.min(100, math.floor(submitted * 100 / total))
        field(_("已回传"), string.format(_("%d / %d 段（%d%%）"), submitted,
            total, percent))
    end
    field(_("引擎"), job.model_name or job.provider_id)
    -- What the agent was told to honour.  A row that came from the task list
    -- (jobDetail returned nil) has no counts at all; leave the line out
    -- instead of claiming 无.
    if job.glossary_terms ~= nil or job.style_guide_custom ~= nil then
        local instructions = glossary_instruction_text(
            tonumber(job.glossary_terms) or 0, job.style_guide_custom == true)
        field(_("翻译要求"), instructions or _("无"))
    end

    local chapters = job.chapters or {}
    lines[#lines + 1] = ""
    if #chapters == 0 then
        if (tonumber(job.chapter_count) or 0) > 0 then
            lines[#lines + 1] = string.format(
                _("章节：%d 章（任务文件里没有章节标题）"), job.chapter_count)
        else
            lines[#lines + 1] = _("章节：任务文件里没有章节记录")
        end
    else
        lines[#lines + 1] = string.format(_("章节（%d）："), #chapters)
        -- 300 lines is already many screens; past that the exact tail of a
        -- 646-chapter job is not what the dialog is for.
        local shown = math.min(#chapters, 300)
        for position = 1, shown do
            local chapter = chapters[position]
            lines[#lines + 1] = string.format("%d. %s",
                chapter.index or position,
                chapter.title or string.format(_("第 %d 章"), position))
        end
        if shown < #chapters then
            lines[#lines + 1] = string.format(_("…另有 %d 章未列出"),
                #chapters - shown)
        end
    end
    return table.concat(lines, "\n")
end

-- Rebuild whatever page the menu is currently showing.  Each builder attaches
-- refresh_func to its own item table, because only it knows how to rebuild
-- that level (task list vs. batch list).  The page number is kept so a delete
-- on page 3 does not throw the user back to the top of the list.
function dualtranslate:refreshMenuPage(menu)
    if not (menu and menu.updateItems) then return end
    local page = menu.item_table
    if page and page.refresh_func then
        local rebuilt = page.refresh_func()
        if rebuilt then menu.item_table = rebuilt end
    else
        -- A page built without refresh_func is left exactly as it is: the
        -- delete looks like it did nothing.  Cheap to spot in the log.
        logger.warn("dualtranslate: menu page has no refresh_func; not rebuilding")
    end
    menu:updateItems(menu.page or 1)
end

function dualtranslate:refreshMcpJobMenu(menu)
    self._mcp_job_menu_cache = nil
    if not (menu and menu.updateItems) then return end
    -- An emptied batch page would leave nothing to tick: step back to the task
    -- list, which rebuilds itself through its own refresh_func.  "Emptied"
    -- means emptied as shown: with the per-book filter on, another book's
    -- tasks may still exist without appearing on this page.
    if menu.item_table and menu.item_table.batch then
        local visible = self:mcpVisibleJobs()
        if #visible == 0 then
            menu:backToUpperMenu()
            return
        end
    end
    self:refreshMenuPage(menu)
end

------------------------------------------------------------------------
-- Per-book filter
--
-- A few books in flight at once is normal, and their rows look alike.  The
-- switch is a setting, not session state: reopening the list must not silently
-- change what it shows.
------------------------------------------------------------------------

function dualtranslate:mcpFiltersToCurrentBook()
    return self:getSetting(MCP_FILTER_KEY, false) == true
end

function dualtranslate:setMcpFilterCurrentBook(value)
    self:saveSetting(MCP_FILTER_KEY, value and true or false)
    -- The list is cached for the current second; a toggle must not read the
    -- rows that were built under the old filter.
    self._mcp_job_menu_cache = nil
end

-- Jobs in display order, narrowed to the open book when the filter is on.
-- The second value is the unfiltered total, so the page can say how many rows
-- the filter hides.
function dualtranslate:mcpVisibleJobs()
    local Mcp = require("dualtranslate_mcp")
    local jobs = Mcp.listJobs()
    if not self:mcpFiltersToCurrentBook() then return jobs, #jobs end
    local book_path = self:currentBookPath()
    if not book_path then return {}, #jobs end
    local visible = {}
    for _, job in ipairs(jobs) do
        if job.book_path == book_path then visible[#visible + 1] = job end
    end
    return visible, #jobs
end

function dualtranslate:showMcpJob(item, menu)
    local Mcp = require("dualtranslate_mcp")
    -- Read the job again on open: the agent may have submitted or committed
    -- since the row was built.
    local job = Mcp.jobDetail(item.job_id, item) or item
    local TextViewer = require("ui/widget/textviewer")
    local dialog
    local buttons = {
        {
            {
                text = _("关闭"),
                -- TextViewer repaints its own frame on close
                -- (onCloseWidget), so no refresh type is needed here; on e-ink
                -- a forced full refresh would only add a flash.
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("删除任务"),
                callback = function()
                    UIManager:close(dialog)
                    local removed = Mcp.validJobId(item.job_id)
                        and Tools.rmtree(Mcp.jobDir(item.job_id))
                    if self._mcp_batch_selected then
                        self._mcp_batch_selected[item.job_id] = nil
                    end
                    -- The list underneath is still open: refresh its rows
                    -- instead of leaving the deleted task on screen.
                    self:refreshMcpJobMenu(menu)
                    TranslationUI.showInfo(removed and _("已删除任务")
                        or _("删除任务失败"))
                end,
            },
        },
    }
    dialog = TextViewer:new{
        title = _("任务详情"),
        text = format_job_detail(job),
        -- Our own close/delete row replaces the default Close/Find buttons;
        -- the find bar is meaningless for a 40-line summary.
        buttons_table = buttons,
        show_menu = false,
    }
    UIManager:show(dialog)
end

function dualtranslate:buildMcpJobMenu(force)
    -- listJobs() reads meta.json per job; the menu builder runs twice per open
    -- (text_func + sub_item_table_func).  Reuse the result within the same
    -- second, and key the cache by what the filter would change.
    local now = os.time()
    local cache_key = string.format("%s|%s", tostring(self:mcpFiltersToCurrentBook()),
        tostring(self:currentBookPath()))
    local cached = self._mcp_job_menu_cache
    if not force and cached and cached.at == now and cached.key == cache_key then
        return cached.items
    end
    local jobs, total = self:mcpVisibleJobs()
    local items = {}
    if total == 0 then
        items[1] = { text = _("没有任务"), enabled = false }
    else
        -- The switch sits above the rows it decides, and stays reachable when
        -- the filter hides every one of them.
        items[#items + 1] = {
            text_func = function()
                return string.format(_("只显示本书任务（%d/%d）"), #jobs, total)
            end,
            checked_func = function() return self:mcpFiltersToCurrentBook() end,
            -- The callback rebuilds the page and repaints it itself; this only
            -- saves TouchMenu a second full re-render of the same rows.
            check_callback_updates_menu = true,
            callback = function(menu)
                self:setMcpFilterCurrentBook(not self:mcpFiltersToCurrentBook())
                if menu and menu.updateItems then
                    menu.item_table = self:buildMcpJobMenu(true)
                    menu:updateItems(1)
                end
            end,
        }
        if #jobs == 0 then
            items[#items + 1] = {
                text = string.format(_("本书没有任务（其他书 %d 个）"), total),
                enabled = false,
            }
        else
            -- Batch entry first, so it stays reachable when the list runs over
            -- more than one screen.  It manages exactly what this page lists:
            -- with the filter on, another book's tasks are not selected by
            -- "select all".
            items[#items + 1] = {
                text_func = function()
                    return string.format(_("批量管理（%d）"), #jobs)
                end,
                sub_item_table_func = function() return self:buildMcpBatchMenu() end,
            }
            -- Never name the loop variable "_": it shadows gettext.
            for position, job in ipairs(jobs) do
                local entry = job
                items[#items + 1] = {
                    text = job_row_text(position, entry),
                    -- A tap opens the detail dialog over the list; the list is
                    -- what the user comes back to after closing or deleting.
                    keep_menu_open = true,
                    callback = function(menu) self:showMcpJob(entry, menu) end,
                }
            end
        end
    end
    -- Parent level of the batch page: rebuilt when the user goes back, so a
    -- deleted task cannot come back from the cached table.
    items.needs_refresh = true
    items.refresh_func = function() return self:buildMcpJobMenu(true) end
    self._mcp_job_menu_cache = { at = now, items = items, key = cache_key }
    return items
end

-- Batch mode: the same task list as checkboxes.  Rows carry checked_func, and
-- TouchMenu re-renders such rows in place instead of closing the menu, which
-- is what makes ticking several tasks (and then deleting them) one trip.
--
-- keep_selection is only set by the rebuild-after-delete path: entering the
-- page from the task list starts a fresh run, so yesterday's ticks cannot ride
-- along into a delete the user is not expecting.
function dualtranslate:buildMcpBatchMenu(keep_selection)
    -- Same rows as the task list, so "select all" can never reach a book the
    -- user has filtered away.
    local jobs = self:mcpVisibleJobs()
    if not (keep_selection and self._mcp_batch_selected) then
        self._mcp_batch_selected = {}
    end
    -- The selection table is captured by every row below, so it is mutated in
    -- place and never replaced: select-all must not orphan the other closures.
    local selected = self._mcp_batch_selected

    -- Selections follow the jobs that still exist: one deleted from the detail
    -- dialog (or by dtctl) must not linger in the delete set.
    local live = {}
    for _, job in ipairs(jobs) do live[job.job_id] = true end
    for job_id in pairs(selected) do
        if not live[job_id] then selected[job_id] = nil end
    end

    -- Counted from the live list on every render, not from a build-time
    -- snapshot: TouchMenu re-renders text_func after each toggle.
    local function selected_count()
        local count = 0
        for _, job in ipairs(jobs) do
            if selected[job.job_id] then count = count + 1 end
        end
        return count
    end

    local items = {}
    if #jobs == 0 then
        items[1] = { text = _("没有任务"), enabled = false }
    else
        items[1] = {
            text_func = function()
                if selected_count() == #jobs then
                    return string.format(_("取消全选（%d）"), #jobs)
                end
                return string.format(_("全选（%d）"), #jobs)
            end,
            checked_func = function() return selected_count() == #jobs end,
            callback = function()
                if selected_count() == #jobs then
                    for job_id in pairs(selected) do selected[job_id] = nil end
                else
                    for _, job in ipairs(jobs) do selected[job.job_id] = true end
                end
            end,
        }
        for position, job in ipairs(jobs) do
            local entry = job
            items[#items + 1] = {
                text = job_row_text(position, entry),
                checked_func = function() return selected[entry.job_id] == true end,
                callback = function()
                    selected[entry.job_id] = not selected[entry.job_id] or nil
                end,
            }
        end
        items[#items + 1] = {
            text_func = function()
                local count = selected_count()
                if count == 0 then return _("删除所选任务…") end
                return string.format(_("删除所选（%d）…"), count)
            end,
            enabled_func = function() return selected_count() > 0 end,
            keep_menu_open = true,
            callback = function(menu) self:confirmDeleteMcpJobs(menu) end,
        }
    end
    items.batch = true
    items.needs_refresh = true
    -- Rebuild in place after a delete: keep what is still ticked.
    items.refresh_func = function() return self:buildMcpBatchMenu(true) end
    return items
end

-- Current selection, restricted to jobs that still exist on the page the user
-- is looking at, in list order.
function dualtranslate:selectedMcpJobIds()
    local selected = self._mcp_batch_selected or {}
    local ids = {}
    local jobs = self:mcpVisibleJobs()
    for _, job in ipairs(jobs) do
        if selected[job.job_id] then ids[#ids + 1] = job.job_id end
    end
    return ids
end

function dualtranslate:confirmDeleteMcpJobs(menu)
    local Mcp = require("dualtranslate_mcp")
    local ids = self:selectedMcpJobIds()
    if #ids == 0 then
        TranslationUI.showInfo(_("没有选中的任务"))
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(
            _("删除所选的 %d 个任务？\n任务文件（含原文段落）会从设备删除，"
                .. "已导入书中的译文不受影响。"), #ids),
        buttons = {{
            {
                text = _("取消"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("删除"),
                callback = function()
                    UIManager:close(dialog)
                    -- Removing a few dozen job dirs is one synchronous lfs
                    -- walk.  Paint the reason first, or a slow eMMC looks like
                    -- a dead tap.  Under ~8 tasks the pause is not felt.
                    local notice
                    if #ids > 8 then
                        notice = Notification:new{
                            text = string.format(_("正在删除 %d 个任务…"), #ids),
                            timeout = 2,
                        }
                        UIManager:show(notice)
                        UIManager:forceRePaint()
                    end
                    local removed = 0
                    for _, job_id in ipairs(ids) do
                        if Mcp.validJobId(job_id)
                            and Tools.rmtree(Mcp.jobDir(job_id)) then
                            if self._mcp_batch_selected then
                                self._mcp_batch_selected[job_id] = nil
                            end
                            removed = removed + 1
                        end
                    end
                    if notice then UIManager:close(notice) end
                    self:refreshMcpJobMenu(menu)
                    TranslationUI.showInfo(string.format(
                        _("已删除 %d 个任务"), removed))
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

-- 12.1: the MCP submenu.  Export reuses the chapter picker so the chapter
-- identity rules are shared with normal translation.
function dualtranslate:buildMcpMenu()
    local Mcp = require("dualtranslate_mcp")
    local items = {
        {
            text = _("导出所选章节…"),
            enabled_func = function() return self:isEpub() end,
            -- Keep the menu under the picker and the progress dialog: the
            -- export ends on a message box, and closing the menu would drop
            -- the user back into the book after every export.
            keep_menu_open = true,
            callback = function(menu)
                self:showChapterPicker({
                    start_text = _("导出任务（%d 章）"),
                    -- The export runs on the MCP engine whatever 翻译引擎 is
                    -- set to, so the picker's 已翻译 marks must reflect the
                    -- MCP providers (one per model), not the current engine.
                    engine = "mcp_external",
                    on_start = function(ranges, chapters)
                        self:confirmMcpExport(ranges, menu, chapters)
                    end,
                })
            end,
        },
        {
            -- 17 Q5: per-book terminology for the agent.  It lives under MCP
            -- because only the exported job consumes it; adding it does not
            -- touch the manifest or the CSS template.
            text_func = function()
                local data = self:loadBookGlossary()
                if data and data.corrupt then
                    return _("术语表（文件损坏）…")
                end
                local count = data and #data.terms or 0
                if count > 0 then
                    return string.format(_("术语表（%d 条）…"), count)
                end
                return _("术语表…")
            end,
            enabled_func = function() return self:isEpub() end,
            keep_menu_open = true,
            callback = function(menu) self:showGlossaryDialog(menu) end,
        },
        {
            text = _("风格指南…"),
            enabled_func = function() return self:isEpub() end,
            keep_menu_open = true,
            callback = function(menu) self:showStyleGuideDialog(menu) end,
        },
        {
            text_func = function()
                return string.format(_("任务列表（%d）"), Mcp.countJobs())
            end,
            sub_item_table_func = function() return self:buildMcpJobMenu() end,
        },
        {
            text = _("刷新外部译文"),
            enabled_func = function() return self:isEpub() end,
            keep_menu_open = true,
            callback = function()
                local signal = self:checkExternalReload(true)
                TranslationUI.showInfo(signal and _("已刷新外部译文")
                    or _("没有新的外部译文"))
            end,
        },
    }
    -- Back from the task list, and after an export, the count in the title has
    -- to be rebuilt rather than left as it was when the page was opened.
    items.needs_refresh = true
    items.refresh_func = function() return self:buildMcpMenu() end
    return items
end

-- The worker stops after a run of consecutive failures.  Microsoft Edge is
-- the only provider that works without a proxy, so the fallback is offered as
-- one explicit choice: the engine is never switched behind the user's back.
function dualtranslate:offerEngineFallback(item, result)
    local current = item.provider or self:getMode()
    local reason = tostring(result and result.error or "")
    local function give_up()
        item.switch_display_to = nil
        item.status = "failed"
        item.error = reason ~= ""
            and reason
            or _("当前翻译引擎不可用（可能无法访问 Google）")
        self:saveTranslationQueue()
        if item.silent then
            logger.warn("dualtranslate: engine unavailable, job parked:", item.error)
        else
            TranslationUI.showInfo(item.error
                .. _("\n可在「翻译引擎」菜单改用 Microsoft Edge（免费）"), 6)
        end
        self:startNextQueuedTranslation()
    end
    -- A modal card may only interrupt the reader when this job is the one the
    -- user is looking at.  A whole-book job keeps running while the user reads
    -- (or switches to) another book; asking "switch to Edge?" over that page
    -- would be an interruption about a book that is not on screen.  The
    -- queue row and the log carry the reason in that case.
    local on_screen = self.ui and self.ui.document
        and self.ui.document.file == item.book_path
    if current == "microsoft_free" or item.silent or not on_screen then
        give_up()
        return
    end
    local name = current
    for _, provider in ipairs(Providers.list or {}) do
        if provider.id == current then name = provider.name or current end
    end
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(
            _("当前引擎（%s）连续失败\n%s\n\n可能无法访问 Google。\n"
                .. "改用「Microsoft Edge（免费）」重试同一范围？"),
            tostring(name), reason),
        buttons = {{
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                    give_up()
                end,
            },
            {
                text = _("改用 Edge 重试"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dialog)
                    self:saveSetting("mode", "microsoft_free")
                    item.provider = "microsoft_free"
                    item.status = "queued"
                    item.error = nil
                    item.retry_count = 0
                    item.partial_retry_count = 0
                    item.switch_display_to = "microsoft_free"
                    self:saveTranslationQueue()
                    UIManager:show(Notification:new{
                        text = _("已改用 Microsoft Edge，继续翻译…"), timeout = 2 })
                    self:startNextQueuedTranslation()
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function dualtranslate:_runTranslation(item)
    local book_path = item.book_path
    local mode = item.mode or "all"
    local file_count = range_files(item.chapter_ranges)
    if file_count == 0 and type(item.chapter_indexes) == "table" then
        file_count = #item.chapter_indexes
    end
    -- Chapters, not files: the picker counts TOC entries and queued items from
    -- before this field existed fall back to the file count.
    local selection_count = tonumber(item.chapter_count) or file_count
    local function progress_title()
        if mode == "all" then return "正在翻译整本书…" end
        if mode == "selection" then
            if file_count > 1 then
                return string.format("正在翻译所选 %d 章（%d 个文件）…",
                    selection_count, file_count)
            end
            return string.format("正在翻译所选 %d 章…", selection_count)
        end
        return "正在翻译当前章节…"
    end
    self._active_translation_book = book_path
    local fragment = item.fragment
    local data_dir = DataStorage:getDataDir()
    local progress_path = data_dir .. "/cache/dualtranslate/progress_"
        .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999)) .. ".txt"
    Tools.mkdir_p(data_dir .. "/cache/dualtranslate")
    self._translation_progress = {
        active = true,
        mode = mode,
        book_path = book_path,
        item = item,
        path = progress_path,
        started_at = os.time(),
    }
    item.progress_path = progress_path
    -- This run's entry.  Every later write goes through this reference: the
    -- watchdog can release it early and the next job then replaces
    -- self._translation_progress, so a late-returning worker must not clear
    -- the *new* job's active flag (that would let a third job start too).
    local own_progress = self._translation_progress
    self:saveTranslationQueue()

    UIManager:scheduleIn(0.1, function()
        -- Only show a modal progress card when this is still the book the
        -- user started from. Queue workers for books that are no longer open
        -- stay completely in the background.
        local progress_dialog
        if not item.silent and self.ui and self.ui.document and self.ui.document.file == book_path then
            progress_dialog = ProgressbarDialog:new{
                title = progress_title(),
                subtitle = "准备中…\n点按进度条可取消，点按外部收起。",
                -- Drive the native progress bar with a fixed 0-100 scale;
                -- the real paragraph total is not known before the worker
                -- starts walking the spine.
                progress_max = 100,
                refresh_time_seconds = 0.5,
                dismissable = true,
            }
        end
        own_progress.dialog = progress_dialog
        -- Closing this status dialog must only hide it.  The worker keeps
        -- running and the queue can show the same dialog again later.
        if progress_dialog then
            local progress_on_close = progress_dialog.onCloseWidget
            function progress_dialog:onCloseWidget()
                self._dualtranslate_hidden = true
                -- Tapping outside hides the dialog through UIManager:close()
                -- without a refresh type, which enqueues nothing: the bar
                -- would stay painted over the page for the whole run.
                UIManager:setDirty(nil, "ui")
                return progress_on_close(self)
            end
            -- Tap on the dialog body opens the cancel-actions dialog; tap
            -- anywhere outside hides the progress dialog as before.  The
            -- native ProgressbarDialog treats the whole screen as one tap
            -- zone, so the hit test happens here in the handler (ges.pos is
            -- the tap coordinate, self[1].dimen the dialog body's box).
            function progress_dialog:onTapClose(arg, ges)
                if ges and ges.pos and self[1] and self[1].dimen
                    and ges.pos:intersectWith(self[1].dimen) then
                    local action_dialog
                    action_dialog = ButtonDialog:new{
                        title = "翻译进行中，要取消吗？\n已翻译部分会保留，可随时重翻。",
                        buttons = {{
                            {
                                text = "返回",
                                id = "close",
                                callback = function() UIManager:close(action_dialog) end,
                            },
                            {
                                text = "取消翻译",
                                is_enter_default = true,
                                callback = function()
                                    UIManager:close(action_dialog)
                                    UIManager:close(progress_dialog, "partial")
                                    dualtranslate:cancelTranslation(item)
                                    UIManager:show(Notification:new{
                                        text = "正在停止翻译…\n（当前批次完成后停止）",
                                        timeout = 2,
                                    })
                                    UIManager:setDirty("all", "ui")
                                end,
                            },
                        }},
                    }
                    UIManager:show(action_dialog)
                    return true
                end
                -- Outside the body: keep the native hide behavior (including
                -- its home_pending handling).
                return ProgressbarDialog.onDismiss(self)
            end
            progress_dialog:show()
        end

        local progress_active = true
        local function update_progress()
            if not progress_active then return end
            -- Stop as soon as this run's entry is gone (the next job replaced
            -- it) or released (watchdog): a live chain would otherwise write
            -- this run's percentage into the next job's entry, and would
            -- outlive its own dialog.
            if self._translation_progress ~= own_progress or not own_progress.active then
                progress_active = false
                return
            end
            if not progress_dialog then return end
            if progress_dialog._dualtranslate_hidden then
                -- Keep the chain alive while the card is hidden.  Hiding only
                -- flips this flag, and reopening it (queue row, or tapping
                -- the same command again) re-runs the native init(), which
                -- rebuilds the bar at 0%: a dead chain would leave the
                -- reopened dialog frozen at 0% for the rest of the run.
                -- Nothing is read from disk on these ticks.
                UIManager:scheduleIn(1, update_progress)
                return
            end
            local file = io.open(progress_path, "r")
            local line = file and file:read("*l") or nil
            if file then file:close() end
            if line then
                local current, total, translated, failed, chapter, chapters = line:match(
                    "^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$")
                current, total = tonumber(current), tonumber(total)
                if current and total then
                    item.current = current
                    item.total = total
                    item.translated = tonumber(translated) or 0
                    item.failed = tonumber(failed) or 0
                    local percentage = total > 0 and math.floor(current * 100 / total + 0.5) or 0
                    -- Remembered so reopenTranslationProgress can restore the
                    -- bar instead of showing init()'s 0% until the next tick.
                    own_progress.last_percentage = percentage
                    progress_dialog.title = string.format("%s  %d%%",
                        progress_title(), percentage)
                    progress_dialog.subtitle = string.format(
                        "段落：%d/%d\n已翻译：%d    失败：%d\n文件：%d/%d\n点按进度条可取消，点按外部收起。",
                        current, total, tonumber(translated) or 0,
                        tonumber(failed) or 0, tonumber(chapter) or 0, tonumber(chapters) or 0)
                    pcall(function()
                        -- Update the existing TextWidgets in place instead of
                        -- rebuilding the whole dialog tree every 0.5s.
                        -- ProgressbarDialog:init() builds self[1] as a
                        -- FrameContainer around a VerticalGroup whose first two
                        -- children are the title and subtitle TextWidgets.
                        local frame = progress_dialog[1]
                        local group = frame and frame[1]
                        if group and group[1] and group[1].setText then
                            group[1]:setText(progress_dialog.title)
                        end
                        if group and group[2] and group[2].setText then
                            group[2]:setText(progress_dialog.subtitle)
                        end
                        progress_dialog:reportProgress(percentage)
                        UIManager:setDirty(progress_dialog, "ui")
                    end)
                end
            end
            UIManager:scheduleIn(0.5, update_progress)
        end
        UIManager:scheduleIn(0.5, update_progress)

        local resume_ok, wrapped_ok = Trapper:wrap(function()
            -- Passing a table avoids Trapper creating its default full-screen
            -- dismiss widget. Page touches remain usable and cannot cancel the
            -- background task.
            local trap_widget = {}
            -- Do not fork an already-open SQLite connection.  The child opens
            -- its own WAL connection and the reader may reopen one later.
            pcall(function() self.cache:close() end)
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                -- Everything the worker touches (provider settings, language
                -- resolution, path helpers) is evaluated inside the pcall.
                -- A failure in any of them must surface as a readable error,
                -- never as a silently lost subprocess result ("无法生成本书
                -- 译文缓存" masks the real cause).
                local ok, info = pcall(function()
                    -- The EPUB engine is cached by main.lua; retry the loader
                    -- once in case init ran before self.path was available.
                    -- A missing engine must surface as a readable message,
                    -- never as an "index a boolean" crash.
                    local Epub = self.epub or self:loadEpubModule()
                    if type(Epub) ~= "table" then
                        return nil, "DualTranslate 模块加载失败：dualtranslate_epub.lua 缺失或损坏，请删除旧插件目录后重新安装"
                    end
                    -- 13.4: a resumed job keeps the engine it was enqueued
                    -- with; only legacy items without a provider fall back
                    -- to the currently selected mode (and say so).
                    local provider = item.provider
                    if not provider or provider == "" then
                        provider = self:getMode()
                        logger.warn("dualtranslate: queue item without provider, using current mode:", provider)
                    end
                    local run_ok, run_info, run_err = pcall(Epub.translate_overlay, Epub, {
                        book_path = book_path,
                        mode = mode,
                        fragment = fragment,
                        span = item.span,
                        chapter_ranges = item.chapter_ranges,
                        chapter_indexes = item.chapter_indexes,
                        source_lang = self:getSourceLang(),
                        target_lang = self:getTargetLang(),
                        provider = provider,
                        translate = function(text, context)
                            return self:translateTextForEpub(text, context)
                        end,
                        translate_batch = function(texts, contexts)
                            return self:translateTextBatchForEpub(texts, contexts)
                        end,
                        progress_path = progress_path,
                        cancel_path = progress_path .. ".cancel",
                        output_dir = self:getBookCacheDirectory(book_path),
                    })
                    if not run_ok then return nil, "翻译过程异常：" .. tostring(run_info) end
                    if not run_info then return nil, run_err end
                    return run_info
                end)
                if not ok then
                    logger.warn("dualtranslate: translate_overlay worker error:", info)
                    return { error = tostring(info) }
                end
                return info
            end, trap_widget)

            if not completed then
                local was_hidden = progress_dialog and progress_dialog._dualtranslate_hidden
                progress_active = false
                own_progress.active = false
                -- The cancel flag file is only meaningful while the worker is
                -- alive; drop it so a later job never sees a stale flag.
                os.remove(progress_path .. ".cancel")
                item.status = "failed"
                item.error = "翻译已中断"
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog, "partial") end)
                if was_hidden and not self._translation_retry_after_hide then
                    -- A dismissed status widget must not turn into a false
                    -- interruption.  Retry once in the background because
                    -- older KOReader builds may deliver that tap to the
                    -- subprocess trap as well.
                    self._translation_retry_after_hide = true
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    UIManager:scheduleIn(0.2, function()
                        self._translation_retry_after_hide = nil
                        self:startNextQueuedTranslation()
                    end)
                elseif mode == "all" then
                    -- Whole-book jobs are background jobs.  A transient
                    -- provider error or a reader restart must never cover the
                    -- page with a modal interruption message.  Keep the
                    -- resumable failed entry in the queue for an explicit
                    -- retry from the queue menu.
                    self._translation_retry_after_hide = nil
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    logger.warn("dualtranslate: background full-book translation interrupted; queued to resume")
                    UIManager:scheduleIn(2, function() self:startNextQueuedTranslation() end)
                else
                    self._translation_retry_after_hide = nil
                    if not item.silent then
                        UIManager:show(Notification:new{ text = "翻译已中断。", timeout = 3 })
                    end
                    self:startNextQueuedTranslation()
                end
                return
            end
            if not result or not result.output then
                progress_active = false
                own_progress.active = false
                -- A killed translation subprocess can return no serialized
                -- value at all (most often after a transient memory spike
                -- from a previous interrupted job). Give a whole-book job
                -- one automatic clean retry instead of turning it into a
                -- permanent false failure.
                local retry_count = tonumber(item.retry_count) or 0
                if mode == "all" and retry_count < 1 then
                    item.retry_count = retry_count + 1
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    pcall(function() UIManager:close(progress_dialog, "partial") end)
                    logger.warn("dualtranslate: full-book worker returned no result; retrying once")
                    UIManager:scheduleIn(1, function()
                        self:startNextQueuedTranslation()
                    end)
                    return
                end
                item.status = "failed"
                item.error = (result and result.error)
                    or "翻译进程未返回结果（可能内存不足或进程被终止），请查看日志后重试"
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog, "partial") end)
                if mode == "all" then
                    -- Do not interrupt reading for a background full-book
                    -- failure.  The queue entry keeps the error and can be
                    -- retried later; the log is available for diagnosis.
                    logger.warn("dualtranslate: background full-book translation failed:", item.error)
                elseif not item.silent then
                    UIManager:show(Notification:new{
                        text = (result and result.error)
                            or "翻译进程未返回结果（可能内存不足或进程被终止）。\n请查看日志后重试。",
                        timeout = 5,
                    })
                end
                self:startNextQueuedTranslation()
                return
            end
            progress_active = false
            own_progress.active = false
            if result.cancelled then
                -- The user asked the queue to cancel this job.  Keep the
                -- checkpoint already written, drop the task, and move on.
                os.remove(progress_path .. ".cancel")
                for index, queued_item in ipairs(self._translation_queue or {}) do
                    if queued_item == item then
                        table.remove(self._translation_queue, index)
                        break
                    end
                end
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog, "partial") end)
                -- Cancelling means "stop translating this book now".  Leaving
                -- 逐章模式 armed turned the next page turn into the same job
                -- (the box stays checked); the flag also keeps a reopened book
                -- from auto-resuming this session without a fresh decision.
                self._page_translation_follow_active = nil
                self._page_translation_last_fragment = nil
                self._page_translation_follow_cancelled = true
                if not item.silent then
                    UIManager:show(Notification:new{ text = "已取消翻译。", timeout = 2 })
                end
                self:startNextQueuedTranslation()
                return
            end
            if item.switch_display_to and (tonumber(result.translated) or 0) > 0 then
                -- A fallback run wrote a different provider; show it, or the
                -- user keeps looking at the layer that just failed.
                local pid = item.switch_display_to
                item.switch_display_to = nil
                local switched = pcall(Store.setDisplayProvider, book_path,
                    self:getTargetLang(), pid)
                if switched then self:refreshDocumentStyles() end
            end
            if result.engine_down then
                -- The worker stopped after N consecutive failures: the engine
                -- is unreachable, not the book.  Offer the one provider that
                -- needs no proxy instead of grinding through the remaining
                -- chapters at one timeout each.
                progress_active = false
                own_progress.active = false
                self._page_translation_follow_active = nil
                pcall(function() UIManager:close(progress_dialog, "partial") end)
                self:offerEngineFallback(item, result)
                return
            end
            local result_failed = tonumber(result.failed) or 0
            if mode == "all" and result_failed > 0 then
                item.output = result.output
                item.failed = result_failed
                local partial_retry = tonumber(item.partial_retry_count) or 0
                if partial_retry < 1 then
                    item.partial_retry_count = partial_retry + 1
                    item.status = "queued"
                    item.error = "有段落翻译失败，正在自动续跑"
                    self:saveTranslationQueue()
                    pcall(function() UIManager:close(progress_dialog, "partial") end)
                    UIManager:scheduleIn(1, function()
                        self:startNextQueuedTranslation()
                    end)
                    return
                end
                item.status = "failed"
                item.error = string.format("仍有 %d 个段落未翻译，可从队列重试", result_failed)
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog, "partial") end)
                self:startNextQueuedTranslation()
                return
            end
            item.status = "done"
            item.output = result.output
            item.current = result.translated or item.current
            item.translated = result.translated or item.translated
            item.failed = result.failed or item.failed
            item.error = nil
            -- Chapter-mode follow: reaching the last spine chapter ends the
            -- session, otherwise page turns would keep re-queueing an
            -- already-complete final chapter forever.  Only span mode drives
            -- follow; a one-shot selection never arms or disarms it (7.4).
            -- A span job narrowed to one TOC entry says nothing about the rest
            -- of that last file, so it must not disarm: the remaining entries
            -- still need to be scheduled as they are reached.
            -- A whole-file range ({index = n}) is the fallback, not a
            -- narrowing: it says the last chapter is done, so follow must end.
            local narrowed = false
            if type(item.chapter_ranges) == "table" and item.chapter_ranges[1] then
                local first = item.chapter_ranges[1]
                narrowed = first.from ~= nil or first.to ~= nil
            end
            if mode == "span" and result.last_chapter and not narrowed then
                self._page_translation_follow_active = nil
            end
            self:saveTranslationQueue()
            -- Drop the finished entry from memory too; it is already
            -- excluded from disk and from the queue dialog, and keeping it
            -- would accumulate one dead entry per finished job.
            for index, queued_item in ipairs(self._translation_queue or {}) do
                if queued_item == item then
                    table.remove(self._translation_queue, index)
                    break
                end
            end
            pcall(function() UIManager:close(progress_dialog, "partial") end)
            if not item.silent and not item.auto then
                local done_text = string.format("翻译完成\n已翻译段落：%d\n失败段落：%d",
                    result.translated or 0, result.failed or 0)
                if (result.failed or 0) > 0 then
                    done_text = done_text .. "\n失败段落将在下次翻译时自动重试"
                end
                UIManager:show(Notification:new{
                    text = done_text,
                    timeout = 3,
                })
            end
            UIManager:scheduleIn(0.2, function()
                self:scheduleTranslationStyleRefresh(book_path)
                self:startNextQueuedTranslation()
            end)
        end)
        -- Trapper:wrap runs the worker in a coroutine and reports failures as
        -- resume_ok == false (coroutine error) or wrapped_ok == false (error
        -- caught by Trapper's xpcall).  On some platforms (Android in
        -- particular) a failing subprocess API would otherwise leave
        -- _translation_progress.active stuck at true, which makes every new
        -- translation queue forever without ever starting.  Recover here.
        if resume_ok == false or wrapped_ok == false then
            progress_active = false
            own_progress.active = false
            item.status = "failed"
            item.error = "翻译进程异常退出，请查看日志后重试"
            self:saveTranslationQueue()
            pcall(function() UIManager:close(progress_dialog, "partial") end)
            logger.warn("dualtranslate: translation worker failed:", wrapped_ok)
            if not item.silent then
                UIManager:show(Notification:new{
                    text = "翻译进程异常退出，已从队列中移除。\n请查看日志后重试。",
                    timeout = 4,
                })
            end
            self:startNextQueuedTranslation()
        end
    end)
end

function dualtranslate:reopenTranslationProgress()
    local progress = self._translation_progress
    if not progress or not progress.active or not progress.dialog then return false end
    local dialog = progress.dialog
    -- Already on screen (the queue menu was merely covering it): nothing to
    -- reopen, the caller has closed the menu.
    if not dialog._dualtranslate_hidden then return true end
    local ok, err = pcall(function()
        dialog._dualtranslate_hidden = false
        dialog:init()
        -- "ui": init() rebuilt the widget tree, so the show itself has to
        -- repaint; the dialog had been removed from the stack when hidden.
        UIManager:show(dialog, "ui")
    end)
    if not ok then
        -- Otherwise the flag says "visible" while nothing is on screen, and
        -- every later call would report success without reopening anything.
        dialog._dualtranslate_hidden = true
        logger.warn("dualtranslate: reopening the progress dialog failed:", tostring(err))
        return false
    end
    -- init() rebuilt the bar at 0%; put the last known percentage back (same
    -- 0-100 scale as progress_max) so the reopened card matches the numbers in
    -- its own title instead of showing an empty bar.  A failure here only
    -- skips that restore: the card is already up and the next poll — at most a
    -- second away while the chain was hidden — writes the real value anyway.
    if progress.last_percentage then
        pcall(function() dialog:reportProgress(progress.last_percentage) end)
    end
    return true
end

function dualtranslate:isCacheEnabled()
    return self:getSetting("enable_cache", true)
end

function dualtranslate:inlineStyleMenu(key, title, choices)
    local items = {}
    for _, choice in ipairs(choices) do
        -- Lua 5.1: capture the per-iteration value; otherwise every menu
        -- entry's checked_func/callback would see the last choice.
        local value, label = choice.value, choice.label
        table.insert(items, {
            text = label,
            radio = true,
            checked_func = function() return self:getSetting(key) == value end,
            callback = function()
                self:saveSetting(key, value)
                self:refreshDocumentStyles()
            end,
        })
    end
    return {
        text = title,
        sub_item_table = items,
    }
end

function dualtranslate:getInlineFontSize()
    local value = tostring(self:getSetting("inline_font_size", 16))
    local number = tonumber(value:match("[%d%.]+")) or 16
    if value:match("%%$") then
        number = 16 * number / 100
    elseif value:match("em$") then
        number = 16 * number
    end
    return math.floor(number + 0.5)
end

function dualtranslate:getInlineFontCssSize()
    -- Treat 16 as the document's 1em base, matching KOReader's numeric font
    -- setting: 20 means 125% of the body text.
    return string.format("%.4gem", self:getInlineFontSize() / 16)
end

-- Translation font family.  "" means "follow the paragraph" (no font-family
-- in the generated CSS, so the ::after node inherits the source paragraph's
-- font); anything else is a CSS font stack injected into the translation CSS.
-- Semicolons/braces are stripped so a hand-edited value can never break the
-- generated stylesheet.
function dualtranslate:getInlineFontFamily()
    local value = tostring(self:getSetting("inline_font_family", ""))
    return value:gsub("[;{}]", "")
end

function dualtranslate:getInlineFontFamilyLabel()
    local value = self:getInlineFontFamily()
    if value == "" then return "跟随段落" end
    if value == "sans-serif" then return "无衬线" end
    if value == "serif" then return "衬线" end
    if value == "monospace" then return "等宽" end
    return value
end

function dualtranslate:showFontFamilyDialog()
    local dialog
    dialog = InputDialog:new{
        title = "自定义译文字体",
        input = self:getInlineFontFamily(),
        input_hint = "输入 CSS 字体栈，如：Noto Serif CJK SC, serif",
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    if value then
                        value = value:gsub("[;{}]", "")
                        self:saveSetting("inline_font_family", value)
                        self:refreshDocumentStyles()
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function dualtranslate:buildFontFamilyMenu()
    local items = {
        {
            text = "跟随段落（默认）",
            radio = true,
            checked_func = function() return self:getInlineFontFamily() == "" end,
            callback = function()
                self:saveSetting("inline_font_family", "")
                self:refreshDocumentStyles()
            end,
        },
    }
    -- Use KOReader's own font registry (the same face list as the built-in
    -- font menu in 版面→字体): CREngine family names are directly usable as
    -- CSS font-family values.  A device with no CRE engine (unlikely) simply
    -- degrades to the default + custom entry.
    local ok, faces = pcall(function()
        local cre = require("document/credocument"):engineInit()
        return cre.getFontFaces()
    end)
    if ok and faces and #faces > 0 then
        local FontList = require("fontlist")
        local seen = {}
        table.sort(faces)
        for _, face in ipairs(faces) do
            -- Lua 5.1: capture the per-iteration value.
            local face_copy = face
            if not seen[face_copy] then
                seen[face_copy] = true
                local text = face_copy
                -- Prefer the localized display name when CREngine can map the
                -- face back to a font file (mirrors readerfont.lua).
                local ok_name, filename, faceindex = pcall(function()
                    return cre.getFontFaceFilenameAndFaceIndex(face_copy)
                end)
                if ok_name and filename and faceindex then
                    local localized = FontList:getLocalizedFontName(filename, faceindex)
                    if localized then text = localized end
                end
                table.insert(items, {
                    text = text,
                    radio = true,
                    checked_func = function() return self:getInlineFontFamily() == face_copy end,
                    callback = function()
                        self:saveSetting("inline_font_family", face_copy)
                        self:refreshDocumentStyles()
                    end,
                })
            end
        end
    end
    table.insert(items, {
        text = "自定义字体…",
        callback = function() self:showFontFamilyDialog() end,
    })
    return items
end

-- Microsoft Edge accepts an array of texts and returns one translation per
-- item. Batch short paragraphs to reduce network round trips while keeping
-- the original paragraph boundaries for EPUB insertion.
function dualtranslate:translateTextBatchForEpub(texts, contexts)
    local mode = self:getMode()
    local function context_at(index)
        return contexts and contexts[index] or nil
    end
    -- No batch endpoint: say so instead of looping here.  The caller
    -- (translate_overlay) walks the same paragraphs one by one right after a
    -- failed batch, and that is where consecutive failures are counted.  Doing
    -- the serial loop here hid those failures: 48 paragraphs x a 5 s timeout
    -- per request is four minutes of "0%" before the engine failover could
    -- even see the first error.
    if not Providers.has_batch(mode) then
        -- No second value on purpose: translate_overlay keeps the first error
        -- it sees (first_error = first_error or ...), so returning a string
        -- here would replace the real per-paragraph failure (timeout, 429)
        -- with "this engine has no batch endpoint" in the failover dialog.
        return nil
    end

    local results = {}
    local pending = {}
    local first_error
    local limit = self:getTranslationChunkLimit()
    for index, text in ipairs(texts) do
        if #text > limit then
            local translated, err = self:translateTextForEpub(text, context_at(index))
            if translated then
                results[index] = translated
            else
                results[index] = false
                first_error = first_error or err
            end
        elseif self:isCacheEnabled() then
            local cached = self.cache:lookupForBook(self._active_translation_book,
                self:getSourceLang(), self:getTargetLang(), text, mode)
            if cached and cached.translated_text then
                results[index] = cached.translated_text
                local meta = context_meta(context_at(index))
                if meta and self.cache.insertLocationRow then
                    self.cache:insertLocationRow(self._active_translation_book,
                        self:getSourceLang(), self:getTargetLang(), text,
                        cached.translated_text, mode, meta)
                end
            else
                table.insert(pending, { index = index, text = text,
                    context = context_at(index) })
            end
        else
            table.insert(pending, { index = index, text = text,
                context = context_at(index) })
        end
    end

    local limits = Providers.batch_limits(mode) or { items = 12, bytes = 4000 }
    local pending_texts = {}
    for index, item in ipairs(pending) do pending_texts[index] = item.text end
    for _, group in ipairs(Providers.split_groups(pending_texts, limits)) do
        local batch, batch_texts = {}, {}
        for _, pending_index in ipairs(group) do
            local item = pending[pending_index]
            table.insert(batch, item)
            table.insert(batch_texts, item.text)
        end
        local translated, err
        translated, err = Providers.translate_batch(mode,
            batch_texts, self:getSourceLang(), self:getTargetLang())
        if not translated then
            -- One immediate retry handles transient resets without falling
            -- back to a slow request for every paragraph.
            translated, err = Providers.translate_batch(mode,
                batch_texts, self:getSourceLang(), self:getTargetLang())
        end
        if not translated then
            -- A batch request can time out even though the single-text Edge
            -- endpoint is still responsive. Retry each item only after the
            -- two batch attempts failed; this keeps normal translation fast
            -- while allowing a long English book to recover from a transient
            -- batch failure instead of producing no EPUB at all.
            if err and (err.code ~= nil or err.message) then
                for _, item in ipairs(batch) do
                    local single, single_err = self:translateTextForEpub(item.text, item.context)
                    if single then
                        results[item.index] = single
                    else
                        results[item.index] = false
                        first_error = first_error or single_err or err
                    end
                end
            else
                for _, item in ipairs(batch) do results[item.index] = false end
                first_error = first_error or err or { message = "翻译服务连接失败" }
            end
        else
            for offset, item in ipairs(batch) do
                local value = translated[offset]
                if value and value ~= "" then
                    results[item.index] = value
                    if self:isCacheEnabled() then
                        self.cache:storeForBook(self._active_translation_book,
                            self:getSourceLang(), self:getTargetLang(), item.text,
                            value, mode, context_meta(item.context))
                    end
                else
                    results[item.index] = false
                    first_error = first_error or { message = "翻译服务返回了空译文" }
                end
            end
        end
    end
    return results, first_error
end

-- Translation-completion style refresh, throttled: consecutive chapters that
-- finish close together are merged into a single re-render, instead of each
-- triggering a full CREngine re-layout (which shows up as a full-screen
-- flicker on e-ink devices like the Kindle).  Setting changes and manual
-- toggles still refresh immediately via refreshDocumentStyles().
function dualtranslate:scheduleTranslationStyleRefresh(book_path)
    if self._style_refresh_scheduled then return end
    self._style_refresh_scheduled = true
    UIManager:scheduleIn(1.5, function()
        self._style_refresh_scheduled = nil
        if self.ui and self.ui.document and self.ui.document.file == book_path then
            self:saveSetting("translation_visible", true)
            self:refreshDocumentStyles()
        end
    end)
end

-- Apply the translation layer styles (non-destructive overlay) without
-- touching the EPUB archive.  Rebuilding this CSS only changes the visible
-- layer; the reading position and the document are left alone.
function dualtranslate:refreshDocumentStyles()
    local document = self.ui and self.ui.document
    local typeset = self.ui and self.ui.typeset
    if not document or not typeset or not document.setStyleSheet then return false end
    local css = typeset.css or document.default_css or ""
    local tweaks = self.ui.styletweak and self.ui.styletweak:getCssText() or ""
    local color = tostring(self:getSetting("inline_color", "#666666"))
    if not color:match("^#%x%x%x%x%x%x$") then color = "#666666" end
    local font_size = self:getInlineFontCssSize()
    local font_family = self:getInlineFontFamily()
    local plugin_enabled = self:isPluginEnabled()
    local book_path = document.file
    local overlay_css = ""
    if book_path then
        local overlay_path = self:getTranslationOverlayPath(book_path)
        if not Overlay.exists(overlay_path) then
            -- Pre-migration v2 book: buildCss resolves the legacy overlay
            -- from the book directory.
            overlay_path = self:getBookCacheDirectory(book_path)
        end
        -- Visibility (translation_visible + plugin_enabled) is enforced here:
        -- buildCss omits the ::after rules entirely when hidden, so the
        -- source text stays untouched and no empty layer is laid out.
        -- Provider/fallback choices are resolved inside buildCss from the
        -- manifest (auto/manual), never from a global setting.
        overlay_css = Overlay.buildCss(overlay_path, {
            translation_visible = plugin_enabled
                and self:getSetting("translation_visible", true) == true
                and not self._translation_stale,
            translation_color = color,
            translation_size = font_size,
            translation_font_family = font_family,
        })
    end
    -- Keep these markers on the document object, which survives the rerender
    -- that setStyleSheet itself initiates.  A plugin instance may be rebuilt
    -- during that rerender, so an instance-local flag cannot stop the loop.
    -- Compare the two pieces before concatenating: the overlay sheet is
    -- megabytes, and holding a second concatenated copy on the document just
    -- doubles the Lua-side cost for no benefit.  The stored overlay string is
    -- normally the same object the CSS cache already owns.
    if document._dualtranslate_overlay_css == overlay_css
        and document._dualtranslate_tweaks == tweaks then
        return true
    end
    local extra_css = tweaks .. "\n" .. overlay_css
    document._dualtranslate_overlay_css = overlay_css
    document._dualtranslate_tweaks = tweaks
    local ok = pcall(function()
        document:setStyleSheet(css, extra_css)
    end)
    if not ok then
        document._dualtranslate_overlay_css = nil
        document._dualtranslate_tweaks = nil
    else
        -- setStyleSheet triggers a full re-render.  The reader's pagination
        -- state (page_states in scroll mode, current_page in paging mode) is
        -- not rebuilt by that re-render, so stale page numbers can make the
        -- next page turn mis-fire EndOfBook ("end of book" dialog) while the
        -- book is still mid-way.  Re-sync the way the reader itself does
        -- after a layout change (rotation / resize): refresh the current
        -- page, recalculate the view, then rebuild the scroll page states.
        UIManager:nextTick(function()
            local ui = self.ui
            if not ui or not ui.view then return end
            pcall(function()
                local new_page = document:getCurrentPage()
                if new_page then
                    ui:handleEvent(Event:new("PageUpdate", new_page))
                end
                ui.view:recalculate()
                ui:handleEvent(Event:new("InitScrollPageStates"))
            end)
        end)
    end
    return ok
end


function dualtranslate:showInlineFontSpin()
    local spin
    spin = SpinWidget:new{
        title_text = "译文字号",
        info_text = "点按 - / + 调整，或点按数字直接输入（8–40）",
        value = self:getInlineFontSize(),
        value_min = 8,
        value_max = 40,
        value_step = 1,
        precision = "%d",
        callback = function()
            local size = math.floor(spin.value_widget.value + 0.5)
            size = math.max(8, math.min(40, size))
            self:saveSetting("inline_font_size", size)
            self:refreshDocumentStyles()
        end,
    }
    UIManager:show(spin)
end

end

return Reader
