-- Data orchestration for the v3 provider-aware store (design 5.2/9/13/14).
-- No UI or queue dependencies: the Reader checks State.hasActiveJob before
-- calling in, and dtctl can reuse this module headless.

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local JSON = require("json")
local logger = require("logger")
local Tools = require("dualtranslate_tools")
local Overlay = require("dualtranslate_overlay")
local Lock = require("dualtranslate_lock")
local Cache = require("dualtranslate_cache")

local Store = {}

local ORPHAN_MAX_AGE = 30 * 24 * 3600

local injected_cache
local function default_cache()
    if not injected_cache then injected_cache = Cache:new() end
    return injected_cache
end

-- Seam for the Reader (PR-4) and tests to share one Cache connection.
function Store.setCache(cache)
    injected_cache = cache
end

-- Same directory identity as Reader:getBookCacheDirectory.
function Store.bookDir(book_path, target_lang)
    return DataStorage:getDataDir() .. "/cache/dualtranslate/books/"
        .. Tools.stable_path_hash(book_path .. "|" .. target_lang)
end

function Store.migrateIfNeeded(cache)
    cache = cache or default_cache()
    local ok, err = cache:initSchema()
    if not ok then return nil, err or "cache schema init failed" end
    return true
end

local function provider_kind(provider_id)
    if provider_id == "system" then return "builtin" end
    if provider_id == "microsoft_free" then return "http" end
    if provider_id == "legacy" then return "legacy" end
    return "mcp"
end

local function count_unique_selectors(entries)
    local seen, count = {}, 0
    for _, entry in ipairs(entries or {}) do
        local selector = entry.selector
        if selector and selector ~= "" and not seen[selector] then
            seen[selector] = true
            count = count + 1
        end
    end
    return count
end

local function db_provider_count(cache, book_path, target_lang, provider_id)
    local rows = cache:_queryAll([[
        SELECT COUNT(*) FROM book_translations
        WHERE book_path = ? AND target_lang = ? AND provider = ?
    ]], book_path, target_lang, provider_id)
    return tonumber(rows[1] and rows[1][1]) or 0
end

-- Lightweight spine count: read only container.xml + OPF straight from the
-- archive (no full extraction).  Any failure degrades to 0, which keeps
-- complete=false per design 6.3.
local function read_spine_count(book_path)
    local ok, count = pcall(function()
        local Archiver = require("ffi/archiver")
        local arc = Archiver.Reader:new()
        if not arc:open(book_path) then return 0 end
        local function finish(value)
            arc:close()
            return value
        end
        local container = arc:extractToMemory("META-INF/container.xml")
        if not container then return finish(0) end
        local opf_path
        for tag in container:gmatch("<[^>]*rootfile[^>]*>") do
            opf_path = tag:match('full%-path%s*=%s*"([^"]+)"')
                or tag:match("full%-path%s*=%s*'([^']+)'")
            if opf_path then break end
        end
        if not opf_path then return finish(0) end
        local opf = arc:extractToMemory(opf_path)
        if not opf then return finish(0) end
        local ids = {}
        for item in opf:gmatch("<[%w_%-]*:?item[^>]*>") do
            local id = item:match('id%s*=%s*"([^"]+)"')
            if id then ids[id] = true end
        end
        local total = 0
        for itemref in opf:gmatch("<[%w_%-]*:?itemref[^>]*>") do
            local idref = itemref:match('idref%s*=%s*"([^"]+)"')
            if idref and ids[idref] then total = total + 1 end
        end
        return finish(total)
    end)
    if not ok then return 0 end
    return tonumber(count) or 0
end

local function provider_meta_from_db(cache, provider_id)
    local meta = cache.getProvider and cache:getProvider(provider_id) or nil
    local confirmed = true
    if meta and meta.confirmed ~= nil then confirmed = meta.confirmed end
    return {
        display_name = meta and meta.display_name or provider_id,
        kind = meta and meta.kind or provider_kind(provider_id),
        model_name = meta and meta.model_name or nil,
        confirmed = confirmed,
    }
end

-- v2 -> v3 per-book migration (design 6.3, seven steps).  Lazy and idempotent.
-- opts.lock_timeout keeps the book-open path (13.1) from blocking the UI
-- thread on the default 10s lock wait while a worker holds the book.
function Store.migrateBookIfNeeded(book_path, target_lang, cache, opts)
    if not book_path or not target_lang then
        return nil, "book_path and target_lang are required"
    end
    cache = cache or default_cache()
    local dir = Store.bookDir(book_path, target_lang)
    local existing = Overlay.loadManifest(dir)
    if existing then return existing end
    local legacy_path = dir .. "/overlay.json"
    local legacy = Overlay.load(legacy_path)
    if not legacy then return nil end
    local lock_opts = { timeout = type(opts) == "table" and opts.lock_timeout or nil }
    return Lock.withBookLock(dir, function()
        existing = Overlay.loadManifest(dir)
        if existing then return existing end

        local provider_id = legacy.provider
        if not provider_id or provider_id == "" then
            -- Only a unique DB provider may claim unmarked entries; guessing
            -- from single rows would relabel A's translations as B (6.3).
            local rows = cache:_queryAll([[
                SELECT provider, COUNT(*) FROM book_translations
                WHERE book_path = ? AND source_lang = ? AND target_lang = ?
                GROUP BY provider
            ]], book_path, legacy.source_lang or "", target_lang)
            if #rows == 1 and rows[1][1] and rows[1][1] ~= "" then
                provider_id = rows[1][1]
            else
                provider_id = "legacy"
            end
        end

        local entries = {}
        for _, entry in ipairs(legacy.entries or {}) do
            if entry.selector and entry.selector ~= ""
                and entry.translation and entry.translation ~= "" then
                entries[#entries + 1] = {
                    selector = entry.selector,
                    xpointer = entry.xpointer,
                    chapter_index = entry.chapter_index,
                    source = entry.source or "",
                    translation = entry.translation,
                    created_at = entry.created_at,
                }
            end
        end
        local translated_count = count_unique_selectors(entries)
        local updated_at = lfs.attributes(legacy_path, "modification") or os.time()
        local spine_count = read_spine_count(book_path)
        local chapters = {}
        if provider_id ~= "legacy" and type(legacy.chapters) == "table" then
            for _, index in ipairs(legacy.chapters) do
                chapters[#chapters + 1] = index
            end
        end
        local complete = false
        if spine_count >= 1 and legacy.complete == true and #chapters > 0 then
            local covered = {}
            for _, index in ipairs(chapters) do covered[index] = true end
            complete = true
            for index = 1, spine_count do
                if not covered[index] then complete = false break end
            end
        end
        local meta = provider_meta_from_db(cache, provider_id)
        local manifest = {
            version = 3,
            revision = 0,
            book_path = legacy.book_path or book_path,
            source_lang = legacy.source_lang or "",
            target_lang = legacy.target_lang or target_lang,
            spine_count = spine_count,
            book_size = lfs.attributes(book_path, "size") or 0,
            book_mtime = lfs.attributes(book_path, "modification") or 0,
            display_mode = "manual",
            display_provider = provider_id,
            display_fallback = true,
            last_used_at = { [provider_id] = updated_at },
            fallback_order = { provider_id },
            providers = {
                [provider_id] = {
                    display_name = meta.display_name,
                    kind = meta.kind,
                    model_name = meta.model_name,
                    confirmed = meta.confirmed,
                    chapters = chapters,
                    partial_chapters = {},
                    failed_chapters = {},
                    complete = complete,
                    translated_count = translated_count,
                    updated_at = updated_at,
                },
            },
        }
        if not Overlay.saveEntries(dir, provider_id, {
            target_lang = manifest.target_lang, entries = entries,
        }) then
            return nil, "cannot write migrated entries"
        end
        if not Overlay.saveManifest(dir, manifest) then
            return nil, "cannot write migrated manifest"
        end
        os.rename(legacy_path, dir .. "/overlay.v2.bak")
        return manifest
    end, lock_opts)
end

-- Next provider with translations, following the stable fallback_order (D9).
function Store.nextAvailableProvider(manifest)
    if type(manifest) ~= "table" or type(manifest.providers) ~= "table" then
        return nil
    end
    for _, pid in ipairs(manifest.fallback_order or {}) do
        local provider = manifest.providers[pid]
        if provider and (tonumber(provider.translated_count) or 0) > 0 then
            return pid
        end
    end
    local best, best_count
    for pid, provider in pairs(manifest.providers) do
        local count = tonumber(provider.translated_count) or 0
        if count > 0 and (not best_count or count > best_count
            or (count == best_count and pid > best)) then
            best, best_count = pid, count
        end
    end
    return best
end

-- Removes a provider from the manifest tables and repairs the display
-- selection.  Returns nil when no provider is left (manifest must go away).
local function detach_provider(manifest, provider_id)
    manifest.providers[provider_id] = nil
    manifest.last_used_at = manifest.last_used_at or {}
    manifest.fallback_order = manifest.fallback_order or {}
    for index = #manifest.fallback_order, 1, -1 do
        if manifest.fallback_order[index] == provider_id then
            table.remove(manifest.fallback_order, index)
        end
    end
    manifest.last_used_at[provider_id] = nil
    if manifest.display_provider == provider_id then
        manifest.display_provider = Store.nextAvailableProvider(manifest)
        manifest.display_mode = manifest.display_provider and "manual" or "auto"
    end
    if not next(manifest.providers) then return nil end
    return manifest
end

-- Design 9.2: intent -> DB -> entries -> manifest -> clear intent, all under
-- the book lock.  Idempotent: deleting again returns deleted=0.
function Store.deleteProvider(book_path, target_lang, provider_id)
    if not book_path or not target_lang or not provider_id or provider_id == "" then
        return nil, "book_path, target_lang and provider_id are required"
    end
    local dir = Store.bookDir(book_path, target_lang)
    local cache = default_cache()
    return Lock.withBookLock(dir, function()
        -- 9.2/D11: the intent must be on disk before anything is deleted.
        -- If it cannot be written (e.g. full disk), abort: deleting without
        -- an intent would let reconcile treat the removed provider's rows
        -- as orphans and patch them back after a crash.
        if not Overlay.saveIntent(dir, {
            op = "delete_provider",
            provider = provider_id,
            target_lang = target_lang,
            started_at = os.time(),
        }) then
            return nil, "cannot write delete intent"
        end

        local deleted, err = cache:deleteProviderForBook(book_path, target_lang, provider_id)
        if deleted == nil then
            Overlay.clearIntent(dir)
            return nil, err or "删除数据库记录失败"
        end

        -- M1: a failed unlink must abort the whole delete.  Detaching the
        -- provider while its entries file survives would let the next light
        -- reconcile adopt those orphan entries and resurrect the provider the
        -- user just deleted.  Keep the intent so reconcile retries instead.
        if not Overlay.deleteEntries(dir, provider_id) then
            return nil, "无法删除译文条目文件"
        end

        local manifest = Overlay.loadManifest(dir)
        if not manifest then
            Overlay.clearIntent(dir)
            return { deleted = deleted, display_provider = nil }
        end

        -- saveManifest owns the revision bump (6.3), so the pseudocode's
        -- manual +1 is not repeated here.
        manifest = detach_provider(manifest, provider_id)
        if not manifest then
            Overlay.removeManifest(dir)
        else
            Overlay.saveManifest(dir, manifest)
        end

        Overlay.clearIntent(dir)
        Overlay.clearCssCache()
        return { deleted = deleted, display_provider = manifest and manifest.display_provider or nil }
    end)
end

function Store.deleteAllProviders(book_path, target_lang)
    if not book_path or not target_lang then
        return nil, "book_path and target_lang are required"
    end
    local dir = Store.bookDir(book_path, target_lang)
    if not Overlay.loadManifest(dir) and Overlay.exists(dir .. "/overlay.json") then
        local migrated, err = Store.migrateBookIfNeeded(book_path, target_lang)
        if not migrated then return nil, err or "cannot migrate v2 overlay before delete" end
    end
    local list = Store.listProviders(book_path, target_lang)
    local total, removed, display_provider = 0, {}, nil
    for _, item in ipairs(list) do
        local result, err = Store.deleteProvider(book_path, target_lang, item.id)
        if not result then return nil, err end
        total = total + (result.deleted or 0)
        removed[#removed + 1] = item.id
        display_provider = result.display_provider
    end
    return { deleted = total, removed = removed, display_provider = display_provider }
end

function Store.listProviders(book_path, target_lang)
    if not book_path or not target_lang then return {} end
    local dir = Store.bookDir(book_path, target_lang)
    local index = Overlay.loadBookIndex(dir)
    if not index then return {} end
    local out, seen = {}, {}
    local function add(pid)
        local provider = index.providers[pid]
        if provider and not seen[pid] then
            seen[pid] = true
            local display_name = provider.display_name
            if not display_name or display_name == pid then
                display_name = provider_meta_from_db(default_cache(), pid).display_name
            end
            out[#out + 1] = {
                id = pid,
                display_name = display_name,
                model_name = provider.model_name,
                count = tonumber(provider.translated_count) or 0,
                complete = provider.complete == true,
                confirmed = provider.confirmed ~= false,
            }
        end
    end
    for _, pid in ipairs(index.fallback_order or {}) do add(pid) end
    local rest = {}
    for pid in pairs(index.providers) do
        if not seen[pid] then rest[#rest + 1] = pid end
    end
    table.sort(rest, function(a, b)
        local count_a = tonumber(index.providers[a].translated_count) or 0
        local count_b = tonumber(index.providers[b].translated_count) or 0
        if count_a ~= count_b then return count_a > count_b end
        return a < b
    end)
    for _, pid in ipairs(rest) do add(pid) end
    return out
end

-- D9: switching the display never rewrites fallback_order.
function Store.setDisplayProvider(book_path, target_lang, provider_id_or_auto)
    if not book_path or not target_lang then
        return nil, "book_path and target_lang are required"
    end
    local dir = Store.bookDir(book_path, target_lang)
    return Lock.withBookLock(dir, function()
        local manifest = Overlay.loadManifest(dir)
        if not manifest then return nil, "no v3 manifest for this book" end
        if provider_id_or_auto == "auto" then
            manifest.display_mode = "auto"
            manifest.display_provider = nil
        else
            local pid = provider_id_or_auto
            if not pid or pid == "" or not manifest.providers[pid] then
                return nil, "unknown provider: " .. tostring(pid)
            end
            manifest.display_mode = "manual"
            manifest.display_provider = pid
            manifest.last_used_at = manifest.last_used_at or {}
            manifest.last_used_at[pid] = os.time()
        end
        if not Overlay.saveManifest(dir, manifest) then
            return nil, "cannot write manifest"
        end
        Overlay.clearCssCache()
        return manifest
    end)
end

function Store.setDisplayFallback(book_path, target_lang, enabled)
    if not book_path or not target_lang then
        return nil, "book_path and target_lang are required"
    end
    local dir = Store.bookDir(book_path, target_lang)
    return Lock.withBookLock(dir, function()
        local manifest = Overlay.loadManifest(dir)
        if not manifest then
            return nil, "no v3 manifest for this book"
        end
        manifest.display_fallback = enabled == true
        if not Overlay.saveManifest(dir, manifest) then
            return nil, "cannot write manifest"
        end
        Overlay.clearCssCache()
        return manifest
    end)
end

local function read_entries_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local raw = file:read("*a")
    file:close()
    if not raw or raw == "" then return nil end
    local ok, doc = pcall(JSON.decode, raw)
    if not ok or type(doc) ~= "table" or type(doc.entries) ~= "table" then
        return nil
    end
    return doc
end

-- Crash recovery (design 9.3/14.3): finish or roll back delete intents, heal
-- orphan entries and missing files, catch the manifest revision up.  Never
-- resurrects a provider the user deleted.  opts.light is the book-open path
-- (14.3): intents + missing entries only, no orphan scan or revision work.
function Store.reconcile(book_path, target_lang, cache, opts)
    if not book_path or not target_lang then
        return nil, "book_path and target_lang are required"
    end
    local light = type(opts) == "table" and opts.light == true
    local lock_opts = { timeout = type(opts) == "table" and opts.lock_timeout or nil }
    cache = cache or default_cache()
    local dir = Store.bookDir(book_path, target_lang)
    return Lock.withBookLock(dir, function()
        if not cache:open() then return nil, "cache db unavailable" end
        local summary = { patched = {}, removed = {} }
        local manifest = Overlay.loadManifest(dir)
        local dirty = false
        local clear_intent_after_save = false

        local intent = Overlay.loadIntent(dir)
        if intent and intent.op == "delete_provider" and intent.provider then
            local pid = intent.provider
            if db_provider_count(cache, book_path, target_lang, pid) > 0 then
                -- Crash before the DB delete committed: roll the deletion back.
                Overlay.clearIntent(dir)
                summary.rolled_back = pid
            elseif not Overlay.deleteEntries(dir, pid) then
                -- The unlink failed again: keep the manifest entry and the
                -- intent, otherwise the orphan scan below patches the
                -- surviving entries straight back and the provider returns.
                summary.pending = pid
            else
                if manifest then
                    manifest = detach_provider(manifest, pid)
                    dirty = true
                end
                clear_intent_after_save = true
                summary.completed = pid
            end
        end

        local function patch_manifest(pid, doc, mtime)
            if not manifest then
                manifest = {
                    version = 3,
                    revision = 0,
                    book_path = book_path,
                    source_lang = "",
                    target_lang = target_lang,
                    spine_count = 0,
                    book_size = lfs.attributes(book_path, "size") or 0,
                    book_mtime = lfs.attributes(book_path, "modification") or 0,
                    display_mode = "auto",
                    display_fallback = true,
                    last_used_at = {},
                    fallback_order = {},
                    providers = {},
                }
            end
            if manifest.providers[pid] then return end
            local meta = provider_meta_from_db(cache, pid)
            manifest.providers[pid] = {
                display_name = meta.display_name,
                kind = meta.kind,
                model_name = meta.model_name,
                confirmed = meta.confirmed,
                chapters = {},
                partial_chapters = {},
                failed_chapters = {},
                complete = false,
                translated_count = count_unique_selectors(doc.entries),
                updated_at = mtime,
            }
            manifest.last_used_at = manifest.last_used_at or {}
            if not manifest.last_used_at[pid] then
                manifest.last_used_at[pid] = mtime
            end
            manifest.fallback_order = manifest.fallback_order or {}
            local listed = false
            for _, existing in ipairs(manifest.fallback_order) do
                if existing == pid then listed = true break end
            end
            if not listed then
                manifest.fallback_order[#manifest.fallback_order + 1] = pid
            end
            summary.patched[#summary.patched + 1] = pid
            dirty = true
        end

        local entries_dir = dir .. "/entries"
        local ok, iterator, state = false, nil, nil
        if not light then
            ok, iterator, state = pcall(lfs.dir, entries_dir)
        end
        if ok and iterator then
            for name in iterator, state do
                if name:match("%.json$") then
                    local path = entries_dir .. "/" .. name
                    local doc = read_entries_file(path)
                    local pid = doc and doc.provider
                    if pid and pid ~= ""
                        and not (manifest and manifest.providers[pid]) then
                        local mtime = lfs.attributes(path, "modification") or 0
                        if db_provider_count(cache, book_path, target_lang, pid) > 0 then
                            patch_manifest(pid, doc, mtime)
                        elseif os.time() - mtime > ORPHAN_MAX_AGE then
                            os.remove(path)
                            summary.removed[#summary.removed + 1] = pid
                        else
                            -- No DB rows is not proof of deletion: a failed DB
                            -- write or a rebuilt cache db leaves legal orphans,
                            -- so only age may condemn them (9.3).
                            patch_manifest(pid, doc, mtime)
                            logger.warn("dualtranslate: orphan entries without DB rows kept:", pid)
                        end
                    end
                end
            end
        end

        if manifest then
            for pid in pairs(manifest.providers) do
                if not Overlay.exists(Overlay.entriesPath(dir, pid)) then
                    summary.removed[#summary.removed + 1] = pid
                    manifest = detach_provider(manifest, pid)
                    dirty = true
                    if not manifest then break end
                end
            end
        end

        if manifest and not light then
            local max_entries_revision = 0
            for pid in pairs(manifest.providers) do
                local doc = Overlay.loadEntries(dir, pid)
                local revision = doc and tonumber(doc.revision) or 0
                if revision > max_entries_revision then
                    max_entries_revision = revision
                end
            end
            if max_entries_revision > (tonumber(manifest.revision) or 0) then
                manifest.revision = max_entries_revision
                dirty = true
            end
        end

        if dirty then
            if manifest and next(manifest.providers) then
                if not Overlay.saveManifest(dir, manifest) then
                    return nil, "cannot write manifest"
                end
            else
                Overlay.removeManifest(dir)
            end
        end
        if clear_intent_after_save then Overlay.clearIntent(dir) end
        return summary
    end, lock_opts)
end

return Store