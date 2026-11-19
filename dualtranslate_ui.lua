local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local TranslationUI = {}

-- A message the user has to acknowledge: no timeout, tap anywhere to close.
-- Used where the result matters and a 3-second notification would be missed
-- (an export that took a minute, an engine that cannot be reached).  The
-- widget is required lazily so headless callers (tests, dtctl) can load this
-- module without pulling in the whole device stack.
function TranslationUI.showPersistent(message)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = nil,
    })
end

function TranslationUI.showError(message)
    UIManager:show(Notification:new{
        text = message,
        timeout = 5,
    })
end

function TranslationUI.showInfo(message, timeout)
    UIManager:show(Notification:new{
        text = message,
        timeout = timeout or 3,
    })
end

-- InfoMessage centres its box on screen.  The chapter picker's detail belongs
-- at the top instead: it describes the row the user just held, and the middle
-- of the screen is where that row is.  A container that centres horizontally
-- and pins to the top, built lazily so this module still loads headless.
local top_center_class

local function top_center_container()
    if top_center_class then return top_center_class end
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    top_center_class = WidgetContainer:extend{}
    function top_center_class:paintTo(bb, x, y)
        local size = self[1]:getSize()
        local left = x + math.floor((self.dimen.w - size.w) / 2)
        if left < x then left = x end
        self[1]:paintTo(bb, left, y + (self.top_margin or 0))
    end
    return top_center_class
end

-- A longer message whose lines must not be cut: the toast renders one line
-- per "\n" and truncates anything wider than the screen with "…", while the
-- info box wraps.  Used for the chapter picker's long-press detail, where the
-- point is showing the whole TOC label.  Near full width, ten seconds, top of
-- the screen.
function TranslationUI.showDetail(message, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    local Screen = require("device").screen
    local Size = require("ui/size")
    local detail = InfoMessage:new{
        text = message,
        timeout = timeout or 10,
        width_factor = 0.9,
        show_icon = false,
    }
    -- Reparent the box: the widget keeps its frame, the layout around it just
    -- stops centring.  MovableContainer records the paint position in its
    -- dimen, so the refresh area follows.
    detail[1] = top_center_container():new{
        dimen = Screen:getSize(),
        top_margin = Size.margin.default,
        detail[1][1],
    }
    UIManager:show(detail)
end

return TranslationUI
