-- Persistent plugin state: configuration and the single-book translation queue.
-- This module deliberately contains no translation or EPUB logic.
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ButtonDialog = require("ui/widget/buttondialog")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Tools = require("dualtranslate_tools")
local dump = require("dump")

local State = {}

function State.getQueuePath()
    local directory = DataStorage:getDataDir() .. "/cache/dualtranslate"
    Tools.mkdir_p(directory)
    return directory .. "/translation_queue.lua"
end

-- Configuration now lives in KOReader's native G_reader_settings (the same
-- settings.reader.lua every other plugin uses), keyed with a dualtranslate_
-- prefix to avoid collisions.  loadConfig performs a one-time migration from
-- the standalone settings/dualtranslate.lua (and, before that, the plugin
-- folder's dualtranslate_configuration.lua) written by older builds, then
-- renames those files away.  Nothing is read or written through a custom
-- serializer anymore.
function State.loadConfig(plugin)
    if not G_reader_settings then return end
    local migrated_any = false
    local sources = {}
    -- Newest first: the settings-directory file replaced the in-plugin file.
    local settings_path = DataStorage:getDataDir() .. "/settings/dualtranslate.lua"
    if lfs.attributes(settings_path, "mode") == "file" then
        sources[#sources + 1] = settings_path
    end
    if plugin.path then
        local legacy = plugin.path .. "/dualtranslate_configuration.lua"
        if lfs.attributes(legacy, "mode") == "file" then
            sources[#sources + 1] = legacy
        end
    end
    for _, path in ipairs(sources) do
        local ok, config = pcall(dofile, path)
        if ok and type(config) == "table" then
            for key, value in pairs(config) do
                local prefixed = "dualtranslate_" .. key
                if G_reader_settings:readSetting(prefixed) == nil then
                    G_reader_settings:saveSetting(prefixed, value)
                end
            end
            migrated_any = true
        end
        -- Rename the old file even when unreadable: a corrupted config must
        -- not shadow the migrated copy on the next startup.
        os.rename(path, path .. ".migrated")
    end
    if migrated_any then
        logger.info("dualtranslate: migrated settings to G_reader_settings")
    end
end

-- Persist the queue through KOReader's own dump serializer.  The written
-- file stays valid Lua ("return {...}") so loadQueue can simply dofile it.
function State.saveQueue(plugin)
    local file = io.open(State.getQueuePath(), "w")
    if not file then return false end
    local clean = {}
    for _, item in ipairs(plugin._translation_queue or {}) do
        -- Defensive: never crash on a corrupted queue entry at startup.
        if type(item) == "table" and item.book_path and item.status ~= "done" then
            clean[#clean + 1] = item
        end
    end
    file:write("return ", dump(clean))
    file:close()
    return true
end

-- 13.4: older persisted queue items may predate the current field set.
-- Normalize the job shape (all / span / selection) from the legacy
-- all_chapters/fragment fields; an item whose shape cannot be inferred is
-- marked failed so the queue menu surfaces it instead of a worker crashing.
-- provider is deliberately left nil here: a resumed job picks up its own
-- provider at start time (Reader:_runTranslation), never the mode that
-- happens to be selected when the queue loads.
local function backfill_queue_item(item)
    if item.provider == "" then item.provider = nil end
    if item.mode == nil then
        if item.chapter_indexes ~= nil then
            item.mode = "selection"
        elseif item.all_chapters == true then
            item.mode = "all"
        elseif item.all_chapters == false
            or (item.fragment ~= nil and item.fragment ~= "") then
            item.mode = "span"
        else
            item.status = "failed"
            item.error = "旧队列任务无法推断翻译范围，请重新发起翻译"
            logger.warn("dualtranslate: legacy queue item without inferable scope:",
                tostring(item.book_path))
            return
        end
    end
    item.all_chapters = nil
    if item.mode == "all" then
        item.fragment = nil
        item.span = nil
        item.chapter_indexes = nil
    elseif item.mode == "span" then
        item.span = tonumber(item.span) or 1
        item.chapter_indexes = nil
    elseif item.mode == "selection" then
        item.fragment = nil
        item.span = nil
        item.chapter_indexes = type(item.chapter_indexes) == "table"
            and item.chapter_indexes or {}
    else
        item.status = "failed"
        item.error = "旧队列任务无法推断翻译范围，请重新发起翻译"
    end
end

function State.loadQueue()
    local ok, value = pcall(dofile, State.getQueuePath())
    local queue = ok and type(value) == "table" and value or {}
    local pending, retried = {}, {}
    for _, item in ipairs(queue) do
        -- Drop corrupted entries instead of crashing at startup; they would
        -- also take down saveQueue/startNext on the same load path.
        if type(item) ~= "table" then
            logger.warn("dualtranslate: dropping malformed queue entry")
        else
            if item.status == "active" then item.status = "queued" end
            backfill_queue_item(item)
            local key = tostring(item.book_path or "") .. "\0" .. tostring(item.mode)
            local retryable = item.status == "failed" and item.mode == "all"
                and (tonumber(item.retry_count) or 0) < 2
            if retryable and not retried[key] then
                item.status, item.error = "queued", nil
                item.retry_count = math.max(1, tonumber(item.retry_count) or 0)
                retried[key] = true
                table.insert(pending, item)
            elseif item.status ~= "done" then
                table.insert(pending, item)
            end
        end
    end
    return pending
end

function State.clearForBook(plugin, book_path)
    if not book_path then return true end
    if plugin._translation_progress and plugin._translation_progress.active
        and plugin._translation_progress.book_path == book_path then
        return false
    end
    local kept = {}
    for _, item in ipairs(plugin._translation_queue or {}) do
        if type(item) == "table" and item.book_path == book_path then
            if item.progress_path then os.remove(item.progress_path) end
        elseif type(item) == "table" then
            kept[#kept + 1] = item
        end
    end
    plugin._translation_queue = kept
    State.saveQueue(plugin)
    return true
end

function State.enqueue(plugin, opts)
    opts = opts or {}
    local book_path = opts.book_path
    if not book_path or not book_path:lower():match("%.epub$") then return end
    local mode = opts.mode or "all"
    local silent = opts.silent == true
    if plugin._translation_migration_failed then
        if not silent then
            plugin.TranslationUI.showInfo("译文数据迁移失败，已保留备份，翻译暂不可用")
        end
        return
    end
    if plugin.isPluginEnabled and not plugin:isPluginEnabled() then
        if not silent then
            plugin.TranslationUI.showInfo("插件当前已禁用，请在 DualTranslate 菜单中启用后再翻译")
        end
        return
    end
    -- One job per book at a time, regardless of job type (whole-book vs
    -- chapter-mode follow).  A second job for the same book would duplicate
    -- work and confuse the queue display.
    for _, existing in ipairs(plugin._translation_queue or {}) do
        if type(existing) == "table"
            and existing.book_path == book_path
            and (existing.status == "queued" or existing.status == "active") then
            if not silent then
                if plugin._translation_progress and plugin._translation_progress.dialog then
                    plugin:reopenTranslationProgress()
                else
                    plugin.TranslationUI.showInfo("这本书已经在翻译队列中")
                end
            end
            return
        end
    end
    local item = {
        book_path = book_path,
        -- Generation engine at enqueue time (9.3): delete guards and queue
        -- display key off this.  Older persisted items have no provider.
        provider = opts.provider or (plugin.getMode and plugin:getMode() or nil),
        mode = mode,
        -- Selection mode carries the explicit spine-index list; span mode
        -- carries the starting fragment plus the chapter count.
        chapter_indexes = mode == "selection" and opts.chapter_indexes or nil,
        fragment = mode == "span" and opts.fragment or nil,
        span = mode == "span" and (tonumber(opts.span) or 1) or nil,
        status = "queued", current = 0, total = 0, translated = 0, failed = 0,
        silent = silent,
        -- Page-turn driven (逐章模式 auto-continue): completion keeps the
        -- progress dialog but skips the per-chapter completion toast.
        auto = opts.auto == true,
    }
    table.insert(plugin._translation_queue, item)
    State.saveQueue(plugin)
    plugin:startNextQueuedTranslation()
    if not silent
        and (not plugin._translation_progress or plugin._translation_progress.item ~= item) then
        plugin.TranslationUI.showInfo("已加入翻译队列")
    end
end

function State.progress(item)
    if type(item) ~= "table" then return 0, 0, 0, 0 end
    if not item.progress_path then
        return item.current or 0, item.total or 0, item.translated or 0, item.failed or 0
    end
    local file = io.open(item.progress_path, "r")
    local line = file and file:read("*l") or nil
    if file then file:close() end
    local current, total, translated, failed = line and line:match("^(%d+)|(%d+)|(%d+)|(%d+)|")
    if current then return tonumber(current), tonumber(total), tonumber(translated), tonumber(failed) end
    return item.current or 0, item.total or 0, item.translated or 0, item.failed or 0
end

function State.cancelTranslation(plugin, item)
    if type(item) ~= "table" then return false end
    -- Remove a queued/failed entry outright; an active worker stops at the
    -- next batch boundary (cancel flag file) and _runTranslation cleans up.
    if item.status == "active" then
        if not item.progress_path then
            -- Active but no progress file: nothing to signal, drop directly.
            for index, queued_item in ipairs(plugin._translation_queue or {}) do
                if queued_item == item then table.remove(plugin._translation_queue, index) break end
            end
            plugin:saveTranslationQueue()
            return true
        end
        local flag = io.open(item.progress_path .. ".cancel", "w")
        if flag then flag:close() end
        -- Leave the entry in the queue; the worker observes the flag and the
        -- completion branch removes it.  Persist nothing (status stays
        -- "active" until then).
        return true
    end
    for index, queued_item in ipairs(plugin._translation_queue or {}) do
        if queued_item == item then
            table.remove(plugin._translation_queue, index)
            break
        end
    end
    plugin:saveTranslationQueue()
    return true
end

-- Build the queue as a native sub-menu item table (expands inline in the
-- main menu, no separate window).  Returns an empty table when idle.
function State.buildQueueMenu(plugin)
    local item_table = {}
    -- Cancel confirmation: fallback for a running job whose progress dialog
    -- cannot be reopened (rare), and for the cancel sub-item below.
    local function cancel_job(item_copy, menu)
        State.cancelTranslation(plugin, item_copy)
        if menu and menu.onClose then menu:onClose() end
        UIManager:show(Notification:new{
            text = item_copy.status == "active"
                and "正在停止翻译…\n（当前批次完成后停止）" or "已从队列移除。",
            timeout = 2,
        })
        UIManager:setDirty("all", "ui")
    end
    for index, item in ipairs(plugin._translation_queue or {}) do
        -- Lua 5.1 loop variables are shared by every closure created inside
        -- the loop; capture the per-iteration value so each row's cancel
        -- action acts on its own job, not on the last one in the queue.
        local item_copy = item
        -- Defensive: a malformed queue file entry (or one written by an older
        -- build) must never take down the whole menu.  Finished jobs are
        -- kept in memory until the next save; skip them here so they do not
        -- show up as "失败".
        if type(item_copy) == "table" and item_copy.book_path and item_copy.status ~= "done" then
            local path = tostring(item_copy.book_path)
            local name = path:match("([^/]+)$") or path
            local current, total, translated, failed = State.progress(item_copy)
            local status = item_copy.status == "active" and "翻译中"
                or item_copy.status == "queued" and "排队中" or "失败"
            local label = name
            if item_copy.status ~= "failed" then
                label = string.format("%s  [%s] %d/%d  成功%d  失败%d",
                    name, status, current or 0, total or 0,
                    translated or 0, failed or 0)
            else
                -- Error strings can carry a stack trace (e.g. a worker
                -- crash); clamp the label so the menu stays readable.
                local error_text = tostring(item.error or "")
                if #error_text > 56 then
                    error_text = error_text:sub(1, 56) .. "…"
                end
                label = string.format("%s  [失败] %s", name, error_text)
            end
            if item_copy.status == "active" then
                -- Running job: tapping the row brings the progress dialog
                -- back (tap the dialog body again for cancel actions).
                table.insert(item_table, {
                    text_func = function() return label end,
                    callback = function(menu)
                        if menu and menu.onClose then menu:onClose() end
                        if not plugin:reopenTranslationProgress() then
                            -- Progress dialog unavailable: fall back to the
                            -- cancel confirmation.
                            local dialog
                            dialog = ButtonDialog:new{
                                title = "取消「" .. name .. "」？\n已翻译部分会保留，可随时重翻。",
                                buttons = {{
                                    { text = "返回", id = "close",
                                        callback = function() UIManager:close(dialog) end },
                                    { text = "取消翻译", is_enter_default = true,
                                        callback = function()
                                            UIManager:close(dialog)
                                            cancel_job(item_copy, menu)
                                        end },
                                }},
                            }
                            UIManager:show(dialog)
                        end
                    end,
                })
            else
                -- Queued/failed: a native sub-item for cancelling, no popup.
                table.insert(item_table, {
                    text_func = function() return label end,
                    sub_item_table = {{
                        text = "取消翻译",
                        callback = function(menu) cancel_job(item_copy, menu) end,
                    }},
                })
            end
        end
    end
    return item_table
end

local STALE_TRANSLATION_SECONDS = 10 * 60 -- watchdog: progress not touched

function State.startNext(plugin)
    if plugin._translation_migration_failed then return end
    if plugin.isPluginEnabled and not plugin:isPluginEnabled() then return end
    if plugin._translation_progress and plugin._translation_progress.active then
        -- Watchdog: a worker that has not written to its progress file for a
        -- long time is considered dead (subprocess lost, API failure on some
        -- platforms, crash).  Release the slot so the queue can move on.
        local progress = plugin._translation_progress
        local progress_path = progress.path
        local mtime = progress_path and lfs.attributes(progress_path, "modification") or nil
        if mtime and os.time() - mtime > STALE_TRANSLATION_SECONDS then
            logger.warn("dualtranslate: watchdog resetting stalled translation worker")
            progress.active = false
            local stalled_item = progress.item
            if stalled_item then
                stalled_item.status = "failed"
                stalled_item.error = "翻译进程无响应，已自动重置，请重试"
                plugin:saveTranslationQueue()
            end
            -- fall through to start the next queued item
        else
            return
        end
    end
    local item
    for _, candidate in ipairs(plugin._translation_queue or {}) do
        if type(candidate) == "table" and candidate.status == "queued" then
            item = candidate
            break
        end
    end
    if not item then return end
    local source = io.open(item.book_path, "rb")
    if not source then
        item.status, item.error = "failed", "找不到原书文件"
        State.saveQueue(plugin)
        return State.startNext(plugin)
    end
    source:close()
    item.status, item.error = "active", nil
    State.saveQueue(plugin)
    -- A corrupted item (missing book_path, wrong field types) must not take
    -- down the whole plugin through the worker entry point.
    local ok, err = pcall(function() plugin:_runTranslation(item) end)
    if not ok then
        logger.err("dualtranslate: translation worker failed to start:", err)
        item.status = "failed"
        item.error = "翻译任务启动失败：" .. tostring(err)
        State.saveQueue(plugin)
        return State.startNext(plugin)
    end
end

-- 9.3: is a queued/active job touching this book (and provider) right now?
-- Used as the delete guard.  Old queue items carry no provider: they match
-- any requested provider (conservative — an unidentified running job must
-- block deletion rather than race it).
function State.hasActiveJob(plugin, book_path, provider_id)
    if not book_path then return false end
    local function matches(item)
        local pid = item and item.provider
        if pid == nil or pid == "" then return true end
        return provider_id == nil or pid == provider_id
    end
    for _, item in ipairs(plugin._translation_queue or {}) do
        if type(item) == "table" and item.book_path == book_path
            and (item.status == "queued" or item.status == "active")
            and matches(item) then
            return true
        end
    end
    local progress = plugin._translation_progress
    if progress and progress.active and progress.book_path == book_path
        and matches(progress.item) then
        return true
    end
    return false
end

function State.attach(plugin)
    plugin.TranslationUI = require("dualtranslate_ui")
    plugin.getTranslationQueuePath = State.getQueuePath
    plugin.loadConfig = State.loadConfig
    plugin.saveTranslationQueue = State.saveQueue
    plugin.loadTranslationQueue = State.loadQueue
    plugin.clearTranslationQueueForBook = State.clearForBook
    plugin.enqueueTranslation = State.enqueue
    plugin.cancelTranslation = State.cancelTranslation
    plugin.hasActiveJob = State.hasActiveJob
    plugin.getQueueProgress = function(_, item) return State.progress(item) end
    plugin.buildTranslationQueueMenu = State.buildQueueMenu
    plugin.startNextQueuedTranslation = State.startNext
end

return State
