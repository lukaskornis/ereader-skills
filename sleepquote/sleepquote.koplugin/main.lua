--[[
Sleep screen: a picture (the eye by default, or one the reader picks), the battery percent, and one
highlight from recently read books, each part switchable.
It wraps Screensaver.show for plain suspends; power-off and reboot screens stay KOReader's own.
]]
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local PathChooser = require("ui/widget/pathchooser")
local bit = require("bit")
local Device = require("device")
local DocSettings = require("docsettings")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local ReadHistory = require("readhistory")
local RenderText = require("ui/rendertext")
local Screensaver = require("ui/screensaver")
local ScreenSaverLockWidget = require("ui/widget/screensaverlockwidget")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local DIR = debug.getinfo(1, "S").source:match("^@(.*/)")
local Logic = dofile(DIR .. "logic.lua")

local ENABLED_KEY = "sleepquote_enabled"
local BALANCE_KEY = "sleepquote_balance"
local PICTURE_KEY = "sleepquote_picture"
local PICTURE_FILE_KEY = "sleepquote_picture_file"
local HIGHLIGHT_KEY = "sleepquote_highlight"
local BATTERY_KEY = "sleepquote_battery"
local MAX_BOOKS = 30
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.Color8(0x44)

local SCALE = Screen:scaleBySize(1000) / 1000
-- getFace scales by DPI; sizes here are pixels.
local function face(file, px)
    return Font:getFace(file, math.floor(px) / SCALE)
end

local function highlightsOf(annotations)
    local list = {}
    for _, a in ipairs(annotations or {}) do
        local text = a.drawer and Logic.clean(a.text)
        if text then list[#list + 1] = text end
    end
    return list
end

local function titleOf(file, props)
    local title = props and props.title
    if title and title ~= "" then return title end
    return (file:match("[^/]+$") or file):gsub("%.[^.]+$", ""):gsub("%.kepub$", "")
end

-- Current book first (live annotations, not yet flushed), then the reading history.
local function collectBooks()
    local books, seen = {}, {}
    local reader = require("apps/reader/readerui").instance
    if reader and reader.document and reader.annotation then
        local file = reader.document.file
        seen[file] = true
        books[1] = {
            file = file,
            title = titleOf(file, reader.doc_props),
            highlights = highlightsOf(reader.annotation.annotations),
        }
    end
    local lastfile = G_reader_settings:readSetting("lastfile")
    local files = { lastfile }
    for _, item in ipairs(ReadHistory.hist) do files[#files + 1] = item.file end
    for _, file in ipairs(files) do
        if #books >= MAX_BOOKS then break end
        if file and not seen[file] and lfs.attributes(file, "mode") == "file" and DocSettings:hasSidecarFile(file) then
            seen[file] = true
            local ds = DocSettings:open(file)
            books[#books + 1] = {
                file = file,
                title = titleOf(file, ds:readSetting("doc_props")),
                highlights = highlightsOf(ds:readSetting("annotations")),
            }
        end
    end
    return books
end

local SleepQuoteWidget = Widget:extend{
    picture = nil, -- image file path or nil
    quote = nil, -- { text, title } or nil
    battery = nil, -- 0..100 or nil
}

function SleepQuoteWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

local function textWidth(f, s)
    return RenderText:sizeUtf8Text(0, Screen:getWidth() * 2, f, s, true, false).x
end

-- Largest quote size from 3.6% down to 1.8% of the screen height whose quote and title fit band_h.
-- Returns nil when even the smallest does not fit.
local function fitQuote(text, box_w, band_h, title_h, h)
    for px = h * 0.036, h * 0.018, -h * 0.002 do
        local box = TextBoxWidget:new{
            text = "\u{201C}" .. text .. "\u{201D}",
            face = face("NotoSerif-Italic.ttf", px),
            width = box_w,
            alignment = "center",
            line_height = 0.35,
        }
        if box:getSize().h + title_h <= band_h then return box end
        box:free()
    end
end

local function paintPicture(bb, file, x, y, size)
    -- SVGs render sharp at the exact size; raster pictures scale to fit, keeping their aspect.
    local svg = file:lower():match("%.svg$") ~= nil
    local img = ImageWidget:new{
        file = file,
        width = size,
        height = size,
        scale_factor = not svg and 0 or nil,
        file_do_cache = false,
        alpha = true, -- transparent pictures blend onto the white page instead of black
    }
    local sz = img:getSize()
    img:paintTo(bb, x + math.floor((size - sz.w) / 2), y + math.floor((size - sz.h) / 2))
    img:free()
end

function SleepQuoteWidget:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, WHITE)
    self:paintBody(bb, x, y, w, h)
    -- Battery last: the picture's white margins may reach the corner.
    if self.battery then
        local bface = face("NotoSerif-Regular.ttf", h * 0.0235)
        local pct = self.battery .. "%"
        RenderText:renderUtf8Text(bb, x + w - math.floor(w * 0.046) - textWidth(bface, pct),
            y + math.floor(h * 0.043), bface, pct, true, false, GRAY)
    end
end

function SleepQuoteWidget:paintBody(bb, x, y, w, h)

    local margin = math.floor(w * 0.1)
    local box_w = w - 2 * margin
    local tpx = h * 0.0245
    local tface = face("NotoSerif-Regular.ttf", tpx)
    local title_gap = math.floor(tpx * 2.2)
    local title_block = title_gap + math.floor(tpx * 1.4)

    local qbox, pic_size
    if self.quote and self.picture then
        -- Picture nearly full width, smaller only when a long quote needs room.
        local rule_gap = math.floor(h * 0.022)
        for _, frac in ipairs({ 0.92, 0.8, 0.684, 0.56, 0.44 }) do
            pic_size = math.floor(w * frac)
            local band_h = h - math.floor(h * 0.03) - pic_size - 2 * rule_gap - math.floor(h * 0.06)
            qbox = fitQuote(self.quote.text, box_w, band_h, title_block, h)
            if qbox then break end
        end
        if not qbox then
            self.picture = nil
        else
            local top = y + math.floor(h * 0.03)
            paintPicture(bb, self.picture, x + math.floor((w - pic_size) / 2), top, pic_size)
            local rule_y = top + pic_size + rule_gap
            local rule_w = math.floor(w * 0.2)
            bb:paintRect(x + math.floor((w - rule_w) / 2), rule_y, rule_w, math.max(1, math.floor(h / 936)), BLACK)
            local band_top = rule_y + rule_gap
            local band_h = y + h - math.floor(h * 0.06) - band_top
            self:paintQuote(bb, x, band_top, band_h, qbox, tface, tpx, title_gap, box_w)
            return
        end
    end

    if self.picture then
        local size = w
        paintPicture(bb, self.picture, x + math.floor((w - size) / 2), y + math.floor((h - size) / 2), size)
        return
    end

    if self.quote then
        local band_top, band_h = math.floor(h * 0.1), math.floor(h * 0.8)
        qbox = fitQuote(self.quote.text, box_w, band_h, title_block, h)
            or fitQuote(Logic.clean(self.quote.text:sub(1, 200)), box_w, band_h, title_block, h)
        if qbox then self:paintQuote(bb, x, y + band_top, band_h, qbox, tface, tpx, title_gap, box_w) end
    end
end

-- Quote and title centred together in the band; frees qbox.
function SleepQuoteWidget:paintQuote(bb, x, band_top, band_h, qbox, tface, tpx, title_gap, box_w)
    local w = self.dimen.w
    local qh = qbox:getSize().h
    local top = band_top + math.floor((band_h - qh - title_gap - tpx * 1.4) / 2)
    qbox:paintTo(bb, x + math.floor((w - box_w) / 2), top)
    qbox:free()

    local title = self.quote.title
    while textWidth(tface, title) > box_w and #title > 8 do
        title = title:sub(1, -2):gsub("[\192-\255][\128-\191]*$", "")
    end
    RenderText:renderUtf8Text(bb, x + math.floor((w - textWidth(tface, title)) / 2),
        math.floor(top + qh + title_gap + tpx * 0.36), tface, title, true, false, GRAY)
end

local SleepQuote = WidgetContainer:extend{
    name = "sleepquote",
    Widget = SleepQuoteWidget, -- for device previews with sample text
}

local function pictureFile()
    local file = G_reader_settings:readSetting(PICTURE_FILE_KEY)
    if file and lfs.attributes(file, "mode") == "file" then return file end
    return DIR .. "eye.png"
end

function SleepQuote.buildWidget()
    local entry
    if G_reader_settings:nilOrTrue(HIGHLIGHT_KEY) then
        local state = G_reader_settings:readSetting(BALANCE_KEY) or {}
        entry = Logic.pick(collectBooks(), state)
        if entry then G_reader_settings:saveSetting(BALANCE_KEY, state) end
    end
    local powerd = G_reader_settings:nilOrTrue(BATTERY_KEY) and Device:hasBattery() and Device:getPowerDevice()
    return SleepQuoteWidget:new{
        picture = G_reader_settings:nilOrTrue(PICTURE_KEY) and pictureFile() or nil,
        quote = entry and { text = entry.text, title = entry.title },
        battery = powerd and powerd:getCapacity() or nil,
    }
end

local function showSleepQuote(self)
    local ok, widget = pcall(SleepQuote.buildWidget)
    if not ok then
        logger.warn("sleepquote: build failed, using the default sleep screen:", widget)
        return false
    end

    Device.screen_saver_mode = true
    local with_gesture_lock = Device:isTouchDevice() and G_reader_settings:readSetting("screensaver_delay") == "gesture"
    local orig_dimen
    Device.orig_rotation_mode = nil
    local rotation_mode = Screen:getRotationMode()
    if bit.band(rotation_mode, 1) == 1 then
        Device.orig_rotation_mode = rotation_mode
        orig_dimen = with_gesture_lock and { w = Screen:getWidth(), h = Screen:getHeight() }
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        widget:init()
    end

    UIManager:setIgnoreTouchInput(false)
    if with_gesture_lock then
        self.screensaver_lock_widget = ScreenSaverLockWidget:new{ ui = self.ui, orig_dimen = orig_dimen }
    end
    self.screensaver_widget = ScreenSaverWidget:new{
        widget = widget,
        background = WHITE,
        covers_fullscreen = true,
    }
    self.screensaver_widget.modal = true
    UIManager:show(self.screensaver_widget, "full")
    if self.screensaver_lock_widget then
        UIManager:show(self.screensaver_lock_widget)
    end
    return true
end

-- Wrap once, even across `ink reload`.
if not Screensaver._sleepquote_orig_show then
    Screensaver._sleepquote_orig_show = Screensaver.show
    function Screensaver:show(...)
        local orig = Screensaver._sleepquote_orig_show
        if not self.ui or self.prefix ~= "" or G_reader_settings:isFalse(ENABLED_KEY) then
            return orig(self, ...)
        end
        if showSleepQuote(self) then return end
        return orig(self, ...)
    end
end

function SleepQuote:init()
    G_reader_settings:delSetting("sleepquote_shown") -- memory of the old random picker
    self.ui.menu:registerToMainMenu(self)
end

local PreviewWidget = InputContainer:extend{ name = "SleepQuotePreview" }

function PreviewWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self[1] = SleepQuote.buildWidget()
end

function PreviewWidget:onTap()
    UIManager:close(self, "full")
    return true
end

function PreviewWidget:onShow()
    UIManager:setDirty(self, "full")
end

local IMAGE_SUFFIXES = { png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true, bmp = true }

local function isImage(path)
    local ext = path:match("%.([^./]+)$")
    return ext ~= nil and IMAGE_SUFFIXES[ext:lower()] == true
end

-- Shelf Apps tile: one tap per switch, a picture chooser and a preview of the next sleep screen.
function SleepQuote:open()
    local dialog
    local function mark(key, label)
        return label .. (G_reader_settings:nilOrTrue(key) and "  \u{2713}" or "  \u{2014}")
    end
    local function switch(key, label)
        return {
            text = mark(key, label),
            callback = function()
                G_reader_settings:flipNilOrTrue(key)
                G_reader_settings:flush()
                UIManager:close(dialog)
                self:open()
            end,
        }
    end
    local custom = G_reader_settings:readSetting(PICTURE_FILE_KEY)
    local picture_row = {
        switch(PICTURE_KEY, _("Picture")),
        {
            text = _("Choose\u{2026}"),
            callback = function()
                UIManager:close(dialog)
                local function choose(path)
                    G_reader_settings:saveSetting(PICTURE_FILE_KEY, path)
                    G_reader_settings:makeTrue(PICTURE_KEY)
                    G_reader_settings:flush()
                    self:open()
                end
                UIManager:show(PathChooser:new{
                    title = _("Sleep picture"),
                    -- KOReader's chooser wants a long press on files; a tap picks the picture here.
                    onMenuSelect = function(chooser, item)
                        if lfs.attributes(item.path, "mode") ~= "file" then
                            return PathChooser.onMenuSelect(chooser, item)
                        end
                        UIManager:close(chooser)
                        choose(item.path)
                        return true
                    end,
                    select_directory = false,
                    select_file = true,
                    detailed_file_info = false,
                    file_filter = isImage,
                    path = custom and custom:match("^(.*)/") or G_reader_settings:readSetting("home_dir") or Device.home_dir or "/",
                    onConfirm = choose,
                })
            end,
        },
    }
    if custom then
        picture_row[#picture_row + 1] = {
            text = _("Reset"),
            callback = function()
                G_reader_settings:delSetting(PICTURE_FILE_KEY)
                G_reader_settings:flush()
                UIManager:close(dialog)
                self:open()
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = _("Sleep screen"),
        buttons = {
            { switch(ENABLED_KEY, _("On")), {
                text = _("Preview"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(PreviewWidget:new{})
                end,
            } },
            picture_row,
            { switch(HIGHLIGHT_KEY, _("Highlight")), switch(BATTERY_KEY, _("Battery")) },
        },
    }
    UIManager:show(dialog)
end

function SleepQuote:addToMainMenu(menu_items)
    menu_items.sleepquote = {
        text = _("Sleep screen"),
        sorting_hint = "screen",
        checked_func = function() return G_reader_settings:nilOrTrue(ENABLED_KEY) end,
        callback = function() G_reader_settings:flipNilOrTrue(ENABLED_KEY) end,
    }
end

return SleepQuote
