--[[--
Export: what (current filter / all / selected), format, what to include and
where to save. Opened from the Library menu, the selection bar, or a single
highlight's "More" menu. The file name follows the chosen format; an existing
file is never silently overwritten.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local BaseScreen = require("hlm/screen")
local Export = require("hlm/export")
local Kit = require("hlm/kit")

local ExportScreen = BaseScreen:extend{
    name = "hlmanager_export",
    scope = "filtered",   -- "filtered" | "all" | "selected" | "single"
    single_items = nil,
}

local SCOPES = { "filtered", "all", "selected" }

local INCLUDE = {
    { id = "notes", text = _("Notes") },
    { id = "tags", text = _("Tags") },
    { id = "page", text = _("Page & chapter") },
    { id = "date", text = _("Date & time") },
}

function ExportScreen:setup()
    self.include = self.app:get("export_include", { notes = true, tags = true, page = true, date = false })
    self.format = self.app:get("export_format", "md")
end

function ExportScreen:items(scope)
    local app, m = self.app, self.app.model
    scope = scope or self.scope
    if scope == "single" then
        local out = {}
        for __, h in ipairs(self.single_items or {}) do
            local fresh = m:get(h.key)
            if fresh then table.insert(out, fresh) end
        end
        return out
    elseif scope == "all" then
        return m.items
    elseif scope == "selected" then
        local out = {}
        for k in pairs(app.selection) do
            local h = m:get(k)
            if h then table.insert(out, h) end
        end
        return out
    end
    return m:filter(app:libraryFilter())
end

function ExportScreen:build(W, H)
    local app = self.app
    local inner = W - 2 * Kit.PAD
    local last = app:get("last_export")
    local header = Kit.header{
        width = W,
        title = _("Export"),
        small_title = true,
        left = Kit.iconButton("chevron.left", function() self:onClose() end),
        right = {
            last and Kit.text(T(_("Last: %1"), Kit.shortDate(last)), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK })
                or Kit.hspan(0),
            Kit.hspan(Kit.PAD),
        },
    }

    local sections = self:sections()
    local n = #self:items()
    local landscape = self:isLandscape()
    if landscape then
        -- The export button joins the header; the body gets the height.
        header = Kit.header{
            width = W,
            title = _("Export"),
            small_title = true,
            left = Kit.iconButton("chevron.left", function() self:onClose() end),
            right = {
                Kit.button{
                    text = T(N_("Export %1 highlight", "Export %1 highlights", n), n),
                    primary = true,
                    enabled = n > 0,
                    callback = function() self:run() end,
                },
                Kit.hspan(Kit.PAD),
            },
        }
    end
    local cta = landscape and Kit.vspan(0) or VerticalGroup:new{
        align = "left",
        Kit.hline(W, Kit.dp(1)),
        Kit.vspan(Kit.dp(12)),
        HorizontalGroup:new{
            Kit.hspan(Kit.PAD),
            Kit.button{
                text = T(N_("Export %1 highlight", "Export %1 highlights", n), n),
                icon = "tab-export",
                primary = true,
                width = inner,
                height = Kit.dp(56),
                enabled = n > 0,
                callback = function() self:run() end,
            },
        },
        Kit.vspan(Kit.dp(16)),
    }
    local body_h = H - header:getSize().h - cta:getSize().h
    local body = self:column(sections, inner)
    if body:getSize().h > body_h then
        -- Short screen (landscape): two columns, split where they balance best.
        local gap = Kit.dp(24)
        local col_w = math.floor((inner - gap) / 2)
        local best, best_k
        for k = 1, #sections - 1 do
            local a = self:column({ unpack(sections, 1, k) }, col_w):getSize().h
            local b = self:column({ unpack(sections, k + 1) }, col_w):getSize().h
            if not best or math.max(a, b) < best then best, best_k = math.max(a, b), k end
        end
        local left, right = {}, {}
        for i, sec in ipairs(sections) do
            table.insert(i <= best_k and left or right, sec)
        end
        body = HorizontalGroup:new{
            align = "top",
            self:column(left, col_w),
            Kit.hspan(gap),
            self:column(right, col_w),
        }
    end
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(W, body_h, HorizontalGroup:new{ Kit.hspan(Kit.PAD), body }, "top"),
        cta,
    }
end

-- Stack sections (each { title, build = function(width) }) in one column.
function ExportScreen:column(sections, width)
    local col = VerticalGroup:new{ align = "left" }
    for i, sec in ipairs(sections) do
        table.insert(col, Kit.vspan(Kit.dp(10)))
        table.insert(col, Kit.sectionTitle(sec.title, width))
        table.insert(col, Kit.vspan(Kit.dp(6)))
        table.insert(col, sec.build(width))
        table.insert(col, Kit.vspan(Kit.dp(10)))
        if i < #sections then table.insert(col, Kit.hline(width, Kit.dp(1))) end
    end
    return col
end

function ExportScreen:sections()
    local app = self.app
    local list = {}

    table.insert(list, { title = _("WHAT"), build = function(width)
        if self.scope == "single" then
            return Kit.text(_("This highlight"), Kit.ui(Kit.SIZE.body))
        end
        local labels, selected = {}, 1
        for i, s in ipairs(SCOPES) do
            local count = #self:items(s)
            local name = ({ filtered = _("Filtered"), all = _("All"), selected = _("Selected") })[s]
            table.insert(labels, T("%1 · %2", name, count))
            if s == self.scope then selected = i end
        end
        return Kit.segmented{
            labels = labels,
            selected = selected,
            width = width,
            on_pick = function(i)
                self.scope = SCOPES[i]
                self:refresh()
            end,
        }
    end })

    table.insert(list, { title = _("FORMAT"), build = function(width)
        local formats = VerticalGroup:new{ align = "left" }
        for __, fmt in ipairs(Export.FORMATS) do
            table.insert(formats, Kit.choiceRow{
                width = width,
                text = fmt.text,
                trailing = fmt.hint,
                mark = Kit.radio(fmt.id == self.format),
                callback = function()
                    self.format = fmt.id
                    app:set("export_format", fmt.id)
                    self:refresh()
                end,
            })
        end
        return formats
    end })

    table.insert(list, { title = _("INCLUDE"), build = function(width)
        local col_w = math.floor((width - Kit.dp(12)) / 2)
        local grid = VerticalGroup:new{ align = "left" }
        for r = 0, 1 do
            local row = HorizontalGroup:new{ align = "center" }
            for c = 1, 2 do
                local it = INCLUDE[r * 2 + c]
                if c == 2 then table.insert(row, Kit.hspan(Kit.dp(12))) end
                table.insert(row, Kit.choiceRow{
                    width = col_w,
                    text = it.text,
                    mark = Kit.checkbox(self.include[it.id]),
                    callback = function()
                        self.include[it.id] = not self.include[it.id]
                        app:set("export_include", self.include)
                        self:refresh()
                    end,
                })
            end
            table.insert(grid, row)
        end
        return grid
    end })

    table.insert(list, { title = _("SAVE TO"), build = function(width)
        local path = Export.targetPath(app:exportDir(), self.format)
        local change = Kit.button{ text = _("Change"), callback = function() self:chooseDir() end }
        local path_w = width - change:getSize().w - Kit.dp(10)
        return HorizontalGroup:new{
            align = "center",
            Kit.textbox(path, Kit.ui(Kit.SIZE.tiny), path_w, { max_lines = 3 }),
            Kit.hspan(Kit.dp(10)),
            change,
        }
    end })
    return list
end

function ExportScreen:chooseDir()
    local app = self.app
    local dir = app:exportDir()
    local util = require("util")
    if not require("libs/libkoreader-lfs").attributes(dir, "mode") then
        util.makePath(dir)
    end
    UIManager:show(PathChooser:new{
        select_file = false,
        path = dir,
        onConfirm = function(path)
            app:set("export_dir", path)
            self:refresh()
        end,
    })
end

function ExportScreen:run()
    local dir = self.app:exportDir()
    local path = Export.targetPath(dir, self.format)
    if Export.exists(path) then
        local dialog
        dialog = ButtonDialog:new{
            title = T(_("%1 already exists."), path:match("[^/]+$")),
            title_align = "center",
            buttons = {
                { { text = _("Keep both"), callback = function()
                    UIManager:close(dialog)
                    self:write(Export.uniquePath(dir, self.format))
                end } },
                { { text = _("Replace"), callback = function()
                    UIManager:close(dialog)
                    self:write(path)
                end } },
                { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
            },
        }
        UIManager:show(dialog)
    else
        self:write(path)
    end
end

function ExportScreen:write(path)
    local items = self:items()
    local opts = {
        format = self.format,
        notes = self.include.notes,
        tags = self.include.tags,
        page = self.include.page,
        date = self.include.date,
    }
    local ok, res, err = pcall(Export.write, self.app.model, items, path, opts)
    if not ok or not res then
        UIManager:show(InfoMessage:new{
            text = T(_("Export failed:\n%1"), tostring(ok and err or res)),
        })
        return
    end
    self.app:set("last_export", os.time())
    self.app:flushSettings()
    self.app:closeScreen(self)
    UIManager:show(InfoMessage:new{
        text = T(N_("Exported %1 highlight to:\n%2", "Exported %1 highlights to:\n%2", #items), #items, res),
    })
end

return ExportScreen
