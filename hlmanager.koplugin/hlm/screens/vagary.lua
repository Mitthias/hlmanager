--[[--
Vagary: one random highlight, large.

* No repeats until every highlight in the current draw has been shown. The
  "seen" list is stored per filter, so it survives restarts and starts over
  when the filter changes.
* Long quotes step down through smaller sizes; if one still does not fit at
  the smallest size, "Continue reading" opens the full text.
* Another: button, tap on the quote, swipe left or the page-forward key.
  Previous: swipe right or the page-back key.
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local BaseScreen = require("hlm/screen")
local Kit = require("hlm/kit")
local Model = require("hlm/model")

local Vagary = BaseScreen:extend{
    name = "hlmanager_vagary",
}

local QUOTE_SIZES = { 26, 24, 22, 20, 18 }

function Vagary:setup()
    self.history = {}
    local key = self.app:get("vag_current")
    local h = key and self.app.model:get(key)
    if h and self.app.model:matcher(self.app:vagaryFilter())(h) then
        self.current = key
        self:updateCounts()
    else
        self:draw(true)
    end
end

function Vagary:updateCounts()
    local app = self.app
    local f = app:vagaryFilter()
    local cands = app.model:filter(f)
    local seen = app.store:seenKeys(Model.signature(f))
    local n_seen = 0
    for __, h in ipairs(cands) do
        if seen[h.key] then n_seen = n_seen + 1 end
    end
    self.total, self.seen_count = #cands, n_seen
end

function Vagary:draw(no_history)
    local app = self.app
    local f = app:vagaryFilter()
    local sig = Model.signature(f)
    local cands = app.model:filter(f)
    if #cands == 0 then
        self.current = nil
        self.total, self.seen_count = 0, 0
        return
    end
    local seen = app.store:seenKeys(sig)
    local pool = {}
    for __, h in ipairs(cands) do
        if not seen[h.key] and h.key ~= self.current then table.insert(pool, h) end
    end
    if #pool == 0 then
        -- Everything has been shown: start a new round (avoid repeating the current one).
        app.store:clearSeen(sig)
        for __, h in ipairs(cands) do
            if h.key ~= self.current or #cands == 1 then table.insert(pool, h) end
        end
    end
    local pick = pool[math.random(#pool)]
    if self.current and not no_history then
        table.insert(self.history, self.current)
        if #self.history > 50 then table.remove(self.history, 1) end
    end
    self.current = pick.key
    app.store:markSeen(sig, pick.key)
    app:set("vag_current", pick.key)
    self:updateCounts()
end

-- Layout ------------------------------------------------------------------------

function Vagary:build(W, H)
    local app, m = self.app, self.app.model
    local f = app:vagaryFilter()
    local inner = W - 2 * Kit.dp(28)
    local h = self.current and m:get(self.current)

    local chip_text = Model.isActive(f) and T(_("From: %1 filtered"), m:count(f))
        or T(_("From: all %1"), m:total())
    local header = Kit.header{
        width = W,
        title = _("Vagary"),
        right = {
            Kit.chip{ text = chip_text, callback = function() self:changeFilter() end },
            Kit.hspan(Kit.dp(4)),
            Kit.iconButton("close", function() self:onClose() end),
        },
    }

    local bottom = VerticalGroup:new{ align = "left" }
    local actions = self:actions(W, h)
    table.insert(bottom, actions)
    table.insert(bottom, Kit.tabbar(W, "vagary", function(id) app:showTab(id) end, self:isLandscape()))

    local main_h = H - header:getSize().h - bottom:getSize().h
    local main
    if h then
        main = self:quoteBlock(h, W, inner, main_h)
    else
        local msg = m:total() == 0 and _("No highlights yet.")
            or _("No highlights match this draw.")
        local g = VerticalGroup:new{
            align = "center",
            Kit.textbox(msg, Kit.ui(Kit.SIZE.body), inner, { alignment = "center", fgcolor = Kit.GREY_DARK }),
        }
        if m:total() > 0 then
            table.insert(g, Kit.vspan(Kit.dp(16)))
            table.insert(g, Kit.button{ text = _("Change filter"), callback = function() self:changeFilter() end })
        end
        main = Kit.box(W, main_h, g)
    end

    return VerticalGroup:new{
        align = "left",
        header,
        main,
        bottom,
    }
end

function Vagary:quoteBlock(h, W, inner, main_h)
    local book = h.book
    local landscape = self:isLandscape()
    local pad_top, pad_bottom = Kit.dp(landscape and 12 or 28), Kit.dp(landscape and 8 or 16)
    -- The decorative opening mark is dropped in landscape to give the quote room.
    local mark = landscape and Kit.vspan(0) or Kit.text("\u{201C}", Kit.serif(48), { padding = 0 })
    local rule = Kit.hline(Kit.dp(48), Kit.dp(2))
    local info = VerticalGroup:new{ align = "left" }
    if book and landscape then
        local who = book.author_list[1] and (" — " .. table.concat(book.author_list, ", ")) or ""
        table.insert(info, Kit.text(book.title .. who, Kit.serifItalic(Kit.SIZE.small), { max_width = inner }))
    elseif book then
        table.insert(info, Kit.text(book.title, Kit.serifItalic(Kit.SIZE.body), { max_width = inner }))
        if book.author_list[1] then
            table.insert(info, Kit.text(table.concat(book.author_list, ", "), Kit.ui(Kit.SIZE.small),
                { max_width = inner }))
        end
    end
    local loc = Kit.locationText(h)
    local date = Kit.shortDate(h.ts, true)
    local where = loc ~= "" and (loc .. " · " .. date) or date
    table.insert(info, Kit.text(where, Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = inner }))

    local counter = Kit.text(T(N_("%1 of %2 seen · no repeats until all are seen",
        "%1 of %2 seen · no repeats until all are seen", self.total), self.seen_count, self.total),
        Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = inner })

    local gap = Kit.dp(landscape and 10 or 18)
    local fixed = pad_top + mark:getSize().h + (landscape and 0 or gap) + gap + rule:getSize().h + gap
        + info:getSize().h + gap + counter:getSize().h + pad_bottom
    local avail = main_h - fixed

    -- Largest size that fits; otherwise clamp at the smallest and offer the rest.
    local quote, overflow
    for __, size in ipairs(QUOTE_SIZES) do
        local face = Kit.serif(size)
        local need = Kit.countLines(h.text, face, inner, 0.5) * Kit.lineHeight(face, 0.5)
        if need <= avail then
            quote = Kit.textbox(h.text, face, inner, { line_height = 0.5 })
            break
        end
    end
    if not quote then
        local face = Kit.serif(QUOTE_SIZES[#QUOTE_SIZES])
        local more_h = Kit.TAP
        local lines = math.max(1, math.floor((avail - more_h) / Kit.lineHeight(face, 0.5)))
        quote = Kit.textbox(h.text, face, inner, { line_height = 0.5, max_lines = lines })
        overflow = true
    end

    local quote_group = VerticalGroup:new{ align = "left", quote }
    if overflow then
        table.insert(quote_group, Kit.link(_("Continue reading"), function()
            self.app:showText(book and book.title or _("Highlight"), h.text)
        end))
    end

    local block = VerticalGroup:new{
        align = "left",
        Kit.vspan(pad_top),
        mark,
        Kit.vspan(landscape and 0 or gap),
        -- Tap the quote for another one.
        Kit.tap(quote_group, function() self:another() end, nil, { no_feedback = true }),
        Kit.vspan(gap),
        rule,
        Kit.vspan(gap),
        info,
        Kit.vspan(gap),
        counter,
    }
    return Kit.box(W, main_h, HorizontalGroup:new{ Kit.hspan(Kit.dp(28)), block }, landscape and "top" or "left")
end

function Vagary:actions(W, h)
    local app = self.app
    local gap = Kit.dp(10)
    local landscape = self:isLandscape()
    -- Landscape: buttons and links share one row.
    local bw = landscape and math.floor(W * 0.22) or math.floor((W - 2 * Kit.PAD - gap) / 2)
    local buttons = HorizontalGroup:new{
        align = "center",
        Kit.hspan(Kit.PAD),
        Kit.button{ text = _("Open in book"), icon = "book.opened", primary = true, width = bw,
            height = Kit.dp(52), enabled = h ~= nil and app:canOpen(h),
            callback = function() app:openInBook(h) end },
        Kit.hspan(gap),
        Kit.button{ text = _("Another"), icon = "tab-vagary", width = bw, height = Kit.dp(52),
            enabled = (self.total or 0) > 1, callback = function() self:another() end },
    }
    local links = HorizontalGroup:new{ align = "center" }
    local function add(text, cb)
        if #links > 0 then table.insert(links, Kit.hspan(Kit.dp(16))) end
        table.insert(links, Kit.link(text, cb, { enabled = h ~= nil }))
    end
    add(_("Details"), function() app:showDetail({ h }, 1) end)
    add(_("Tag it"), function() app:showTagPicker({ h.key }) end)
    add(h and h.note and _("Edit note") or _("Add note"), function() app:editNote(h) end)
    if app:canShare() then
        add(_("Share"), function() app:share(h) end)
    end
    if landscape then
        local rest = W - buttons:getSize().w
        return VerticalGroup:new{
            align = "left",
            HorizontalGroup:new{ align = "center", buttons, Kit.box(rest, Kit.dp(52), links) },
            Kit.vspan(Kit.dp(8)),
        }
    end
    return VerticalGroup:new{
        align = "left",
        buttons,
        Kit.box(W, Kit.TAP + Kit.dp(8), links),
    }
end

-- Behaviour -------------------------------------------------------------------

function Vagary:another()
    if (self.total or 0) < 1 then return end
    self:draw()
    self:refresh()
end

function Vagary:previous()
    local key = table.remove(self.history)
    if key and self.app.model:get(key) then
        self.current = key
        self.app:set("vag_current", key)
        self:refresh()
    end
end

function Vagary:onNextPage()
    self:another()
    return true
end

function Vagary:onPrevPage()
    self:previous()
    return true
end

function Vagary:changeFilter()
    local app = self.app
    app:showFilterMenu(app:vagaryFilter(), function(nf)
        app:setVagaryFilter(nf)
        self.history = {}
        self:draw(true)
        self:refresh()
    end)
end

function Vagary:onDataChanged()
    if self.current and not self.app.model:get(self.current) then
        self:draw(true)
    else
        self:updateCounts()
    end
end


return Vagary
