--[[--
Library: search, filter chips, sort, a paged list of highlights, and the
section bar. Export lives in this screen's menu and uses the current filter
(or the current selection).

Rows have a fixed height, so the number of rows per page follows from the
available height (portrait, landscape, any screen size).
Long-press a row to start selecting; selected rows can be tagged, exported
or deleted together.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local BaseScreen = require("hlm/screen")
local Kit = require("hlm/kit")
local Model = require("hlm/model")

-- Fixed row geometry (text lines come from the "Lines per list item" setting).
local ROW_PAD = Kit.dp(10)
local ROW_GAP = Kit.dp(4)

local Library = BaseScreen:extend{
    name = "hlmanager_library",
}

function Library:setup()
    self.page = self.app:get("lib_page", 1)
    self.select_mode = next(self.app.selection) ~= nil
end

function Library:filter()
    return self.app:libraryFilter()
end

function Library:sortMode()
    return self.app:get("lib_sort", "newest")
end

function Library:computeList()
    local m = self.app.model
    self.list = m:sort(m:filter(self:filter()), self:sortMode())
end

-- Layout ------------------------------------------------------------------------

function Library:build(W, H)
    self:computeList()
    if self:isLandscape() then
        return self:buildLandscape(W, H)
    end
    local app, m = self.app, self.app.model
    local inner = W - 2 * Kit.PAD
    local f = self:filter()
    local top = VerticalGroup:new{ align = "left" }

    if self.select_mode then
        local n = Model.setSize(app.selection)
        table.insert(top, Kit.header{
            width = W,
            title = T(N_("%1 selected", "%1 selected", n), n),
            left = Kit.iconButton("close", function() self:exitSelection() end),
            right = { Kit.link(_("Select page"), function() self:selectPage() end), Kit.hspan(Kit.dp(8)) },
        })
    else
        table.insert(top, Kit.header{
            width = W,
            title = _("Highlights"),
            subtitle = T(N_("%1 total", "%1 total", m:total()), m:total()),
            right = {
                Kit.iconButton("appbar.menu", function() self:showMenu() end),
                Kit.iconButton("close", function() self:onClose() end),
            },
        })
    end

    local count = Kit.text(T(N_("%1 highlight", "%1 highlights", #self.list), #self.list),
        Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK })
    local controls = VerticalGroup:new{
        align = "left",
        Kit.vspan(Kit.dp(12)),
        self:searchBar(inner, f),
        Kit.vspan(Kit.dp(10)),
        Kit.flow(self:chips(inner, f), inner),
        Kit.vspan(Kit.dp(4)),
        Kit.spread(inner, Kit.TAP, count, self:sortLink()),
    }
    table.insert(top, HorizontalGroup:new{ Kit.hspan(Kit.PAD), controls })
    table.insert(top, Kit.hline(W, Kit.dp(1)))

    local selection_bar = self.select_mode and self:selectionBar(W) or nil
    local list_h = H - top:getSize().h - self:bottomBarHeight(W)
        - (selection_bar and selection_bar:getSize().h or 0)
    local list = self:buildList(W, inner, list_h)
    app:set("lib_page", self.page)

    local bottom = VerticalGroup:new{ align = "left" }
    if selection_bar then table.insert(bottom, selection_bar) end
    table.insert(bottom, self:bottomBar(W, "library"))
    return VerticalGroup:new{ align = "left", top, Kit.box(W, list_h, list, "top"), bottom }
end

-- Landscape: every pixel of height goes to the list. Search is a header
-- icon (an active query shows as a chip), chips sit on one row, the selection
-- actions live in the header, and pager + sections share the bottom row.
function Library:buildLandscape(W, H)
    local app, m = self.app, self.app.model
    local inner = W - 2 * Kit.PAD
    local f = self:filter()
    local header
    if self.select_mode then
        local n = Model.setSize(app.selection)
        local right = {}
        for __, a in ipairs(self:selectionActions()) do
            table.insert(right, Kit.link(a.text, a.callback, { enabled = n > 0 }))
            table.insert(right, Kit.hspan(Kit.dp(14)))
        end
        table.insert(right, Kit.link(_("Select page"), function() self:selectPage() end))
        table.insert(right, Kit.hspan(Kit.dp(10)))
        header = Kit.header{
            width = W,
            title = T(N_("%1 selected", "%1 selected", n), n),
            left = Kit.iconButton("close", function() self:exitSelection() end),
            right = right,
        }
    else
        local subtitle = #self.list ~= m:total() and T(_("%1 of %2"), #self.list, m:total())
            or T(N_("%1 total", "%1 total", m:total()), m:total())
        header = Kit.header{
            width = W,
            title = _("Highlights"),
            subtitle = subtitle,
            right = {
                self:sortLink(),
                Kit.hspan(Kit.dp(8)),
                Kit.iconButton("appbar.search", function() self:askSearch() end),
                Kit.iconButton("appbar.menu", function() self:showMenu() end),
                Kit.iconButton("close", function() self:onClose() end),
            },
        }
    end
    local chips = self:chips(inner, f)
    if f.search and f.search ~= "" then
        table.insert(chips, 1, Kit.chip{
            text = "“" .. f.search .. "”",
            active = true,
            max_width = math.floor(inner / 3),
            callback = function() self:askSearch() end,
            hold_callback = function()
                f.search = nil
                self:applyFilter(f)
            end,
        })
    end
    local top = VerticalGroup:new{
        align = "left",
        header,
        Kit.vspan(Kit.dp(8)),
        HorizontalGroup:new{ Kit.hspan(Kit.PAD), Kit.flow(chips, inner) },
        Kit.vspan(Kit.dp(8)),
        Kit.hline(W, Kit.dp(1)),
    }

    local list_h = H - top:getSize().h - self:bottomBarHeight(W)
    local list = self:buildList(W, inner, list_h)
    app:set("lib_page", self.page)
    local bottom = self:bottomBar(W, "library")
    return VerticalGroup:new{ align = "left", top, Kit.box(W, list_h, list, "top"), bottom }
end

function Library:sortLink()
    return Kit.link(T(_("Sort: %1"), self:sortLabel()), function() self:showSortMenu() end,
        { size = Kit.SIZE.tiny + 1 })
end

function Library:sortLabel()
    for __, s in ipairs(Model.SORTS) do
        if s.id == self:sortMode() then return s.text end
    end
    return ""
end

function Library:searchBar(width, f)
    local h = Kit.TAP
    local active = f.search and f.search ~= ""
    local text_w = width - Kit.dp(24) - Kit.dp(10) - Kit.dp(24) - (active and Kit.TAP or 0)
    local label = Kit.text(active and f.search or _("Search text, notes, books"), Kit.ui(Kit.SIZE.body),
        { fgcolor = active and Kit.BLACK or Kit.GREY_DARK, max_width = text_w })
    local row = HorizontalGroup:new{
        align = "center",
        Kit.hspan(Kit.dp(12)),
        Kit.icon("appbar.search", Kit.dp(24)),
        Kit.hspan(Kit.dp(10)),
        Kit.box(text_w, h - 2 * Kit.dp(1.5), label, "left"),
    }
    local field = Kit.tap(Kit.box(width - (active and Kit.TAP or 0) - 2 * Kit.dp(1.5), h - 2 * Kit.dp(1.5),
        row, "left"), function() self:askSearch() end)
    local content = HorizontalGroup:new{ align = "center", field }
    if active then
        -- Separate clear target, not inside the text tap area.
        table.insert(content, Kit.iconButton("close", function()
            f.search = nil
            self:applyFilter(f)
        end, { icon_size = Kit.dp(20), size = h - 2 * Kit.dp(1.5) }))
    end
    return FrameContainer:new{
        bordersize = Kit.dp(1.5),
        radius = Kit.dp(6),
        padding = 0,
        background = Kit.WHITE,
        content,
    }
end

function Library:chips(width, f)
    local m = self.app.model
    local function chip(section, idle, active_label)
        return Kit.chip{
            text = active_label or idle,
            active = active_label ~= nil,
            max_width = width,
            callback = function() self:openFilter(section) end,
            -- Long-press an active chip to clear just that filter.
            hold_callback = active_label and function() self:clearSection(section) end or nil,
        }
    end
    local list = {
        chip("books", _("Books"), m:sourceLabel(f)),
        chip("authors", _("Authors"), m:authorLabel(f)),
        chip("tags", _("Tags"), m:tagLabel(f)),
        chip("time", _("Time"), m:timeLabel(f)),
    }
    local any = Model.setSize(f.books) + Model.setSize(f.authors) + Model.setSize(f.tags) > 0
        or f.untagged or (f.time and f.time ~= "all")
    if any then
        table.insert(list, Kit.chip{
            text = _("Clear"),
            callback = function()
                local nf = Model.emptyFilter()
                nf.search = f.search
                self:applyFilter(nf)
            end,
        })
    end
    return list
end

function Library:rowHeight()
    local lines = self.app:get("list_lines", 2)
    local qf = Kit.serif(Kit.SIZE.quote_list)
    local meta_h = Kit.text("Ag", Kit.ui(Kit.SIZE.tiny)):getSize().h
    return ROW_PAD + Kit.lineHeight(qf) * lines + ROW_GAP + meta_h + ROW_PAD + Kit.dp(1)
end

function Library:buildList(W, inner, list_h)
    local app, m = self.app, self.app.model
    if #self.list == 0 then
        self.per_page, self.pages, self.page = 1, 1, 1
        local msg, action
        if m:total() == 0 then
            msg = _("No highlights yet.\n\nHighlight text while reading and it will show up here. Books are picked up from your reading history.")
        else
            msg = _("No highlights match these filters.")
            action = Kit.button{ text = _("Clear filters"), callback = function()
                self:applyFilter(Model.emptyFilter())
            end }
        end
        local g = VerticalGroup:new{
            align = "center",
            Kit.textbox(msg, Kit.ui(Kit.SIZE.body), inner, { alignment = "center", fgcolor = Kit.GREY_DARK }),
        }
        if action then
            table.insert(g, Kit.vspan(Kit.dp(16)))
            table.insert(g, action)
        end
        return Kit.box(W, list_h, g)
    end
    local row_h = self:rowHeight()
    local grid = self:pagedRows{
        count = #self.list,
        row_h = row_h,
        height = list_h,
        width = inner,
        build = function(i, w) return self:buildRow(i, w, row_h) end,
    }
    return HorizontalGroup:new{ Kit.hspan(Kit.PAD), grid }
end

-- One fixed-height row, `w` wide (no outer padding).
function Library:buildRow(i, w, row_h)
    local app = self.app
    local h = self.list[i]
    local lines = app:get("list_lines", 2)
    local selected = app.selection[h.key]
    local mark_w = self.select_mode and (Kit.dp(22) + Kit.dp(12)) or 0
    local text_w = w - mark_w
    local qf = Kit.serif(Kit.SIZE.quote_list)

    local body = VerticalGroup:new{ align = "left" }
    local quote_lines = h.note and math.max(1, lines - 1) or lines
    table.insert(body, Kit.textbox(h.text, qf, text_w, { max_lines = quote_lines }))
    if h.note then
        table.insert(body, Kit.textbox(_("Note: ") .. h.note:gsub("\n", " "), Kit.serifItalic(Kit.SIZE.small),
            text_w, { max_lines = 1, fgcolor = Kit.GREY_DARK }))
    end
    -- Keep every row the same height whatever the text length.
    local text_h = Kit.lineHeight(qf) * lines
    local book = h.book
    local where = {}
    if book then
        table.insert(where, book.title)
        if book.author_list[1] then table.insert(where, book.author_list[1]) end
    end
    local loc = h.pageref and T(_("p. %1"), h.pageref) or (h.pageno and T(_("p. %1"), h.pageno))
    if loc then table.insert(where, loc) end
    local date = Kit.text(Kit.shortDate(h.ts), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK })
    local meta_left = Kit.text(table.concat(where, " · "), Kit.ui(Kit.SIZE.tiny),
        { fgcolor = Kit.GREY_DARK, max_width = text_w - date:getSize().w - Kit.dp(12) })
    local meta = Kit.spread(text_w, meta_left:getSize().h, meta_left, date)

    local content = VerticalGroup:new{
        align = "left",
        Kit.vspan(ROW_PAD),
        Kit.box(text_w, text_h, body, "top"),
        Kit.vspan(ROW_GAP),
        meta,
        Kit.vspan(ROW_PAD),
    }
    local row = HorizontalGroup:new{ align = "center" }
    if self.select_mode then
        table.insert(row, Kit.checkbox(selected))
        table.insert(row, Kit.hspan(Kit.dp(12)))
    end
    table.insert(row, content)
    local cell = VerticalGroup:new{
        align = "left",
        Kit.box(w, row_h - Kit.dp(1), row, "left"),
        Kit.hline(w, Kit.dp(1), Kit.GREY_LIGHT),
    }
    return Kit.tap(cell, function()
        if self.select_mode then
            self:toggleSelect(h)
        else
            app:showDetail(self.list, i)
        end
    end, function()
        if not self.select_mode then
            self.select_mode = true
        end
        self:toggleSelect(h)
    end)
end

function Library:selectionActions()
    local app = self.app
    local function keys()
        local list = {}
        for k in pairs(app.selection) do table.insert(list, k) end
        return list
    end
    return {
        { text = _("Tag"), callback = function() app:showTagPicker(keys()) end },
        { text = _("Export"), callback = function() app:showExport("selected") end },
        { text = _("Delete"), callback = function()
            local items = {}
            for __, k in ipairs(keys()) do
                local h = app.model:get(k)
                if h then table.insert(items, h) end
            end
            app:confirmDelete(items, function() self:exitSelection() end)
        end },
    }
end

function Library:selectionBar(W)
    local has = next(self.app.selection) ~= nil
    local gap = Kit.dp(8)
    local actions = self:selectionActions()
    local bw = math.floor((W - 2 * Kit.PAD - (#actions - 1) * gap) / #actions)
    local row = HorizontalGroup:new{ align = "center", Kit.hspan(Kit.PAD) }
    for i, a in ipairs(actions) do
        if i > 1 then table.insert(row, Kit.hspan(gap)) end
        table.insert(row, Kit.button{ text = a.text, width = bw, enabled = has, callback = a.callback })
    end
    return VerticalGroup:new{
        align = "left",
        Kit.hline(W, Kit.dp(1)),
        Kit.vspan(gap),
        row,
        Kit.vspan(gap),
    }
end

-- Behaviour -------------------------------------------------------------------


function Library:applyFilter(f)
    self.app:setLibraryFilter(f)
    self.page = 1
    self:refresh()
end

function Library:openFilter(section)
    self.app:showFilter(section, self:filter(), function(nf)
        nf.search = self:filter().search
        self:applyFilter(nf)
    end)
end

function Library:clearSection(section)
    local f = Model.copyFilter(self:filter())
    if section == "books" then f.books = nil
    elseif section == "authors" then f.authors = nil
    elseif section == "tags" then f.tags = nil; f.untagged = nil
    elseif section == "time" then f.time = "all"; f.from = nil; f.to = nil
    end
    self:applyFilter(f)
end

function Library:askSearch()
    local f = Model.copyFilter(self:filter())
    local dialog
    dialog = InputDialog:new{
        title = _("Search highlights"),
        input = f.search or "",
        input_hint = _("Words in text, notes, titles"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Clear"), enabled = f.search ~= nil and f.search ~= "", callback = function()
                UIManager:close(dialog)
                f.search = nil
                self:applyFilter(f)
            end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local s = dialog:getInputText()
                UIManager:close(dialog)
                f.search = (s and s ~= "") and s or nil
                self:applyFilter(f)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Library:showSortMenu()
    local dialog
    local buttons = {}
    for __, s in ipairs(Model.SORTS) do
        table.insert(buttons, { {
            text = s.text,
            checked_func = function() return self:sortMode() == s.id end,
            callback = function()
                UIManager:close(dialog)
                self.app:set("lib_sort", s.id)
                self.page = 1
                self:refresh()
            end,
        } })
    end
    dialog = ButtonDialog:new{ title = _("Sort highlights"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function Library:showMenu()
    local app = self.app
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            { { text = T(_("Export %1 highlights…"), #self.list), enabled = #self.list > 0, callback = function()
                UIManager:close(dialog)
                app:showExport("filtered")
            end } },
            { { text = _("Select highlights"), enabled = #self.list > 0, callback = function()
                UIManager:close(dialog)
                self.select_mode = true
                self:refresh()
            end } },
            { { text = _("Rescan all books"), callback = function()
                UIManager:close(dialog)
                app:sync(true, function() self:refresh(true) end)
            end } },
        },
    }
    UIManager:show(dialog)
end

function Library:toggleSelect(h)
    local sel = self.app.selection
    sel[h.key] = (not sel[h.key]) or nil
    self:refresh()
end

function Library:selectPage()
    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(#self.list, first + self.per_page - 1)
    local all = true
    for i = first, last do
        if not self.app.selection[self.list[i].key] then all = false break end
    end
    for i = first, last do
        self.app.selection[self.list[i].key] = (not all) or nil
    end
    self:refresh()
end

function Library:exitSelection()
    self.app.selection = {}
    self.select_mode = false
    self:refresh()
end

function Library:onClose()
    if self.select_mode then
        self:exitSelection()
        return true
    end
    return BaseScreen.onClose(self)
end


return Library
