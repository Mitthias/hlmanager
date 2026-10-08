--[[--
Tags: create, sort (most used / A–Z / recent), and manage tags.
Tap a tag to see its highlights in the Library; ⋯ or long-press to rename,
merge or delete. "Untagged" opens the Library filtered to untagged items.
--]]

local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local BaseScreen = require("hlm/screen")
local Kit = require("hlm/kit")
local Model = require("hlm/model")

local Tags = BaseScreen:extend{
    name = "hlmanager_tags",
}

local SORTS = { "count", "az", "recent" }

function Tags:setup()
    self.page = 1
end

function Tags:build(W, H)
    local app, m = self.app, self.app.model
    local inner = W - 2 * Kit.PAD
    local sort = app:get("tag_sort", "count")
    local header = Kit.header{
        width = W,
        title = _("Tags"),
        subtitle = T(N_("%1 tag", "%1 tags", #m.tags), #m.tags),
        right = { Kit.iconButton("close", function() self:onClose() end) },
    }

    local sort_idx = 1
    for i, s in ipairs(SORTS) do if s == sort then sort_idx = i end end
    local function segmented(width)
        return Kit.segmented{
            labels = { _("Most used"), _("A–Z"), _("Recent") },
            selected = sort_idx,
            width = width,
            on_pick = function(i)
                app:set("tag_sort", SORTS[i])
                self.page = 1
                self:refresh()
            end,
        }
    end
    local landscape = self:isLandscape()
    local controls
    if landscape then
        -- One row: new-tag field beside the sort switch.
        local field_w = math.floor((inner - Kit.dp(12)) * 0.45)
        controls = VerticalGroup:new{
            align = "left",
            Kit.vspan(Kit.dp(8)),
            HorizontalGroup:new{
                align = "center",
                self:newTagField(field_w),
                Kit.hspan(Kit.dp(12)),
                segmented(inner - field_w - Kit.dp(12)),
            },
            Kit.vspan(Kit.dp(8)),
        }
    else
        controls = VerticalGroup:new{
            align = "left",
            Kit.vspan(Kit.dp(12)),
            self:newTagField(inner),
            Kit.vspan(Kit.dp(10)),
            segmented(inner),
            Kit.vspan(Kit.dp(10)),
        }
    end
    local top = VerticalGroup:new{
        align = "left",
        header,
        HorizontalGroup:new{ Kit.hspan(Kit.PAD), controls },
        Kit.hline(W, Kit.dp(1)),
    }

    -- The how-to line is dropped in landscape, where height is scarce.
    local bottom = VerticalGroup:new{ align = "left" }
    if not landscape then
        local hint = Kit.textbox(_("Long-press a tag, or tap its menu button, to rename it, merge it into another, or delete it. Highlights keep their text when a tag is removed."),
            Kit.ui(Kit.SIZE.tiny), inner, { fgcolor = Kit.GREY_DARK, max_lines = 2 })
        bottom = VerticalGroup:new{
            align = "left",
            Kit.hline(W, Kit.dp(1)),
            Kit.vspan(Kit.dp(8)),
            HorizontalGroup:new{ Kit.hspan(Kit.PAD), hint },
            Kit.vspan(Kit.dp(8)),
        }
    end

    -- Rows: every tag, then "Untagged".
    local rows = {}
    for __, t in ipairs(m:tagList(sort)) do table.insert(rows, t) end
    table.insert(rows, { untagged = true, name = _("Untagged"), count = m.untagged_count })

    local row_h = Kit.dp(56)
    local list_h = H - top:getSize().h - bottom:getSize().h - self:bottomBarHeight(W)
    local grid = self:pagedRows{
        count = #rows,
        row_h = row_h + Kit.dp(1),
        height = list_h,
        width = inner,
        build = function(i, w)
            return VerticalGroup:new{
                align = "left",
                self:row(rows[i], w, row_h),
                Kit.hline(w, Kit.dp(1), Kit.GREY_LIGHT),
            }
        end,
    }

    return VerticalGroup:new{
        align = "left",
        top,
        Kit.box(W, list_h, HorizontalGroup:new{ Kit.hspan(Kit.PAD), grid }, "top"),
        bottom,
        self:bottomBar(W, "tags"),
    }
end

-- "New tag" looks like a field but opens the keyboard dialog.
function Tags:newTagField(width)
    local border = Kit.dp(1.5)
    return Kit.tap(FrameContainer:new{
        bordersize = border,
        radius = Kit.dp(6),
        padding = 0,
        background = Kit.WHITE,
        Kit.box(width - 2 * border, Kit.TAP - 2 * border, HorizontalGroup:new{
            align = "center",
            Kit.hspan(Kit.dp(12)),
            Kit.icon("plus", Kit.dp(20)),
            Kit.hspan(Kit.dp(10)),
            Kit.text(_("New tag"), Kit.ui(Kit.SIZE.body), { fgcolor = Kit.GREY_DARK }),
        }, "left"),
    }, function() self.app:createTag() end)
end

-- One tag row, `w` wide.
function Tags:row(t, w, row_h)
    local app = self.app
    local menu_w = t.untagged and 0 or Kit.TAP
    local label_w = w - menu_w - Kit.dp(8)
    local count = Kit.text(tostring(t.count), Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK })
    local name = Kit.text(t.name, t.untagged and Kit.serifItalic(Kit.SIZE.body) or Kit.ui(Kit.SIZE.body),
        { fgcolor = t.untagged and Kit.GREY_DARK or Kit.BLACK,
          max_width = label_w - count:getSize().w - Kit.dp(12) })
    local open = function()
        local f = Model.emptyFilter()
        if t.untagged then
            f.untagged = true
        else
            f.tags = { [t.id] = true }
        end
        app:setLibraryFilter(f)
        app:showTab("library")
    end
    local hold = (not t.untagged) and function() app:tagMenu(t) end or nil
    local label = Kit.tap(Kit.box(label_w, row_h, Kit.spread(label_w, row_h, name, count), "left"), open, hold)
    local row = HorizontalGroup:new{ align = "center", label, Kit.hspan(Kit.dp(8)) }
    if not t.untagged then
        table.insert(row, Kit.iconButton("appbar.menu", function() app:tagMenu(t) end,
            { icon_size = Kit.dp(22) }))
    end
    return row
end



return Tags
