--[[
Sleep quote: the sleep screen shows "Last held on <date>", the battery, and one highlight picked
from the current book (else recently read books), never the same one twice in a row.
It wraps Screensaver.show for plain suspends; power-off and reboot screens stay KOReader's own.
]]
local Blitbuffer = require("ffi/blitbuffer")
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
local SHOWN_KEY = "sleepquote_shown"
local MAX_BOOKS = 30
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

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
    quote = nil, -- { text, title } or nil
    date_line = nil,
    battery = nil, -- 0..100 or nil when the device has none
}

function SleepQuoteWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

local function drawBattery(bb, x, cy, h, percent)
    local w, t = math.floor(h * 1.9), math.max(2, math.floor(h / 9))
    local y = math.floor(cy - h / 2)
    bb:paintBorder(x, y, w, h, t, BLACK)
    local nub_h = math.floor(h * 0.4)
    bb:paintRect(x + w, math.floor(cy - nub_h / 2), t + 1, nub_h, BLACK)
    local gap = t * 2
    local inner = w - 2 * gap
    local fill = math.floor(inner * math.max(0, math.min(100, percent)) / 100 + 0.5)
    if fill > 0 then bb:paintRect(x + gap, y + gap, fill, h - 2 * gap, BLACK) end
    return w + t + 1
end

local function textWidth(f, s)
    return RenderText:sizeUtf8Text(0, Screen:getWidth() * 2, f, s, true, false).x
end

function SleepQuoteWidget:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, WHITE)

    -- Header: date, then battery icon and percent, one centred line.
    local hpx = h * 0.021
    local hface = face("NotoSans-Regular.ttf", hpx)
    local cy = y + math.floor(h * 0.07)
    local base = math.floor(cy + hpx * 0.36)
    local gap = math.floor(hpx * 1.4)
    local icon_h = math.floor(hpx * 0.95)
    local pct = self.battery and (self.battery .. "%")
    local total = textWidth(hface, self.date_line)
    if pct then total = total + gap + math.floor(icon_h * 1.9) + math.floor(icon_h / 9) + 1 + math.floor(hpx * 0.35) + textWidth(hface, pct) end
    local cx = x + math.floor((w - total) / 2)
    RenderText:renderUtf8Text(bb, cx, base, hface, self.date_line, true, false, BLACK)
    if pct then
        cx = cx + textWidth(hface, self.date_line) + gap
        cx = cx + drawBattery(bb, cx, cy, icon_h, self.battery) + math.floor(hpx * 0.35)
        RenderText:renderUtf8Text(bb, cx, base, hface, pct, true, false, BLACK)
    end

    if not self.quote then return end

    -- Quote: serif, as large as fits the middle band, title under it.
    local margin = math.floor(w * 0.1)
    local box_w = w - 2 * margin
    local band_top, band_h = math.floor(h * 0.14), math.floor(h * 0.74)
    local tpx = h * 0.019
    local tface = face("NotoSans-Italic.ttf", tpx)
    local title_gap = math.floor(tpx * 2.2)
    local title_h = math.floor(tpx * 1.4)
    local qbox
    for px = h * 0.036, h * 0.018, -h * 0.002 do
        if qbox then qbox:free() end
        qbox = TextBoxWidget:new{
            text = "\u{201C}" .. self.quote.text .. "\u{201D}",
            face = face("NotoSerif-Regular.ttf", px),
            width = box_w,
            alignment = "center",
            line_height = 0.35,
        }
        if qbox:getSize().h + title_gap + title_h <= band_h then break end
    end
    local qh = qbox:getSize().h
    local top = y + band_top + math.floor((band_h - qh - title_gap - title_h) / 2)
    qbox:paintTo(bb, x + margin, top)
    qbox:free()

    local title = "\u{2014} " .. self.quote.title
    while textWidth(tface, title) > box_w and #title > 8 do
        title = title:sub(1, -2):gsub("[\192-\255][\128-\191]*$", "")
    end
    RenderText:renderUtf8Text(bb, x + math.floor((w - textWidth(tface, title)) / 2),
        math.floor(top + qh + title_gap + tpx * 0.36), tface, title, true, false, BLACK)
end

local SleepQuote = WidgetContainer:extend{
    name = "sleepquote",
}

function SleepQuote.buildWidget()
    local shown = G_reader_settings:readSetting(SHOWN_KEY) or {}
    local entry = Logic.pick(collectBooks(), shown, math.random)
    if entry then
        G_reader_settings:saveSetting(SHOWN_KEY, Logic.remember(shown, entry.key))
    end
    local powerd = Device:hasBattery() and Device:getPowerDevice()
    return SleepQuoteWidget:new{
        quote = entry and { text = entry.text, title = entry.title },
        date_line = Logic.dateLine(os.time()),
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
    math.randomseed(os.time())
    self.ui.menu:registerToMainMenu(self)
end

function SleepQuote:addToMainMenu(menu_items)
    menu_items.sleepquote = {
        text = _("Sleep screen: highlight"),
        sorting_hint = "screen",
        checked_func = function() return G_reader_settings:nilOrTrue(ENABLED_KEY) end,
        callback = function() G_reader_settings:flipNilOrTrue(ENABLED_KEY) end,
    }
end

return SleepQuote
