--[[
Typewriter: a full-screen page fed by keystrokes that `ink type` injects as EV_MSC events.
Speed trick: a key never repaints the page. The changed tail of each touched line is drawn straight
into the framebuffer and only that rect is refreshed with A2 (about 145 ms on a glyph, DU about 300). After a short pause the
touched area gets one clean AUTO refresh (DU drops anti-aliasing) and the text is saved.
Append and backspace at the end only. No caret: moving it left A2 smears. Landscape shows two pages side
by side; text turns over a whole page (spread) at a time, never scrolls.
]]
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local lfs = require("libs/libkoreader-lfs")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local time = require("ui/time")
local _ = require("gettext")
local Screen = Device.screen

local MSC_RAW, KEY_MAGIC = 3, 0x54570000 -- "TW" + byte, written by tw-writer.lua
local BACKSPACE, NEWLINE = 8, 10
local FONTS = { sans = "NotoSans-Regular.ttf", serif = "NotoSerif-Regular.ttf" }
local NOTES = "/mnt/onboard/notes"
local OLD_FILE = "/mnt/onboard/typewriter.txt"
local CLEAN_DELAY = 2.5

local function setting(key, default)
    local v = G_reader_settings:readSetting("typewriter_" .. key)
    if v == nil then return default end
    return v
end

local function union(a, x, y, w, h)
    if not a then return Geom:new{ x = x, y = y, w = w, h = h } end
    return a:combine(Geom:new{ x = x, y = y, w = w, h = h })
end

-- Latency samples in ms, key received to refresh submitted; read with `ink eval`.
_G.TW_LAT = _G.TW_LAT or {}

local TypewriterWidget = InputContainer:extend{
    covers_fullscreen = true,
    is_typewriter = true,
}

function TypewriterWidget:init()
    self.rotation_backup = Screen:getRotationMode()
    self:applyRotation()
    self:registerTouchZones({
        { id = "typewriter_tap", ges = "tap",
          screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function() self:showSettings() return true end },
        { id = "typewriter_swipe", ges = "swipe",
          screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges) return self:onSwipe(ges) end },
    })
    if lfs.attributes(NOTES, "mode") ~= "directory" then
        lfs.mkdir(NOTES)
        if lfs.attributes(OLD_FILE, "mode") == "file" then os.rename(OLD_FILE, NOTES .. "/typewriter.txt") end
    end
    self.utf8 = nil
    self:load(setting("file", NOTES .. "/typewriter.txt"))
end

function TypewriterWidget:load(path)
    self.path = path
    G_reader_settings:saveSetting("typewriter_file", path)
    self.chars = {}
    local f = io.open(path, "r")
    if f then
        local text = f:read("*a")
        f:close()
        for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            self.chars[#self.chars + 1] = c
        end
    end
    self.changed = false
    self:applySettings()
end

function TypewriterWidget:open(path)
    self:save()
    self:load(path)
    UIManager:setDirty(self, "ui")
end

function TypewriterWidget:newNote()
    local base = NOTES .. "/" .. os.date("%Y-%m-%d %H-%M")
    local path, n = base .. ".txt", 2
    while lfs.attributes(path, "mode") do path, n = base .. " " .. n .. ".txt", n + 1 end
    self:open(path)
end

function TypewriterWidget:saveAs()
    local dlg
    dlg = InputDialog:new{
        title = _("Save as"),
        input = self.path:match("([^/]+)%.txt$"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dlg:getInputText():gsub("[/\\]", "-")
                UIManager:close(dlg)
                if name == "" then return end
                local path = NOTES .. "/" .. name .. ".txt"
                if path == self.path then return end
                self.changed = true
                self:save()
                os.remove(path)
                os.rename(self.path, path)
                self.path = path
                G_reader_settings:saveSetting("typewriter_file", path)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function TypewriterWidget:browse()
    self:save()
    local notes = {}
    for name in lfs.dir(NOTES) do
        local path = NOTES .. "/" .. name
        if name:match("%.txt$") then
            notes[#notes + 1] = { name = name:sub(1, -5), path = path, mtime = lfs.attributes(path, "modification") }
        end
    end
    table.sort(notes, function(a, b) return a.mtime > b.mtime end)
    local menu
    local items = {}
    for _, n in ipairs(notes) do
        items[#items + 1] = {
            text = (n.path == self.path and "● " or "") .. n.name,
            mandatory = os.date("%d %b %H:%M", n.mtime),
            callback = function() UIManager:close(menu) self:open(n.path) end,
        }
    end
    menu = Menu:new{ title = _("Notes"), item_table = items, is_popout = false, is_borderless = true,
        covers_fullscreen = true }
    UIManager:show(menu)
end

-- Swipes page back through earlier spreads; the next key jumps back to the last one.
function TypewriterWidget:onSwipe(ges)
    local dir = ges.direction
    local top = self.top
    if dir == "west" then
        top = math.min(self:spreadStart(#self.lines), top + self.per_spread)
    elseif dir == "east" then
        top = math.max(1, top - self.per_spread)
    else
        return false
    end
    if top ~= self.top then
        self.top = top
        UIManager:setDirty(self, "ui")
    end
    return true
end

function TypewriterWidget:applyRotation()
    local mode = setting("orientation", "portrait") == "landscape" and Screen.DEVICE_ROTATED_CLOCKWISE
        or Screen.DEVICE_ROTATED_UPRIGHT
    if Screen:getRotationMode() ~= mode then Screen:setRotationMode(mode) end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

function TypewriterWidget:applySettings()
    self.face = Font:getFace(FONTS[setting("font", "serif")], setting("size", 24))
    local height, ascender = self.face.ftsize:getHeightAndAscender()
    self.pitch = math.floor(height * setting("spacing", 1.4) + 0.5)
    self.ascent = math.floor(ascender + (self.pitch - height) / 2 + 0.5)
    self.margin = Screen:scaleBySize(setting("margin", 40))
    self.cols = self.dimen.w > self.dimen.h and setting("columns", 2) or 1
    self.gap = 2 * self.margin
    self.text_w = math.floor((self.dimen.w - 2 * self.margin - (self.cols - 1) * self.gap) / self.cols)
    self.per_page = math.max(1, math.floor((self.dimen.h - 2 * self.margin) / self.pitch))
    self.per_spread = self.per_page * self.cols
    self.adv = {}
    self.lines = {}
    self:layoutFrom(1)
    self.top = self:spreadStart(#self.lines)
end

function TypewriterWidget:spreadStart(k)
    return math.floor((k - 1) / self.per_spread) * self.per_spread + 1
end

function TypewriterWidget:advance(c)
    local a = self.adv[c]
    if a then return a end
    a = RenderText:sizeUtf8Text(0, self.dimen.w, self.face, c, false, false).x
    self.adv[c] = a
    return a
end

-- Greedy word wrap from line li to the end; each line is { first, last, w } over self.chars.
function TypewriterWidget:layoutFrom(li)
    local lines, chars = self.lines, self.chars
    local first = li > 1 and lines[li].first or 1
    for k = #lines, li, -1 do lines[k] = nil end
    local x, last_space = 0, nil
    local i = first
    while i <= #chars do
        local c = chars[i]
        if c == "\n" then
            lines[#lines + 1] = { first = first, last = i - 1, w = x }
            first, x, last_space = i + 1, 0, nil
        else
            local w = self:advance(c)
            if c ~= " " and x + w > self.text_w and i > first then
                if last_space then
                    local carried = 0
                    for k = last_space + 1, i - 1 do carried = carried + self:advance(chars[k]) end
                    lines[#lines + 1] = { first = first, last = last_space, w = x - carried }
                    first, x = last_space + 1, carried
                else
                    lines[#lines + 1] = { first = first, last = i - 1, w = x }
                    first, x = i, 0
                end
                last_space = nil
            end
            if c == " " then last_space = i end
            x = x + w
        end
        i = i + 1
    end
    lines[#lines + 1] = { first = first, last = #chars, w = x }
end

function TypewriterWidget:lineX(k)
    return self.margin + math.floor((k - self.top) / self.per_page) * (self.text_w + self.gap)
end

function TypewriterWidget:lineY(k)
    return self.margin + ((k - self.top) % self.per_page) * self.pitch
end

function TypewriterWidget:drawLine(bb, k, from)
    local line = self.lines[k]
    local x = self:lineX(k)
    for i = line.first, from - 1 do x = x + self:advance(self.chars[i]) end
    local baseline = self:lineY(k) + self.ascent
    local text = table.concat(self.chars, "", from, line.last)
    if text ~= "" then
        RenderText:renderUtf8Text(bb, x, baseline, self.face, text, false, false, Blitbuffer.COLOR_BLACK)
    end
end

function TypewriterWidget:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    if self.cols == 2 then
        bb:paintRect(x + math.floor(self.dimen.w / 2), y + self.margin, 1, self.dimen.h - 2 * self.margin,
            Blitbuffer.COLOR_GRAY)
    end
    for k = self.top, math.min(#self.lines, self.top + self.per_spread - 1) do
        self:drawLine(bb, k, self.lines[k].first)
    end
end

function TypewriterWidget:isOnTop()
    local top = UIManager._window_stack[#UIManager._window_stack]
    return top and top.widget == self
end

function TypewriterWidget:onKeyByte(b)
    local t0 = time.now()
    -- Typing hides the toolbar; the page stays bare while writing.
    if self.toolbar then
        UIManager:close(self.toolbar)
        self.toolbar = nil
    end
    if b >= 0x80 then
        -- UTF-8: a lead byte opens a sequence, continuation bytes fill it.
        if b >= 0xC0 then
            self.utf8 = { string.char(b), b >= 0xF0 and 3 or b >= 0xE0 and 2 or 1 }
            return
        end
        if not self.utf8 then return end
        self.utf8[1] = self.utf8[1] .. string.char(b)
        self.utf8[2] = self.utf8[2] - 1
        if self.utf8[2] > 0 then return end
        self:edit(self.utf8[1])
        self.utf8 = nil
    elseif b == BACKSPACE then
        self:edit(nil)
    elseif b == NEWLINE then
        self:edit("\n")
    else
        self:edit(string.char(b))
    end
    self.key_times = self.key_times or {}
    table.insert(self.key_times, t0)
end

-- c appends a character; nil deletes the last one. Redraws only the changed tails.
function TypewriterWidget:edit(c)
    local chars, lines = self.chars, self.lines
    if not c and #chars == 0 then return end
    local old = {}
    local li = math.max(1, #lines - 2)
    for k = li, #lines do old[k] = { first = lines[k].first, last = lines[k].last, w = lines[k].w } end
    local old_count = #lines
    local edit_at
    if c then
        chars[#chars + 1] = c
        edit_at = #chars
    else
        edit_at = #chars
        chars[#chars] = nil
    end
    self.changed = true
    self:layoutFrom(li)

    local on_top = self:isOnTop()
    local last = #lines
    if last > self.top + self.per_spread - 1 or last < self.top then
        self.top = self:spreadStart(last)
        if on_top then UIManager:setDirty(self, "ui") end
        return
    end
    if not on_top then return end

    local bb = Screen.bb
    for k = li, math.max(last, old_count) do
        local o, n = old[k], lines[k]
        local from_x, end_x = 0, 0
        local from = n and n.first
        if o and n and o.first == n.first then
            -- The common prefix stays; restart one char early so a glyph overhang isn't clipped.
            local keep = math.min(o.last, n.last, edit_at - 1)
            from = math.max(n.first, keep)
            for i = n.first, from - 1 do from_x = from_x + self:advance(chars[i]) end
        end
        if o then end_x = o.w end
        if n then end_x = math.max(end_x, n.w) end
        local unchanged = o and n and o.first == n.first and o.last == n.last and o.last < edit_at - 1
        if not unchanged and end_x > from_x and k >= self.top then
            local x, y, w = self:lineX(k) + from_x, self:lineY(k), end_x - from_x + 2
            bb:paintRect(x, y, w, self.pitch, Blitbuffer.COLOR_WHITE)
            if n then self:drawLine(bb, k, from) end
            self.dirty = union(self.dirty, x, y, w, self.pitch)
        end
    end
    if self.dirty and not self.flush_scheduled then
        self.flush_scheduled = true
        UIManager:nextTick(self.flush_cb)
    end
end

function TypewriterWidget:flush()
    self.flush_scheduled = false
    local d = self.dirty
    if not d then return end
    self.dirty = nil
    if setting("waveform", "a2") == "a2" then
        Screen:refreshA2(d.x, d.y, d.w, d.h)
    else
        Screen:refreshFast(d.x, d.y, d.w, d.h)
    end
    local now = time.now()
    for _, t in ipairs(self.key_times or {}) do
        table.insert(_G.TW_LAT, time.to_ms(now - t))
        if #_G.TW_LAT > 200 then table.remove(_G.TW_LAT, 1) end
    end
    self.key_times = {}
    self.clean = union(self.clean, d.x, d.y, d.w, d.h)
    UIManager:unschedule(self.idle_cb)
    UIManager:scheduleIn(CLEAN_DELAY, self.idle_cb)
end

function TypewriterWidget:onIdle()
    if self.clean and self:isOnTop() then
        local c = self.clean
        UIManager:setDirty(nil, "ui", c)
    end
    self.clean = nil
    self:save()
end

function TypewriterWidget:save()
    if not self.changed then return end
    local f = io.open(self.path .. ".part", "w")
    if not f then return end
    f:write(table.concat(self.chars))
    f:close()
    os.rename(self.path .. ".part", self.path)
    self.changed = false
end

function TypewriterWidget:onShow()
    self.flush_cb = function() self:flush() end
    self.idle_cb = function() self:onIdle() end
end

-- Toolbar strip: notes actions, layout toggles, close. The Aa icon opens the type rows below it.
function TypewriterWidget:showSettings()
    local function save(key, v) G_reader_settings:saveSetting("typewriter_" .. key, v) end
    local function step(key, default, delta, lo, hi)
        local v = setting(key, default) + delta
        save(key, math.floor(math.min(hi, math.max(lo, v)) * 10 + 0.5) / 10)
    end
    local landscape = setting("orientation", "portrait") == "landscape"
    local two = setting("columns", 2) == 2
    local font = setting("font", "serif")
    local wave = setting("waveform", "a2")
    local icon_size = Screen:scaleBySize(36)
    local dlg
    local function action(fn)
        return function()
            UIManager:close(dlg)
            fn()
        end
    end
    local function change(fn)
        return function()
            fn()
            UIManager:close(dlg)
            self:applyRotation()
            self:applySettings()
            UIManager:setDirty(self, "ui")
            self:showSettings()
        end
    end
    local function icon(name, callback, enabled)
        return { icon = name, icon_width = icon_size, icon_height = icon_size, callback = callback,
            enabled = enabled ~= false }
    end
    local function stepper(label, key, default, delta, lo, hi)
        return {
            { text = "−", callback = change(function() step(key, default, -delta, lo, hi) end) },
            { text = label .. " " .. setting(key, default), enabled = false },
            { text = "+", callback = change(function() step(key, default, delta, lo, hi) end) },
        }
    end
    local buttons = {{
        icon("plus", action(function() self:newNote() end)),
        icon("appbar.filebrowser", action(function() self:browse() end)),
        icon("edit", action(function() self:saveAs() end)),
        icon(landscape and "rotation.L.90CW" or "rotation.P.0UR", change(function()
            save("orientation", landscape and "portrait" or "landscape") end)),
        icon(two and "column.two" or "column.one", change(function() save("columns", two and 1 or 2) end),
            landscape),
        icon("appbar.textsize", change(function() self.type_open = not self.type_open end)),
        icon("close", action(function() self:onClose() end)),
    }}
    if self.type_open then
        table.insert(buttons, {
            { text = (font == "sans" and "● " or "") .. "Sans", callback = change(function() save("font", "sans") end) },
            { text = (font == "serif" and "● " or "") .. "Serif", callback = change(function() save("font", "serif") end) },
            { text = wave == "a2" and "A2" or "DU", callback = change(function()
                save("waveform", wave == "a2" and "du" or "a2") end) },
        })
        local row = {}
        for _, part in ipairs({ stepper("Aa", "size", 24, 2, 10, 60), stepper("↕", "spacing", 1.4, 0.1, 1.0, 3.0),
            stepper("↔", "margin", 40, 10, 0, 200) }) do
            for _, btn in ipairs(part) do row[#row + 1] = btn end
        end
        table.insert(buttons, row)
    end
    dlg = ButtonDialog:new{ buttons = buttons }
    self.toolbar = dlg
    UIManager:show(dlg)
end

function TypewriterWidget:onClose()
    UIManager:unschedule(self.idle_cb)
    self:save()
    UIManager:close(self, "ui")
    return true
end

-- Dialogs on top hold back direct drawing; the page catches up once it is uncovered.
function TypewriterWidget:onCloseWidget()
    UIManager:unschedule(self.idle_cb)
    self:save()
    if Screen:getRotationMode() ~= self.rotation_backup then
        Screen:setRotationMode(self.rotation_backup)
        UIManager:onRotation()
    end
end

local Typewriter = WidgetContainer:extend{
    name = "typewriter",
}

function Typewriter:init()
    local input = Device.input
    -- Installed once per KOReader run; it forwards to whatever sink the newest plugin instance set.
    if not input.typewriter_hooked then
        input.typewriter_hooked = true
        local handleMiscEv = input.handleMiscEv
        input.handleMiscEv = function(this, ev)
            if ev.code == MSC_RAW and ev.value >= KEY_MAGIC and ev.value <= KEY_MAGIC + 0xFF then
                if this.typewriter_sink then this.typewriter_sink(ev.value - KEY_MAGIC) end
                return
            end
            return handleMiscEv(this, ev)
        end
    end
    input.typewriter_sink = function(b) self:onKeyByte(b) end
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
end

-- Looks the page up by flag, not by a module field: `ink reload` swaps the module, and a second page
-- would stack on the first.
function Typewriter:open()
    for _, w in ipairs(UIManager._window_stack) do
        if w.widget.is_typewriter then return w.widget end
    end
    local widget = TypewriterWidget:new{}
    widget:onShow()
    UIManager:show(widget, "ui")
    return widget
end

-- The first key typed anywhere opens the page and lands on it.
function Typewriter:onKeyByte(b)
    self:open():onKeyByte(b)
end

function Typewriter:addToMainMenu(menu_items)
    menu_items.typewriter = {
        text = _("Typewriter"),
        sorting_hint = "tools",
        callback = function() self:open() end,
    }
end

return Typewriter
