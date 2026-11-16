--[[--
Library shelf: opens a full-screen library over the file manager on start
and whenever a book is closed. The folder icon reveals the normal file browser.
--]]--

local Device = require("device")
local Dispatcher = require("dispatcher")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Covers = require("covers")
local Library = require("library")
local Power = require("power")
local Profile = require("profile")
local ShelfWidget = require("shelfwidget")

local EXTRACTION_CHECK_SECONDS = 2

-- Set by the reader's "Library" action: the file manager that replaces the reader opens the shelf even without autostart.
local show_after_reader = false

local Shelf = WidgetContainer:extend{
    name = "shelf",
    is_doc_only = false,
}

function Shelf:init()
    Dispatcher:registerAction("shelf_show", { category = "none", event = "ShowShelf", title = _("Library shelf"),
        filemanager = true, reader = true })
    self.ui.menu:registerToMainMenu(self)
    Power.start()
    if self.ui.document then return end -- reader, not the file manager
    self:hookHomeButton()
    local plugins_dir = plugin_dir:match("^(.*)/[^/]*$")
    self.library = Library:new{
        bim = Library.loadBookInfoManager(plugins_dir),
        cover_specs = { max_cover_w = math.floor(Device.screen:getWidth() * 0.26),
                        max_cover_h = math.floor(Device.screen:getWidth() * 0.39) },
    }
    if show_after_reader or G_reader_settings:nilOrTrue("shelf_autostart") then
        show_after_reader = false
        UIManager:nextTick(function() self:onShowShelf() end)
    end
end

-- The file browser's Home icon goes to the home folder and opens the shelf over it.
function Shelf:hookHomeButton()
    local fm = self.ui
    fm.onHome = function()
        fm.file_chooser:goHome()
        return self:onShowShelf()
    end
end

function Shelf:addToMainMenu(menu_items)
    if self.ui.document then
        menu_items.shelf = {
            text = _("Library"),
            sorting_hint = "main",
            callback = function() self:onShowShelf() end,
        }
        return
    end
    menu_items.shelf = {
        text = _("Library shelf"),
        sorting_hint = "filemanager_settings",
        sub_item_table = {
            {
                text = _("Show library"),
                callback = function() self:onShowShelf() end,
            },
            {
                text = _("Open library on start and after a book"),
                checked_func = function() return G_reader_settings:nilOrTrue("shelf_autostart") end,
                callback = function() G_reader_settings:flipNilOrTrue("shelf_autostart") end,
            },
        },
    }
end

function Shelf:onShowShelf()
    if self.ui.document then
        show_after_reader = true
        self.ui:onHome()
        return true
    end
    if self.widget then return true end
    local home = G_reader_settings:readSetting("home_dir") or Profile.home_dir
    self.widget = ShelfWidget:new{
        ui = self.ui,
        library = self.library,
        root = home,
        plugin_path = plugin_dir,
        extract_missing = function() self:extractMissing() end,
        close_callback = function() self.widget = nil end,
    }
    local onCloseWidget = self.widget.onCloseWidget
    self.widget.onCloseWidget = function(w)
        onCloseWidget(w)
        self.widget = nil
    end
    -- Closing a book queues a full flash, which blocks ~0.6 s on the Kobo until the panel finishes; a partial "ui" is enough for the shelf.
    for _, refresh in ipairs(UIManager._refresh_stack) do
        if refresh.mode == "full" then refresh.mode = "ui" end
    end
    UIManager:show(self.widget, "ui")
    self:extractMissing()
    return true
end

function Shelf:extractMissing()
    local pending = self.library.pending_extraction
    if not pending or #pending == 0 then
        self:fetchCovers()
        return
    end
    logger.info("shelf: extracting metadata for", #pending, "books")
    self.library.bim:extractInBackground(pending)
    self.library.pending_extraction = nil
    UIManager:scheduleIn(EXTRACTION_CHECK_SECONDS, self.checkExtraction, self)
end

function Shelf:checkExtraction()
    if self.library.bim:isExtractingInBackground() then
        UIManager:scheduleIn(EXTRACTION_CHECK_SECONDS, self.checkExtraction, self)
        return
    end
    if self.widget then
        self.widget:reload()
        UIManager:setDirty(self.widget, "ui")
    end
    self:fetchCovers()
end

-- Online covers only while connected; without a network the books keep their own covers.
function Shelf:fetchCovers()
    local pending = self.library.pending_covers
    if not Covers.busy() then
        if not pending or #pending == 0 or not NetworkMgr:isConnected() then return end
        logger.info("shelf: looking up online covers for", #pending, "books")
        if not Covers.fetchInBackground(pending, self.library.cover_specs) then return end
        self.library.pending_covers = nil
    end
    UIManager:unschedule(self.checkCovers)
    UIManager:scheduleIn(EXTRACTION_CHECK_SECONDS, self.checkCovers, self)
end

function Shelf:checkCovers()
    local found = Covers.collectFinished()
    if not found then
        UIManager:scheduleIn(EXTRACTION_CHECK_SECONDS, self.checkCovers, self)
        return
    end
    logger.info("shelf: online covers found for", #found, "books")
    if not self.widget or #found == 0 then return end
    self.widget:forgetCovers(found)
    self.widget:reload()
    UIManager:setDirty(self.widget, "ui")
end

function Shelf:onNetworkConnected()
    if self.library then self:fetchCovers() end
end

function Shelf:onResume()
    Power.onResume()
end

-- The file manager closes when a book opens; take the shelf with it in the same tick.
function Shelf:onCloseWidget()
    UIManager:unschedule(self.checkExtraction)
    UIManager:unschedule(self.checkCovers)
    if self.widget then
        UIManager:close(self.widget)
    end
end

return Shelf
