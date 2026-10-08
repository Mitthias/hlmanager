--[[--
Highlights: browse, tag, rediscover and export highlights from every book.

Entry points
* Tools ▸ Highlights (file browser and reader menus)
* Gesture/hotkey actions "Highlights: library" and "Highlights: Vagary"

@module koplugin.hlmanager
--]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local HLManager = WidgetContainer:extend{
    name = "hlmanager",
    is_doc_only = false,
}

function HLManager:init()
    local Kit = require("hlm/kit")
    Kit.icons_dir = self.path .. "/icons"
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/hlmanager.lua")
    Kit.setQuoteFont(self.settings:readSetting("quote_font"))
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- Opened lazily, so a database problem never blocks KOReader from starting.
function HLManager:getStore()
    if not self.store then
        local ok, res = pcall(function()
            return require("hlm/store").new(DataStorage:getSettingsDir() .. "/hlmanager.sqlite3")
        end)
        if not ok then
            logger.err("Highlights: cannot open database", res)
            UIManager:show(InfoMessage:new{ text = T(_("Highlights could not open its database:\n%1"), tostring(res)) })
            return
        end
        self.store = res
    end
    return self.store
end

function HLManager:onDispatcherRegisterActions()
    Dispatcher:registerAction("hlmanager_library", {
        category = "none", event = "ShowHighlightsLibrary",
        title = _("Highlights: library"), general = true,
    })
    Dispatcher:registerAction("hlmanager_vagary", {
        category = "none", event = "ShowHighlightsVagary",
        title = _("Highlights: Vagary (random highlight)"), general = true,
    })
end

function HLManager:show(tab)
    if not self:getStore() then return end
    if not self.app then
        self.app = require("hlm/app").new(self)
    end
    self.app:open(tab)
end

function HLManager:onAppClosed(app)
    if self.app == app then self.app = nil end
end

function HLManager:onShowHighlightsLibrary()
    self:show("library")
    return true
end

function HLManager:onShowHighlightsVagary()
    self:show("vagary")
    return true
end

function HLManager:onCloseWidget()
    if self.app then self.app:closeAll() end
    self.settings:flush()
end

function HLManager:addToMainMenu(menu_items)
    local Kit = require("hlm/kit")
    menu_items.hlmanager = {
        text = _("Highlights"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Library"),
                callback = function() self:show("library") end,
            },
            {
                text = _("Vagary (random highlight)"),
                callback = function() self:show("vagary") end,
            },
            {
                text = _("Tags"),
                callback = function() self:show("tags") end,
                separator = true,
            },
            {
                text = _("Rescan all books"),
                help_text = _("Re-read the highlights of every book in your reading history. Normally only books changed since the last visit are read."),
                callback = function()
                    local store = self:getStore()
                    if not store then return end
                    local Indexer = require("hlm/indexer")
                    UIManager:show(InfoMessage:new{ text = _("Indexing highlights…"), timeout = 1 })
                    UIManager:nextTick(function()
                        local n = Indexer.syncAll(store, self.ui, true)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Highlights from %1 books indexed."), n + (self.ui.document and 1 or 0)),
                            timeout = 3,
                        })
                    end)
                end,
            },
            {
                text = _("Quote font"),
                sub_item_table = {
                    {
                        text = _("Serif (Noto Serif)"),
                        radio = true,
                        checked_func = function() return self.settings:readSetting("quote_font", "serif") == "serif" end,
                        callback = function()
                            self.settings:saveSetting("quote_font", "serif")
                            Kit.setQuoteFont("serif")
                        end,
                    },
                    {
                        text = _("Same as interface"),
                        radio = true,
                        checked_func = function() return self.settings:readSetting("quote_font") == "sans" end,
                        callback = function()
                            self.settings:saveSetting("quote_font", "sans")
                            Kit.setQuoteFont("sans")
                        end,
                    },
                },
            },
            {
                text_func = function()
                    return T(_("Lines per list item: %1"), self.settings:readSetting("list_lines", 2))
                end,
                help_text = _("Fewer lines fit more highlights on each Library page."),
                sub_item_table = (function()
                    local items = {}
                    for __, n in ipairs({ 2, 3, 4, 5 }) do
                        table.insert(items, {
                            text = tostring(n),
                            radio = true,
                            checked_func = function() return self.settings:readSetting("list_lines", 2) == n end,
                            callback = function() self.settings:saveSetting("list_lines", n) end,
                        })
                    end
                    return items
                end)(),
            },
            {
                text_func = function()
                    local dir = self.settings:readSetting("export_dir") or require("hlm/export").defaultDir()
                    return T(_("Export folder: %1"), dir)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local util = require("util")
                    local dir = self.settings:readSetting("export_dir") or require("hlm/export").defaultDir()
                    if not require("libs/libkoreader-lfs").attributes(dir, "mode") then
                        util.makePath(dir)
                    end
                    UIManager:show(PathChooser:new{
                        select_file = false,
                        path = dir,
                        onConfirm = function(path)
                            self.settings:saveSetting("export_dir", path)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
        },
    }
end

return HLManager
