--[[
Word search: one full-screen widget that paints itself with Blitbuffer. Two modes, "home" (continue,
new board by size, toggles) and "game" (grid, word list, a win panel on top when solved).
A stroke across the grid draws a live outline (DU refresh on its box only); on release it snaps to
the nearest unfound word (logic.lua). The board is saved in G_reader_settings after every find and
on close, so the home screen can offer Continue.
]]
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen

local DIR = debug.getinfo(1, "S").source:match("^@(.*/)")
local Logic = dofile(DIR .. "logic.lua")
local THEMES = dofile(DIR .. "words.lua")

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local DARK = Blitbuffer.Color8(0x55)
local GRAY = Blitbuffer.Color8(0x88)
local LIGHT = Blitbuffer.Color8(0xC8)
local PALE = Blitbuffer.Color8(0xE8)
local CHEERS = { "Nice!", "Great find!", "Sharp eyes!", "Brilliant!", "Got it!", "Superb!", "Spot on!" }
local FLASH_TIME, CHEER_TIME = 0.5, 1.8
local SAVE_KEY = "wordsearch_game"

local SCALE = Screen:scaleBySize(1000) / 1000
local faces = {}
-- Faces by pixel size; getFace scales by DPI, so undo that.
local function face(px, bold)
    px = math.floor(px)
    local key = (bold and "b" or "r") .. px
    if not faces[key] then
        faces[key] = Font:getFace(bold and "NotoSans-Bold.ttf" or "NotoSans-Regular.ttf", px / SCALE)
    end
    return faces[key]
end

local function textWidth(text, px, bold)
    return RenderText:sizeUtf8Text(0, Screen:getWidth() * 2, face(px, bold), text, true, false).x
end

-- Draws text with its capital letters centred on cy.
local function text(bb, s, x, cy, px, bold, color)
    RenderText:renderUtf8Text(bb, math.floor(x), math.floor(cy + px * 0.36), face(px, bold), s, true, false,
        color or BLACK)
end

local function textCentered(bb, s, cx, cy, px, bold, color)
    text(bb, s, cx - textWidth(s, px, bold) / 2, cy, px, bold, color)
end

-- A round-ended stroke from (x1, y1) to (x2, y2): the marker highlight around a word.
local function capsule(bb, x1, y1, x2, y2, r, color)
    x1, y1, x2, y2, r = math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2), math.floor(r)
    if y1 == y2 then
        bb:paintRect(math.min(x1, x2), y1 - r, math.abs(x2 - x1), 2 * r + 1, color)
    elseif x1 == x2 then
        bb:paintRect(x1 - r, math.min(y1, y2), 2 * r + 1, math.abs(y2 - y1), color)
    else
        local steps = math.ceil(math.max(math.abs(x2 - x1), math.abs(y2 - y1)) / 3)
        for i = 1, steps - 1 do
            bb:paintCircle(math.floor(x1 + (x2 - x1) * i / steps), math.floor(y1 + (y2 - y1) * i / steps), r, color)
        end
    end
    bb:paintCircle(x1, y1, r, color)
    bb:paintCircle(x2, y2, r, color)
end

local function setting(key, default)
    local v = G_reader_settings:readSetting("wordsearch_" .. key)
    if v == nil then return default end
    return v
end

local function clock(seconds)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local WordSearchWidget = InputContainer:extend{
    covers_fullscreen = true,
    is_wordsearch = true,
}

function WordSearchWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.game = G_reader_settings:readSetting(SAVE_KEY)
    self.mode = "home"
    self.hits = {}
    local all = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }
    local function zone(id, ges, handler)
        return { id = "wordsearch_" .. id, ges = ges, screen_zone = all, handler = handler }
    end
    self:registerTouchZones({
        zone("touch", "touch", function(g) return self:onStrokeStart(g.pos) end),
        zone("pan", "pan", function(g) return self:onStrokeMove(g.pos) end),
        zone("hold_pan", "hold_pan", function(g) return self:onStrokeMove(g.pos) end),
        zone("pan_release", "pan_release", function(g) return self:onStrokeEnd(g.pos) end),
        zone("hold_release", "hold_release", function(g) return self:onStrokeEnd(g.pos) end),
        zone("swipe", "swipe", function(g) return self:onSwipe(g) end),
        zone("tap", "tap", function(g) return self:onTap(g.pos) end),
        zone("hold", "hold", function() return true end),
    })
end

-- Layout --------------------------------------------------------------------------------------------

function WordSearchWidget:gameLayout()
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(math.min(W, H) * 0.035)
    local header = math.floor(math.min(W, H) * 0.11)
    local n = self.game.n
    local L = { m = m, header = header, n = n }
    if W > H then
        local side = math.min(H - header - 2 * m, math.floor(W * 0.6))
        L.cell = math.floor(side / n)
        L.gx, L.gy = m, header + m
        L.list = Geom:new{ x = L.gx + L.cell * n + 2 * m, y = header + m }
        L.list.w, L.list.h = W - L.list.x - m, H - L.list.y - m
    else
        local side = math.min(W - 2 * m, math.floor(H * 0.62))
        L.cell = math.floor(side / n)
        L.gx, L.gy = math.floor((W - L.cell * n) / 2), header + m
        L.list = Geom:new{ x = m, y = L.gy + L.cell * n + m }
        L.list.w, L.list.h = W - 2 * m, H - L.list.y - m
    end
    return L
end

function WordSearchWidget:cellCenter(r, c)
    local L = self.layout
    return L.gx + (c - 0.5) * L.cell, L.gy + (r - 0.5) * L.cell
end

function WordSearchWidget:toCells(pos)
    local L = self.layout
    return (pos.x - L.gx) / L.cell, (pos.y - L.gy) / L.cell
end

function WordSearchWidget:lineBox(r1, c1, r2, c2)
    local L = self.layout
    local pad = 6
    return Geom:new{
        x = L.gx + (math.min(c1, c2) - 1) * L.cell - pad,
        y = L.gy + (math.min(r1, r2) - 1) * L.cell - pad,
        w = (math.abs(c2 - c1) + 1) * L.cell + 2 * pad,
        h = (math.abs(r2 - r1) + 1) * L.cell + 2 * pad,
    }
end

function WordSearchWidget:hit(x, y, w, h, fn)
    self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, fn = fn }
end

-- Painting ------------------------------------------------------------------------------------------

function WordSearchWidget:paintTo(bb, x, y)
    self.hits = {}
    bb:paintRect(0, 0, self.dimen.w, self.dimen.h, WHITE)
    if self.mode == "game" then
        self:paintGame(bb)
        if self.game.done and not self.flash then self:paintWin(bb) end
    else
        self:paintHome(bb)
    end
end

-- Letter tiles, alternating solid and grey, as used by the titles.
function WordSearchWidget:paintTiles(bb, word, cx, cy, t)
    local gap = math.floor(t * 0.12)
    local x = math.floor(cx - (#word * t + (#word - 1) * gap) / 2)
    for i = 1, #word do
        local solid = i % 2 == 1
        bb:paintRoundedRect(x, math.floor(cy - t / 2), t, t, solid and BLACK or LIGHT, math.floor(t * 0.18))
        textCentered(bb, word:sub(i, i), x + t / 2, cy, t * 0.62, true, solid and WHITE or BLACK)
        x = x + t + gap
    end
    return #word * t + (#word - 1) * gap
end

-- n x n squares in a box; `dark(r, c)` picks the filled ones.
local function miniGrid(bb, x, y, side, n, dark)
    local cell = side / n
    local s = math.max(1, math.floor(cell * 0.78))
    for r = 1, n do
        for c = 1, n do
            bb:paintRect(math.floor(x + (c - 1) * cell), math.floor(y + (r - 1) * cell), s, s,
                dark(r, c) and BLACK or LIGHT)
        end
    end
end

local function closeIcon(bb, cx, cy, size)
    local h = size / 2
    capsule(bb, cx - h, cy - h, cx + h, cy + h, math.max(2, size / 12), BLACK)
    capsule(bb, cx - h, cy + h, cx + h, cy - h, math.max(2, size / 12), BLACK)
end

local function switch(bb, x, cy, w, on)
    local h = math.floor(w * 0.52)
    local y = math.floor(cy - h / 2)
    bb:paintRoundedRect(x, y, w, h, on and BLACK or LIGHT, math.floor(h / 2))
    local kr = math.floor(h / 2) - 5
    bb:paintCircle(on and x + w - h / 2 or x + h / 2, cy, kr, WHITE)
end

function WordSearchWidget:paintHome(bb)
    local W, H = self.dimen.w, self.dimen.h
    local S = math.min(W, H)
    local m = math.floor(S * 0.05)
    local t = math.floor(math.min((S - 2 * m) / 7.5, H * 0.08))
    local y = m + t / 2

    -- Title: WORD circled like a found word, SEARCH below.
    local word_w = 4 * t + 3 * math.floor(t * 0.12)
    local r = math.floor(t * 0.66)
    capsule(bb, W / 2 - word_w / 2 + t / 2, y + t * 0.1, W / 2 + word_w / 2 - t / 2, y + t * 0.1, r, BLACK)
    capsule(bb, W / 2 - word_w / 2 + t / 2, y + t * 0.1, W / 2 + word_w / 2 - t / 2, y + t * 0.1, r - 6, WHITE)
    self:paintTiles(bb, "WORD", W / 2, y + t * 0.1, t)
    y = y + t * 1.35
    self:paintTiles(bb, "SEARCH", W / 2, y, t)
    local cs = math.floor(t * 0.45)
    closeIcon(bb, W - m, m, cs)
    self:hit(W - m - t, 0, t + m, t + m, function() self:onClose() end)
    y = y + t * 0.5 + m

    local g = self.game
    if g and not g.done then
        local ch = math.floor(t * 2.1)
        local pad = math.floor(ch * 0.14)
        bb:paintRoundedRect(m, y, W - 2 * m, ch, BLACK, 28)
        local thumb = ch - 2 * pad
        bb:paintRoundedRect(m + pad - 6, y + pad - 6, thumb + 12, thumb + 12, WHITE, 12)
        local found = {}
        for _, w in ipairs(g.words) do
            if w.found then
                local steps = math.max(math.abs(w.r2 - w.r1), math.abs(w.c2 - w.c1))
                for k = 0, steps do
                    found[(w.r1 + k * (w.r2 - w.r1) / steps) * 100 + w.c1 + k * (w.c2 - w.c1) / steps] = true
                end
            end
        end
        miniGrid(bb, m + pad, y + pad, thumb, g.n, function(rr, cc) return found[rr * 100 + cc] end)
        local tx = m + 2 * pad + thumb + pad
        local total, left = #g.words, Logic.remaining(g)
        text(bb, _("Continue"), tx, y + ch * 0.27, t * 0.55, true, WHITE)
        text(bb, g.theme .. "  ·  " .. Logic.size(g.size).name, tx, y + ch * 0.53, t * 0.36, false, WHITE)
        local bw = W - m - pad - tx
        local by = math.floor(y + ch * 0.76)
        bb:paintRoundedRect(tx, by, bw, 18, DARK, 9)
        bb:paintRoundedRect(tx, by, math.max(18, math.floor(bw * (total - left) / total)), 18, WHITE, 9)
        self:hit(m, y, W - 2 * m, ch, function() self:startGame() end)
        y = y + ch + m
    end

    text(bb, _("New puzzle"), m, y + t * 0.3, t * 0.42, true)
    y = y + t * 0.75
    local gap = math.floor(m * 0.6)
    local cw = math.floor((W - 2 * m - gap) / 2)
    local ch = math.floor(t * 1.6)
    local diag = setting("diagonals", true)
    for i, size in ipairs(Logic.SIZES) do
        local cx = m + ((i - 1) % 2) * (cw + gap)
        local cy = y + math.floor((i - 1) / 2) * (ch + gap)
        bb:paintBorder(cx, cy, cw, ch, 4, BLACK, 24)
        local pad = math.floor(ch * 0.16)
        local side = ch - 2 * pad
        local n = size.n
        local word_row, word_len = math.floor(n / 3), math.floor(n / 2)
        miniGrid(bb, cx + pad, cy + pad, side, n, function(rr, cc)
            if rr == word_row and cc >= 2 and cc < 2 + word_len then return true end
            return diag and rr == cc + math.floor(n / 3) and cc <= word_len
        end)
        local tx = cx + 2 * pad + side
        text(bb, size.name, tx, cy + ch * 0.36, t * 0.5, true)
        text(bb, n .. "×" .. n .. " · " .. size.words .. " " .. _("words"), tx, cy + ch * 0.68, t * 0.3, false, DARK)
        self:hit(cx, cy, cw, ch, function() self:newGame(size.key) end)
    end
    y = y + 2 * ch + gap + m

    local rows = {
        { key = "diagonals", label = _("Diagonal words"), default = true },
        { key = "show_left", label = _("Show words left"), default = true },
    }
    local rh = math.floor(t * 0.95)
    for _, row in ipairs(rows) do
        local on = setting(row.key, row.default)
        text(bb, row.label, m, y + rh / 2, t * 0.4, false)
        switch(bb, W - m - math.floor(t * 1.15), math.floor(y + rh / 2), math.floor(t * 1.15), on)
        self:hit(0, y, W, rh, function()
            G_reader_settings:saveSetting("wordsearch_" .. row.key, not on)
            UIManager:setDirty(self, "ui")
        end)
        bb:paintRect(m, y + rh, W - 2 * m, 2, LIGHT)
        y = y + rh
    end
    textCentered(bb, _("Swipe across a word to circle it."), W / 2, math.min(H - m, y + m * 1.5), t * 0.32, false, GRAY)
end

function WordSearchWidget:paintGame(bb)
    local g, L = self.game, self.layout
    local W = self.dimen.w
    local n, cell = g.n, L.cell
    local header = L.header

    -- Header: back, theme (or a cheer), words left.
    local hy = header / 2 + L.m / 2
    local hp = header * 0.42
    text(bb, "‹", L.m, hy - hp * 0.08, hp * 1.4, true)
    text(bb, _("Menu"), L.m + hp * 0.7, hy, hp * 0.62, false)
    self:hit(0, 0, L.m + hp * 3.2, header + L.m / 2, function() self:goHome() end)
    local title = self.cheer or g.theme
    textCentered(bb, title, W / 2, hy, hp * (self.cheer and 0.95 or 0.8), true)
    local total, left = #g.words, Logic.remaining(g)
    if setting("show_left", true) then
        local label = left == 0 and "✓" or (left .. " " .. _("left"))
        local px = hp * 0.6
        local pw = textWidth(label, px, true) + px * 1.4
        local ph = math.floor(px * 1.8)
        bb:paintRoundedRect(math.floor(W - L.m - pw), math.floor(hy - ph / 2), math.floor(pw), ph, BLACK, math.floor(ph / 2))
        textCentered(bb, label, W - L.m - pw / 2, hy, px, true, WHITE)
        -- Progress bar along the header's foot.
        bb:paintRect(L.m, header + L.m / 2 - 3, W - 2 * L.m, 3, LIGHT)
        bb:paintRect(L.m, header + L.m / 2 - 6, math.floor((W - 2 * L.m) * (total - left) / total), 9, BLACK)
    else
        bb:paintRect(L.m, header + L.m / 2 - 3, W - 2 * L.m, 3, LIGHT)
    end

    -- Highlights: all dark rims first, then the light fills, so crossing words merge into one marker.
    local r = cell * 0.42
    for pass = 1, 2 do
        for i, w in ipairs(g.words) do
            if w.found then
                local x1, y1 = self:cellCenter(w.r1, w.c1)
                local x2, y2 = self:cellCenter(w.r2, w.c2)
                if i == self.flash then
                    if pass == 1 then capsule(bb, x1, y1, x2, y2, r, BLACK) end
                elseif pass == 1 then
                    capsule(bb, x1, y1, x2, y2, r, DARK)
                else
                    capsule(bb, x1, y1, x2, y2, r - 4, LIGHT)
                end
            end
        end
    end
    local flash_cells = {}
    if self.flash then
        local w = g.words[self.flash]
        local steps = math.max(math.abs(w.r2 - w.r1), math.abs(w.c2 - w.c1))
        for k = 0, steps do
            flash_cells[(w.r1 + k * (w.r2 - w.r1) / steps) * 100 + w.c1 + k * (w.c2 - w.c1) / steps] = true
        end
    end
    local s = self.stroke
    if s and s.er then
        local x1, y1 = self:cellCenter(s.r, s.c)
        local x2, y2 = self:cellCenter(s.er, s.ec)
        capsule(bb, x1, y1, x2, y2, r + 2, BLACK)
        capsule(bb, x1, y1, x2, y2, r - 4, WHITE)
    end

    local px = cell * 0.56
    for rr = 1, n do
        for cc = 1, n do
            local x, y = self:cellCenter(rr, cc)
            textCentered(bb, Logic.letter(g, rr, cc), x, y, px, true, flash_cells[rr * 100 + cc] and WHITE or BLACK)
        end
    end

    self:paintWordList(bb)
end

function WordSearchWidget:paintWordList(bb)
    local g, area = self.game, self.layout.list
    local count = #g.words
    local px, cols, rows, colw
    for size = math.floor(self.layout.cell * 0.6), 18, -2 do
        local maxw = 0
        for _, w in ipairs(g.words) do maxw = math.max(maxw, textWidth(w.w, size, true)) end
        colw = maxw + size * 1.6
        cols = math.max(1, math.floor((area.w + size * 1.6) / colw))
        rows = math.ceil(count / cols)
        px = size
        if rows * size * 1.75 <= area.h then break end
    end
    local lh = px * 1.75
    local block_w = cols * colw - px * 1.6
    local x0 = area.x + math.max(0, (area.w - block_w) / 2)
    local y0 = area.y + math.max(0, (area.h - rows * lh) / 2)
    for i, w in ipairs(g.words) do
        local col, row = math.floor((i - 1) / rows), (i - 1) % rows
        local x, cy = x0 + col * colw, y0 + row * lh + lh / 2
        if w.found then
            text(bb, w.w, x, cy, px, false, GRAY)
            bb:paintRect(math.floor(x - 4), math.floor(cy - 2), math.floor(textWidth(w.w, px, false) + 8), 4, DARK)
        else
            text(bb, w.w, x, cy, px, true, BLACK)
        end
    end
end

-- Win panel: confetti over the board, a card with tiles, time and stars.
function WordSearchWidget:paintWin(bb)
    local W, H = self.dimen.w, self.dimen.h
    local g = self.game
    local rnd = Logic.rng(g.seed or 1)
    for _ = 1, 70 do
        local x, y, s = rnd(W), rnd(H), 6 + rnd(18)
        local kind = rnd(3)
        if kind == 1 then
            bb:paintCircle(x, y, s, BLACK)
        elseif kind == 2 then
            bb:paintRect(x, y, s * 2, s, DARK)
        else
            bb:paintCircle(x, y, s, BLACK, 4)
        end
    end
    local S = math.min(W, H)
    local pw, ph = math.floor(S * 0.86), math.floor(S * 0.78)
    local px, py = math.floor((W - pw) / 2), math.floor((H - ph) / 2)
    bb:paintRoundedRect(px - 10, py - 10, pw + 20, ph + 20, WHITE, 44)
    bb:paintBorder(px, py, pw, ph, 8, BLACK, 36)
    local t = math.floor(pw / 8.5)
    local y = py + ph * 0.17
    self:paintTiles(bb, "SOLVED", W / 2, y, t)

    local per_word = (g.elapsed or 0) / math.max(1, #g.words)
    local stars = per_word < 20 and 3 or per_word < 40 and 2 or 1
    local ss = math.floor(t * 1.05)
    y = y + t * 0.9
    for i = 1, 3 do
        local icon = IconWidget:new{ icon = i <= stars and "star.full" or "star.empty", width = ss, height = ss }
        icon:paintTo(bb, math.floor(W / 2 + (i - 2) * ss * 1.15 - ss / 2), math.floor(y))
        icon:free()
    end
    y = y + ss + t * 0.45
    textCentered(bb, clock(g.elapsed or 0), W / 2, y, t * 0.75, true)
    y = y + t * 0.8
    textCentered(bb, g.theme .. "  ·  " .. Logic.size(g.size).name .. "  ·  " .. #g.words .. " " .. _("words"),
        W / 2, y, t * 0.36, false, DARK)

    local bh = math.floor(t * 0.95)
    local bw = math.floor((pw - 3 * t * 0.5) / 2)
    local by = math.floor(py + ph - t * 0.5 - bh)
    local b1 = math.floor(px + t * 0.5)
    local b2 = b1 + bw + math.floor(t * 0.5)
    bb:paintRoundedRect(b1, by, bw, bh, BLACK, math.floor(bh / 2))
    textCentered(bb, _("Play again"), b1 + bw / 2, by + bh / 2, t * 0.4, true, WHITE)
    self:hit(b1, by, bw, bh, function() self:newGame(g.size) end)
    bb:paintBorder(b2, by, bw, bh, 5, BLACK, math.floor(bh / 2))
    textCentered(bb, _("Menu"), b2 + bw / 2, by + bh / 2, t * 0.4, true)
    self:hit(b2, by, bw, bh, function() self:goHome() end)
end

-- State ---------------------------------------------------------------------------------------------

function WordSearchWidget:tick()
    if not self.started then return end
    local now = os.time()
    self.game.elapsed = (self.game.elapsed or 0) + now - self.started
    self.started = now
end

function WordSearchWidget:save()
    if not self.game then return end
    self:tick()
    G_reader_settings:saveSetting(SAVE_KEY, self.game)
end

function WordSearchWidget:startGame()
    self.mode = "game"
    self.layout = self:gameLayout()
    self.started = not self.game.done and os.time() or nil
    UIManager:setDirty(self, "flashui")
end

function WordSearchWidget:newGame(size_key)
    local last = self.game and self.game.theme
    self.game = Logic.generate(THEMES, size_key, setting("diagonals", true), os.time(), last)
    self:clearTimers()
    self:save()
    self:startGame()
end

function WordSearchWidget:goHome()
    self:save()
    self:clearTimers()
    self.started = nil
    self.mode = "home"
    self.stroke = nil
    UIManager:setDirty(self, "flashui")
end

function WordSearchWidget:clearTimers()
    if self.flash_cb then UIManager:unschedule(self.flash_cb) end
    if self.cheer_cb then UIManager:unschedule(self.cheer_cb) end
    self.flash, self.cheer = nil, nil
end

function WordSearchWidget:found(i)
    local g = self.game
    g.words[i].found = true
    self:clearTimers()
    self.flash = i
    self.cheer = CHEERS[math.random(#CHEERS)]
    if Logic.remaining(g) == 0 then
        g.done = true
        self:tick()
        self.started = nil
    end
    self:save()
    G_reader_settings:flush()
    UIManager:setDirty(self, "ui")
    self.flash_cb = function()
        self.flash = nil
        UIManager:setDirty(self, g.done and "flashui" or "ui")
    end
    UIManager:scheduleIn(FLASH_TIME, self.flash_cb)
    self.cheer_cb = function()
        self.cheer = nil
        UIManager:setDirty(self, "ui")
    end
    UIManager:scheduleIn(CHEER_TIME, self.cheer_cb)
end

-- Strokes -------------------------------------------------------------------------------------------

function WordSearchWidget:strokeActive()
    return self.mode == "game" and self.game and not self.game.done
end

function WordSearchWidget:onStrokeStart(pos)
    if not self:strokeActive() then return false end
    local fx, fy = self:toCells(pos)
    local n = self.game.n
    if fx < 0 or fy < 0 or fx >= n or fy >= n then
        self.stroke = nil
        return false
    end
    self.stroke = { sx = fx, sy = fy, r = math.floor(fy) + 1, c = math.floor(fx) + 1 }
    return true
end

function WordSearchWidget:onStrokeMove(pos)
    local s = self.stroke
    if not s or not pos then return false end
    s.ex, s.ey = self:toCells(pos)
    local er, ec = Logic.lineEnd(self.game, s.r, s.c, s.ex, s.ey)
    if er == s.er and ec == s.ec then return true end
    local box = self:lineBox(s.r, s.c, er, ec)
    if s.er then box = box:combine(self:lineBox(s.r, s.c, s.er, s.ec)) end
    s.er, s.ec = er, ec
    UIManager:setDirty(self, function() return "fast", box end)
    return true
end

function WordSearchWidget:onStrokeEnd(pos)
    local s = self.stroke
    if not s then return false end
    if pos then s.ex, s.ey = self:toCells(pos) end
    self.stroke = nil
    local box = s.er and self:lineBox(s.r, s.c, s.er, s.ec)
    local i = s.ex and Logic.snap(self.game, s.sx, s.sy, s.ex, s.ey)
    if i then
        self:found(i)
    elseif box then
        UIManager:setDirty(self, function() return "ui", box end)
    end
    return true
end

-- A fast stroke ends as a swipe, which reports where it started plus direction and distance.
local SWIPE_DIRS = {
    north = { 0, -1 }, south = { 0, 1 }, east = { 1, 0 }, west = { -1, 0 },
    northeast = { 0.7071, -0.7071 }, northwest = { -0.7071, -0.7071 },
    southeast = { 0.7071, 0.7071 }, southwest = { -0.7071, 0.7071 },
}

function WordSearchWidget:onSwipe(ges)
    if not self:strokeActive() then return self.mode == "game" end
    if not self.stroke then self:onStrokeStart(ges.pos) end
    local s = self.stroke
    if not s then return true end
    local v = SWIPE_DIRS[ges.direction]
    if v and ges.distance then
        s.ex, s.ey = self:toCells({ x = ges.pos.x + v[1] * ges.distance, y = ges.pos.y + v[2] * ges.distance })
    end
    return self:onStrokeEnd(nil)
end

function WordSearchWidget:onTap(pos)
    if self.stroke then
        local s = self.stroke
        self.stroke = nil
        if s.er then UIManager:setDirty(self, function() return "ui", self:lineBox(s.r, s.c, s.er, s.ec) end) end
    end
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if pos.x >= h.x and pos.x < h.x + h.w and pos.y >= h.y and pos.y < h.y + h.h then
            h.fn()
            return true
        end
    end
    return true
end

function WordSearchWidget:onFlushSettings()
    self:save()
end

function WordSearchWidget:onClose()
    UIManager:close(self, "flashui")
    return true
end

function WordSearchWidget:onCloseWidget()
    self:clearTimers()
    self:save()
end

local WordSearch = WidgetContainer:extend{
    name = "wordsearch",
}

function WordSearch:init()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
end

-- Looks the page up by flag, not by a module field: `ink reload` swaps the module.
function WordSearch:open()
    for _, w in ipairs(UIManager._window_stack) do
        if w.widget.is_wordsearch then return w.widget end
    end
    local widget = WordSearchWidget:new{}
    UIManager:show(widget, "flashui")
    return widget
end

function WordSearch:addToMainMenu(menu_items)
    menu_items.wordsearch = {
        text = _("Word search"),
        sorting_hint = "tools",
        callback = function() self:open() end,
    }
end

return WordSearch
