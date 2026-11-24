-- Which TOC entries a finished run covers.
--
-- A job carries anchor ranges ({index, from, to}, `to` exclusive, nil at the
-- file edges) and the manifest records the ranges that came back.  That is
-- already per chapter: a file holding nine chapters gets nine ranges, so the
-- chapter picker can mark the one that was translated instead of painting
-- "partial" over all nine.  This module turns those anchors back into entry
-- positions, which is the only thing both the picker and the page-turn follow
-- need to agree on.
local Coverage = {}

-- First and last row position of every anchor in one file.  A duplicated id
-- (bad converters emit them) takes the first occurrence as a start and the
-- last as an end, the same widening rule the slicer follows.
function Coverage.anchor_positions(rows)
    local positions = {}
    for position, row in ipairs(rows or {}) do
        local anchor = row.anchor
        if anchor then
            local hit = positions[anchor]
            if hit then
                hit.last = position
            else
                positions[anchor] = { first = position, last = position }
            end
        end
    end
    return positions
end

-- Entry positions a stored range covers: `first, last` inclusive, or nil when
-- the range cannot own an entry.  A missing anchor widens to the file edge:
-- too much coverage is recoverable, a hidden chapter is not.
function Coverage.range_span(range, positions, row_count)
    local first = 1
    if range.from then
        local hit = positions[range.from]
        if hit then first = hit.first end
    end
    local last = row_count
    if range.to then
        local hit = positions[range.to]
        if hit then last = hit.last - 1 end
    end
    if last < first then return nil end
    return first, last
end

local function range_key(range)
    return tostring(range.from or "") .. "\0" .. tostring(range.to or "")
end

-- Merge new coverage into the list the manifest already holds.  A range that
-- finished stays finished when a later run of the same range fails: entries
-- are only ever added or replaced, so coverage can only grow.
function Coverage.merge_ranges(existing, additions)
    local merged, by_key = {}, {}
    for _, list in ipairs({ existing or {}, additions or {} }) do
        for _, range in ipairs(list) do
            local key = range_key(range)
            local at = by_key[key]
            if at then
                if range.done == true then merged[at].done = true end
            else
                merged[#merged + 1] = { from = range.from, to = range.to,
                    done = range.done == true or nil }
                by_key[key] = #merged
            end
        end
    end
    return merged
end

-- Done / partial entry keys ("index.position") for one provider.  The map is
-- the manifest's `entry_ranges` (the fields are read by caller); a file that
-- only appears in `chapters` needs no map — every row is already translated.
function Coverage.entry_states(provider, rows_by_file)
    local full, partial = {}, {}
    local ranges = type(provider) == "table"
        and type(provider.entry_ranges) == "table" and provider.entry_ranges or nil
    if not ranges then return full, partial end
    for index, rows in pairs(rows_by_file or {}) do
        local list = ranges[tostring(index)]
        if type(list) == "table" then
            local positions = Coverage.anchor_positions(rows)
            for _, range in ipairs(list) do
                local first, last = Coverage.range_span(range, positions, #rows)
                if first then
                    for position = first, last do
                        local key = index .. "." .. position
                        if range.done == true then
                            full[key] = true
                        elseif not full[key] then
                            partial[key] = true
                        end
                    end
                end
            end
        end
    end
    return full, partial
end

-- The entry being read: the last anchor that starts at or before `page`.  A
-- page before the first anchor belongs to the first entry, whose text runs
-- from the file start.
--
-- When two entries start on the same page, the later one wins: that page is
-- mostly the new chapter's text, and the tail of the previous chapter was
-- already reachable (and translated) while the reader was on that entry.
function Coverage.entry_at_page(pages, page)
    local current
    for _, item in ipairs(pages or {}) do
        if item.page <= page and (not current or item.page >= current.page) then
            current = item
        end
    end
    if current then return current.position end
    -- Page before the first anchor: still the first entry.
    if pages and #pages > 0 then return 1 end
    return nil
end

-- The entry being read, with the page's own layout taken into account: a
-- chapter heading that only appears at the bottom of the page is not the
-- chapter being read yet (the page still shows the previous one above it),
-- even though CREngine reports the same page for both.  `y_of(item)` returns
-- the heading's vertical position inside the page, or nil when unknown; the
-- entry counts as current only when it starts in the upper half.
function Coverage.reading_position(pages, page, height, y_of)
    local position = Coverage.entry_at_page(pages, page)
    if not position or not height or height <= 0 or type(y_of) ~= "function" then
        return position
    end
    local by_position = {}
    for _, item in ipairs(pages or {}) do by_position[item.position] = item end
    while position > 1 do
        local item = by_position[position]
        if not item or item.page ~= page then break end
        local y = y_of(item)
        if type(y) ~= "number" or y <= height * 0.5 then break end
        position = position - 1
    end
    return position
end

-- The job range a TOC entry covers: from its own anchor to the next distinct
-- one.  The first entry of a file starts at the file edge (nil) even when it
-- carries an anchor — its opening text precedes that anchor, and a range
-- starting there would drop it.  An entry without an anchor inherits the
-- previous one, because that is where its text begins.
function Coverage.entry_range(rows, position, index)
    rows = rows or {}
    if #rows == 0 then return nil end
    position = math.max(1, math.min(tonumber(position) or 1, #rows))
    local from
    if position > 1 then
        from = rows[position].anchor
        if not from then
            for probe = position - 1, 1, -1 do
                if rows[probe].anchor then from = rows[probe].anchor break end
            end
        end
    end
    -- The end is the next anchor this entry does not already own: adjacent
    -- TOC labels sometimes share one, and slicing stops *before* the end
    -- anchor, so ending on the entry's own anchor would cut its heading.
    local stops = {}
    if from then stops[from] = true end
    if rows[position].anchor then stops[rows[position].anchor] = true end
    local to
    for probe = position + 1, #rows do
        local anchor = rows[probe].anchor
        if anchor and not stops[anchor] then to = anchor break end
    end
    return { index = index, from = from, to = to }
end

return Coverage