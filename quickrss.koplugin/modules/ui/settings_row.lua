-- QuickRSS: Shared settings row builder
-- Rakuyomi-style 60/40 split row used by both SettingsUI and ReaderSettingsUI.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")

local Screen = Device.screen

local PAD        = Screen:scaleBySize(6)
local ROW_H      = Screen:scaleBySize(46)
local LABEL_FACE = Font:getFace("cfont", 16)
local VALUE_FACE = Font:getFace("smallinfofontbold", 16)

local function makeRow(inner_w, label, val_widget, on_tap)
    local content_w = inner_w - PAD * 2
    local label_w   = math.floor((content_w - PAD) * 0.60)
    local dimen = Geom:new{ x = 0, y = 0, w = inner_w, h = ROW_H }
    local row   = InputContainer:new{ dimen = dimen }
    row.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = dimen } },
    }
    row.onTap = function() on_tap(); return true end
    row[1] = FrameContainer:new{
        width      = inner_w,
        height     = ROW_H,
        padding    = PAD,
        margin     = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            TextBoxWidget:new{
                text          = label,
                face          = LABEL_FACE,
                width         = label_w,
                height        = ROW_H - PAD * 2,
                height_adjust = true,
                alignment     = "left",
            },
            HorizontalSpan:new{ width = PAD },
            HorizontalGroup:new{
                align = "center",
                val_widget,
                HorizontalSpan:new{ width = Screen:scaleBySize(4) },
                TextWidget:new{ text = "›", face = VALUE_FACE },
            },
        },
    }
    return row
end

return {
    makeRow    = makeRow,
    PAD        = PAD,
    ROW_H      = ROW_H,
    LABEL_FACE = LABEL_FACE,
    VALUE_FACE = VALUE_FACE,
}
