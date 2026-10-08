--[[--
Filter editor for one section: Books, Authors, Tags or Time.
Each Library chip opens only its own section. Changes apply when the bottom
button ("Show N highlights", live count) is tapped; ✕ discards them.
--]]

local DateTimeWidget = require("ui/widget/datetimewidget")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local BaseScreen = require("hlm/screen")
local Kit = require("hlm/kit")
local Model = require("hlm/model")

local Filter = BaseScreen:extend{
    name = "hlmanager_filter",
    section = "books",
    filter = nil,
    on_apply = nil,
}

local TITLES = {
    books = _("Books"),
    authors = _("Authors"),
    tags = _("Tags"),
    time = _("Time"),
}

function Filter:setup()
    self.page = 1
end

-- Rows for the checklist sections.
function Filter:rows()
    local m, f = self.app.model, self.filter
    local rows = {}
    if self.section == "books" then
        for __, b in ipairs(m:bookList()) do
            table.insert(rows, {
                text = b.title,
                sub = b.author_list[1],
                face = Kit.serifItalic(Kit.SIZE.body),
                count = b.count,
                checked = f.books and f.books[b.id],
                toggle = function()
                    f.books = f.books or {}
                    f.books[b.id] = (not f.books[b.id]) or nil
                end,
            })
        end
    elseif self.section == "authors" then
        for __, a in ipairs(m:authorList()) do
            table.insert(rows, {
                text = a.name,
                count = a.count,
                checked = f.authors and f.authors[a.name],
                toggle = function()
                    f.authors = f.authors or {}
                    f.authors[a.name] = (not f.authors[a.name]) or nil
                end,
            })
        end
    elseif self.section == "tags" then
        for __, t in ipairs(m:tagList("count")) do
            table.insert(rows, {
                text = t.name,
                count = t.count,
                checked = f.tags and f.tags[t.id],
                toggle = function()
                    f.tags = f.tags or {}
                    f.tags[t.id] = (not f.tags[t.id]) or nil
                end,
            })
        end
        table.insert(rows, {
            text = _("Untagged"),
            face = Kit.serifItalic(Kit.SIZE.body),
            count = m.untagged_count,
            checked = f.untagged,
            toggle = function() f.untagged = (not f.untagged) or nil end,
        })
    end
    return rows
end

function Filter:build(W, H)
    local inner = W - 2 * Kit.PAD
    local header = Kit.header{
        width = W,
        title = TITLES[self.section] or _("Filter"),
        small_title = true,
        left = Kit.iconButton("close", function() self:onClose() end),
        right = { Kit.link(_("Reset"), function() self:resetSection() end), Kit.hspan(Kit.dp(10)) },
    }
    local n = self.app.model:count(self.filter)
    local cta_text = T(self.cta or N_("Show %1 highlight", "Show %1 highlights", n), n)
    local cta = VerticalGroup:new{
        align = "left",
        Kit.hline(W, Kit.dp(2)),
        Kit.vspan(Kit.dp(12)),
        HorizontalGroup:new{
            Kit.hspan(Kit.PAD),
            Kit.button{ text = cta_text, primary = true, width = inner, height = Kit.dp(56),
                callback = function() self:apply() end },
        },
        Kit.vspan(Kit.dp(16)),
    }
    local body_h = H - header:getSize().h - cta:getSize().h
    local body
    if self.section == "time" then
        body = self:timeBody(W, inner, body_h)
    else
        body = self:listBody(W, inner, body_h)
    end
    return VerticalGroup:new{ align = "left", header, Kit.box(W, body_h, body, "top"), cta }
end

function Filter:listBody(W, inner, body_h)
    local f = self.filter
    local top = VerticalGroup:new{ align = "left" }
    if self.section == "tags" then
        top = VerticalGroup:new{
            align = "left",
            Kit.vspan(Kit.dp(12)),
            HorizontalGroup:new{
                Kit.hspan(Kit.PAD),
                Kit.segmented{
                    labels = { _("Match any tag"), _("Match all tags") },
                    selected = f.tag_mode == "all" and 2 or 1,
                    width = inner,
                    on_pick = function(i)
                        f.tag_mode = i == 2 and "all" or "any"
                        self:refresh()
                    end,
                },
            },
            Kit.vspan(Kit.dp(8)),
        }
    end
    local rows = self:rows()
    local row_h = Kit.dp(56)
    local list_h = body_h - top:getSize().h - Kit.PAGER_H
    local list
    if #rows == 0 then
        list = Kit.box(W, list_h, Kit.text(_("Nothing here yet."), Kit.ui(Kit.SIZE.body),
            { fgcolor = Kit.GREY_DARK }))
    else
        list = HorizontalGroup:new{ Kit.hspan(Kit.PAD), self:pagedRows{
            count = #rows,
            row_h = row_h + Kit.dp(1),
            height = list_h,
            width = inner,
            build = function(i, w)
                local r = rows[i]
                return VerticalGroup:new{
                    align = "left",
                    Kit.choiceRow{
                        width = w,
                        height = row_h,
                        text = r.text,
                        sub = r.sub,
                        face = r.face,
                        trailing = tostring(r.count),
                        mark = Kit.checkbox(r.checked),
                        callback = function()
                            r.toggle()
                            self:refresh()
                        end,
                    },
                    Kit.hline(w, Kit.dp(1), Kit.GREY_LIGHT),
                }
            end,
        } }
    end
    return VerticalGroup:new{
        align = "left",
        top,
        Kit.box(W, list_h, list, "top"),
        self:pagerWidget(W),
    }
end

local function dateLabel(ts)
    return ts and os.date("%Y-%m-%d", ts) or _("choose")
end

function Filter:timeBody(W, inner, body_h)
    local f = self.filter
    local selected = 1
    for i, id in ipairs(Model.TIME_ORDER) do
        if id == (f.time or "all") then selected = i end
    end
    local labels = {}
    for __, id in ipairs(Model.TIME_ORDER) do table.insert(labels, Model.TIME_LABELS[id]) end
    local g = VerticalGroup:new{
        align = "left",
        Kit.vspan(Kit.dp(16)),
        Kit.segmented{
            labels = labels,
            selected = selected,
            width = inner,
            on_pick = function(i)
                f.time = Model.TIME_ORDER[i]
                if f.time == "range" and not f.from then
                    f.from = os.time() - 30 * 86400
                    f.to = os.time()
                end
                self:refresh()
            end,
        },
        Kit.vspan(Kit.dp(16)),
    }
    if f.time == "range" then
        local bw = math.floor((inner - Kit.dp(10)) / 2)
        table.insert(g, HorizontalGroup:new{
            align = "center",
            VerticalGroup:new{
                align = "left",
                Kit.text(_("From"), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK }),
                Kit.button{ text = dateLabel(f.from), width = bw, callback = function() self:pickDate("from") end },
            },
            Kit.hspan(Kit.dp(10)),
            VerticalGroup:new{
                align = "left",
                Kit.text(_("To"), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK }),
                Kit.button{ text = dateLabel(f.to), width = bw, callback = function() self:pickDate("to") end },
            },
        })
    else
        local hint = {
            all = _("Every highlight, whenever it was made."),
            ["7d"] = _("Highlights made in the last 7 days, including today."),
            ["30d"] = _("Highlights made in the last 30 days, including today."),
            year = T(_("Highlights made since 1 January %1."), os.date("%Y")),
        }
        table.insert(g, Kit.textbox(hint[f.time or "all"] or "", Kit.ui(Kit.SIZE.small), inner,
            { fgcolor = Kit.GREY_DARK }))
    end
    return HorizontalGroup:new{ Kit.hspan(Kit.PAD), g }
end

function Filter:pickDate(which)
    local f = self.filter
    local t = os.date("*t", f[which] or os.time())
    local widget
    widget = DateTimeWidget:new{
        year = t.year,
        month = t.month,
        day = t.day,
        title_text = which == "from" and _("From date") or _("To date"),
        ok_text = _("Set"),
        callback = function(v)
            f[which] = os.time{ year = v.year, month = v.month, day = v.day, hour = 12 }
            if f.from and f.to and f.from > f.to then
                f.from, f.to = f.to, f.from
            end
            self:refresh()
        end,
    }
    UIManager:show(widget)
end

-- Behaviour -------------------------------------------------------------------

function Filter:resetSection()
    local f = self.filter
    if self.section == "books" then f.books = nil
    elseif self.section == "authors" then f.authors = nil
    elseif self.section == "tags" then f.tags = nil; f.untagged = nil; f.tag_mode = "any"
    elseif self.section == "time" then f.time = "all"; f.from = nil; f.to = nil
    end
    self.page = 1
    self:refresh()
end

function Filter:apply()
    local f = self.filter
    -- Drop empty sets so saved filters stay small.
    for __, k in ipairs({ "books", "authors", "tags" }) do
        if f[k] and next(f[k]) == nil then f[k] = nil end
    end
    if self.on_apply then self.on_apply(f) end
    self.app:closeScreen(self)
end


return Filter
