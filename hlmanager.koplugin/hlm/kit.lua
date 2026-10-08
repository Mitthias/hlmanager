--[[--
Small UI kit shared by every Highlights screen.

Everything is sized in density-independent units through Screen:scaleBySize(),
so the same layout works on any e-ink panel and in landscape.
Colours are limited to white, black and two greys; "selected" is always solid
black so it stays readable after the panel ghosts.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

local Kit = {}

Kit.WHITE = Blitbuffer.COLOR_WHITE
Kit.BLACK = Blitbuffer.COLOR_BLACK
Kit.GREY_DARK = Blitbuffer.COLOR_GRAY_4  -- secondary text
Kit.GREY_LIGHT = Blitbuffer.COLOR_GRAY_9 -- hairlines, disabled

function Kit.dp(n)
    return Screen:scaleBySize(n)
end

-- Minimum tap target: ~7 mm on any panel, because scaleBySize tracks DPI.
Kit.TAP = Screen:scaleBySize(44)
Kit.PAD = Screen:scaleBySize(16)
Kit.GAP = Screen:scaleBySize(8)

Kit.icons_dir = nil -- set by main.lua to "<plugin>/icons"

-- Fonts ---------------------------------------------------------------------
-- UI text uses KOReader's own UI font (Noto Sans + CJK fallbacks).
-- Quotes use Noto Serif, which KOReader ships; the user can switch quotes to
-- the UI font in settings. Both fall back to Noto Sans CJK for Chinese.

Kit.SIZE = {
    title = 22,
    body = 18,
    small = 15,
    tiny = 13,
    quote_list = 18,
    quote_detail = 23,
    quote_big = 26,
}

local quote_font = "serif"

function Kit.setQuoteFont(which)
    quote_font = which == "sans" and "sans" or "serif"
end

-- Memoized: a failed Font:getFace() rescans every font folder, so a missing
-- file (e.g. a build without Noto Serif Italic) must only be tried once.
local face_cache = {}
local function face(name, size)
    local key = name .. "@" .. tostring(size)
    local f = face_cache[key]
    if f == nil then
        f = Font:getFace(name, size) or Font:getFace("cfont", size)
        face_cache[key] = f
    end
    return f
end

function Kit.ui(size)
    return face("cfont", size or Kit.SIZE.body)
end

function Kit.uiBold(size)
    return face("smallinfofontbold", size or Kit.SIZE.body)
end

function Kit.serif(size)
    if quote_font == "sans" then return Kit.ui(size) end
    return face("NotoSerif-Regular.ttf", size or Kit.SIZE.quote_list)
end

function Kit.serifItalic(size)
    if quote_font == "sans" then return Kit.ui(size) end
    return face("NotoSerif-Italic.ttf", size or Kit.SIZE.body)
end

-- Height of one line in a TextBoxWidget (mirrors TextBoxWidget's own maths).
function Kit.lineHeight(f, line_height_em)
    return math.floor((1 + (line_height_em or 0.3)) * f.size + 0.5)
end

-- Primitives ----------------------------------------------------------------

function Kit.text(text, f, opts)
    opts = opts or {}
    return TextWidget:new{
        text = text,
        face = f or Kit.ui(),
        fgcolor = opts.fgcolor or Kit.BLACK,
        bold = opts.bold,
        max_width = opts.max_width,
        padding = opts.padding,
    }
end

-- Multi-line text clamped to max_lines (ellipsis on the last line).
function Kit.textbox(text, f, width, opts)
    opts = opts or {}
    local line_height = opts.line_height or 0.3
    local height
    if opts.max_lines then
        -- Clamp to max_lines, but never reserve more lines than the text needs.
        local lines = math.min(opts.max_lines, Kit.countLines(text, f, width, line_height))
        height = Kit.lineHeight(f, line_height) * math.max(1, lines)
    elseif opts.height then
        height = opts.height
    end
    return TextBoxWidget:new{
        text = text,
        face = f,
        width = width,
        height = height,
        height_adjust = height ~= nil,
        height_overflow_show_ellipsis = height ~= nil,
        line_height = line_height,
        alignment = opts.alignment or "left",
        fgcolor = opts.fgcolor or Kit.BLACK,
        bgcolor = opts.bgcolor,
        bold = opts.bold,
    }
end

-- Number of lines `text` needs at `width` with face `f`.
function Kit.countLines(text, f, width, line_height)
    local tb = TextBoxWidget:new{ text = text, face = f, width = width, line_height = line_height or 0.3 }
    local n = tb:getAllLineCount()
    tb:free()
    return n
end

function Kit.vspan(h)
    return VerticalSpan:new{ width = h }
end

function Kit.hspan(w)
    return HorizontalSpan:new{ width = w }
end

function Kit.hline(width, thickness, color)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = thickness or Kit.dp(1) },
        background = color or Kit.BLACK,
    }
end

-- Fixed-size box; align = "left" | "center" | "right" (vertically centred)
-- or "top" (top-left corner).
function Kit.box(w, h, child, align)
    local dimen = Geom:new{ w = w, h = h }
    if align == "top" then
        return TopContainer:new{ dimen = dimen, child }
    elseif align == "left" then
        return LeftContainer:new{ dimen = dimen, child }
    elseif align == "right" then
        return RightContainer:new{ dimen = dimen, child }
    end
    return CenterContainer:new{ dimen = dimen, child }
end

-- Row with `left` aligned left and `right` aligned right inside `width`.
function Kit.spread(width, h, left, right)
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = h },
        allow_mirroring = false,
        Kit.box(left:getSize().w, h, left, "left"),
    }
    if right then
        local r = Kit.box(right:getSize().w, h, right, "right")
        r.overlap_align = "right"
        table.insert(group, r)
    end
    return group
end

local plugin_icon_cache = {} -- name -> path | false

-- Icons are flattened on white; `invert` gives a white icon for black buttons.
-- Plugin icons live in ./icons, anything else falls back to KOReader's set.
function Kit.icon(name, size, opts)
    size = size or Kit.dp(24)
    opts = opts or {}
    local file = plugin_icon_cache[name]
    if file == nil then
        file = Kit.icons_dir and (Kit.icons_dir .. "/" .. name .. ".svg")
        if not (file and require("libs/libkoreader-lfs").attributes(file, "mode") == "file") then
            file = false
        end
        plugin_icon_cache[name] = file
    end
    file = file or nil
    return IconWidget:new{
        file = file,
        icon = not file and name or nil,
        width = size,
        height = size,
        invert = opts.invert,
        dim = opts.dim,
    }
end

-- Tap -----------------------------------------------------------------------
-- Wraps any widget and makes it tappable (and optionally holdable), with the
-- standard KOReader "flash_ui" inverted feedback.

local Tap = InputContainer:extend{
    callback = nil,
    hold_callback = nil,
    enabled = true,
    no_feedback = false,
}

function Tap:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    -- Matched directly in onGesture (not via ges_events): InputContainer would
    -- re-dispatch a named event to our children, firing nested taps too.
    self._tap = GestureRange:new{ ges = "tap", range = self.dimen }
    self._hold = GestureRange:new{ ges = "hold", range = self.dimen }
    self._hold_release = GestureRange:new{ ges = "hold_release", range = self.dimen }
end

function Tap:onGesture(ev)
    if self._tap:match(ev) then
        return self:onTapKit()
    elseif self._hold:match(ev) then
        return self:onHoldKit()
    elseif self._hold_release:match(ev) then
        return self:onHoldReleaseKit()
    end
end

function Tap:onTapKit()
    if not self.enabled or not self.callback then
        -- Disabled targets still swallow the tap, so it does not fall through.
        return self.enabled == false or nil
    end
    if not self.no_feedback and G_reader_settings:nilOrTrue("flash_ui") then
        local d = self.dimen
        UIManager:widgetInvert(self, d.x, d.y, d.w, d.h)
        UIManager:setDirty(nil, "fast", d)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()
        UIManager:widgetInvert(self, d.x, d.y, d.w, d.h)
        UIManager:setDirty(nil, "ui", d)
    end
    self.callback()
    return true
end

function Tap:onHoldKit()
    if self.enabled and self.hold_callback then
        self._hold_handled = true
        self.hold_callback()
        return true
    end
    self._hold_handled = nil
end

function Tap:onHoldReleaseKit()
    if self._hold_handled then
        self._hold_handled = nil
        return true
    end
end

function Kit.tap(child, callback, hold_callback, opts)
    opts = opts or {}
    return Tap:new{
        callback = callback,
        hold_callback = hold_callback,
        enabled = opts.enabled ~= false,
        no_feedback = opts.no_feedback,
        child,
    }
end

-- Chip ----------------------------------------------------------------------
-- 44dp tall pill. Active = solid black with white text.

function Kit.chip(opts)
    local h = opts.height or Kit.TAP
    local border = Kit.dp(1.5)
    local fg = opts.active and Kit.WHITE or Kit.BLACK
    local label = Kit.text(opts.text, Kit.ui(opts.size or Kit.SIZE.small), {
        fgcolor = opts.enabled == false and Kit.GREY_LIGHT or fg,
        bold = opts.active,
        max_width = opts.max_width and (opts.max_width - 2 * Kit.dp(14) - 2 * border) or nil,
    })
    local inner_w = label:getSize().w + 2 * Kit.dp(14)
    local frame = FrameContainer:new{
        bordersize = border,
        radius = math.floor(h / 2),
        padding = 0,
        background = opts.active and Kit.BLACK or Kit.WHITE,
        color = opts.enabled == false and Kit.GREY_LIGHT or Kit.BLACK,
        Kit.box(inner_w, h - 2 * border, label),
    }
    return Kit.tap(frame, opts.callback, opts.hold_callback, { enabled = opts.enabled })
end

-- Lay out widgets left-to-right, wrapping to new lines inside `width`.
function Kit.flow(widgets, width, gap)
    gap = gap or Kit.GAP
    local rows = VerticalGroup:new{ align = "left" }
    local row = HorizontalGroup:new{ align = "center" }
    local row_w = 0
    for __, w in ipairs(widgets) do
        local ww = w:getSize().w
        if row_w > 0 and row_w + gap + ww > width then
            table.insert(rows, row)
            table.insert(rows, Kit.vspan(gap))
            row = HorizontalGroup:new{ align = "center" }
            row_w = 0
        end
        if row_w > 0 then
            table.insert(row, Kit.hspan(gap))
            row_w = row_w + gap
        end
        table.insert(row, w)
        row_w = row_w + ww
    end
    if #row > 0 then
        table.insert(rows, row)
    end
    return rows
end

-- Button --------------------------------------------------------------------
-- primary = solid black. Always at least Kit.TAP tall.

function Kit.button(opts)
    local h = math.max(opts.height or Kit.TAP, Kit.TAP)
    local w = opts.width
    local border = opts.primary and 0 or Kit.dp(1.5)
    local fg = opts.primary and Kit.WHITE or Kit.BLACK
    if opts.enabled == false then fg = Kit.GREY_LIGHT end
    local label = Kit.text(opts.text, Kit.uiBold(opts.size or Kit.SIZE.body), {
        fgcolor = fg,
        max_width = w and (w - 2 * Kit.dp(10)) or nil,
    })
    local content = label
    if opts.icon then
        content = HorizontalGroup:new{
            align = "center",
            Kit.icon(opts.icon, Kit.dp(22), { invert = opts.primary }),
            Kit.hspan(Kit.dp(8)),
            label,
        }
    end
    w = w or (content:getSize().w + 2 * Kit.dp(16))
    local frame = FrameContainer:new{
        bordersize = border,
        radius = Kit.dp(6),
        padding = 0,
        background = opts.primary and Kit.BLACK or Kit.WHITE,
        color = opts.enabled == false and Kit.GREY_LIGHT or Kit.BLACK,
        Kit.box(w - 2 * border, h - 2 * border, content),
    }
    return Kit.tap(frame, opts.callback, opts.hold_callback, { enabled = opts.enabled })
end

-- Underlined text link, 44dp tall.
function Kit.link(text, callback, opts)
    opts = opts or {}
    local label = Kit.text(text, Kit.ui(opts.size or Kit.SIZE.small), {
        fgcolor = opts.enabled == false and Kit.GREY_LIGHT or Kit.BLACK,
    })
    local lw = label:getSize().w
    local group = VerticalGroup:new{
        align = "left",
        label,
        Kit.hline(lw, Kit.dp(1), opts.enabled == false and Kit.GREY_LIGHT or Kit.BLACK),
    }
    return Kit.tap(Kit.box(lw + 2 * Kit.dp(6), opts.height or Kit.TAP, group), callback, nil,
        { enabled = opts.enabled })
end

-- Icon-only tap target (44 x 44).
function Kit.iconButton(name, callback, opts)
    opts = opts or {}
    local size = opts.size or Kit.TAP
    local icon = Kit.icon(name, opts.icon_size or Kit.dp(26), { dim = opts.enabled == false })
    return Kit.tap(Kit.box(size, size, icon), callback,
        opts.hold_callback, { enabled = opts.enabled })
end

-- Segmented control ---------------------------------------------------------
-- One row of equal cells; the selected cell is solid black.

function Kit.segmented(opts)
    local labels = opts.labels
    local n = #labels
    local border = Kit.dp(1.5)
    local h = opts.height or Kit.TAP
    local inner_w = opts.width - 2 * border
    local cell_w = math.floor((inner_w - (n - 1) * border) / n)
    local row = HorizontalGroup:new{ align = "center" }
    for i, text in ipairs(labels) do
        local selected = i == opts.selected
        local w = (i == n) and (inner_w - (n - 1) * (cell_w + border)) or cell_w
        local label = Kit.text(text, selected and Kit.uiBold(Kit.SIZE.tiny + 1) or Kit.ui(Kit.SIZE.tiny + 1), {
            fgcolor = selected and Kit.WHITE or Kit.BLACK,
            max_width = w - Kit.dp(4),
        })
        local cell = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = selected and Kit.BLACK or Kit.WHITE,
            Kit.box(w, h - 2 * border, label),
        }
        table.insert(row, Kit.tap(cell, function() opts.on_pick(i) end))
        if i < n then
            table.insert(row, LineWidget:new{
                dimen = Geom:new{ w = border, h = h - 2 * border },
                background = Kit.BLACK,
            })
        end
    end
    return FrameContainer:new{
        bordersize = border,
        padding = 0,
        background = Kit.WHITE,
        row,
    }
end

-- Check box and radio -------------------------------------------------------

function Kit.checkbox(checked, size)
    size = size or Kit.dp(22)
    local mark = checked and Kit.text("\u{2713}", Kit.uiBold(Kit.SIZE.tiny), { fgcolor = Kit.WHITE, padding = 0 })
        or Kit.vspan(0)
    return FrameContainer:new{
        bordersize = Kit.dp(2),
        padding = 0,
        radius = Kit.dp(3),
        background = checked and Kit.BLACK or Kit.WHITE,
        Kit.box(size - 2 * Kit.dp(2), size - 2 * Kit.dp(2), mark),
    }
end

function Kit.radio(checked, size)
    size = size or Kit.dp(22)
    local b = Kit.dp(2)
    local inner = Kit.vspan(0)
    if checked then
        local dot = size - 2 * b - 2 * Kit.dp(4)
        inner = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            radius = math.floor(dot / 2),
            background = Kit.BLACK,
            Kit.box(dot, dot, Kit.vspan(0)),
        }
    end
    return FrameContainer:new{
        bordersize = b,
        padding = 0,
        radius = math.floor(size / 2),
        background = Kit.WHITE,
        Kit.box(size - 2 * b, size - 2 * b, inner),
    }
end

-- A full-width tappable row: [mark] label ......... trailing
function Kit.choiceRow(opts)
    local h = math.max(opts.height or Kit.TAP, Kit.TAP)
    local mark = opts.mark
    local mark_w = mark and (mark:getSize().w + Kit.dp(12)) or 0
    local trailing = opts.trailing and Kit.text(opts.trailing, Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK })
    local trail_w = trailing and (trailing:getSize().w + Kit.dp(12)) or 0
    local label_w = opts.width - mark_w - trail_w
    local label
    if opts.sub then
        label = VerticalGroup:new{
            align = "left",
            Kit.text(opts.text, opts.face or Kit.ui(), { max_width = label_w }),
            Kit.text(opts.sub, Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = label_w }),
        }
    else
        label = Kit.text(opts.text, opts.face or Kit.ui(), { max_width = label_w })
    end
    local row = HorizontalGroup:new{ align = "center" }
    if mark then
        table.insert(row, mark)
        table.insert(row, Kit.hspan(Kit.dp(12)))
    end
    table.insert(row, Kit.box(label_w, h, label, "left"))
    if trailing then
        table.insert(row, Kit.hspan(Kit.dp(12)))
        table.insert(row, trailing)
    end
    return Kit.tap(Kit.box(opts.width, h, row, "left"), opts.callback, opts.hold_callback)
end

-- Section heading: small caps-like label with optional right-side widget.
function Kit.sectionTitle(text, width, right)
    local label = Kit.text(text, Kit.uiBold(Kit.SIZE.tiny), { fgcolor = Kit.BLACK })
    return Kit.spread(width, right and math.max(label:getSize().h, right:getSize().h) or label:getSize().h, label, right)
end

-- Header --------------------------------------------------------------------
-- [left] Title [subtitle] ...... [right widgets], 2dp black rule below.

function Kit.header(opts)
    local width = opts.width
    local h = Kit.dp(56)
    -- NB: Horizontal/VerticalGroup cache their size on first getSize(), so
    -- groups are only measured once complete.
    local left = opts.left or Kit.hspan(Kit.PAD)
    local right_group = HorizontalGroup:new{ align = "center" }
    for __, w in ipairs(opts.right or {}) do
        table.insert(right_group, w)
    end
    if #right_group == 0 then
        table.insert(right_group, Kit.hspan(Kit.PAD))
    end
    local avail = width - left:getSize().w - right_group:getSize().w - Kit.dp(8)
    local title = Kit.text(opts.title, Kit.uiBold(opts.small_title and Kit.SIZE.body or Kit.SIZE.title),
        { max_width = avail })
    local left_group = HorizontalGroup:new{ align = "center", left, title }
    if opts.subtitle then
        local remaining = avail - title:getSize().w - Kit.dp(10)
        if remaining > Kit.dp(30) then
            table.insert(left_group, Kit.hspan(Kit.dp(10)))
            table.insert(left_group, Kit.text(opts.subtitle, Kit.ui(Kit.SIZE.small),
                { fgcolor = Kit.GREY_DARK, max_width = remaining }))
        end
    end
    return VerticalGroup:new{
        align = "left",
        Kit.spread(width, h, left_group, right_group),
        Kit.hline(width, Kit.dp(2)),
    }
end

-- Pager ---------------------------------------------------------------------
-- « ‹   Page 2 of 5   › »   Tap the label to type a page number.

Kit.PAGER_H = Kit.dp(52) + Kit.dp(1)

function Kit.pager(opts)
    local width = opts.width
    local h = Kit.dp(52)
    local page, pages = opts.page, math.max(opts.pages or 1, 1)
    local can_back, can_fwd = page > 1, page < pages
    local function nav(icon, enabled, cb)
        return Kit.iconButton(icon, cb, { enabled = enabled, icon_size = Kit.dp(28), size = h })
    end
    local label = Kit.text(T(_("Page %1 of %2"), page, pages), Kit.ui(Kit.SIZE.small))
    local label_tap = Kit.tap(Kit.box(label:getSize().w + Kit.dp(24), h, label),
        pages > 1 and opts.on_goto or nil, nil, { no_feedback = pages <= 1 })
    local left = HorizontalGroup:new{ align = "center",
        nav("chevron.first", can_back, opts.on_first), nav("chevron.left", can_back, opts.on_prev) }
    local right = HorizontalGroup:new{ align = "center",
        nav("chevron.right", can_fwd, opts.on_next), nav("chevron.last", can_fwd, opts.on_last) }
    right = Kit.box(right:getSize().w, h, right)
    right.overlap_align = "right"
    return VerticalGroup:new{
        align = "left",
        Kit.hline(width, Kit.dp(1)),
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = h },
            allow_mirroring = false,
            Kit.box(width, h, label_tap),
            left,
            right,
        },
    }
end

-- Tab bar -------------------------------------------------------------------

Kit.TABS = {
    { id = "library", text = _("Library"), icon = "tab-library" },
    { id = "vagary", text = _("Vagary"), icon = "tab-vagary" },
    { id = "tags", text = _("Tags"), icon = "tab-tags" },
}

-- compact: icon beside the label in a shorter bar (landscape).
function Kit.tabbar(width, active, on_pick, compact)
    local n = #Kit.TABS
    local h = compact and Kit.dp(48) or Kit.dp(64)
    local cell_w = math.floor(width / n)
    local row = HorizontalGroup:new{ align = "center" }
    for i, tab in ipairs(Kit.TABS) do
        local w = (i == n) and (width - (n - 1) * cell_w) or cell_w
        local selected = tab.id == active
        local icon = Kit.icon(tab.icon, Kit.dp(24))
        local label = Kit.text(tab.text, selected and Kit.uiBold(Kit.SIZE.tiny) or Kit.ui(Kit.SIZE.tiny), { padding = 0 })
        local content = compact
            and HorizontalGroup:new{ align = "center", icon, Kit.hspan(Kit.dp(8)), label }
            or VerticalGroup:new{ align = "center", icon, Kit.vspan(Kit.dp(3)), label }
        local cell = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Kit.WHITE,
            invert = selected, -- solid black when selected (icon + text become white)
            Kit.box(w, h, content),
        }
        table.insert(row, Kit.tap(cell, function() on_pick(tab.id) end, nil, { no_feedback = selected }))
    end
    return VerticalGroup:new{
        align = "left",
        Kit.hline(width, Kit.dp(2)),
        row,
    }
end

-- Formatting helpers ----------------------------------------------------------

local MONTHS = { _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
                 _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec") }

function Kit.shortDate(ts, with_year)
    if not ts or ts == 0 then return "" end
    local t = os.date("*t", ts)
    local now = os.date("*t")
    if with_year or t.year ~= now.year then
        return T("%1 %2 %3", t.day, MONTHS[t.month], t.year)
    end
    return T("%1 %2", t.day, MONTHS[t.month])
end

function Kit.longDate(ts)
    if not ts or ts == 0 then return "" end
    local t = os.date("*t", ts)
    return T("%1 %2 %3, %4", t.day, MONTHS[t.month], t.year, string.format("%02d:%02d", t.hour, t.min))
end

-- Where a highlight sits in its book, worded so a stale page number is not
-- presented as the current one: "Ch. 3 · 20% · p. 214 when highlighted".
function Kit.locationText(h, long)
    local parts = {}
    if h.chapter and h.chapter ~= "" then
        table.insert(parts, h.chapter)
    end
    local pct = h.percent and math.floor(h.percent * 100 + 0.5)
    if pct then
        table.insert(parts, T(_("%1%"), pct))
    end
    if h.pageref and h.pageref ~= "" then
        -- Stable page label (publisher page map): safe to show as is.
        table.insert(parts, T(_("p. %1"), h.pageref))
    elseif h.pageno then
        table.insert(parts, long and T(_("p. %1 when highlighted"), h.pageno) or T(_("p. %1"), h.pageno))
    end
    return table.concat(parts, " · ")
end

return Kit
