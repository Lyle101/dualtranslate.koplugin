
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Cache = require("dualtranslate_cache")
local Providers = require("dualtranslate_providers")
local TranslationUI = require("dualtranslate_ui")
local Languages = require("dualtranslate_languages")
local State = require("dualtranslate_state")
local Reader = require("dualtranslate_reader")
local PageTrans = require("dualtranslate_pagetrans")
local Store = require("dualtranslate_store")
local Overlay = require("dualtranslate_overlay")

local dualtranslate = WidgetContainer:extend{
    name = "dualtranslate",
    is_doc_only = false,
}

function dualtranslate:init()
    State.attach(self)
    Reader.attach(self)
    PageTrans.attach(self)
    -- One-time migration of older standalone config files into KOReader's
    -- native G_reader_settings (see State.loadConfig).  All settings are then
    -- read and written through the standard KOReader settings API.
    self:loadConfig()
    self.cache = Cache:new()
    Store.setCache(self.cache)
    -- 13.1: the schema migration must finish before any queue worker can
    -- start.  On failure keep the backup and disable the translation
    -- entries instead of running workers on the old schema.
    local migrated, migrate_err = Store.migrateIfNeeded(self.cache)
    if not migrated then
        self._translation_migration_failed = true
        logger.err("dualtranslate: cache migration failed:", tostring(migrate_err))
    end
    self._translation_queue = self:loadTranslationQueue()
    -- Persist cleanup of completed entries immediately after startup.
    self:saveTranslationQueue()

    -- Load the EPUB engine defensively.  Prefer require(), but fall back to
    -- an absolute-path dofile from our own plugin directory so the engine
    -- can never resolve to another plugin's file or to a non-table value.
    self.epub = self:loadEpubModule()
    if not self.epub then
        logger.warn("dualtranslate: EPUB engine failed to load (no module, no dofile)")
    end

    -- Translation requests may need Wi-Fi, but connection retries must stay
    -- in the background.  Keep an explicit user's "ignore" choice intact;
    -- only replace KOReader's default prompt behavior.
    if G_reader_settings then
        if not G_reader_settings:readSetting("dualtranslate_silent_network") then
            G_reader_settings:saveSetting("dualtranslate_silent_network", true)
        end
        -- Never overwrite KOReader's global Wi-Fi policy.  The reader's own
        -- NetworkMgr handles prompts and restoration; the plugin only reports
        -- provider errors to the user.
    end

    self.ui.menu:registerToMainMenu(self)

    -- The reader hooks open the companion after document-ready. Keep the
    -- queue startup here, but do not replace a document during init.
    if self._translation_migration_failed then
        TranslationUI.showInfo(_("迁移失败，已保留备份。翻译入口已禁用，请查看日志后重试。"))
    else
        self:startNextQueuedTranslation()
    end
end

-- Load the EPUB engine module.
--
-- KOReader appends every installed plugin directory to package.path (in
-- path-sorted order).  A bare module name could therefore resolve to a
-- file belonging to another plugin; require() can even come back with a
-- non-table value.  We therefore try require() first, then fall back to
-- loading the file straight from our own directory via self.path (set by
-- PluginLoader), which is immune to any package.path pollution.
function dualtranslate:loadEpubModule()
    local ok, mod = pcall(require, "dualtranslate_epub")
    if ok and type(mod) == "table" then
        return mod
    end
    logger.warn("dualtranslate: require(\"dualtranslate_epub\") failed:", tostring(mod))
    if self.path then
        local ok2, mod2 = pcall(dofile, self.path .. "/dualtranslate_epub.lua")
        if ok2 and type(mod2) == "table" then
            logger.warn("dualtranslate: loaded dualtranslate_epub.lua via dofile")
            return mod2
        end
        logger.warn("dualtranslate: dofile dualtranslate_epub.lua failed:", tostring(mod2))
    end
    return nil
end

-- Persistent configuration and translation-queue state lives in dualtranslate_state.lua.

------------------------------------------------------------------------
-- Settings helpers
------------------------------------------------------------------------
-- All plugin settings are stored through KOReader's native G_reader_settings
-- (settings.reader.lua), keyed with the dualtranslate_ prefix.
function dualtranslate:getSetting(key, default)
    local prefixed = "dualtranslate_" .. key
    local value = G_reader_settings and G_reader_settings:readSetting(prefixed)
    if value == nil then
        return default
    end
    return value
end

function dualtranslate:saveSetting(key, value)
    if G_reader_settings then
        G_reader_settings:saveSetting("dualtranslate_" .. key, value)
    end
end

function dualtranslate:isPluginEnabled()
    return self:getSetting("plugin_enabled", true) == true
end

function dualtranslate:togglePluginEnabled(menu)
    local enabled = not self:isPluginEnabled()
    self:saveSetting("plugin_enabled", enabled)
    self:refreshDocumentStyles()
    if enabled then
        self:startNextQueuedTranslation()
    else
        UIManager:setDirty("all", "ui")
    end
    if menu and menu.updateItems then menu:updateItems() end
end

function dualtranslate:queueStats()
    local active, queued = 0, 0
    for _, item in ipairs(self._translation_queue or {}) do
        if type(item) == "table" then
            if item.status == "queued" then queued = queued + 1
            elseif item.status == "active" then active = active + 1 end
        end
    end
    return active, queued
end

function dualtranslate:getMode()
    local mode = self:getSetting("mode", "microsoft_free")
    if mode ~= "system" and mode ~= "microsoft_free" then
        return "microsoft_free"
    end
    return mode
end

function dualtranslate:getSourceLang()
    return self:getSetting("source_lang", "auto")
end

function dualtranslate:getTargetLang()
    return self:getSetting("target_lang", "zh-Hans")
end

-- Keep requests below the common free web-engine request limit.
function dualtranslate:getTranslationChunkLimit()
    local limits = {
        microsoft_free = 4500,
    }
    return limits[self:getMode()] or 4500
end

function dualtranslate:addToMainMenu(menu_items)
    -- Single top-level entry. The enable/disable checkbox lives as the first
    -- item of the submenu (see buildMenuTable) so it can be toggled by a
    -- plain tap; KOReader would otherwise swallow taps on any item that also
    -- carries a sub_item_table and the checkbox would be display-only.
    menu_items.dualtranslate = {
        text = _("DualTranslate"),
        sorting_hint = "tools",
        sub_item_table = self:buildMenuTable(),
    }
end

function dualtranslate:buildMenuTable()
    local menu = {
        -- Master switch as a plain tap-to-toggle checkbox inside the submenu.
        {
            text = "启用插件",
            checkbox = true,
            checked_func = function() return self:isPluginEnabled() end,
            callback = function(menu) self:togglePluginEnabled(menu) end,
        },
        {
            text = "翻译本书",
            enabled_func = function()
                return self:isEpub() and not self:isLegacyBilingualEpub(self.ui.document.file)
                    and not self._translation_migration_failed
            end,
            callback = function()
                self:translateBook(true)
            end,
        },
        {
            -- "逐章模式" preference.  Checked: tapping "翻译本书" starts from
            -- the current chapter and follows the reading position (page
            -- turns silently translate newly reached chapters).  Unchecked:
            -- "翻译本书" translates the whole book.
            text_func = function()
                return self:isPageTranslationEnabled() and "逐章模式（从当前章开始）" or "逐章模式"
            end,
            checkbox = true,
            checked_func = function() return self:isPageTranslationEnabled() end,
            enabled_func = function()
                return self:isEpub() and not self:isLegacyBilingualEpub(self.ui.document.file)
                    and not self._translation_migration_failed
            end,
            callback = function(menu) self:togglePageTranslation(menu) end,
        },
        -- Generation engine selector (12.2: 翻译引擎 = which service
        -- produces translations; 显示译文 = whose translations are shown).
        {
            text_func = function()
                return _("翻译引擎") .. "：" .. Providers.getProviderName(self:getMode())
            end,
            sub_item_table = self:buildProviderSelector(),
        },
        {
            -- Queue as a native sub-menu: items expand inline instead of
            -- popping a separate window.
            text_func = function()
                local active, queued = self:queueStats()
                if active + queued == 0 then return "翻译队列（空）" end
                return string.format("翻译队列（进行中%d，排队%d）", active, queued)
            end,
            enabled_func = function()
                local active, queued = self:queueStats()
                return active + queued > 0
            end,
            sub_item_table_func = function()
                return self:buildTranslationQueueMenu()
            end,
        },
        {
            -- 显示译文子菜单（8.1）：可见性开关 + 显示哪个服务的译文 +
            -- 缺失段落回退。显示选择只写 manifest，不改 fallback_order。
            text_func = function() return self:displayText() end,
            enabled_func = function()
                local path = self:currentBookPath()
                return self:isEpub() and self:hasTranslationOverlay(path)
            end,
            sub_item_table_func = function()
                return self:buildDisplayMenu()
            end,
        },
        {
            text = _("管理译文"),
            enabled_func = function() return self:isEpub() end,
            sub_item_table_func = function()
                return self:buildManageMenu()
            end,
        },
        -- Language settings: plain sub-menus with radio items (the same
        -- structure the translator_switch plugin uses), no pop-up dialog.
        {
            text_func = function()
                local sl = self:getSourceLang()
                local name = sl == "auto" and "自动识别" or Languages.getNameByCode(sl)
                return "源语言：" .. name
            end,
            sub_item_table = self:buildLanguageMenu("source"),
        },
        {
            text_func = function()
                return "目标语言：" .. Languages.getNameByCode(self:getTargetLang())
            end,
            sub_item_table = self:buildLanguageMenu("target"),
        },
        {
            text_func = function()
                return "译文字号：" .. self:getInlineFontSize()
            end,
            callback = function() self:showInlineFontSpin() end,
        },
        {
            text_func = function()
                return "译文字体：" .. self:getInlineFontFamilyLabel()
            end,
            sub_item_table_func = function()
                return self:buildFontFamilyMenu()
            end,
        },
        self:inlineStyleMenu("inline_color", "译文颜色…", {
            { value = "#e6e6e6", label = "10% 灰" },
            { value = "#cccccc", label = "20% 灰" },
            { value = "#b3b3b3", label = "30% 灰" },
            { value = "#999999", label = "40% 灰" },
            { value = "#808080", label = "50% 灰" },
            { value = "#666666", label = "60% 灰" },
            { value = "#4d4d4d", label = "70% 灰" },
            { value = "#333333", label = "80% 灰" },
            { value = "#1a1a1a", label = "90% 灰" },
        }),
    }

    return menu
end

function dualtranslate:currentBookPath()
    return self.ui and self.ui.document and self.ui.document.file
end

function dualtranslate:currentManifest()
    local path = self:currentBookPath()
    if not path then return nil end
    return Overlay.loadManifest(self:getBookCacheDirectory(path))
end

function dualtranslate:displayText()
    local label = _("显示译文")
    local manifest = self:currentManifest()
    if not manifest then return label end
    if manifest.display_mode ~= "manual" then
        return label .. "：" .. _("自动（最近使用）")
    end
    local pid = manifest.display_provider
    local provider = pid and manifest.providers[pid]
    local name = provider and provider.display_name or pid
    if not name then return label end
    return label .. "：" .. name
end

function dualtranslate:buildDisplayMenu()
    local path = self:currentBookPath()
    local target_lang = self:getTargetLang()
    local items = {
        {
            text = _("显示译文"),
            checkbox = true,
            checked_func = function()
                return self:getSetting("translation_visible", true) == true
            end,
            callback = function() self:toggleTranslationVisible() end,
        },
        {
            text = _("自动（最近使用）"),
            radio = true,
            checked_func = function()
                local manifest = self:currentManifest()
                return not manifest or manifest.display_mode ~= "manual"
            end,
            callback = function()
                if not path then return end
                local ok, result, err = pcall(Store.setDisplayProvider, path, target_lang, "auto")
                if not ok or not result then
                    TranslationUI.showInfo(_("切换显示失败：") .. tostring(ok and err or result))
                    return
                end
                self:refreshDocumentStyles()
            end,
        },
    }
    for idx, item in ipairs(path and Store.listProviders(path, target_lang) or {}) do
        -- Lua 5.1: capture per-iteration values for the closures below.
        local pid, name, count = item.id, item.display_name, item.count
        local confirmed, model_name = item.confirmed, item.model_name
        items[#items + 1] = {
            text_func = function()
                if not confirmed then
                    return _("MCP · 待确认") .. "（" .. (model_name or pid) .. "）"
                end
                return string.format("%s（%d %s）", name, count, _("段"))
            end,
            radio = true,
            enabled_func = function() return confirmed end,
            checked_func = function()
                local manifest = self:currentManifest()
                return manifest ~= nil and manifest.display_mode == "manual"
                    and manifest.display_provider == pid
            end,
            callback = function()
                if not confirmed then
                    -- The model confirmation dialog is P3; until then an
                    -- unconfirmed provider cannot be selected for display.
                    TranslationUI.showInfo(_("该模型尚未确认，暂不能显示其译文"))
                    return
                end
                local ok, result, err = pcall(Store.setDisplayProvider, path, target_lang, pid)
                if not ok or not result then
                    TranslationUI.showInfo(_("切换显示失败：") .. tostring(ok and err or result))
                    return
                end
                self:refreshDocumentStyles()
            end,
        }
    end
    items[#items + 1] = {
        text = _("缺失段落回退到其他服务"),
        checkbox = true,
        checked_func = function()
            local manifest = self:currentManifest()
            return not manifest or manifest.display_fallback ~= false
        end,
        callback = function()
            if not path then return end
            local manifest = self:currentManifest()
            -- Same semantics as checked_func: no manifest means the default
            -- (enabled).  Parenthesize the and/or so a stored false actually
            -- reads as disabled and the toggle can turn it back on.
            local enabled = not manifest or manifest.display_fallback ~= false
            local ok, result, err = pcall(Store.setDisplayFallback, path, target_lang, not enabled)
            if not ok or not result then
                TranslationUI.showInfo(_("设置回退失败：") .. tostring(ok and err or result))
                return
            end
            self:refreshDocumentStyles()
        end,
    }
    return items
end

function dualtranslate:buildManageMenu()
    local path = self:currentBookPath()
    local target_lang = self:getTargetLang()
    local delete_items = {}
    for idx, item in ipairs(path and Store.listProviders(path, target_lang) or {}) do
        local pid, name, count = item.id, item.display_name, item.count
        delete_items[#delete_items + 1] = {
            text_func = function()
                return string.format("%s（%d %s）", name, count, _("段"))
            end,
            callback = function()
                self:confirmDeleteProvider(pid, name, count)
            end,
        }
    end
    return {
        {
            text = _("删除某服务的译文…"),
            enabled_func = function() return #delete_items > 0 end,
            sub_item_table = delete_items,
        },
        {
            text = _("删除本书全部译文"),
            enabled_func = function() return self:isEpub() end,
            callback = function() self:confirmClearCache() end,
        },
        {
            text = _("修复本书译文数据"),
            enabled_func = function() return self:isEpub() end,
            callback = function() self:repairBookTranslationData() end,
        },
    }
end

function dualtranslate:confirmDeleteProvider(provider_id, display_name, count)
    local book_path = self:currentBookPath()
    if not book_path then return end
    -- 6.2.1: DB rows are not segments.  Refresh the entries-based
    -- translated_count so the confirmation dialog and the success notice
    -- report the same figure the menu shows.
    for _, item in ipairs(Store.listProviders(book_path, self:getTargetLang())) do
        if item.id == provider_id then
            count = item.count
            break
        end
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(_("将删除 %s 在本书的 %d 段译文\n（SQLite 缓存 + overlay 条目），原书不会被修改。"),
            display_name, count),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    -- 9.3: never delete under a running job of the same
                    -- provider (or an unidentified legacy job).
                    if self:hasActiveJob(book_path, provider_id) then
                        TranslationUI.showInfo(_("该服务正在翻译中，请在任务结束后再删除"))
                        return
                    end
                    local ok, result, err = pcall(Store.deleteProvider,
                        book_path, self:getTargetLang(), provider_id)
                    if not ok or not result then
                        TranslationUI.showInfo(_("删除失败：") .. tostring(ok and err or result))
                        return
                    end
                    self._page_translation_overlay_state = nil
                    self:refreshDocumentStyles()
                    TranslationUI.showInfo(string.format(_("已删除 %s 译文 %d 段"),
                        display_name, count or 0))
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function dualtranslate:repairBookTranslationData()
    local book_path = self:currentBookPath()
    if not book_path then return end
    -- Full reconcile (14.3): orphan scan + revision catch-up, only on this
    -- explicit user action, never on the book-open path.
    local ok, summary, err = pcall(Store.reconcile,
        book_path, self:getTargetLang(), self.cache)
    if not ok or not summary then
        TranslationUI.showInfo(_("修复失败：") .. tostring(ok and err or summary))
        return
    end
    self._page_translation_overlay_state = nil
    self:refreshDocumentStyles()
    TranslationUI.showInfo(_("本书译文数据修复完成"))
end

function dualtranslate:buildProviderSelector()
    local items = {}
    for i, provider in ipairs(Providers.list) do
        -- Lua 5.1: loop variables are shared by every closure created inside
        -- the loop.  Capture the per-iteration values (id and name) so each
        -- row shows its own provider and toggles its own mode.
        local pid, pname = provider.id, provider.name

        table.insert(items, {
            text_func = function()
                return pname
            end,
            checked_func = function()
                return self:getMode() == pid
            end,
            radio = true,
            callback = function()
                self:saveSetting("mode", pid)
                TranslationUI.showInfo(T(_("Provider: %1"), pname))
            end,
        })
    end
    return items
end

------------------------------------------------------------------------
-- Language sub-menus (source / target)
------------------------------------------------------------------------
-- Generic radio sub-menu like translator_switch's genLanguagesMenu: no
-- pop-up dialog, selection is applied immediately, and the parent menu item
-- reflects the new value on the next rebuild.
function dualtranslate:buildLanguageMenu(which)
    local items = {}

    if which == "source" then
        table.insert(items, {
            text = "自动识别 (auto)",
            radio = true,
            checked_func = function() return self:getSourceLang() == "auto" end,
            callback = function()
                self:saveSetting("source_lang", "auto")
            end,
        })
    end

    local is_target = which == "target"
    for __, lang in ipairs(Languages.list) do
        -- Lua 5.1: capture the per-iteration values; otherwise every row's
        -- closures would use the last language in the list.
        local code, name = lang.code, lang.name
        table.insert(items, {
            text = string.format("%s (%s)", _(name), code),
            radio = true,
            checked_func = function()
                local current = is_target and self:getTargetLang() or self:getSourceLang()
                return current == code
            end,
            callback = function()
                self:saveSetting(is_target and "target_lang" or "source_lang", code)
            end,
        })
    end
    return items
end

------------------------------------------------------------------------
-- Clear cache
------------------------------------------------------------------------
function dualtranslate:confirmClearCache()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        -- ButtonDialog has no separate info field; the body text lives in
        -- the title (TextBoxWidget, wraps).
        title = "清除本书译文\n彻底删除当前书的全部译文数据？原 EPUB 不会被修改。",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Clear"),
                    callback = function()
                        local book_path = self.ui and self.ui.document and self.ui.document.file
                        -- 9.3: any queued/active job of any provider for this
                        -- book blocks the clear (same State.hasActiveJob guard
                        -- as the per-provider delete), not just a worker that
                        -- happens to be running right now.
                        if self:hasActiveJob(book_path) then
                            UIManager:close(dialog)
                            TranslationUI.showInfo("这本书正在翻译，请在任务结束后再清除。")
                            return
                        end
                        self:clearTranslationQueueForBook(book_path)
                        -- v3: the SQLite rows and per-provider entries must
                        -- go through the delete protocol before the book
                        -- directories are swept (9.1/9.2).
                        local ok, result, err = pcall(Store.deleteAllProviders,
                            book_path, self:getTargetLang())
                        if not ok or not result then
                            UIManager:close(dialog)
                            TranslationUI.showInfo(_("删除失败：") .. tostring(ok and err or result))
                            return
                        end
                        local removed = self:clearBookTranslationData(book_path)
                        self:saveSetting("translation_visible", false)
                        -- Stop follow-mode after a clear: the page-turn
                        -- scheduler must not immediately re-translate the
                        -- chapter the user just wiped.
                        self._page_translation_follow_active = nil
                        self._page_translation_last_fragment = nil
                        self._page_translation_overlay_state = nil
                        self._chapter_index_cache = nil
                        UIManager:close(dialog)
                        if self.ui and self.ui.document then
                            self.ui.document._dualtranslate_extra_css = nil
                        end
                        self:refreshDocumentStyles()
                        TranslationUI.showInfo(removed > 0
                            and "已彻底删除本书译文"
                            or "已清除本书译文数据库记录")
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function dualtranslate:onCloseDocument()
    -- Follow-mode session state is per book: closing the book must not let
    -- the next opened book inherit an armed follow session (which would
    -- auto-translate it on the first page turn).
    self._page_translation_overlay_state = nil
    self._page_translation_follow_active = nil
    self._page_translation_last_fragment = nil
    self._chapter_index_cache = nil
    self._style_refresh_scheduled = nil
    self._translation_stale = nil
    self.cache:close()
end

function dualtranslate:onReaderReady()
    UIManager:nextTick(function()
        self:refreshDocumentStyles()
    end)
end

-- Restore the saved translation layer while CREngine is still loading its
-- document settings. Applying the same CSS after ReaderReady makes the built
-- DOM stale and triggers KOReader's full-reload prompt; at this stage it is
-- part of the initial render and appears immediately without a toggle cycle.
function dualtranslate:onReadSettings()
    local path = self.ui and self.ui.document and self.ui.document.file
    if not path then return end
    local dir = self:getBookCacheDirectory(path)
    if Overlay.exists(dir .. "/manifest.json") or Overlay.exists(dir .. "/overlay.json") then
        -- 13.1: lazy per-book migration before any read.  14.3: book open
        -- only runs the light reconcile (delete intents + missing entries);
        -- the full orphan scan belongs to import/delete-failure/repair.
        pcall(Store.migrateBookIfNeeded, path, self:getTargetLang(), self.cache)
        pcall(Store.reconcile, path, self:getTargetLang(), self.cache, { light = true })
        local manifest = Overlay.loadManifest(dir)
        if manifest and Overlay.isStale(manifest, path) then
            -- Hide the layer for this session instead of persisting a global
            -- translation_visible=false (which would leak to other books).
            self._translation_stale = true
            TranslationUI.showInfo(_("缓存与当前文件不符，建议清除后重译"))
        else
            self._translation_stale = nil
        end
    else
        self._translation_stale = nil
    end
    if self:hasTranslationOverlay(path)
        and self:getSetting("translation_visible", true) == true then
        self:refreshDocumentStyles(true)
    end
end

function dualtranslate:onPageUpdate()
    if self.maybeSchedulePageTranslation then
        -- Auto-continue for chapter-by-chapter translation shows the same
        -- progress dialog as a manual start, so the user can watch the
        -- newly reached chapter being translated.
        self:maybeSchedulePageTranslation(false)
    end
end

function dualtranslate:onPosUpdate()
    if self.maybeSchedulePageTranslation then
        self:maybeSchedulePageTranslation(false)
    end
end

function dualtranslate:onDocumentRerendered()
    if self.maybeSchedulePageTranslation then
        self:maybeSchedulePageTranslation(false)
    end
end

dualtranslate.onDocumentPartiallyRerendered = dualtranslate.onDocumentRerendered

return dualtranslate
