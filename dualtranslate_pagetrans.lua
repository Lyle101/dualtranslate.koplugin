-- Per-page translation, document-flow edition.
--
-- Instead of painting framebuffer overlays with a line cap, page translation
-- now reuses the full-book overlay pipeline: translating the current chapter
-- writes entries into the per-book v3 overlay (manifest.json + entries/),
-- which refreshDocumentStyles exposes to CREngine as generated ::after CSS.
-- The translation therefore lives in the document flow exactly like the
-- book-level overlay: complete text, toggleable visibility, persistent
-- across reopens, no line limit.
--
-- Exposed as the "逐章模式" checkbox next to "翻译本书".  Checking it arms the
-- follow mode directly: the next page turn translates the entry being read,
-- and every entry reached afterwards, through the serial queue (the job is
-- flagged `auto` so the per-chapter completion notice stays quiet).  Tapping
-- "翻译当前章节" does the same for the current entry without waiting for a
-- page turn.  Already translated paragraphs are reused by the overlay merge
-- and never requested again.
--
-- Arming on the checkbox (not only on "翻译当前章节") matches what the label
-- promises.  Before, ticking it and turning pages did nothing — the
-- preference was silently inert until a second, unrelated action.
local UIManager = require("ui/uimanager")
local Overlay = require("dualtranslate_overlay")
local TranslationUI = require("dualtranslate_ui")
local _ = require("gettext")

local PageTrans = {}

function PageTrans.attach(plugin)
    plugin.isPageTranslationEnabled = function()
        return plugin:getSetting("page_translation", false) == true
    end

    -- Checking "逐章模式" arms follow right away: the next page turn starts
    -- with the entry being read (the key is cleared, so the guard does not
    -- skip it).  Unchecking disarms, so page turns stop scheduling.
    plugin.togglePageTranslation = function(self, menu)
        local enabled = not self:isPageTranslationEnabled()
        self:saveSetting("page_translation", enabled)
        if enabled then
            self._page_translation_follow_active = true
            self._page_translation_last_fragment = nil
            -- Re-checking the box is an explicit decision to follow again.
            self._page_translation_follow_cancelled = nil
            -- Warm the outline after the toast is on screen (one cold parse
            -- with its notice) instead of freezing the first page turn that
            -- needs the entry table.
            if self.getBookOutline then
                UIManager:scheduleIn(0.5, function()
                    pcall(self.getBookOutline, self)
                end)
            end
            TranslationUI.showInfo(_("逐章模式已开启：翻页时自动翻译当前与后续章节"))
        else
            self._page_translation_follow_active = nil
            TranslationUI.showInfo(_("逐章模式已关闭：翻页不再自动翻译"))
        end
        UIManager:setDirty("all", "ui")
        if menu and menu.updateItems then menu:updateItems() end
    end

    -- Called from onPageUpdate / onPosUpdate / onDocumentRerendered with
    -- silent=false (auto-continue keeps the progress dialog), and after
    -- translateCurrentChapter when follow mode was armed.  The `auto` flag
    -- passed on to the job is what keeps the per-chapter completion notice
    -- quiet — not `silent`.
    -- Queues the current chapter when this book has no complete overlay yet.
    -- The serial queue deduplicates by book, and the overlay merge is
    -- idempotent, so repeated page turns never re-translate already-covered
    -- paragraphs.
    plugin.maybeSchedulePageTranslation = function(self, silent)
        -- 7.4: MCP providers are import-driven; never auto-schedule pages
        -- for them (no mcp_external option exists before P3).
        if self:getMode() == "mcp_external" then return end
        if not self:isPageTranslationEnabled() then return end
        -- Only auto-continue while a follow session was explicitly started
        -- from "翻译当前章节" (or its chapter-mode variant).
        if not self._page_translation_follow_active then return end
        if not self:isEpub() then return end
        -- Never compete with a running full-book/chapter worker writing
        -- overlay.json.
        if self._translation_progress and self._translation_progress.active then
            return
        end
        local book_path = self.ui and self.ui.document and self.ui.document.file
        if not book_path then return end
        -- Which TOC entry the page is in.  A file holding several chapters is
        -- read chapter by chapter now, so the guard has to identify the entry
        -- ("12.3"), not just the file.
        local range, key, rows = self:currentChapterRange()
        -- No entry range (no outline, no CREngine probing): the chapter index
        -- is still enough to keep the old whole-file guard.
        if not key then key = self:getCurrentFragment() end
        local fragment_key = key or "__unknown_fragment__"
        if fragment_key == self._page_translation_last_fragment then return end
        -- The whole book is already translated by the *current generation
        -- engine* (7.4): completeness is judged per provider, so a book
        -- finished with one engine still schedules for another.  Cache the
        -- index briefly so ordinary page turns do not re-parse it each time.
        local dir = self:getBookCacheDirectory(book_path)
        local cached = self._page_translation_overlay_state
        local now = os.time()
        if not cached or cached.path ~= dir or now - cached.at > 3 then
            local index = Overlay.loadBookIndex(dir)
            -- A replaced copy of the book must not drive the skip logic: its
            -- chapters describe text that is no longer there.
            if index and type(Overlay.isStale) == "function"
                and Overlay.isStale(index, book_path) then
                return
            end
            local state = index and index.providers
                and index.providers[self:getMode()]
            cached = {
                path = dir,
                complete = state and state.complete == true or false,
                chapters = state and state.chapters or nil,
                entry_ranges = state and state.entry_ranges or nil,
                at = now,
            }
            self._page_translation_overlay_state = cached
        end
        if cached.complete then return end
        -- Chapter-mode runs never set complete, so "this chapter is already
        -- translated" is tracked through the provider's chapters list.
        -- partial_chapters/failed_chapters are deliberately NOT treated as
        -- covered: those chapters must stay re-queueable (7.4).
        local chapter_index = range and range.index or tonumber(fragment_key)
        if chapter_index and cached.chapters and type(cached.chapters) == "table" then
            for _, covered in ipairs(cached.chapters) do
                if covered == chapter_index then return end
            end
        end
        -- Entry-level skip: a finished range inside a shared file marks only
        -- its own entries, so turning into an untranslated neighbour still
        -- schedules it.  This is what makes page-turn follow work inside one
        -- XHTML instead of stopping at the first translated entry.
        if rows and chapter_index and cached.entry_ranges then
            local Coverage = require("dualtranslate_coverage")
            local full = Coverage.entry_states(
                { entry_ranges = cached.entry_ranges }, { [chapter_index] = rows })
            if full[fragment_key] then return end
        end
        -- Queue the current chapter.  `silent` is forwarded as-is (every
        -- production caller passes false, so auto-continue shows the same
        -- progress dialog); `auto` marks the job as page-turn driven and only
        -- suppresses the completion toast — a toast on every chapter would be
        -- noise.
        -- translateCurrentChapter records the key once the job is queued; hand
        -- it ours so an unmappable page still remembers what it scheduled.
        self:translateCurrentChapter(silent == true, true, fragment_key)
    end
end

return PageTrans
