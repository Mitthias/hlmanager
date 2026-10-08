--[[--
Controller for the Highlights screens: navigation, saved state, and every
action that touches a book (open at highlight, edit note, delete).

Navigation model
* One "tab" screen at a time (Library, Vagary, Tags), switched from the tab bar.
* Detail, Filter, Tag picker and Export are pushed on top and closed with ✕ / ‹ /
  Back, returning to the screen below.
* Closing a tab screen leaves the plugin. The last tab, filter, sort and page
  are saved, so reopening (menu or gesture) returns to the same place — also
  after "Open in book".
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Indexer = require("hlm/indexer")
local Model = require("hlm/model")

local App = {}
App.__index = App

function App.new(plugin)
    local self = setmetatable({
        plugin = plugin,
        ui = plugin.ui,
        store = plugin:getStore(),
        settings = plugin.settings,
        overlays = {},
        tab_screen = nil,
        selection = {}, -- [key] = true, Library multi-select
    }, App)
    return self
end

-- Settings helpers -------------------------------------------------------------

function App:get(key, default)
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function App:set(key, value)
    self.settings:saveSetting(key, value)
end

function App:flushSettings()
    self.settings:flush()
end

function App:libraryFilter()
    if not self.lib_filter then
        self.lib_filter = Model.copyFilter(self:get("lib_filter"))
    end
    return self.lib_filter
end

function App:setLibraryFilter(f)
    self.lib_filter = f
    self:set("lib_filter", f)
    self:set("lib_page", 1)
end

function App:vagaryFilter()
    if not self.vag_filter then
        self.vag_filter = Model.copyFilter(self:get("vag_filter"))
    end
    return self.vag_filter
end

function App:setVagaryFilter(f)
    self.vag_filter = f
    self:set("vag_filter", f)
end

function App:exportDir()
    return self:get("export_dir", require("hlm/export").defaultDir())
end

-- Index -----------------------------------------------------------------------

-- Bring the index up to date, then (re)build the model. Shows a message only
-- when there is actual work, so normal opens stay instant.
function App:sync(force, done)
    local pending = force and 1 or Indexer.pendingCount(self.store)
    local function run()
        local ok, err = pcall(Indexer.syncAll, self.store, self.ui, force)
        if not ok then logger.warn("Highlights: sync failed", err) end
        self.model = Model.new(self.store)
        if done then done() end
    end
    if pending > 0 then
        local msg = InfoMessage:new{ text = _("Indexing highlights…"), dismissable = false }
        UIManager:show(msg)
        UIManager:forceRePaint()
        UIManager:nextTick(function()
            run()
            UIManager:close(msg)
        end)
    else
        run()
    end
end

-- Re-read one book after we changed it, then refresh every open screen.
function App:reindexBook(file)
    if self.ui.document and self.ui.document.file == file then
        pcall(Indexer.indexOpenDocument, self.store, self.ui)
    else
        pcall(Indexer.indexFile, self.store, file, true)
    end
    self:dataChanged()
end

function App:dataChanged()
    self.model:reload()
    for key in pairs(self.selection) do
        if not self.model:get(key) then self.selection[key] = nil end
    end
    self:refreshAll()
end

function App:refreshAll()
    local top = self:topScreen()
    if self.tab_screen and self.tab_screen ~= top then self.tab_screen:rebuild() end
    for __, s in ipairs(self.overlays) do
        if s ~= top then
            if s.onDataChanged then s:onDataChanged() end
            s:rebuild()
        end
    end
    if top then
        if top.onDataChanged then top:onDataChanged() end
        top:refresh()
    end
end

-- Navigation ------------------------------------------------------------------

function App:topScreen()
    return self.overlays[#self.overlays] or self.tab_screen
end

local TAB_MODULES = {
    library = "hlm/screens/library",
    vagary = "hlm/screens/vagary",
    tags = "hlm/screens/tags",
}

function App:open(tab)
    tab = tab or self:get("tab", "library")
    if self.tab_screen then
        self:showTab(tab)
        return
    end
    self:sync(false, function()
        self:showTab(tab)
    end)
end

function App:showTab(id)
    if not TAB_MODULES[id] then id = "library" end
    for i = #self.overlays, 1, -1 do
        UIManager:close(self.overlays[i])
        self.overlays[i] = nil
    end
    local old = self.tab_screen
    local Cls = require(TAB_MODULES[id])
    self.tab_screen = Cls:new{ app = self }
    self:set("tab", id)
    UIManager:show(self.tab_screen, "flashui")
    if old then UIManager:close(old) end
end

function App:push(screen)
    table.insert(self.overlays, screen)
    UIManager:show(screen, "flashui")
    return screen
end

function App:closeScreen(screen)
    if screen == self.tab_screen then
        self:closeAll()
        return
    end
    for i, s in ipairs(self.overlays) do
        if s == screen then
            table.remove(self.overlays, i)
            break
        end
    end
    UIManager:close(screen, "flashui")
    local top = self:topScreen()
    if top and top.onRevealed then top:onRevealed() end
end

function App:closeAll()
    for i = #self.overlays, 1, -1 do
        UIManager:close(self.overlays[i])
        self.overlays[i] = nil
    end
    if self.tab_screen then
        UIManager:close(self.tab_screen, "flashui")
        self.tab_screen = nil
    end
    self:flushSettings()
    self.plugin:onAppClosed(self)
end

-- Screens -----------------------------------------------------------------------

function App:showDetail(list, index)
    local Detail = require("hlm/screens/detail")
    return self:push(Detail:new{ app = self, list = list, index = index })
end

-- section: "books" | "authors" | "tags" | "time"
function App:showFilter(section, filter, on_apply)
    local Filter = require("hlm/screens/filter")
    return self:push(Filter:new{ app = self, section = section, filter = Model.copyFilter(filter),
        on_apply = on_apply })
end

-- Menu of filter sections (used by Vagary's "From" chip).
function App:showFilterMenu(filter, on_apply)
    local dialog
    local function open(section)
        UIManager:close(dialog)
        self:showFilter(section, filter, on_apply)
    end
    local m = self.model
    local function label(text, summary)
        return summary and (text .. ": " .. summary) or text
    end
    dialog = ButtonDialog:new{
        title = T(_("Draw from %1 highlights"), m:count(filter)),
        buttons = {
            { { text = label(_("Books"), m:sourceLabel(filter)), callback = function() open("books") end } },
            { { text = label(_("Authors"), m:authorLabel(filter)), callback = function() open("authors") end } },
            { { text = label(_("Tags"), m:tagLabel(filter)), callback = function() open("tags") end } },
            { { text = label(_("Time"), m:timeLabel(filter)), callback = function() open("time") end } },
            {
                {
                    text = _("Reset to all"),
                    enabled = Model.isActive(filter),
                    callback = function()
                        UIManager:close(dialog)
                        on_apply(Model.emptyFilter())
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- keys: array of highlight keys. on_done() after changes were saved.
function App:showTagPicker(keys, on_done)
    local Picker = require("hlm/screens/tagpicker")
    return self:push(Picker:new{ app = self, keys = keys, on_done = on_done })
end

-- scope: "filtered" | "all" | "selected" | "single" (with items = { h })
function App:showExport(scope, items)
    local ExportScreen = require("hlm/screens/export")
    return self:push(ExportScreen:new{ app = self, scope = scope, single_items = items })
end

function App:showText(title, text)
    UIManager:show(TextViewer:new{ title = title, text = text })
end

-- Actions on highlights -------------------------------------------------------

local function findAnnotationIndex(annotations, h)
    if not annotations then return end
    local fallback, fallback_count = nil, 0
    for i, a in ipairs(annotations) do
        if a.datetime == h.datetime and a.drawer then
            if Indexer.posKey(a) == h.poskey then
                return i
            end
            fallback, fallback_count = i, fallback_count + 1
        end
    end
    -- Highlight boundaries edited since indexing: accept a unique time match.
    if fallback_count == 1 then return fallback end
end

function App:isCurrentBook(h)
    return self.ui.document and h.book and self.ui.document.file == h.book.file
end

function App:canOpen(h)
    local file = h.book and h.book.file
    return file and require("libs/libkoreader-lfs").attributes(file, "mode") == "file"
end

function App:openInBook(h)
    if not self:canOpen(h) then
        UIManager:show(InfoMessage:new{ text = _("This book's file can no longer be found.") })
        return
    end
    local file = h.book.file
    local ui = self.ui
    local function after_open(rui)
        local idx = findAnnotationIndex(rui.annotation and rui.annotation.annotations, h)
        if idx then
            local a = rui.annotation.annotations[idx]
            if rui.link and rui.link.addCurrentLocationToStack then
                rui.link:addCurrentLocationToStack()
            end
            rui.bookmark:gotoBookmark(a.page, a.pos0)
        else
            UIManager:show(InfoMessage:new{ text = _("Could not find this highlight in the book any more.") })
        end
    end
    self:closeAll()
    if ui.document then
        if ui.document.file == file then
            after_open(ui)
        else
            ui:switchDocument(file, nil, after_open)
        end
    else
        ui:openFile(file, nil, nil, nil, after_open)
    end
end

function App:editNote(h, on_done)
    local dialog
    dialog = InputDialog:new{
        title = h.note and _("Edit note") or _("Add note"),
        description = h.book and h.book.title or nil,
        input = h.note or "",
        allow_newline = true,
        use_available_height = true,
        add_scroll_buttons = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        value = util.trim(value or "")
                        if value == "" then value = nil end
                        UIManager:close(dialog)
                        local ok, err = self:writeNote(h, value)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = err or _("Could not save the note.") })
                            return
                        end
                        self:reindexBook(h.book.file)
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function App:writeNote(h, value)
    if self:isCurrentBook(h) then
        local ui = self.ui
        local anns = ui.annotation.annotations
        local idx = findAnnotationIndex(anns, h)
        if not idx then return nil, _("Could not find this highlight in the book.") end
        local a = anns[idx]
        local before = a.note and "note" or "highlight"
        a.note = value
        if ui.paging and ui.highlight and ui.highlight.writePdfAnnotation then
            ui.highlight:writePdfAnnotation("content", a, value or "")
        end
        local after = a.note and "note" or "highlight"
        if before ~= after then
            ui:handleEvent(Event:new("AnnotationsModified", {
                a,
                nb_highlights_added = before == "highlight" and -1 or 1,
                nb_notes_added = before == "highlight" and 1 or -1,
            }))
        else
            ui:handleEvent(Event:new("AnnotationsModified", { a }))
        end
        return true
    end
    local file = h.book and h.book.file
    if not file or not DocSettings:hasSidecarFile(file) then
        return nil, _("This book's metadata could not be found.")
    end
    local ds = DocSettings:open(file)
    local anns = ds:readSetting("annotations")
    local idx = findAnnotationIndex(anns, h)
    if not idx then return nil, _("Could not find this highlight in the book.") end
    anns[idx].note = value
    anns[idx].datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
    ds:saveSetting("annotations", anns)
    ds:flush()
    return true
end

-- Deletes from the book itself: KOReader is the source of truth, so a
-- "remove from list only" would come back on the next scan.
function App:confirmDelete(items, on_done)
    local text
    if #items == 1 then
        local title = items[1].book and items[1].book.title or ""
        text = T(_("Delete this highlight from “%1”?\n\nIt is removed from the book itself, with its note and tags. This cannot be undone."), title)
    else
        text = T(N_("Delete %1 highlight from its book?\n\nThis cannot be undone.",
            "Delete %1 highlights from their books?\n\nThis cannot be undone.", #items), #items)
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Delete"),
        ok_callback = function()
            self:deleteHighlights(items)
            if on_done then on_done() end
        end,
    })
end

function App:deleteHighlights(items)
    -- Group by book so each sidecar is written once.
    local by_file = {}
    for __, h in ipairs(items) do
        local file = h.book and h.book.file
        if file then
            by_file[file] = by_file[file] or {}
            table.insert(by_file[file], h)
        end
    end
    local failed = 0
    for file, list in pairs(by_file) do
        if self.ui.document and self.ui.document.file == file then
            for __, h in ipairs(list) do
                local idx = findAnnotationIndex(self.ui.annotation.annotations, h)
                if idx then
                    self.ui.highlight:deleteHighlight(idx)
                    self.store:forgetHighlight(h.key)
                else
                    failed = failed + 1
                end
            end
            pcall(Indexer.indexOpenDocument, self.store, self.ui)
        elseif DocSettings:hasSidecarFile(file) then
            local ds = DocSettings:open(file)
            local anns = ds:readSetting("annotations") or {}
            for __, h in ipairs(list) do
                local idx = findAnnotationIndex(anns, h)
                if idx then
                    table.remove(anns, idx)
                    self.store:forgetHighlight(h.key)
                else
                    failed = failed + 1
                end
            end
            ds:saveSetting("annotations", anns)
            -- Ask the reader to re-check page numbers and stats on next open.
            ds:makeTrue("annotations_externally_modified")
            ds:flush()
            local ok, BookList = pcall(require, "ui/widget/booklist")
            if ok and BookList.setBookInfoCacheProperty then
                BookList.setBookInfoCacheProperty(file, "has_annotations", #anns > 0)
            end
            pcall(Indexer.indexFile, self.store, file, true)
        else
            failed = failed + #list
        end
        for __, h in ipairs(list) do self.selection[h.key] = nil end
    end
    self:dataChanged()
    if failed > 0 then
        UIManager:show(InfoMessage:new{
            text = T(N_("%1 highlight could not be deleted.", "%1 highlights could not be deleted.", failed), failed),
        })
    end
end

function App:copy(h)
    Device.input.setClipboardText(h.text)
    Notification:notify(_("Highlight copied to clipboard."))
end

function App:canShare()
    return Device:canShareText()
end

function App:share(h)
    local text = h.text
    if h.book then
        text = "“" .. h.text .. "”\n— " .. h.book.title
        if h.book.author_list[1] then text = text .. ", " .. h.book.author_list[1] end
    end
    Device:doShareText(text, nil, h.book and h.book.title)
end

-- Tags --------------------------------------------------------------------------

-- Prompt for a tag name. on_name(name) receives the trimmed name.
function App:askTagName(title, initial, ok_text, on_name)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        input_hint = _("Tag name"),
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                {
                    text = ok_text or _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = util.trim(dialog:getInputText() or "")
                        name = name:gsub("%s+", " ")
                        if name == "" then return end
                        UIManager:close(dialog)
                        on_name(name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function App:createTag(on_created)
    self:askTagName(_("New tag"), "", _("Add"), function(name)
        local id = self.store:ensureTag(name)
        self:dataChanged()
        if on_created then on_created(id) end
    end)
end

function App:tagMenu(tag)
    local dialog
    dialog = ButtonDialog:new{
        title = tag.name,
        title_align = "center",
        buttons = {
            { { text = _("Rename…"), callback = function()
                UIManager:close(dialog)
                self:renameTag(tag)
            end } },
            { { text = _("Merge into…"), enabled = #self.model.tags > 1, callback = function()
                UIManager:close(dialog)
                self:mergeTag(tag)
            end } },
            { { text = _("Delete…"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = T(N_("Delete tag “%1”?\n\nIt is removed from %2 highlight. The highlights themselves are kept.",
                        "Delete tag “%1”?\n\nIt is removed from %2 highlights. The highlights themselves are kept.",
                        tag.count), tag.name, tag.count),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self.store:deleteTag(tag.id)
                        self:forgetTagInFilters(tag.id)
                        self:dataChanged()
                    end,
                })
            end } },
        },
    }
    UIManager:show(dialog)
end

function App:renameTag(tag)
    self:askTagName(_("Rename tag"), tag.name, _("Rename"), function(name)
        local existing = self.store:tagIdByName(name)
        if existing and existing ~= tag.id then
            UIManager:show(ConfirmBox:new{
                text = T(_("A tag named “%1” already exists. Merge “%2” into it?"), name, tag.name),
                ok_text = _("Merge"),
                ok_callback = function()
                    self.store:mergeTag(tag.id, existing)
                    self:forgetTagInFilters(tag.id, existing)
                    self:dataChanged()
                end,
            })
            return
        end
        self.store:renameTag(tag.id, name)
        self:dataChanged()
    end)
end

function App:mergeTag(tag)
    local buttons = {}
    for __, t in ipairs(self.model:tagList("az")) do
        if t.id ~= tag.id then
            table.insert(buttons, { {
                text = T("%1 (%2)", t.name, t.count),
                callback = function()
                    UIManager:close(self._merge_dialog)
                    self.store:mergeTag(tag.id, t.id)
                    self:forgetTagInFilters(tag.id, t.id)
                    self:dataChanged()
                end,
            } })
        end
    end
    self._merge_dialog = ButtonDialog:new{
        title = T(_("Merge “%1” into…"), tag.name),
        title_align = "center",
        buttons = buttons,
        rows_per_page = 8,
    }
    UIManager:show(self._merge_dialog)
end

-- Keep saved filters valid after a tag disappears (optionally mapped to another).
function App:forgetTagInFilters(old_id, new_id)
    for __, f in ipairs({ self:libraryFilter(), self:vagaryFilter() }) do
        if f.tags and f.tags[old_id] then
            f.tags[old_id] = nil
            if new_id then f.tags[new_id] = true end
        end
    end
    self:set("lib_filter", self.lib_filter)
    self:set("vag_filter", self.vag_filter)
end

return App
