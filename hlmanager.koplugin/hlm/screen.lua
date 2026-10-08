--[[--
Base class for every full-screen view.

* Swipe west/east and the page-turn keys call nextPage()/prevPage().
* Back (or swipe south on screens with a close button) calls onClose().
* A full flashing refresh when a screen opens clears e-ink ghosting; updates
  inside a screen use the cheaper "ui" refresh.
* Rotation/resize rebuilds the layout from the new screen size.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Kit = require("hlm/kit")
local Screen = Device.screen

local BaseScreen = InputContainer:extend{
    covers_fullscreen = true,
    name = "hlmanager_screen",
    app = nil,
    closable = true, -- swipe south closes
}

function BaseScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        local Input = Device.input
        self.key_events = {
            Close = { { Input.group.Back } },
            NextPage = { { Input.group.PgFwd } },
            PrevPage = { { Input.group.PgBack } },
        }
    end
    if self.setup then self:setup() end
    self:rebuild()
end

-- Subclasses implement build(width, height) -> widget filling the screen.
function BaseScreen:rebuild()
    local w, h = self.dimen.w, self.dimen.h
    local content = self:build(w, h)
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Kit.WHITE,
        TopContainer:new{
            dimen = Geom:new{ w = w, h = h },
            content,
        },
    }
end

-- Rebuild and repaint in place. Screens covered by another one are only
-- rebuilt; they repaint when revealed.
function BaseScreen:refresh(full)
    self:rebuild()
    if self.app and self.app:topScreen() ~= self then return end
    UIManager:setDirty(self, function()
        return full and "flashui" or "ui", self.dimen
    end)
end

function BaseScreen:onScreenResize(dimen)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if self.ges_events and self.ges_events.Swipe then
        self.ges_events.Swipe[1].range = self.dimen
    end
    self:refresh(true)
end

function BaseScreen:onSetRotationMode()
    -- KOReader resizes the screen and then sends ScreenResize; nothing to do here.
end

function BaseScreen:onSwipe(_, ges)
    local BD = require("ui/bidi")
    local dir = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if dir == "west" then
        self:onNextPage()
    elseif dir == "east" then
        self:onPrevPage()
    elseif dir == "south" and self.closable then
        self:onClose()
    elseif dir ~= "north" then
        UIManager:setDirty(nil, "full") -- diagonal: manual full refresh
    end
    return true
end

-- Called when the screen above this one closes.
function BaseScreen:onRevealed()
    if self.onDataChanged then self:onDataChanged() end
    self:refresh()
end

-- Paging shared by list screens (they set self.page and self.pages).
function BaseScreen:goPage(p)
    if not self.pages then return end
    p = math.max(1, math.min(p, self.pages))
    if p ~= self.page then
        self.page = p
        self:refresh()
    end
end

function BaseScreen:onNextPage()
    if self.page then self:goPage(self.page + 1) end
    return true
end

function BaseScreen:onPrevPage()
    if self.page then self:goPage(self.page - 1) end
    return true
end

function BaseScreen:askPage()
    local InputDialog = require("ui/widget/inputdialog")
    local T = require("ffi/util").template
    local _ = require("gettext")
    local dialog
    dialog = InputDialog:new{
        title = T(_("Go to page (1–%1)"), self.pages),
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Go"), is_enter_default = true, callback = function()
                local p = tonumber(dialog:getInputText())
                UIManager:close(dialog)
                if p then self:goPage(p) end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BaseScreen:isLandscape()
    return self.dimen.w > self.dimen.h
end

--[[
Fixed-height rows laid out top-to-bottom, in two columns in landscape.
opts = { count, row_h, height, width, build = function(i, row_width) }
Sets self.per_page / self.pages and clamps self.page.
]]
function BaseScreen:pagedRows(opts)
    local cols = self:isLandscape() and 2 or 1
    local gap = Kit.dp(24)
    local col_w = cols == 1 and opts.width or math.floor((opts.width - gap) / 2)
    local per_col = math.max(1, math.floor(opts.height / opts.row_h))
    self.per_page = per_col * cols
    self.pages = math.max(1, math.ceil(opts.count / self.per_page))
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local first = (self.page - 1) * self.per_page + 1
    local grid = HorizontalGroup:new{ align = "top" }
    for c = 1, cols do
        local col = VerticalGroup:new{ align = "left" }
        local from = first + (c - 1) * per_col
        for i = from, math.min(opts.count, from + per_col - 1) do
            table.insert(col, opts.build(i, col_w))
        end
        if c > 1 then table.insert(grid, Kit.hspan(gap)) end
        table.insert(grid, col)
    end
    return grid
end

-- Pager + section tabs for tab screens: stacked in portrait, one shared row
-- in landscape (height matters more there).
function BaseScreen:bottomBar(width, active_tab)
    local app = self.app
    local function pick(id) app:showTab(id) end
    if not self:isLandscape() then
        return VerticalGroup:new{
            align = "left",
            self:pagerWidget(width),
            Kit.tabbar(width, active_tab, pick),
        }
    end
    local pager_w = math.floor(width * 0.5)
    local tabs = Kit.tabbar(width - pager_w - Kit.dp(2), active_tab, pick, true)
    local h = math.max(Kit.PAGER_H, tabs:getSize().h)
    return HorizontalGroup:new{
        align = "bottom",
        Kit.box(pager_w, h, self:pagerWidget(pager_w), "top"),
        LineWidget:new{ dimen = Geom:new{ w = Kit.dp(2), h = h }, background = Kit.BLACK },
        tabs,
    }
end

-- Height bottomBar() will take (it needs self.pages, known only after layout).
function BaseScreen:bottomBarHeight(width)
    if not self:isLandscape() then
        return Kit.PAGER_H + Kit.tabbar(width, "library", function() end):getSize().h
    end
    local tabs = Kit.tabbar(width - math.floor(width * 0.5) - Kit.dp(2), "library", function() end, true)
    return math.max(Kit.PAGER_H, tabs:getSize().h)
end

-- Standard pager wired to the helpers above.
function BaseScreen:pagerWidget(width)
    return Kit.pager{
        width = width, page = self.page, pages = self.pages,
        on_prev = function() self:onPrevPage() end,
        on_next = function() self:onNextPage() end,
        on_first = function() self:goPage(1) end,
        on_last = function() self:goPage(self.pages) end,
        on_goto = function() self:askPage() end,
    }
end

function BaseScreen:onClose()
    if self.app then
        self.app:closeScreen(self)
    else
        UIManager:close(self)
    end
    return true
end

return BaseScreen
