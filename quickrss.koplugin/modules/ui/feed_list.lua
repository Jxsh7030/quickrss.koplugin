-- QuickRSS: Feed List UI
-- Fixed-size centered popup for managing configured feeds: add, remove.
-- The list scrolls when there are more feeds than fit in the viewport.
-- Opened from the settings icon in QuickRSSUI's title bar.
--
-- Constructor fields:
--   reload_callback  function()  called when the popup closes after a change

local Blitbuffer          = require("ffi/blitbuffer")
local Button              = require("ui/widget/button")
local CenterContainer     = require("ui/widget/container/centercontainer")
local Config              = require("modules/data/config")
local Icons               = require("modules/ui/icons")
local Device              = require("device")
local Font                = require("ui/font")
local FrameContainer      = require("ui/widget/container/framecontainer")
local Geom                = require("ui/geometry")
local GestureRange        = require("ui/gesturerange")
local HorizontalGroup     = require("ui/widget/horizontalgroup")
local InputContainer      = require("ui/widget/container/inputcontainer")
local LineWidget          = require("ui/widget/linewidget")
local MultiInputDialog    = require("ui/widget/multiinputdialog")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size                = require("ui/size")
local TextBoxWidget       = require("ui/widget/textboxwidget")
local TextWidget          = require("ui/widget/textwidget")
local TitleBar            = require("ui/widget/titlebar")
local UIManager           = require("ui/uimanager")
local VerticalGroup       = require("ui/widget/verticalgroup")
local VerticalSpan        = require("ui/widget/verticalspan")
local _                   = require("gettext")

local Screen = Device.screen

-- ── Layout constants ──────────────────────────────────────────────────────────
local PAD       = Screen:scaleBySize(10)
local DEL_W     = Screen:scaleBySize(48)
local ROW_H     = Screen:scaleBySize(68)
local NAME_FACE = Font:getFace("smallinfofontbold", 15)
local URL_FACE  = Font:getFace("smallinfofont", 12)

-- ─────────────────────────────────────────────────────────────────────────────
local FeedListUI = InputContainer:extend{
    name            = "quickrss_feed_list",
    reload_callback = nil,   -- set by QuickRSSUI
    _feeds_changed  = false,
}

function FeedListUI:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    self.key_events = {
        Close = { { "Back" }, doc = "close feed settings" },
    }

    -- ── Fixed popup dimensions ────────────────────────────────────────────────
    -- The popup is always the same size regardless of how many feeds exist.
    -- The feed list scrolls when content is taller than the viewport.
    local popup_w = math.floor(screen_w * 0.9)
    local popup_h = math.floor(screen_h * 0.72)
    self.popup_w  = popup_w

    -- inner_w is the content width used for feed rows and separators.
    -- It is PAD narrower than popup_w so there is a clear white gap between
    -- the rightmost content (× button) and the popup border.
    self.inner_w = popup_w - PAD

    -- ── Title bar ─────────────────────────────────────────────────────────────
    -- TitleBar stays popup_w wide so its bottom line reaches both borders.
    local title_bar = TitleBar:new{
        width            = popup_w,
        title            = Icons.FEEDS .. "  " .. _("Feeds"),
        with_bottom_line = true,
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }
    local title_h = title_bar:getSize().h

    -- ── Footer (Add Feed button) ───────────────────────────────────────────────
    local add_button = Button:new{
        text      = _("+ Add Feed"),
        callback  = function() self:_addFeedDialog() end,
        width     = popup_w - PAD * 4,
        bordersize = Size.border.button,
        padding   = PAD,
    }
    local footer_h = add_button:getSize().h + PAD * 2

    local footer = CenterContainer:new{
        dimen = Geom:new{ w = popup_w, h = footer_h },
        add_button,
    }

    -- ── Scrollable feed list ───────────────────────────────────────────────────
    -- Reserve PAD pixels at the bottom for a gap between the footer and the
    -- popup border; the VerticalSpan below accounts for it.
    self.scroll_h  = popup_h - title_h - footer_h - PAD
    self.feed_list = VerticalGroup:new{ align = "left" }

    self.scroll_container = ScrollableContainer:new{
        dimen       = Geom:new{ w = popup_w, h = self.scroll_h },
        show_parent = self,
        self.feed_list,
    }

    -- ── Popup frame ───────────────────────────────────────────────────────────
    -- No padding on the frame itself; the right gap comes from inner_w being
    -- narrower than popup_w, and the bottom gap from the VerticalSpan.
    local popup = FrameContainer:new{
        width     = popup_w,
        height    = popup_h,
        padding   = 0,
        margin    = 0,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            title_bar,
            self.scroll_container,
            footer,
            VerticalSpan:new{ width = PAD },  -- bottom gap before border
        },
    }

    -- The outer InputContainer covers the full screen so key events (Back)
    -- are delivered correctly; the visual popup is centered within it.
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        popup,
    }

    self:_populateFeeds()
end

-- Rebuild the feed list and request a repaint.
function FeedListUI:_populateFeeds()
    self.feed_list:clear()
    self.feed_list:resetLayout()

    local feeds = Config.getFeeds()

    if #feeds == 0 then
        table.insert(self.feed_list, CenterContainer:new{
            dimen = Geom:new{ w = self.inner_w, h = self.scroll_h },
            TextWidget:new{
                text = _("No feeds yet.\nTap + Add Feed to get started."),
                face = Font:getFace("cfont", 15),
            },
        })
    else
        for i, feed in ipairs(feeds) do
            table.insert(self.feed_list, self:_makeFeedRow(feed, i))
            if i < #feeds then
                table.insert(self.feed_list, LineWidget:new{
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                    dimen      = Geom:new{ w = self.inner_w, h = Size.line.thin },
                    style      = "solid",
                })
            end
        end
    end

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- Build one row: name+url text on the left, delete button on the right.
-- Uses inner_w (= popup_w - PAD) so the rightmost content sits PAD pixels
-- away from the popup border, keeping it clearly inside the frame.
function FeedListUI:_makeFeedRow(feed, index)
    local row_w  = self.inner_w
    local text_w = row_w - DEL_W - PAD * 3

    local tapper = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = row_w - DEL_W, h = ROW_H },
    }
    tapper.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = tapper.dimen } },
    }
    tapper.onTap = function() return true end
    tapper[1] = FrameContainer:new{
        width     = row_w - DEL_W,
        height    = ROW_H,
        padding   = PAD,
        margin    = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text          = feed.name,
                face          = NAME_FACE,
                width         = text_w,
                height        = Screen:scaleBySize(24),
                height_adjust = true,
                alignment     = "left",
            },
            VerticalSpan:new{ width = math.floor(PAD / 2) },
            TextBoxWidget:new{
                text          = feed.url,
                face          = URL_FACE,
                width         = text_w,
                height        = Screen:scaleBySize(20),
                height_adjust = true,
                alignment     = "left",
            },
        },
    }

    local del_btn = Button:new{
        text      = "×",
        callback  = function() self:_deleteFeed(index) end,
        width     = DEL_W,
        height    = ROW_H,
        bordersize = 0,
        padding   = 0,
    }

    return HorizontalGroup:new{
        align = "center",
        tapper,
        del_btn,
    }
end

-- Confirm, then remove a feed, persist, and redraw.
function FeedListUI:_deleteFeed(index)
    local feeds = Config.getFeeds()
    local name  = feeds[index] and feeds[index].name or "?"
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Remove feed?\n") .. name,
        ok_text = _("Remove"),
        ok_callback = function()
            table.remove(feeds, index)
            Config.saveFeeds(feeds)
            self._feeds_changed = true
            self:_populateFeeds()
            UIManager:forceRePaint()
        end,
    })
end

-- Two-field dialog for entering name + URL.
function FeedListUI:_addFeedDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title  = _("Add Feed"),
        fields = {
            { hint = _("Name  (e.g. Ars Technica)") },
            { hint = _("URL   (e.g. feeds.example.com/rss)") },
        },
        buttons = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text             = _("Add"),
                is_enter_default = true,
                callback         = function()
                    local fields = dialog:getFields()
                    local name   = fields[1]:match("^%s*(.-)%s*$")
                    local url    = fields[2]:match("^%s*(.-)%s*$")
                    UIManager:close(dialog)
                    if name == "" or url == "" then return end
                    local feeds = Config.getFeeds()
                    table.insert(feeds, { name = name, url = url })
                    Config.saveFeeds(feeds)
                    self._feeds_changed = true
                    self:_populateFeeds()
                    UIManager:forceRePaint()
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function FeedListUI:onClose()
    UIManager:close(self)
    if self._feeds_changed and self.reload_callback then
        self.reload_callback()
    end
end

return FeedListUI
