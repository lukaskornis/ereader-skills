--[[--
Full-screen library page: header (title, clock, view icons, sort, Wi-Fi, light, battery; the last three open popups),
current-book strip, a page of books, page count, footer (search, folder, library, apps, settings).
The apps icon swaps the books for a grid of tools (Writer, Wi-Fi, Send).
Send shows a bookdrop.cc code and saves whatever arrives on it to Books.

Layout is in mock units: the approved mock is 300 px wide, so one unit is
screen_width / 300 px. Kobo and Kindle are both 3:4, so the same numbers fit both.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local DocSettings = require("docsettings")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ProgressWidget = require("ui/widget/progresswidget")
local RenderImage = require("ui/renderimage")
local RightContainer = require("ui/widget/container/rightcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Bookdrop = require("bookdrop")
local Clock = require("clock")
local Library = require("library")
local Power = require("power")
local Profile = require("profile")
local logger = require("logger")
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY
local GREY = Blitbuffer.COLOR_DARK_GRAY
local SERIF = "NotoSerif-Regular.ttf"
local SERIF_BOLD = "NotoSerif-Bold.ttf"
local SEND_POLL_SECONDS = 5
local SEND_RATE_LIMIT_SECONDS = 60
local STRETCH_LIMIT_PERCENT = 10
local MAX_SCALED_COVERS = 64
-- Same edge strip as KOReader's DSWIPE_ZONE_LEFT_EDGE / RIGHT_EDGE.
local EDGE_RATIO = 1 / 8
local LEVEL_SECONDS = 1.5

-- Scaled covers outlive the widget: the file manager, and the shelf with it, is rebuilt after every book.
-- Scaling was most of the shelf's paint time (about 140 ms a page).
-- The last bookdrop key outlives the widget, so reopening Send keeps its code (the server allows 3 live keys per IP).
local send_key = nil

local scaled_covers = {} -- "path|w|h" -> { bb, used }
local cover_uses = 0

local function evictScaledCovers()
    local count, oldest_key, oldest_use = 0, nil, math.huge
    for key, entry in pairs(scaled_covers) do
        count = count + 1
        if entry.used < oldest_use then oldest_key, oldest_use = key, entry.used end
    end
    if count <= MAX_SCALED_COVERS then return end
    scaled_covers[oldest_key].bb:free()
    scaled_covers[oldest_key] = nil
end

-- Same rule as ImageWidget's stretch_limit_percentage: stretch when close to the frame's shape, else fit.
local function scaleCover(bb, w, h)
    local bb_w, bb_h = bb:getWidth(), bb:getHeight()
    local divergence = math.abs(100 - (bb_w / bb_h) / (w / h) * 100)
    if divergence > STRETCH_LIMIT_PERCENT then
        local factor = math.min(w / bb_w, h / bb_h)
        w, h = math.floor(bb_w * factor), math.floor(bb_h * factor)
    end
    local scaled = RenderImage:scaleBlitBuffer(bb, w, h, false)
    -- Stored in the screen's format and dithered once, so painting is a plain copy (see is_icon below).
    local screen_bb = Blitbuffer.new(w, h, Screen.bb:getType())
    if Screen.sw_dithering then
        screen_bb:ditherblitFrom(scaled, 0, 0, 0, 0, w, h)
    else
        screen_bb:blitFrom(scaled, 0, 0, 0, 0, w, h)
    end
    if scaled ~= bb then scaled:free() end
    return screen_bb
end

local ShelfWidget = InputContainer:extend{
    name = "shelf",
    covers_fullscreen = true,
    library = nil, -- Library instance
    extract_missing = nil, -- called after a reload that found books without metadata
    ui = nil, -- FileManager
    plugin_path = nil,
}

function ShelfWidget:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.u = self.width / 300
    self.font_scale = Screen:scaleBySize(1000) / 1000
    self.line_w = math.max(1, math.floor(self.u * 0.5))
    self.view = G_reader_settings:readSetting("shelf_view") or "covers"
    self.sort_mode = G_reader_settings:readSetting("shelf_sort") or "read"
    self.page = 1
    self.show_apps = false
    self.show_send = false
    self.send_tick = function() self:sendTick() end
    self.clock_tick = function() self:clockTick() end
    self.level_hide = function() self:hideLevel() end
    self.covers = {}
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self:reload()
end

function ShelfWidget:px(units)
    return math.floor(units * self.u + 0.5)
end

function ShelfWidget:face(units, font)
    return Font:getFace(font or SERIF, units * self.u / self.font_scale)
end

function ShelfWidget:icon(name, units)
    local size = self:px(units)
    return IconWidget:new{
        file = self.plugin_path .. "/icons/shelf." .. name .. ".svg",
        width = size,
        height = size,
        -- The white ".on" icons sit on black; without alpha their transparent parts paint white.
        alpha = true,
    }
end

function ShelfWidget:reload()
    for path, bb in pairs(self.covers) do
        if not bb then self.covers[path] = nil end
    end
    self.books = self.library:collect(self.root)
    Library.sort(self.books, self.sort_mode)
    local last = G_reader_settings:readSetting("lastfile")
    self.current = nil
    self.time_left = nil
    self.list = {}
    for _, book in ipairs(self.books) do
        if book.path == last then
            self.current = book
            self.time_left = Library.timeLeft(book.path, Library.progress(book.path))
        else
            table.insert(self.list, book)
        end
    end
    self:rebuild()
end

-- Tappable regions are FrameContainers; their dimen gets its screen position when painted.
function ShelfWidget:tappable(widget, callback, opts)
    opts = opts or {}
    local frame = FrameContainer:new{
        padding = 0,
        bordersize = opts.bordersize or 0,
        background = opts.background,
        color = BLACK,
        widget,
    }
    table.insert(self.hits, { frame = frame, callback = callback, book = opts.book })
    return frame
end

function ShelfWidget:hline(color)
    return LineWidget:new{
        background = color or BLACK,
        dimen = Geom:new{ w = self.width, h = self.line_w },
    }
end

local VIEWS = { { "covers", "layout-grid" }, { "tiles", "grid-dots" }, { "names", "list" } }

function ShelfWidget:cycleView()
    for i, v in ipairs(VIEWS) do
        if v[1] == self.view then
            self:setView(VIEWS[i % #VIEWS + 1][1])
            return
        end
    end
    self:setView(VIEWS[1][1])
end

function ShelfWidget:headerButton(widget, callback, on)
    return self:tappable(
        FrameContainer:new{ padding = self:px(1), padding_left = self:px(2), padding_right = self:px(2),
            bordersize = 0, background = on and BLACK or nil, widget },
        callback)
end

local function batteryIcon(capacity, charging)
    if charging then return "battery-charging" end
    if capacity >= 88 then return "battery-4" end
    if capacity >= 63 then return "battery-3" end
    if capacity >= 38 then return "battery-2" end
    if capacity >= 13 then return "battery-1" end
    return "battery"
end

-- Sort, Wi-Fi, light and battery; each opens its popup (sort flips).
function ShelfWidget:buildStatus()
    local group = HorizontalGroup:new{ align = "center" }
    local gap = self:px(1)
    local function add(widget)
        if #group > 0 then table.insert(group, HorizontalSpan:new{ width = gap }) end
        table.insert(group, widget)
    end
    if not (self.show_apps or self.show_send) then
        add(self:headerButton(self:icon(self.sort_mode == "new" and "sparkles" or "history", 14),
            function() self:setSort(self.sort_mode == "new" and "read" or "new") end))
    end
    add(self:headerButton(self:icon(NetworkMgr:isWifiOn() and "wifi" or "wifi-off", 14),
        function() self:togglePopup("wifi") end))
    if Device:hasFrontlight() then
        add(self:headerButton(self:icon("sun", 14), function() self:togglePopup("light") end))
    end
    local pd = Device:getPowerDevice()
    local capacity = pd:getCapacity()
    local battery = HorizontalGroup:new{ align = "center",
        self:icon(batteryIcon(capacity, pd:isCharging()), 14),
        HorizontalSpan:new{ width = self:px(1) },
        TextWidget:new{ text = capacity .. "%", face = self:face(10) },
    }
    if Power.saving() then
        table.insert(battery, HorizontalSpan:new{ width = self:px(1) })
        table.insert(battery, self:icon("leaf", 10))
    end
    add(self:headerButton(battery, function() self:togglePopup("battery") end))
    return group
end

function ShelfWidget:buildHeader()
    local h = self:px(31)
    local pad = self:px(10)
    local right = HorizontalGroup:new{ align = "center" }
    if not (self.show_apps or self.show_send) then
        -- One icon for the current view; tap cycles covers, tiles, names.
        local view = VIEWS[1]
        for _, v in ipairs(VIEWS) do
            if v[1] == self.view then view = v end
        end
        table.insert(right, self:headerButton(self:icon(view[2], 14), function() self:cycleView() end))
        table.insert(right, HorizontalSpan:new{ width = self:px(1) })
    end
    table.insert(right, self:buildStatus())
    if self.show_send then
        table.insert(right, HorizontalSpan:new{ width = self:px(6) })
        table.insert(right, self:tappable(self:icon("x", 16), function() self:closeSend() end))
    end
    local text = self.show_send and "Send" or self.show_apps and "Apps" or "Library"
    local title_row = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad },
        TextWidget:new{ text = text, face = self:face(15) } }
    if Clock.trusted() then
        table.insert(title_row, HorizontalSpan:new{ width = self:px(6) })
        table.insert(title_row, TextWidget:new{ text = Clock.text(), face = self:face(11), fgcolor = GREY })
    end
    local title = LeftContainer:new{ dimen = Geom:new{ w = self.width, h = h }, title_row }
    self.header_spare = self.width - 2 * pad - title_row:getSize().w - right:getSize().w
    return OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = h },
        title,
        RightContainer:new{ dimen = Geom:new{ w = self.width, h = h },
            HorizontalGroup:new{ right, HorizontalSpan:new{ width = pad } } },
    }
end

-- Popups: a bordered box under the header's right edge. Rows are split by thin grey lines.
local POPUP_W = 170
local ROW_H = 24

function ShelfWidget:switch(on)
    local w, h, knob = self:px(24), self:px(13), self:px(9)
    local inset = math.floor((h - 2 * self.line_w - knob) / 2)
    local dot = FrameContainer:new{ padding = 0, bordersize = 0, radius = math.floor(knob / 2),
        background = on and WHITE or BLACK,
        CenterContainer:new{ dimen = Geom:new{ w = knob, h = knob }, HorizontalSpan:new{ width = 0 } } }
    local place = on and RightContainer or LeftContainer
    return FrameContainer:new{ padding = 0, bordersize = self.line_w, color = BLACK, radius = math.floor(h / 2),
        background = on and BLACK or WHITE,
        place:new{ dimen = Geom:new{ w = w - 2 * self.line_w, h = h - 2 * self.line_w },
            HorizontalGroup:new{ HorizontalSpan:new{ width = on and 0 or inset }, dot,
                HorizontalSpan:new{ width = on and inset or 0 } } } }
end

-- label left, widget right, one popup row tall.
function ShelfWidget:popupRow(label, widget, callback, label_color)
    local inner_w = self:px(POPUP_W) - 2 * self:px(8)
    local row = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = self:px(ROW_H) },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = self:px(ROW_H) },
            TextWidget:new{ text = label, face = self:face(label_color and 10 or 11), fgcolor = label_color or BLACK,
                max_width = inner_w - (widget and widget:getSize().w + self:px(6) or 0) } },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = self:px(ROW_H) },
            widget or HorizontalSpan:new{ width = 0 } },
    }
    row = HorizontalGroup:new{ HorizontalSpan:new{ width = self:px(8) }, row, HorizontalSpan:new{ width = self:px(8) } }
    if callback then return self:tappable(row, callback) end
    return row
end

function ShelfWidget:popupLine()
    return LineWidget:new{ background = LIGHT,
        dimen = Geom:new{ w = self:px(POPUP_W) - 2 * self.line_w, h = self.line_w } }
end

-- A bar that sets value 0..1 from where it is tapped; the frame's padding widens the target.
function ShelfWidget:slider(icon, percent, callback)
    local bar_w = self:px(POPUP_W - 16 - 20)
    local bar = self:bar(bar_w, self:px(6), percent)
    local target = self:tappable(FrameContainer:new{ padding = 0, padding_top = self:px(8),
        padding_bottom = self:px(8), bordersize = 0, bar },
        function(ges, frame)
            local value = (ges.pos.x - frame.dimen.x) / frame.dimen.w
            callback(math.min(1, math.max(0, value)))
        end)
    return HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = self:px(8) },
        self:icon(icon, 12), HorizontalSpan:new{ width = self:px(8) }, target }
end

function ShelfWidget:segment(options, current, callback)
    local seg = HorizontalGroup:new{}
    for _, o in ipairs(options) do
        local on = current == o[1]
        table.insert(seg, self:tappable(
            FrameContainer:new{ padding = 0, padding_left = self:px(5), padding_right = self:px(5),
                padding_top = self:px(1), padding_bottom = self:px(1),
                bordersize = 0, background = on and BLACK or nil,
                TextWidget:new{ text = o[2], face = self:face(10), fgcolor = on and WHITE or BLACK } },
            function() callback(o[1]) end))
    end
    return FrameContainer:new{ padding = 0, bordersize = self.line_w, color = BLACK, seg }
end

local function clockText(minutes)
    return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

function ShelfWidget:pickTime(minutes, title, callback)
    local DateTimeWidget = require("ui/widget/datetimewidget")
    UIManager:show(DateTimeWidget:new{
        hour = math.floor(minutes / 60), min = minutes % 60,
        title_text = title, ok_text = "Set",
        callback = function(time) callback(time.hour * 60 + time.min) end,
    })
end

function ShelfWidget:buildLightPopup(rows)
    local pd = Device:getPowerDevice()
    table.insert(rows, self:slider("sun", Power.brightness() / pd.fl_max, function(v)
        Power.setBrightness(math.floor(v * pd.fl_max + 0.5))
        self:refreshPopup()
    end))
    if Device:hasNaturalLight() then
        table.insert(rows, self:popupLine())
        table.insert(rows, self:slider("temperature", pd:frontlightWarmth() / 100, function(v)
            pd:setWarmth(math.floor(v * 100 + 0.5))
            self:refreshPopup()
        end))
    end
    table.insert(rows, self:popupLine())
    local modes = { { "off", "Off" }, { "schedule", "Schedule" } }
    if Power.hasSensor() then table.insert(modes, { "sensor", "Sensor" }) end
    local mode = Power.autoMode()
    table.insert(rows, self:popupRow("Auto", self:segment(modes, mode, function(m) Power.setAutoMode(m) end)))
    if mode == "schedule" then
        local from, to = Power.schedule()
        table.insert(rows, self:popupLine())
        local times = HorizontalGroup:new{ align = "center",
            self:tappable(TextWidget:new{ text = clockText(from), face = self:face(11) }, function()
                self:pickTime(from, "Light on at", function(m) Power.setSchedule(m, to) self:refreshPopup() end)
            end),
            TextWidget:new{ text = "  –  ", face = self:face(11) },
            self:tappable(TextWidget:new{ text = clockText(to), face = self:face(11) }, function()
                self:pickTime(to, "Light off at", function(m) Power.setSchedule(from, m) self:refreshPopup() end)
            end),
        }
        table.insert(rows, self:popupRow("On", times))
    end
end

function ShelfWidget:buildWifiPopup(rows)
    local on = NetworkMgr:isWifiOn()
    table.insert(rows, self:popupRow("Wi-Fi", self:switch(on), function() self:toggleWifi() end))
    if on then
        table.insert(rows, self:popupLine())
        local name = NetworkMgr:isConnected() and self.wifi_ssid or "Not connected"
        table.insert(rows, self:popupRow(name or "Connected", nil, nil, GREY))
    end
    table.insert(rows, self:popupLine())
    table.insert(rows, self:popupRow("Networks", self:icon("chevron-right", 12), function() self:showNetworks() end))
end

function ShelfWidget:buildBatteryPopup(rows)
    table.insert(rows, self:popupRow("Power save", self:switch(Power.saving()),
        function() Power.setSaving(not Power.saving()) end))
    table.insert(rows, self:popupLine())
    table.insert(rows, self:popupRow(Device:hasFrontlight() and "Wi-Fi and light off, slower CPU" or "Wi-Fi off, slower CPU", nil, nil, GREY))
end

function ShelfWidget:buildPopup()
    local rows = VerticalGroup:new{ align = "left" }
    if self.popup == "light" then
        self:buildLightPopup(rows)
    elseif self.popup == "wifi" then
        self:buildWifiPopup(rows)
    else
        self:buildBatteryPopup(rows)
    end
    local box = FrameContainer:new{ padding = 0, bordersize = self.line_w, color = BLACK, background = WHITE,
        rows }
    box.overlap_offset = { self.width - self:px(10) - box:getSize().w, self.header_h - self.line_w }
    return box
end

function ShelfWidget:togglePopup(name)
    if name == "wifi" and self.popup ~= "wifi" then self:readNetworkName() end
    self.popup = self.popup ~= name and name or nil
    self:refreshPopup()
end

function ShelfWidget:readNetworkName()
    self.wifi_ssid = nil
    if not (NetworkMgr:isWifiOn() and NetworkMgr:isConnected()) then return end
    local network = NetworkMgr:getCurrentNetwork()
    self.wifi_ssid = network and network.ssid
end

local function popupBottom(box)
    if not box then return 0 end
    return box.overlap_offset[2] + box:getSize().h
end

-- Only the header and the old or new popup's area are refreshed, so the covers below are not redrawn on the panel.
function ShelfWidget:refreshPopup()
    local old_bottom = popupBottom(self.popup_box)
    self:rebuild()
    local h = math.max(old_bottom, popupBottom(self.popup_box), self.header_h)
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.width, h = h })
end

function ShelfWidget:showNetworks()
    self.popup = nil
    self:refresh()
    local done = function() self:readNetworkName() self:refresh() end
    if NetworkMgr:isWifiOn() then
        -- With the long-press flag the scan list is shown even when already connected.
        NetworkMgr.wifi_toggle_long_press = true
        NetworkMgr:reconnectOrShowNetworkMenu(done, true)
    else
        NetworkMgr:toggleWifiOn(done, true, true)
    end
end

-- Covers within 10% of the frame's shape are stretched to fill it; others keep their shape, centred.
-- With no cover, a grey frame shows the title at the bottom when label_units is given.
function ShelfWidget:sourceCover(path)
    local bb = self.covers[path]
    if bb == nil then
        bb = self.library:cover(path) or false
        self.covers[path] = bb
    end
    return bb
end

--- Drops the cached covers of these books, so the next paint loads their new ones.
function ShelfWidget:forgetCovers(paths)
    for _, path in ipairs(paths) do
        if self.covers[path] then self.covers[path]:free() end
        self.covers[path] = nil
        local prefix = path .. "|"
        for key, entry in pairs(scaled_covers) do
            if key:sub(1, #prefix) == prefix then
                entry.bb:free()
                scaled_covers[key] = nil
            end
        end
    end
end

function ShelfWidget:scaledCover(path, w, h)
    local key = path .. "|" .. w .. "|" .. h
    local entry = scaled_covers[key]
    if not entry then
        local source = self:sourceCover(path)
        if not source then return nil end
        entry = { bb = scaleCover(source, w, h) }
        scaled_covers[key] = entry
    end
    cover_uses = cover_uses + 1
    entry.used = cover_uses
    evictScaledCovers()
    return entry.bb
end

-- Covers within 10% of the frame's shape are stretched to fill it; others keep their shape, centred.
-- With no cover, a grey frame shows the title at the bottom when label_units is given.
function ShelfWidget:coverImage(book, w, h, label_units)
    local inner_w, inner_h = w - 2 * self.line_w, h - 2 * self.line_w
    local bb = self:scaledCover(book.path, inner_w, inner_h)
    if not bb then
        local label = VerticalSpan:new{ width = 0 }
        if label_units then
            local pad = self:px(3)
            label = TextBoxWidget:new{ text = book.title, face = self:face(label_units),
                width = inner_w - 2 * pad, bgcolor = LIGHT, line_height = 0.05 }
            label = FrameContainer:new{ padding = pad, bordersize = 0, label }
        end
        return FrameContainer:new{ padding = 0, bordersize = self.line_w, color = BLACK, background = LIGHT,
            BottomContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, label } }
    end
    local image = FrameContainer:new{ padding = 0, bordersize = self.line_w, color = BLACK,
        -- is_icon skips ImageWidget's per-paint dithering; the cached cover is already dithered.
        ImageWidget:new{ image = bb, image_disposable = false, is_icon = true } }
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, image }
end

function ShelfWidget:bar(width, height, percent)
    return ProgressWidget:new{
        width = width, height = height, percentage = percent or 0,
        margin_h = 0, margin_v = 0, radius = 0, bordersize = 0,
        bgcolor = LIGHT, fillcolor = BLACK,
    }
end

local function percentText(percent)
    return string.format("%d%%", math.floor((percent or 0) * 100 + 0.5))
end

local function timeLeftText(seconds)
    if seconds < 3600 then
        return string.format("%d min left", math.max(1, math.ceil(seconds / 60)))
    end
    return string.format("%d h left", math.floor(seconds / 3600 + 0.5))
end

function ShelfWidget:buildStrip()
    local book = self.current
    if not book then return nil end
    local pad_h, pad_v = self:px(10), self:px(7)
    local cover_w = self:px(34)
    local cover_h = math.floor(cover_w * 1.5)
    local percent = Library.progress(book.path)
    local right = VerticalGroup:new{ align = "right",
        TextWidget:new{ text = percentText(percent), face = self:face(10) } }
    if self.time_left then
        table.insert(right, TextWidget:new{ text = timeLeftText(self.time_left), face = self:face(10) })
    end
    local pct_w = math.max(self:px(26), right:getSize().w)
    local text_w = self.width - 2 * pad_h - cover_w - self:px(8) - pct_w - self:px(8)
    local info = VerticalGroup:new{ align = "left",
        TextWidget:new{ text = book.title, face = self:face(13), max_width = text_w },
        book.author and TextWidget:new{ text = book.author, face = self:face(10), max_width = text_w }
            or VerticalSpan:new{ width = 0 },
        VerticalSpan:new{ width = self:px(3) },
        self:bar(text_w, self:px(4), percent),
    }
    local row = HorizontalGroup:new{ align = "center",
        HorizontalSpan:new{ width = pad_h },
        self:coverImage(book, cover_w, cover_h),
        HorizontalSpan:new{ width = self:px(8) },
        info,
        HorizontalSpan:new{ width = self:px(8) },
        RightContainer:new{ dimen = Geom:new{ w = pct_w, h = cover_h }, right },
    }
    return self:tappable(
        VerticalGroup:new{ VerticalSpan:new{ width = pad_v }, row, VerticalSpan:new{ width = pad_v } },
        function() self:openBook(book) end, { book = book })
end

function ShelfWidget:rowLabel(book)
    if book.author then return book.author .. " — " .. book.title end
    return book.title
end

function ShelfWidget:buildNames(body_h)
    local row_h = self:px(24.5)
    local per_page = math.max(1, math.floor(body_h / row_h))
    self:setPaging(per_page)
    local pad = self:px(10)
    local mark_w = self:px(26)
    local text_w = self.width - 2 * pad - mark_w - self:px(8)
    local group = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * per_page
    for i = first + 1, math.min(first + per_page, #self.list) do
        local book = self.list[i]
        local percent, finished = Library.progress(book.path)
        local mark
        if finished then
            mark = self:icon("check", 10)
        elseif percent then
            mark = TextWidget:new{ text = percentText(percent), face = self:face(10) }
        end
        local line = HorizontalGroup:new{ align = "center",
            HorizontalSpan:new{ width = pad },
            LeftContainer:new{ dimen = Geom:new{ w = text_w, h = row_h - self.line_w },
                TextWidget:new{ text = self:rowLabel(book), face = self:face(12), max_width = text_w } },
            HorizontalSpan:new{ width = self:px(8) },
            RightContainer:new{ dimen = Geom:new{ w = mark_w, h = row_h - self.line_w },
                mark or HorizontalSpan:new{ width = 0 } },
        }
        table.insert(group, self:tappable(line, function() self:openBook(book) end, { book = book }))
        table.insert(group, self:hline(LIGHT))
    end
    return group
end

function ShelfWidget:buildHero()
    local book = self.current
    if not book then return nil end
    local pad_h, pad_v, gap = self:px(10), self:px(8), self:px(12)
    local cover_w = math.floor((self.width - 2 * pad_h) * 0.25)
    local cover_h = math.floor(cover_w * 1.5)
    local text_w = self.width - 2 * pad_h - cover_w - gap
    local percent = Library.progress(book.path)
    local status = percentText(percent)
    if self.time_left then status = status .. " · " .. timeLeftText(self.time_left) end
    local info = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{ text = book.title, face = self:face(16), width = text_w, line_height = 0.1,
            height = 3 * self:px(18), height_adjust = true, height_overflow_show_ellipsis = true },
        book.author and TextWidget:new{ text = book.author, face = self:face(11), max_width = text_w }
            or VerticalSpan:new{ width = 0 },
        VerticalSpan:new{ width = self:px(6) },
        self:bar(text_w, self:px(5), percent),
        VerticalSpan:new{ width = self:px(4) },
        TextWidget:new{ text = status, face = self:face(11) },
    }
    local row = HorizontalGroup:new{ align = "center",
        HorizontalSpan:new{ width = pad_h },
        self:coverImage(book, cover_w, cover_h, 12),
        HorizontalSpan:new{ width = gap },
        info,
    }
    return self:tappable(
        VerticalGroup:new{ VerticalSpan:new{ width = pad_v }, row, VerticalSpan:new{ width = pad_v } },
        function() self:openBook(book) end, { book = book })
end

-- Grid of 2:3 covers; as many rows as fit. label_units nil means no title on blank covers.
function ShelfWidget:buildGrid(body_h, cols, gap_h, gap_v, top_gap, label_units)
    local pad = self:px(10)
    local line_h, line_gap = self:px(3), self:px(3)
    local cover_w = math.floor((self.width - 2 * pad - (cols - 1) * gap_h) / cols)
    local cover_h = math.floor(cover_w * 1.5)
    local cell_h = cover_h + line_gap + line_h
    local rows = math.max(1, math.floor((body_h - top_gap + gap_v) / (cell_h + gap_v)))
    local per_page = rows * cols
    self:setPaging(per_page)
    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * per_page
    for r = 0, rows - 1 do
        local row = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = pad } }
        for c = 1, cols do
            local book = self.list[first + r * cols + c]
            if not book then break end
            local percent, finished = Library.progress(book.path)
            local under = VerticalSpan:new{ width = line_h }
            if percent and percent > 0 and not finished then
                under = self:bar(cover_w, line_h, percent)
            end
            local cell = VerticalGroup:new{ align = "left",
                self:coverImage(book, cover_w, cover_h, label_units),
                VerticalSpan:new{ width = line_gap },
                under,
            }
            if c > 1 then table.insert(row, HorizontalSpan:new{ width = gap_h }) end
            table.insert(row, self:tappable(cell, function() self:openBook(book) end, { book = book }))
        end
        if #row == 1 then break end
        if r > 0 then table.insert(grid, VerticalSpan:new{ width = gap_v }) end
        table.insert(grid, row)
    end
    table.insert(grid, 1, VerticalSpan:new{ width = top_gap })
    return grid
end

-- 4 across with titles on blank covers; 2 rows under the hero, 3 without it.
function ShelfWidget:buildCovers(body_h)
    -- The hero brings its own bottom padding; without it the grid needs a top gap.
    local top_gap = self.current and 0 or self:px(8)
    return self:buildGrid(body_h, 4, self:px(8), self:px(6), top_gap, 8)
end

-- 5 across, no text; 3 rows under the strip (tighter gaps since the page count took 9 units).
function ShelfWidget:buildTiles(body_h)
    return self:buildGrid(body_h, 5, self:px(6), self:px(5), self:px(6), nil)
end

function ShelfWidget:setPaging(per_page)
    self.page_count = math.max(1, math.ceil(#self.list / per_page))
    self.page = math.min(math.max(1, self.page), self.page_count)
end

function ShelfWidget:buildFooter()
    local h = self:px(27)
    local pad = self:px(12)
    local items = {
        self:tappable(self:icon("search", 16), function() self:showSearch() end),
        self:tappable(self:icon("folder", 16), function() self:showFolders() end),
        self:tappable(self:footerIcon("books", not self.show_apps), function() self:showLibrary() end),
        self:tappable(self:footerIcon("apps", self.show_apps), function() self:showApps() end),
        self:tappable(self:icon("settings", 16), function() self:showSettings() end),
    }
    local used = 0
    for _, w in ipairs(items) do used = used + w:getSize().w end
    local gap = math.floor((self.width - 2 * pad - used) / (#items - 1))
    local row = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad } }
    for i, w in ipairs(items) do
        table.insert(row, w)
        if i < #items then table.insert(row, HorizontalSpan:new{ width = gap }) end
    end
    return LeftContainer:new{ dimen = Geom:new{ w = self.width, h = h }, row }
end

function ShelfWidget:footerIcon(name, on)
    return FrameContainer:new{ padding = self:px(1), padding_left = self:px(3), padding_right = self:px(3),
        bordersize = 0, background = on and BLACK or nil,
        self:icon(on and name .. ".on" or name, 16) }
end

function ShelfWidget:appTile(size, icon, label, callback)
    return self:tappable(CenterContainer:new{
        dimen = Geom:new{ w = size - 2 * self.line_w, h = size - 2 * self.line_w },
        VerticalGroup:new{ align = "center",
            self:icon(icon, 30),
            VerticalSpan:new{ width = self:px(4) },
            TextWidget:new{ text = label, face = self:face(11) },
        },
    }, callback, { bordersize = self.line_w })
end

function ShelfWidget:buildApps()
    local pad = self:px(10)
    local gap = self:px(8)
    local size = math.floor((self.width - 2 * pad - 3 * gap) / 4)
    local row = HorizontalGroup:new{ HorizontalSpan:new{ width = pad } }
    if self.ui.typewriter then
        table.insert(row, self:appTile(size, "typography", "Writer", function() self.ui.typewriter:open() end))
        table.insert(row, HorizontalSpan:new{ width = gap })
    end
    if self.ui.minesweeper then
        table.insert(row, self:appTile(size, "bomb", "Mines", function() self.ui.minesweeper:open() end))
        table.insert(row, HorizontalSpan:new{ width = gap })
    end
    table.insert(row, self:appTile(size, NetworkMgr:isWifiOn() and "wifi" or "wifi-off", "Wi-Fi",
        function() self:toggleWifi() end))
    table.insert(row, HorizontalSpan:new{ width = gap })
    table.insert(row, self:appTile(size, "book-download", "Send", function() self:openSend() end))
    table.insert(row, HorizontalSpan:new{ width = gap })
    table.insert(row, self:appTile(size, "history", "History", function() self:showHistory() end))
    return VerticalGroup:new{ align = "left", VerticalSpan:new{ width = self:px(12) }, row }
end

local function sizeText(bytes)
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5)))
end

function ShelfWidget:buildCodeBoxes()
    local key = self.send.key or "    "
    local row = HorizontalGroup:new{}
    for i = 1, 4 do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = self:px(6.4) }) end
        table.insert(row, FrameContainer:new{ padding = 0, bordersize = self:px(1.6), color = BLACK,
            CenterContainer:new{ dimen = Geom:new{ w = self:px(43), h = self:px(56) },
                TextWidget:new{ text = key:sub(i, i), face = self:face(37, SERIF_BOLD) } } })
    end
    return row
end

-- The book just received: cover, title, author and size, and an Open button.
function ShelfWidget:buildReceived()
    local got = self.send.got
    local book
    for _, b in ipairs(self.books) do
        if b.path == got.path then book = b break end
    end
    local pad, gap = self:px(8), self:px(10)
    local card_w = self:px(240)
    local open = FrameContainer:new{ padding = 0, padding_left = self:px(13), padding_right = self:px(13),
        padding_top = self:px(5), padding_bottom = self:px(5), bordersize = 0, background = BLACK,
        TextWidget:new{ text = "Open", face = self:face(13), fgcolor = WHITE } }
    local cover_w = self:px(37)
    local text_w = card_w - 2 * pad - 2 * self.line_w - cover_w - 2 * gap - open:getSize().w
    local title = book and book.title or got.path:match("[^/]*$")
    local sub = sizeText(got.size)
    if book and book.author then sub = book.author .. " · " .. sub end
    local row = HorizontalGroup:new{ align = "center",
        book and self:coverImage(book, cover_w, math.floor(cover_w * 1.5)) or HorizontalSpan:new{ width = cover_w },
        HorizontalSpan:new{ width = gap },
        VerticalGroup:new{ align = "left",
            TextBoxWidget:new{ text = title, face = self:face(13), width = text_w,
                height = 2 * self:px(18), height_adjust = true, height_overflow_show_ellipsis = true },
            VerticalSpan:new{ width = self:px(2) },
            TextWidget:new{ text = sub, face = self:face(9.6), fgcolor = GREY, max_width = text_w },
        },
        HorizontalSpan:new{ width = gap },
        open,
    }
    local card = FrameContainer:new{ padding = pad, bordersize = self.line_w, color = BLACK, row }
    if not book then return card end
    return self:tappable(card, function() self:openBook(book) end, { book = book })
end

-- bookdrop.cc, the hint, the code, a status line and, once something arrived, its card.
function ShelfWidget:buildSend()
    local send = self.send
    local group = VerticalGroup:new{ align = "center",
        VerticalSpan:new{ width = self:px(21) },
        TextWidget:new{ text = Bookdrop.host, face = self:face(24) },
        VerticalSpan:new{ width = self:px(3) },
        TextBoxWidget:new{ text = "Open it on your phone or computer and type this code", face = self:face(10.4),
            fgcolor = GREY, width = self.width - self:px(20), alignment = "center" },
        VerticalSpan:new{ width = self:px(16) },
        self:buildCodeBoxes(),
        VerticalSpan:new{ width = self:px(18) },
    }
    local status = HorizontalGroup:new{ align = "center" }
    if send.icon then
        table.insert(status, self:icon(send.icon, 12))
        table.insert(status, HorizontalSpan:new{ width = self:px(5) })
    end
    table.insert(status, TextWidget:new{ text = send.status, face = self:face(12),
        max_width = self.width - self:px(40) })
    table.insert(group, status)
    if send.got then
        table.insert(group, VerticalSpan:new{ width = self:px(16) })
        table.insert(group, self:buildReceived())
        table.insert(group, VerticalSpan:new{ width = self:px(18) })
        table.insert(group, TextWidget:new{ text = "Code stays live; send another anytime", face = self:face(10.4),
            fgcolor = GREY })
    end
    return CenterContainer:new{ dimen = Geom:new{ w = self.width, h = group:getSize().h }, group }
end

-- Small, above the footer, only when there is more than one page.
function ShelfWidget:buildPageCount(h)
    local dimen = Geom:new{ w = self.width, h = h }
    if self.show_apps or self.page_count <= 1 then return VerticalSpan:new{ width = h } end
    return CenterContainer:new{ dimen = dimen,
        TextWidget:new{ text = string.format("%d / %d", self.page, self.page_count), face = self:face(9) } }
end

function ShelfWidget:rebuild()
    self.hits = {}
    local header = self:buildHeader()
    local header_hits = self.hits
    self.hits = {}
    self.header_h = header:getSize().h
    self:scheduleClock()
    local covers = self.view == "covers"
    local top = VerticalGroup:new{ align = "left", header, self:hline() }
    if self.show_apps then
        -- No hero or strip.
    elseif covers then
        local hero = self:buildHero()
        if hero then table.insert(top, hero) end
    else
        local strip = self:buildStrip()
        if strip then
            table.insert(top, strip)
            table.insert(top, self:hline())
        end
    end
    local footer_h = self:px(27) + self.line_w
    -- Kept tight: two cover rows under the hero need all but ~2 units of the rest.
    local count_h = self:px(9)
    local body_h = self.height - top:getSize().h - footer_h - count_h
    -- The page count needs the body's paging, so the body is built first.
    local body
    if self.show_send then
        body = self:buildSend()
    elseif self.show_apps then
        body = self:buildApps()
    elseif covers then
        body = self:buildCovers(body_h)
    elseif self.view == "tiles" then
        body = self:buildTiles(body_h)
    else
        body = self:buildNames(body_h)
    end
    local footer = self:buildFooter()
    local page = FrameContainer:new{
        padding = 0, bordersize = 0, background = WHITE,
        dimen = Geom:new{ w = self.width, h = self.height },
        VerticalGroup:new{ align = "left",
            top,
            TopContainer:new{ dimen = Geom:new{ w = self.width, h = body_h }, body },
            self:buildPageCount(count_h),
            self:hline(),
            footer,
        },
    }
    self.popup_box = nil
    self.level_box = nil
    if self.level then
        self.level_box = self:buildLevel()
        page = OverlapGroup:new{ dimen = Geom:new{ w = self.width, h = self.height }, page, self.level_box }
    end
    if not self.popup then
        for _, hit in ipairs(header_hits) do table.insert(self.hits, hit) end
        self[1] = page
        return
    end
    -- While a popup is open only its rows and the header take taps; a tap anywhere else closes it.
    self.hits = {}
    self.popup_box = self:buildPopup()
    for _, hit in ipairs(header_hits) do table.insert(self.hits, hit) end
    self[1] = OverlapGroup:new{ dimen = Geom:new{ w = self.width, h = self.height }, page, self.popup_box }
end

function ShelfWidget:refresh()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

function ShelfWidget:setView(view)
    if view == self.view then return end
    self.view = view
    self.page = 1
    G_reader_settings:saveSetting("shelf_view", view)
    self:refresh()
end

function ShelfWidget:setSort(mode)
    if mode == self.sort_mode then return end
    self.sort_mode = mode
    self.page = 1
    G_reader_settings:saveSetting("shelf_sort", mode)
    Library.sort(self.list, mode)
    self:refresh()
end

function ShelfWidget:onTap(_, ges)
    for _, hit in ipairs(self.hits) do
        local d = hit.frame.dimen
        if d and d.x and ges.pos:intersectWith(d) then
            hit.callback(ges, hit.frame)
            return true
        end
    end
    if self.popup then
        self.popup = nil
        self:refreshPopup()
    end
    return true
end

function ShelfWidget:onHold(_, ges)
    if self.popup then return true end
    for _, hit in ipairs(self.hits) do
        local d = hit.frame.dimen
        if hit.book and d and d.x and ges.pos:intersectWith(d) then
            self:showBookMenu(hit.book)
            return true
        end
    end
    return true
end

function ShelfWidget:showBookMenu(book)
    local dialog
    local function done()
        UIManager:close(dialog)
        self:reload()
        UIManager:setDirty(self, "ui")
    end
    local _, finished = Library.progress(book.path)
    local reset = filemanagerutil.genResetSettingsButton(book.path, done)
    reset.text = "Reset progress"
    local info = filemanagerutil.genBookInformationButton(book.path, nil, function() UIManager:close(dialog) end)
    info.text = "Book info"
    dialog = ButtonDialog:new{
        title = book.title,
        title_align = "center",
        buttons = {
            { { text = "Open", callback = function() UIManager:close(dialog) self:openBook(book) end } },
            { {
                text = finished and "Mark as unread" or "Mark as read",
                callback = function()
                    local status = finished and "reading" or "complete"
                    local settings = DocSettings:open(book.path)
                    local summary = settings:readSetting("summary") or {}
                    summary.status = status
                    filemanagerutil.saveSummary(settings, summary)
                    BookList.setBookInfoCacheProperty(book.path, "status", status)
                    done()
                end,
            } },
            { reset },
            { info },
            { { text = "Send to…", callback = function() UIManager:close(dialog) self:askSendTo(book) end } },
            { {
                text = "Delete",
                callback = function()
                    UIManager:close(dialog)
                    self.ui:showDeleteFileDialog(book.path, function()
                        self:reload()
                        UIManager:setDirty(self, "ui")
                    end)
                end,
            } },
        },
    }
    UIManager:show(dialog)
end

-- The other reader shows the code in its own Send screen; any Wi-Fi works, bookdrop.cc relays.
function ShelfWidget:askSendTo(book)
    local input
    input = InputDialog:new{
        title = "Code on the other reader",
        input_hint = "ABCD",
        buttons = { {
            { text = "Cancel", id = "close", callback = function() UIManager:close(input) end },
            {
                text = "Send",
                is_enter_default = true,
                callback = function()
                    local key = input:getInputText():gsub("%s", ""):upper()
                    if not key:match("^%w%w%w%w$") then
                        UIManager:show(InfoMessage:new{ text = "The code has 4 letters.", timeout = 2 })
                        return
                    end
                    UIManager:close(input)
                    NetworkMgr:runWhenConnected(function() self:sendTo(book, key) end)
                end,
            },
        } },
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

-- The upload blocks, so each progress step is painted before the next chunk goes out.
function ShelfWidget:sendTo(book, key)
    local message
    local function show(text, timeout)
        if message then UIManager:close(message) end
        message = InfoMessage:new{ text = text, timeout = timeout }
        UIManager:show(message)
        UIManager:forceRePaint()
    end
    local shown_tenth = -1
    show("Sending…")
    local ok, err = Bookdrop.upload(key, book.path, function(sent, total)
        local tenth = math.floor(sent * 10 / total)
        if tenth == shown_tenth or tenth >= 10 then return end
        shown_tenth = tenth
        show(string.format("Sending… %d%%", tenth * 10))
    end)
    if ok then
        show("Sent to " .. key, 3)
        return
    end
    logger.warn("shelf: bookdrop upload failed", err)
    local reason = err == "too big" and "Too big, 50 MB at most."
        or (err == 404 or err == 400) and "Code not found. Check the other reader."
        or "Send failed. Check Wi-Fi."
    show(reason, 4)
end

function ShelfWidget:onSwipe(_, ges)
    if self.popup then return true end
    if self:edgeSwipe(ges) then return true end
    if self.show_apps then return true end
    local dir = ges.direction
    if dir == "west" and self.page < self.page_count then
        self.page = self.page + 1
    elseif dir == "east" and self.page > 1 then
        self.page = self.page - 1
    else
        return true
    end
    self:refresh()
    return true
end

-- Up or down along the left edge sets brightness, the right edge warmth, as in the reader's default gestures.
-- Same curve as KOReader's DeviceListener: a full-height swipe moves half the range.
function ShelfWidget:edgeSwipe(ges)
    local dir = ges.direction
    if not (Device:hasFrontlight() and (dir == "north" or dir == "south")) then return false end
    local edge = self.width * EDGE_RATIO
    local left, right = ges.pos.x < edge, ges.pos.x > self.width - edge
    if not (left or right) then return false end
    if right and not Device:hasNaturalLight() then return false end
    local pd = Device:getPowerDevice()
    local max = left and pd.fl_max or 100
    local x = math.min(1, (ges.distance or 1) / (self.height * 0.8))
    local delta = math.ceil(0.5 * max * x * x) * (dir == "north" and 1 or -1)
    if left then
        local value = math.max(0, math.min(max, Power.brightness() + delta))
        Power.setBrightness(value)
        pd:updateResumeFrontlightState()
        self:showLevel("sun", value / max)
    else
        local value = math.max(0, math.min(100, pd:frontlightWarmth() + delta))
        pd:setWarmth(value)
        self:showLevel("temperature", value / 100)
    end
    return true
end

-- A small icon, bar and number under the header for a moment.
function ShelfWidget:showLevel(icon, fraction)
    self.level = { icon = icon, fraction = fraction }
    UIManager:unschedule(self.level_hide)
    UIManager:scheduleIn(LEVEL_SECONDS, self.level_hide)
    self:rebuild()
    local d = self.level_box.dimen_hint
    UIManager:setDirty(self, "ui", d)
end

function ShelfWidget:hideLevel()
    if not self.level then return end
    local d = self.level_box and self.level_box.dimen_hint
    self.level = nil
    self:rebuild()
    UIManager:setDirty(self, "ui", d)
end

function ShelfWidget:buildLevel()
    local level = self.level
    local row = HorizontalGroup:new{ align = "center",
        self:icon(level.icon, 12),
        HorizontalSpan:new{ width = self:px(6) },
        self:bar(self:px(70), self:px(5), level.fraction),
        HorizontalSpan:new{ width = self:px(6) },
        RightContainer:new{ dimen = Geom:new{ w = self:px(16), h = self:px(12) },
            TextWidget:new{ text = tostring(math.floor(level.fraction * 100 + 0.5)), face = self:face(10) } },
    }
    local box = FrameContainer:new{ padding = self:px(5), padding_left = self:px(8), padding_right = self:px(8),
        bordersize = self.line_w, color = BLACK, background = WHITE, radius = self:px(4), row }
    local size = box:getSize()
    local x, y = math.floor((self.width - size.w) / 2), self.header_h + self:px(6)
    box.overlap_offset = { x, y }
    box.dimen_hint = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    return box
end

-- Stays open until the reader replaces the file manager, so the file manager never flashes.
function ShelfWidget:openBook(book)
    -- The reader shows itself with a full flash, which blocks ~0.6 s on the Kobo until the panel finishes; a partial "ui" is enough.
    local ReaderUI = require("apps/reader/readerui")
    local doShowReader = ReaderUI.doShowReader
    ReaderUI.doShowReader = function(...)
        ReaderUI.doShowReader = doShowReader
        doShowReader(...)
        for _, refresh in ipairs(UIManager._refresh_stack) do
            if refresh.mode == "full" then refresh.mode = "ui" end
        end
    end
    self.ui:openFile(book.path)
end

function ShelfWidget:showFolders()
    UIManager:close(self)
end

function ShelfWidget:showSearch()
    self.ui.filesearcher:onShowFileSearch()
end

function ShelfWidget:showHistory()
    self.ui.history:onShowHist()
end

function ShelfWidget:showLibrary()
    if not self.show_apps then return end
    self:stopSend()
    self.show_apps = false
    self:refresh()
end

function ShelfWidget:showApps()
    if self.show_apps and not self.show_send then return end
    self:stopSend()
    self.show_apps = true
    self:refresh()
end

-- Opens with a fresh code; polls only while this screen is open.
function ShelfWidget:openSend()
    self.show_send = true
    self.send = { key = send_key, status = "Connecting…", icon = "refresh", fetched = {} }
    self:refresh()
    -- Turns Wi-Fi on first if it is off.
    NetworkMgr:runWhenConnected(function()
        if self.show_send then self:sendTick() end
    end)
end

function ShelfWidget:stopSend()
    UIManager:unschedule(self.send_tick)
    self.show_send = false
end

function ShelfWidget:closeSend()
    self:stopSend()
    self:refresh()
end

function ShelfWidget:setSendStatus(status, icon)
    if self.send.status == status and self.send.icon == icon then return end
    self.send.status, self.send.icon = status, icon
    self:refresh()
end

-- One poll: get a key if there is none, then fetch every file not seen yet. Reschedules itself.
function ShelfWidget:sendTick()
    UIManager:unschedule(self.send_tick)
    if not self.show_send then return end
    local send = self.send
    if not send.key then
        local key, err = Bookdrop.generate()
        if not key then
            logger.warn("shelf: bookdrop generate failed", err)
            self:setSendStatus(err == 429 and "Too many codes, retrying…" or "No connection, retrying…", "refresh")
            -- Rejected attempts count against the server's limit too, so back off.
            UIManager:scheduleIn(err == 429 and SEND_RATE_LIMIT_SECONDS or SEND_POLL_SECONDS, self.send_tick)
            return
        end
        send.key = key
        send_key = key
        send.fetched = {}
        send.status = nil
        self:setSendStatus(send.got and "Saved to Books" or "Waiting for a book…", send.got and "check" or "refresh")
    end
    local names, err = Bookdrop.files(send.key)
    if not names then
        logger.warn("shelf: bookdrop status failed", err)
        if err == 404 then
            -- Expired; a fresh key replaces it on the next tick.
            send.key = nil
            send_key = nil
            UIManager:nextTick(self.send_tick)
            return
        end
        self:setSendStatus("No connection, retrying…", "refresh")
        UIManager:scheduleIn(SEND_POLL_SECONDS, self.send_tick)
        return
    end
    for _, name in ipairs(names) do
        if not send.fetched[name] then
            send.fetched[name] = true
            self:receive(name)
        end
    end
    if not send.got then self:setSendStatus("Waiting for a book…", "refresh") end
    UIManager:scheduleIn(SEND_POLL_SECONDS, self.send_tick)
end

-- The download blocks, so the status is painted first.
function ShelfWidget:receive(name)
    self:setSendStatus("Downloading…", "book-download")
    UIManager:forceRePaint()
    local path, size = Bookdrop.download(self.send.key, name, Profile.send_dir)
    if not path then
        logger.warn("shelf: bookdrop download failed", name, size)
        self.send.status = nil
        self:setSendStatus("Download failed", nil)
        return
    end
    self.send.got = { path = path, size = size }
    self.send.status, self.send.icon = "Saved to Books", "check"
    self:reload()
    UIManager:setDirty(self, "ui")
    if self.extract_missing then self.extract_missing() end
end

-- The icon follows the network events, so it is also right when Wi-Fi changes elsewhere.
function ShelfWidget:toggleWifi()
    if NetworkMgr:isWifiOn() then
        NetworkMgr:toggleWifiOff()
    else
        NetworkMgr:toggleWifiOn()
    end
end

function ShelfWidget:onNetworkConnected()
    self:readNetworkName()
    self:refresh()
end

function ShelfWidget:onNetworkDisconnected()
    self:refresh()
end

function ShelfWidget:onShelfPowerChanged()
    if Power.saving() and self.show_send then self:stopSend() end
    self:refresh()
end

function ShelfWidget:onCharging()
    self:refresh()
end

function ShelfWidget:onNotCharging()
    self:refresh()
end

-- The light popup's bars follow changes made elsewhere too (auto light, gestures).
function ShelfWidget:onFrontlightStateChanged()
    if self.popup == "light" then self:refreshPopup() end
end

function ShelfWidget:showSettings()
    self.ui.menu:onShowMenu()
end

-- One tick per minute while the shelf is open, for the clock and the battery.
-- The first server check runs once Wi-Fi is up, never in power save.
function ShelfWidget:scheduleClock()
    UIManager:unschedule(self.clock_tick)
    if Clock.needsCheck() and not Power.saving() and NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then
        UIManager:nextTick(function()
            Clock.check()
            if not Clock.trusted() then self:refresh() end
        end)
    end
    UIManager:scheduleIn(Clock.secondsToNextMinute(), self.clock_tick)
end

-- The rebuild schedules the next tick.
function ShelfWidget:clockTick()
    self:rebuild()
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.width, h = self.header_h })
end

function ShelfWidget:onResume()
    self:refresh()
end

function ShelfWidget:onCloseWidget()
    UIManager:unschedule(self.clock_tick)
    UIManager:unschedule(self.level_hide)
    self:stopSend()
    for _, bb in pairs(self.covers) do
        if bb then bb:free() end
    end
    self.covers = {}
end

return ShelfWidget
