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

return TranslationUI
