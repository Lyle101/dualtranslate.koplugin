-- ============================================================
-- 条目级覆盖：锚点范围 ↔ 目录条目的位置换算
-- ============================================================
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

package.path = "tests/?.lua;./?.lua;" .. package.path
local Coverage = require("dualtranslate_coverage")

print("== 1. 锚点位置表 ==")
do
    local rows = {
        { anchor = "a" }, { anchor = "b" }, { anchor = "b" }, { anchor = nil },
        { anchor = "c" },
    }
    local positions = Coverage.anchor_positions(rows)
    check("重复锚点记住首末位置", positions.b.first == 2 and positions.b.last == 3,
        positions.b and (positions.b.first .. "-" .. positions.b.last))
    check("无锚点行不入表", positions.b ~= nil and positions[""] == nil)
    check("末尾锚点", positions.c.first == 5 and positions.c.last == 5)

    local first, last = Coverage.range_span({ from = "a", to = "c" }, positions, #rows)
    check("范围换算成条目区间", first == 1 and last == 4, tostring(first) .. "-" .. tostring(last))
    first, last = Coverage.range_span({ from = "b", to = nil }, positions, #rows)
    check("缺终点 = 到文件末", first == 2 and last == 5)
    first, last = Coverage.range_span({ from = nil, to = "b" }, positions, #rows)
    -- 终点锚点被两条目录条目共用时，两条都在范围之外（切片停在锚点之前）
    check("共用的终点锚点整组排除", first == 1 and last == 1,
        tostring(first) .. "-" .. tostring(last))
    first, last = Coverage.range_span({ from = "a", to = "b" }, positions, #rows)
    check("终点前的条目仍被覆盖", first == 1 and last == 1)
    first, last = Coverage.range_span({ from = "zz", to = nil }, positions, #rows)
    check("未知起点放宽到文件头", first == 1 and last == 5)
    first, last = Coverage.range_span({ from = "a", to = "zz" }, positions, #rows)
    check("未知终点放宽到文件末", first == 1 and last == 5)
    first, last = Coverage.range_span({ from = "c", to = "a" }, positions, #rows)
    check("倒序范围不覆盖任何条目", first == nil)
    -- 目录重新解析/换书后锚点全变：两端都找不到时不能放宽到整文件，否则整本被
    -- 标成已翻译、逐章模式永久跳过
    first, last = Coverage.range_span({ from = "gone1", to = "gone2" }, positions, #rows)
    check("两端锚点都漂移时不覆盖", first == nil,
        tostring(first) .. "-" .. tostring(last))
    -- 手改/截断的 manifest 里出现非表条目不能让选择器崩
    local cleaned = Coverage.merge_ranges({ { 1, 2 }, { from = "a", to = "b" } }, {})
    check("畸形范围条目被忽略", #cleaned == 1 and cleaned[1].from == "a", #cleaned)
end

print("== 2. 范围合并 ==")
do
    local merged = Coverage.merge_ranges(
        { { from = "a", to = "b", done = true } },
        { { from = "a", to = "b" }, { from = "b", to = nil } })
    check("同一范围不重复，完成态保留", #merged == 2
        and merged[1].from == "a" and merged[1].done == true
        and merged[2].from == "b" and merged[2].done == nil, #merged)
    local carried = Coverage.merge_ranges(
        { { from = nil, to = nil, done = nil } },
        { { from = nil, to = nil, done = nil } })
    check("空边界范围也能合并", #carried == 1 and carried[1].from == nil)
end

print("== 3. 条目状态 ==")
do
    local rows_by_file = {
        [3] = { { anchor = "a" }, { anchor = "b" }, { anchor = "c" } },
        [4] = { { anchor = "x" } },
    }
    local full, partial = Coverage.entry_states({
        entry_ranges = {
            ["3"] = { { from = "a", to = "c", done = true },
                { from = "c", to = nil } },
            ["4"] = { { from = nil, to = nil, done = true } },
        },
    }, rows_by_file)
    check("完成的条目记 done", full["3.1"] == true and full["3.2"] == true)
    check("未完成的范围记 partial", partial["3.3"] == true and full["3.3"] == nil)
    check("整文件范围覆盖唯一条目", full["4.1"] == true, tostring(full["4.1"]))
    local none_full, none_partial = Coverage.entry_states({}, rows_by_file)
    check("没有覆盖表时什么也不标", next(none_full) == nil and next(none_partial) == nil)
end

print("== 4. 当前页 → 条目 ==")
do
    local pages = { { position = 1, page = 5 }, { position = 2, page = 9 },
        { position = 3, page = 9 }, { position = 4, page = 20 } }
    check("页面落在两条之间取前一条", Coverage.entry_at_page(pages, 12) == 3)
    check("同一页的多条取最后一条", Coverage.entry_at_page(pages, 9) == 3)
    check("首页之前算第一条", Coverage.entry_at_page(pages, 3) == 1)
    check("超出最后一条仍算最后一条", Coverage.entry_at_page(pages, 99) == 4)
    check("没有可用锚点返回 nil", Coverage.entry_at_page({}, 5) == nil)

    -- 同一页上出现下一条目的标题：只看页码会提前跳到下一章，
    -- 标题在页面下半部时应仍算上一章
    local same_page = { { position = 1, page = 5 }, { position = 2, page = 9 },
        { position = 3, page = 9 } }
    local function y_at(map)
        return function(item) return map[item.position] end
    end
    check("标题在页面上半部算新章",
        Coverage.reading_position(same_page, 9, 1000, y_at({ [2] = 120, [3] = 150 })) == 3)
    check("标题在页面下半部仍算上一章",
        Coverage.reading_position(same_page, 9, 1000, y_at({ [2] = 120, [3] = 860 })) == 2)
    check("拿不到坐标时退回页码判定",
        Coverage.reading_position(same_page, 9, 1000, function() return nil end) == 3)
    check("没有页面高度时退回页码判定",
        Coverage.reading_position(same_page, 9, nil, y_at({ [3] = 900 })) == 3)
    check("第一条不会被退掉",
        Coverage.reading_position(same_page, 5, 1000, y_at({ [1] = 900 })) == 1)
    check("只退同页的条目",
        Coverage.reading_position(same_page, 9, 1000, y_at({ [2] = 900, [3] = 900 })) == 1)

    local rows = {
        { anchor = "a" }, { anchor = "b" }, { anchor = "c" }, { anchor = "c" },
    }
    local range = Coverage.entry_range(rows, 1, 7)
    check("第一条从文件头开始", range.index == 7 and range.from == nil and range.to == "b",
        tostring(range.from) .. "-" .. tostring(range.to))
    range = Coverage.entry_range(rows, 2, 7)
    check("中间条目起止都带锚点", range.from == "b" and range.to == "c")
    range = Coverage.entry_range(rows, 3, 7)
    check("共用锚点时终点顺延", range.from == "c" and range.to == nil,
        tostring(range.from) .. "-" .. tostring(range.to))
    -- 第一条与第二条共用锚点：终点要跳过该锚点，否则标题被切掉
    local shared = { { anchor = "x" }, { anchor = "x" }, { anchor = "y" } }
    range = Coverage.entry_range(shared, 1, 7)
    check("首条自身锚点不算终点", range.from == nil and range.to == "y",
        tostring(range.from) .. "-" .. tostring(range.to))
    range = Coverage.entry_range(shared, 2, 7)
    check("共用锚点的后一条同样顺延", range.from == "x" and range.to == "y")
    range = Coverage.entry_range(rows, 4, 7)
    check("最后一条到文件末", range.from == "c" and range.to == nil)
    range = Coverage.entry_range({ { anchor = "solo" } }, 1, 2)
    check("单条目文件退化为整文件", range.from == nil and range.to == nil)
    check("空列表返回 nil", Coverage.entry_range({}, 1, 2) == nil)
end

print(string.format("==== 覆盖结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
