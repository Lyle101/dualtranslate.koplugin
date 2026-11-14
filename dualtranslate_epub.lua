-- Small EPUB reader/writer used by DualTranslate's chapter mode.
-- It intentionally handles XHTML as text: the original markup is preserved and
-- only translated block paragraphs are inserted after their source element.

local Epub = {}
local Archiver = require("ffi/archiver")
local Overlay = require("dualtranslate_overlay")
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

function Epub:resolve(book_path, work_dir, fragment)
    local container = read_file(work_dir .. "/META-INF/container.xml")
    if not container then return nil, "找不到 META-INF/container.xml" end
    local opf_path = container_opf_path(container)
    if not opf_path then return nil, "找不到 OPF 路径" end
    local opf = read_file(work_dir .. "/" .. opf_path)
    if not opf then return nil, "找不到 OPF 文件" end

    local spine = parse_package(opf, opf_path).spine

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
    }
end

local overlay_target_tags = {
    p = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    figcaption = true, dt = true, dd = true,
}

local void_tags = {
    area = true, base = true, br = true, col = true, embed = true, hr = true,
    img = true, input = true, link = true, meta = true, param = true,
    source = true, track = true, wbr = true,
}

local function css_attribute(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

-- Build selectors from the original XHTML tree.  These selectors address
-- CREngine's internal DocFragment nodes, so generated text is laid out in the
-- open source EPUB while the archive itself stays byte-for-byte untouched.
local function collect_overlay_candidates(document, relative, fragment_index, div_fallback)
    local targets = div_fallback and { div = true } or overlay_target_tags
    local root = { counts = {}, in_body = false, path = "", xpath = "" }
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
                            local source = html_to_text(inner)
                            if looks_translatable(source) then
                                table.insert(candidates, {
                                    source = source,
                                    selector = 'DocFragment[Source="' .. css_attribute(relative)
                                        .. '"] > body' .. node.path,
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
                    local node = {
                        name = name,
                        counts = {},
                        in_body = in_body,
                        path = path,
                        xpath = xpath,
                        inner_start = tag_end + 1,
                        target = in_body and targets[name] == true,
                    }
                    local self_closing = raw:match("/%s*>$") ~= nil or void_tags[name]
                    if not self_closing then table.insert(stack, node) end
                end
            end
        end
    end
    return candidates
end

function Epub:translate_overlay(book_path, fragment, target_lang, source_lang,
        translate, all_chapters, progress_path, translate_batch, output_dir, span,
        cancel_path, provider)
    if not book_path:lower():match("%.epub$") then
        return nil, "整书翻译目前仅支持 EPUB"
    end
    -- P0: the provider is part of the overlay identity.  Without it a
    -- provider switch can silently reuse the previous service's entries.
    if not provider or provider == "" then
        return nil, "缺少翻译服务标识"
    end
    local data_dir = DataStorage:getDataDir()
    local nonce = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    local work_dir = data_dir .. "/cache/dualtranslate/overlay_" .. nonce
    if not Tools.mkdir_p(work_dir) then
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
    local chapter, err = self:resolve(book_path, work_dir, fragment)
    if not chapter then cleanup(); return nil, err end
    local chapters = {}
    if all_chapters then
        for index, relative in ipairs(chapter.spine) do
            table.insert(chapters, { index = index, relative = relative,
                absolute = work_dir .. "/" .. relative })
        end
    else
        -- Chapter mode translates the current chapter plus the next few
        -- (span = number of consecutive chapters starting at the current
        -- one, clamped to the end of the spine).
        local span_count = math.max(1, tonumber(span) or 1)
        for offset = 0, span_count - 1 do
            local index = chapter.index + offset
            local relative = chapter.spine[index]
            if not relative then break end
            table.insert(chapters, { index = index, relative = relative,
                absolute = work_dir .. "/" .. relative })
        end
    end

    local chapter_candidates = {}
    local total = 0
    for _, current in ipairs(chapters) do
        local document = read_file(current.absolute)
        local candidates = document and collect_overlay_candidates(document,
            current.relative, current.index, false) or {}
        if #candidates == 0 and document then
            candidates = collect_overlay_candidates(document, current.relative,
                current.index, true)
        end
        chapter_candidates[current.index] = candidates
        total = total + #candidates
    end
    if total == 0 then cleanup(); return nil, "没有找到可翻译的段落" end

    if not Tools.mkdir_p(output_dir) then
        cleanup(); return nil, "无法创建本书翻译缓存目录"
    end
    local output = output_dir .. "/manifest.json"
    local legacy_path = output_dir .. "/overlay.json"
    local entries, entry_index = {}, {}
    -- A killed subprocess or closing the book may interrupt a run.  Keep the
    -- batches already completed and merge into them on the next run.
    local covered_indexes, covered_seen = {}, {}
    local function carry_chapters(list)
        if type(list) ~= "table" then return end
        for _, index in ipairs(list) do
            if not covered_seen[index] then
                covered_seen[index] = true
                covered_indexes[#covered_indexes + 1] = index
            end
        end
    end
    local previous
    local legacy_consumed = false
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
        local pstate = manifest.providers and manifest.providers[provider]
        carry_chapters(pstate and pstate.chapters)
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
            carry_chapters(legacy.chapters)
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
            spine_count = chapter.spine_count or 0,
            book_size = lfs.attributes(book_path, "size") or 0,
            book_mtime = lfs.attributes(book_path, "modification") or 0,
            display_mode = "auto", display_fallback = true,
            last_used_at = {}, fallback_order = {}, providers = {},
        }
    end
    local function save_checkpoint(complete)
        -- Never replace an existing overlay with an empty one.  When the
        -- provider changed and every request failed, writing an empty
        -- checkpoint would erase the previous provider's finished entries.
        if #entries == 0 then return true end
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
            if #merged == 0 then return true end
            local manifest = Overlay.loadManifest(output_dir) or fresh_manifest()
            manifest.providers = manifest.providers or {}
            local existing = manifest.providers[provider]
            upsert_provider_state(manifest, provider, {
                display_name = existing and existing.display_name or provider,
                kind = existing and existing.kind or provider_kind(provider),
                model_name = existing and existing.model_name,
                confirmed = existing == nil or existing.confirmed ~= false,
                -- Spine indexes covered so far.  Chapter-mode runs never set
                -- complete, so follow mode uses this list to tell "chapter
                -- already translated" from "whole book done".
                chapters = covered_indexes,
                partial_chapters = existing and existing.partial_chapters or {},
                failed_chapters = existing and existing.failed_chapters or {},
                complete = complete == true,
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
    local last_processed_index = 0
    local function cancel_requested()
        if not cancel_path then return false end
        local file = io.open(cancel_path, "rb")
        if file then file:close() return true end
        return false
    end
    write_progress(progress_path, 0, total, 0, 0, 0, #chapters)
    for _, current in ipairs(chapters) do
        if cancel_requested() then cancelled = true; break end
        last_processed_index = current.index
        if not covered_seen[current.index] then
            covered_seen[current.index] = true
            covered_indexes[#covered_indexes + 1] = current.index
        end
        local candidates = chapter_candidates[current.index] or {}
        -- Release the collected source text of this chapter as soon as its
        -- batch loop finishes.  On a several-hundred-chapter book the full
        -- candidate list would otherwise stay resident for the whole run,
        -- needlessly raising the subprocess memory watermark.
        local function release_chapter()
            chapter_candidates[current.index] = nil
        end
        local batch_size = 48
        for first = 1, #candidates, batch_size do
            if cancel_requested() then cancelled = true; break end
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
                        created_at = os.time() }
                    local existing = entry_index[entry.selector]
                    if existing then
                        entries[existing] = entry
                    else
                        entries[#entries + 1] = entry
                        entry_index[entry.selector] = #entries
                    end
                    translated_count = translated_count + 1
                else
                    failed_count = failed_count + 1
                end
                write_progress(progress_path, processed, total, translated_count,
                    failed_count, current.index, #chapters)
            end
            -- Atomic JSON replacement after every network batch provides a
            -- real restart point even when KOReader or the book closes.
            save_checkpoint(false)
        end
        release_chapter()
    end
    if translated_count == 0 and not cancelled then
        cleanup()
        return nil, type(first_error) == "table" and first_error.message
            or tostring(first_error or "翻译服务没有返回译文")
    end
    -- Only a whole-book run may mark the overlay complete.  A chapter-mode
    -- run (span == 1, follow mode) must leave it incomplete so page-turn
    -- scheduling keeps working and the "翻译本书" entry does not report the
    -- book as done while chapters are still missing.
    local saved = save_checkpoint(all_chapters and not cancelled and failed_count == 0)
    cleanup()
    if not saved then return nil, "无法保存本书翻译缓存" end
    return {
        output = output,
        overlay = true,
        chapters = #chapters,
        translated = translated_count,
        failed = failed_count,
        cancelled = cancelled,
        last_chapter = last_processed_index >= (chapter.spine_count or 1),
    }
end

-- EPUB outline (design 7.2): the chapter list behind the picker.  Identity is
-- the spine index, titles are display-only (design 6.5).

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
    for _, child in ipairs(chosen.children) do
        if child.name == "ol" then walk_list(child, 0) end
    end
    return entries
end

local function toc_href(base, href)
    if not href or href == "" then return nil end
    local path = href:gsub("#.*$", "")
    if path == "" then return nil end
    path = socket_url.unescape(path)
    if path:sub(1, 1) == "/" then return normalize_path(path) end
    return normalize_path(base .. "/" .. path)
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

local function toc_chapters(entries, base, spine, exact, lowered, logger)
    local chapters, by_index = {}, {}
    for _, entry in ipairs(entries) do
        local href = toc_href(base, entry.href)
        local index, original
        if href then index, original = map_to_spine(href, spine, exact, lowered) end
        if not index then
            logger.warn("dualtranslate: outline entry not in spine, skipped:",
                tostring(entry.href))
        else
            local level = tonumber(entry.level) or 0
            local title = entry.title
            if not title or title == "" then title = string.format("第 %d 节", index) end
            local kept = by_index[index]
            if not kept then
                kept = { index = index, title = title, href = original, level = level }
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
            local chapters = entries
                and toc_chapters(entries, base, package.spine, exact, lowered, logger) or {}
            if #chapters > 0 then
                return { source = source, spine_count = #package.spine, chapters = chapters }
            end
        end
    end
    return { source = "spine", spine_count = #package.spine,
        chapters = spine_chapters(package.spine) }
end

local function outline_cache_file(book_path)
    return DataStorage:getDataDir() .. "/cache/dualtranslate/outline/"
        .. Tools.stable_path_hash(book_path) .. ".json"
end

local function load_outline_cache(book_path, size, mtime)
    local raw = read_file(outline_cache_file(book_path))
    if not raw then return nil end
    local JSON = require("json")
    local ok, doc = pcall(JSON.decode, raw)
    if not ok or type(doc) ~= "table" or doc.version ~= 1 then return nil end
    -- size/mtime are part of the key: a replaced or edited book must reparse.
    if doc.book_path ~= book_path or doc.book_size ~= size or doc.book_mtime ~= mtime then
        return nil
    end
    if doc.source ~= "ncx" and doc.source ~= "nav" and doc.source ~= "spine" then return nil end
    if type(doc.spine_count) ~= "number" or type(doc.chapters) ~= "table" then return nil end
    local chapters = {}
    for _, chapter in ipairs(doc.chapters) do
        if type(chapter) ~= "table" or type(chapter.index) ~= "number"
            or type(chapter.title) ~= "string" or type(chapter.href) ~= "string" then
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
    return { source = doc.source, spine_count = doc.spine_count, chapters = chapters }
end

local function save_outline_cache(book_path, size, mtime, outline)
    local logger = require("logger")
    local JSON = require("json")
    local path = outline_cache_file(book_path)
    local ok, encoded = pcall(JSON.encode, {
        version = 1, book_path = book_path, book_size = size, book_mtime = mtime,
        source = outline.source, spine_count = outline.spine_count,
        chapters = outline.chapters,
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
    if type(book_path) == "table" then book_path = ... end
    if type(book_path) ~= "string" or book_path == "" then return nil, "缺少书路径" end
    if not book_path:lower():match("%.epub$") then
        return nil, "目录解析目前仅支持 EPUB"
    end
    local size = lfs.attributes(book_path, "size")
    local mtime = lfs.attributes(book_path, "modification") or 0
    if not size then return nil, "找不到书文件" end
    local cached = load_outline_cache(book_path, size, mtime)
    if cached then return cached end

    local nonce = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    local work_dir = DataStorage:getDataDir() .. "/cache/dualtranslate/outline_" .. nonce
    if not Tools.mkdir_p(work_dir) then return nil, "无法创建临时目录" end
    -- pcall keeps the cleanup unconditional: a parse error must not leave an
    -- outline_<nonce> directory behind (design 7.2).
    local ok, result, err = pcall(parse_outline, book_path, work_dir)
    Tools.rmtree(work_dir)
    if not ok then return nil, tostring(result) end
    if not result then return nil, err end
    save_outline_cache(book_path, size, mtime, result)
    return result
end

return Epub
