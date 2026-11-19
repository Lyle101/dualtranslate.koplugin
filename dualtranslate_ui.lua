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

-- A longer message whose lines must not be cut: the toast renders one line
-- per "\n" and truncates anything wider than the screen with "…", while the
-- info box wraps.  Used for the chapter picker's long-press detail, where the
-- point is showing the whole TOC label.
function TranslationUI.showDetail(message, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = timeout or 5,
        show_icon = false,
    })
end

return TranslationUI
