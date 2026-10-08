--[[--
Highlight detail: book, location, quote, note and tags, with "Open in book"
as the main action and previous/next through the list it was opened from.

The location is worded "20% · p. 214 when highlighted" because reflowable
page numbers change with font size; the jump itself uses the stored position.
Delete is kept out of the main row, in the "More" menu, behind a confirmation.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local T = require("ffi/util").template

local BaseScreen = require("hlm/screen")
local Kit = require("hlm/kit")

local Detail = BaseScreen:extend{
    name = "hlmanager_detail",
    list = nil,  -- array of highlights (from the opening screen)
    index = 1,
}

function Detail:setup()
    -- Keep keys, not objects: the model is rebuilt after every edit.
    self.keys = {}
    for i, h in ipairs(self.list) do self.keys[i] = h.key end
    self.list = nil
end

function Detail:current()
    return self.app.model:get(self.keys[self.index])
end

function Detail:build(W, H)
    local h = self:current()
    local landscape = self:isLandscape()
    local position = Kit.text(T("%1 / %2", self.index, #self.keys), Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK })
    local right = { position, Kit.hspan(Kit.PAD) }
    if landscape then
        -- Previous/next move into the header so the body gets the height.
        local prev, next_ = self:navLinks()
        right = { prev, Kit.hspan(Kit.dp(12)), position, Kit.hspan(Kit.dp(12)), next_, Kit.hspan(Kit.dp(8)) }
    end
    local header = Kit.header{
        width = W,
        title = _("Highlight"),
        small_title = true,
        left = Kit.iconButton("chevron.left", function() self:onClose() end),
        right = right,
    }
    if not h then
        return VerticalGroup:new{
            align = "left",
            header,
            Kit.box(W, H - header:getSize().h, Kit.text(_("This highlight no longer exists."),
                Kit.ui(Kit.SIZE.body), { fgcolor = Kit.GREY_DARK })),
        }
    end

    local pad = Kit.dp(20)
    local gap = Kit.dp(18)

    if landscape then
        -- Quote on the left; note, tags and actions on the right.
        local col_gap = Kit.dp(28)
        local left_w = math.floor((W - 2 * pad - col_gap) * 0.56)
        local right_w = W - 2 * pad - col_gap - left_w
        local main_h = H - header:getSize().h
        local actions = self:actions(right_w, h)
        local right_col = VerticalGroup:new{
            align = "left",
            Kit.vspan(Kit.dp(12)),
            self:noteSection(h, right_w, 3),
            Kit.vspan(gap),
            self:tagSection(h, right_w),
        }
        local right_h = main_h - actions:getSize().h
        local left = self:quoteColumn(h, left_w, main_h)
        return VerticalGroup:new{
            align = "left",
            header,
            HorizontalGroup:new{
                align = "top",
                Kit.hspan(pad),
                Kit.box(left_w, main_h, left, "top"),
                Kit.hspan(col_gap),
                VerticalGroup:new{
                    align = "left",
                    Kit.box(right_w, right_h, right_col, "top"),
                    actions,
                },
            },
        }
    end

    local nav = self:navBar(W)
    local inner = W - 2 * pad
    local actions = HorizontalGroup:new{ Kit.hspan(Kit.PAD), self:actions(W - 2 * Kit.PAD, h) }
    local main_h = H - header:getSize().h - actions:getSize().h - nav:getSize().h
    local note = self:noteSection(h, inner)
    local tags = self:tagSection(h, inner)
    local below = Kit.dp(16) + gap + note:getSize().h + gap + tags:getSize().h + Kit.dp(8)
    local body = VerticalGroup:new{
        align = "left",
        self:quoteColumn(h, inner, main_h - below),
        Kit.vspan(gap),
        note,
        Kit.vspan(gap),
        tags,
    }
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(W, main_h, HorizontalGroup:new{ Kit.hspan(pad), body }, "top"),
        actions,
        nav,
    }
end

-- Book, location and the quote, fitted into `height`; overflow opens the full text.
function Detail:quoteColumn(h, inner, height)
    local app = self.app
    local book = h.book
    local gap = Kit.dp(18)
    local meta = VerticalGroup:new{ align = "left" }
    table.insert(meta, Kit.text(book and book.title or _("Unknown book"), Kit.serifItalic(Kit.SIZE.body),
        { max_width = inner }))
    if book and book.author_list[1] then
        table.insert(meta, Kit.text(table.concat(book.author_list, ", "), Kit.ui(Kit.SIZE.small),
            { max_width = inner }))
    end
    local loc = Kit.locationText(h, true)
    if loc ~= "" then
        table.insert(meta, Kit.textbox(loc, Kit.ui(Kit.SIZE.tiny), inner, { max_lines = 2, fgcolor = Kit.GREY_DARK }))
    end
    table.insert(meta, Kit.text(Kit.longDate(h.ts), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK }))

    local qf = Kit.serif(Kit.SIZE.quote_detail)
    local lh = Kit.lineHeight(qf, 0.5)
    local avail = height - Kit.dp(16) - meta:getSize().h - gap
    local need = Kit.countLines(h.text, qf, inner, 0.5) * lh
    local quote = VerticalGroup:new{ align = "left" }
    if need <= avail then
        table.insert(quote, Kit.textbox(h.text, qf, inner, { line_height = 0.5 }))
    else
        local lines = math.max(2, math.floor((avail - Kit.TAP) / lh))
        table.insert(quote, Kit.textbox(h.text, qf, inner, { line_height = 0.5, max_lines = lines }))
        table.insert(quote, Kit.link(_("Show full text"), function()
            app:showText(book and book.title or _("Highlight"), h.text)
        end))
    end
    return VerticalGroup:new{
        align = "left",
        Kit.vspan(Kit.dp(16)),
        meta,
        Kit.vspan(gap),
        quote,
    }
end

function Detail:noteSection(h, inner, max_lines)
    local app = self.app
    local title = Kit.text(_("NOTE"), Kit.uiBold(Kit.SIZE.tiny))
    local edit = Kit.link(h.note and _("Edit") or _("Add"), function()
        app:editNote(h)
    end)
    local g = VerticalGroup:new{
        align = "left",
        Kit.hline(inner, Kit.dp(1)),
        Kit.spread(inner, Kit.TAP, title, edit),
    }
    if h.note then
        local f = Kit.ui(Kit.SIZE.body - 1)
        local max = max_lines or 4
        table.insert(g, Kit.textbox(h.note, f, inner, { max_lines = max }))
        if Kit.countLines(h.note, f, inner) > max then
            table.insert(g, Kit.link(_("Show whole note"), function()
                app:showText(_("Note"), h.note)
            end))
        end
    else
        table.insert(g, Kit.text(_("No note yet."), Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK }))
    end
    table.insert(g, Kit.vspan(Kit.dp(12)))
    table.insert(g, Kit.hline(inner, Kit.dp(1)))
    return g
end

function Detail:tagSection(h, inner)
    local app = self.app
    local chips = {}
    for id in pairs(h.tag_ids) do
        local t = app.model.tags_by_id[id]
        if t then
            table.insert(chips, { name = t.name, id = id })
        end
    end
    table.sort(chips, function(a, b) return a.name:lower() < b.name:lower() end)
    local widgets = {}
    local function openPicker()
        app:showTagPicker({ h.key })
    end
    for __, c in ipairs(chips) do
        table.insert(widgets, Kit.chip{
            text = c.name,
            max_width = inner,
            callback = openPicker,
            -- Long-press removes this tag (no tiny ✕ target).
            hold_callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove tag “%1” from this highlight?"), c.name),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        app.store:updateTags({ h.key }, nil, { c.id })
                        app:dataChanged()
                    end,
                })
            end,
        })
    end
    table.insert(widgets, Kit.chip{ text = #chips > 0 and _("Edit tags") or _("+ Add tags"), callback = openPicker })
    return VerticalGroup:new{
        align = "left",
        Kit.text(_("TAGS"), Kit.uiBold(Kit.SIZE.tiny)),
        Kit.vspan(Kit.dp(10)),
        Kit.flow(widgets, inner),
    }
end

-- "Open in book" plus Copy / Share / More…, `inner` wide.
function Detail:actions(inner, h)
    local app = self.app
    local gap = Kit.dp(10)
    local items = {
        { text = _("Copy"), cb = function() app:copy(h) end },
    }
    if app:canShare() then
        table.insert(items, { text = _("Share"), cb = function() app:share(h) end })
    end
    table.insert(items, { text = _("More…"), cb = function() self:moreMenu(h) end })
    local bw = math.floor((inner - (#items - 1) * gap) / #items)
    local row = HorizontalGroup:new{ align = "center" }
    for i, it in ipairs(items) do
        if i > 1 then table.insert(row, Kit.hspan(gap)) end
        table.insert(row, Kit.button{ text = it.text, width = bw, height = Kit.dp(48), callback = it.cb })
    end
    local open = Kit.button{
        text = _("Open in book"),
        icon = "book.opened",
        primary = true,
        width = inner,
        height = Kit.dp(56),
        enabled = app:canOpen(h),
        callback = function() app:openInBook(h) end,
    }
    return VerticalGroup:new{
        align = "left",
        Kit.vspan(Kit.dp(12)),
        open,
        Kit.vspan(gap),
        row,
        Kit.vspan(Kit.dp(12)),
    }
end

function Detail:moreMenu(h)
    local app = self.app
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            { { text = _("Export this highlight…"), callback = function()
                UIManager:close(dialog)
                app:showExport("single", { h })
            end } },
            { { text = _("Copy with source"), callback = function()
                UIManager:close(dialog)
                local text = "“" .. h.text .. "”"
                if h.book then text = text .. "\n— " .. h.book.title end
                require("device").input.setClipboardText(text)
                Notification:notify(_("Copied with source."))
            end } },
            { { text = _("Delete highlight…"), callback = function()
                UIManager:close(dialog)
                app:confirmDelete({ h })
            end } },
        },
    }
    UIManager:show(dialog)
end

function Detail:navLinks()
    local can_prev, can_next = self.index > 1, self.index < #self.keys
    local function link(text, enabled, cb)
        local label = Kit.text(text, Kit.ui(Kit.SIZE.small), { fgcolor = enabled and Kit.BLACK or Kit.GREY_LIGHT })
        return Kit.tap(Kit.box(label:getSize().w + Kit.dp(24), Kit.TAP, label), cb, nil, { enabled = enabled })
    end
    return link(_("‹ Previous"), can_prev, function() self:onPrevPage() end),
        link(_("Next ›"), can_next, function() self:onNextPage() end)
end

function Detail:navBar(W)
    local prev, next_ = self:navLinks()
    return VerticalGroup:new{
        align = "left",
        Kit.hline(W, Kit.dp(2)),
        Kit.spread(W, Kit.dp(52), HorizontalGroup:new{ Kit.hspan(Kit.dp(8)), prev },
            HorizontalGroup:new{ next_, Kit.hspan(Kit.dp(8)) }),
    }
end

function Detail:go(i)
    if i >= 1 and i <= #self.keys and i ~= self.index then
        self.index = i
        self:refresh()
    end
end

function Detail:onNextPage()
    self:go(self.index + 1)
    return true
end

function Detail:onPrevPage()
    self:go(self.index - 1)
    return true
end

function Detail:onDataChanged()
    -- Drop deleted highlights; stay on the same position in the list.
    local keys = {}
    local new_index
    for i, k in ipairs(self.keys) do
        if self.app.model:get(k) then
            table.insert(keys, k)
            if i <= self.index then new_index = #keys end
        end
    end
    self.keys = keys
    self.index = math.max(1, math.min(new_index or 1, #keys))
    if #keys == 0 then
        UIManager:nextTick(function() self:onClose() end)
    end
end


return Detail
