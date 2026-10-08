--[[--
Tag picker: check the tags a highlight (or a selection) should have, add a
new one, then Done returns to where you came from. With several highlights,
a tag only some of them have shows as a dash; tapping it adds it to all.
--]]

local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local BaseScreen = require("hlm/screen")
local Kit = require("hlm/kit")

local TagPicker = BaseScreen:extend{
    name = "hlmanager_tagpicker",
    keys = nil,
    on_done = nil,
}

-- state[tag_id] = "all" | "some" | "none"
function TagPicker:setup()
    self.page = 1
    self.initial = {}
    self.state = {}
    local m = self.app.model
    for __, t in ipairs(m.tags) do
        local n = 0
        for __, k in ipairs(self.keys) do
            local h = m:get(k)
            if h and h.tag_ids[t.id] then n = n + 1 end
        end
        local s = n == 0 and "none" or (n == #self.keys and "all" or "some")
        self.initial[t.id] = s
        self.state[t.id] = s
    end
end

local function mixedMark(size)
    size = size or Kit.dp(22)
    return FrameContainer:new{
        bordersize = Kit.dp(2),
        padding = 0,
        radius = Kit.dp(3),
        background = Kit.WHITE,
        Kit.box(size - 2 * Kit.dp(2), size - 2 * Kit.dp(2), Kit.hline(Kit.dp(10), Kit.dp(2))),
    }
end

function TagPicker:build(W, H)
    local app, m = self.app, self.app.model
    local inner = W - 2 * Kit.PAD
    local n = #self.keys
    local header = Kit.header{
        width = W,
        title = n == 1 and _("Tags") or T(N_("Tags for %1 highlight", "Tags for %1 highlights", n), n),
        small_title = true,
        left = Kit.iconButton("close", function() self:onClose() end),
        right = { Kit.link(_("New tag"), function() self:newTag() end), Kit.hspan(Kit.dp(10)) },
    }
    local done = VerticalGroup:new{
        align = "left",
        Kit.hline(W, Kit.dp(2)),
        Kit.vspan(Kit.dp(12)),
        HorizontalGroup:new{
            Kit.hspan(Kit.PAD),
            Kit.button{ text = _("Done"), primary = true, width = inner, height = Kit.dp(56),
                callback = function() self:done() end },
        },
        Kit.vspan(Kit.dp(16)),
    }

    -- Recently used first: the tag you want is usually one you just used.
    local tags = m:tagList("recent")
    local row_h = Kit.dp(52)
    local list_h = H - header:getSize().h - done:getSize().h - Kit.PAGER_H
    local list
    if #tags == 0 then
        self.pages, self.page = 1, 1
        list = Kit.box(W, list_h, VerticalGroup:new{
            align = "center",
            Kit.text(_("No tags yet."), Kit.ui(Kit.SIZE.body), { fgcolor = Kit.GREY_DARK }),
            Kit.vspan(Kit.dp(16)),
            Kit.button{ text = _("Create a tag"), callback = function() self:newTag() end },
        })
    else
        list = HorizontalGroup:new{ Kit.hspan(Kit.PAD), self:pagedRows{
            count = #tags,
            row_h = row_h + Kit.dp(1),
            height = list_h,
            width = inner,
            build = function(i, w)
                local t = tags[i]
                local s = self.state[t.id] or "none"
                local mark = s == "some" and mixedMark() or Kit.checkbox(s == "all")
                return VerticalGroup:new{
                    align = "left",
                    Kit.choiceRow{
                        width = w,
                        height = row_h,
                        text = t.name,
                        trailing = tostring(t.count),
                        mark = mark,
                        callback = function()
                            self.state[t.id] = (s == "all") and "none" or "all"
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
        header,
        Kit.box(W, list_h, list, "top"),
        self:pagerWidget(W),
        done,
    }
end

function TagPicker:newTag()
    self.app:askTagName(_("New tag"), "", _("Add"), function(name)
        local id = self.app.store:ensureTag(name)
        self.app.model:reload()
        self.state[id] = "all"
        if not self.initial[id] then self.initial[id] = "none" end
        self.page = 1
        self:refresh()
    end)
end

function TagPicker:done()
    local add, remove = {}, {}
    for id, s in pairs(self.state) do
        local before = self.initial[id] or "none"
        if s ~= before then
            if s == "all" then table.insert(add, id)
            elseif s == "none" then table.insert(remove, id) end
        end
    end
    if #add > 0 or #remove > 0 then
        self.app.store:updateTags(self.keys, add, remove)
    end
    -- Screens below repaint from the reloaded model when revealed.
    self.app.model:reload()
    local cb = self.on_done
    self.app:closeScreen(self)
    if cb then cb() end
end

return TagPicker
