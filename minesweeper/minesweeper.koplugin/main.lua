--[[
Minesweeper: one full-screen widget that paints itself with Blitbuffer, like Word search. Two modes,
"home" (continue, difficulty, size, no-guess switch) and "game" (header, board, win card on top).
Tap digs, hold flags (the header toggle swaps them), tapping a number clears around it. Every move
re-renders off screen and copies only the changed cells to the panel with DU: pure black and white,
no flash. No live clock, so an idle board never refreshes.
]]
local Blitbuffer = require("ffi/blitbuffer")
local ffi = require("ffi")
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

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local INK_THRESHOLD = 0xA0
local SAVE_KEY = "minesweeper_game"

local SCALE = Screen:scaleBySize(1000) / 1000
local faces = {}
local function face(px, bold)
    px = math.floor(px)
    local key = (bold and "b" or "r") .. px
    if not faces[key] then
        faces[key] = Font:getFace(bold and "NotoSans-Bold.ttf" or "NotoSans-Regular.ttf", px / SCALE)
    end
    return faces[key]
end

local function textWidth(s, px, bold)
    return RenderText:sizeUtf8Text(0, Screen:getWidth() * 2, face(px, bold), s, true, false).x
end

local function text(bb, s, x, cy, px, bold, color)
    RenderText:renderUtf8Text(bb, math.floor(x), math.floor(cy + px * 0.36), face(px, bold), s, true, false,
        color or BLACK)
end

local function textCentered(bb, s, cx, cy, px, bold, color)
    text(bb, s, cx - textWidth(s, px, bold) / 2, cy, px, bold, color)
end

-- Filled disc or thick line with round ends, one row at a time (paintCircle is per pixel).
local function capsule(bb, x1, y1, x2, y2, r, color)
    local dx, dy = x2 - x1, y2 - y1
    local len2 = dx * dx + dy * dy
    for y = math.floor(math.min(y1, y2) - r), math.ceil(math.max(y1, y2) + r) do
        local lo, hi = math.huge, -math.huge
        local x0, x9 = math.floor(math.min(x1, x2) - r), math.ceil(math.max(x1, x2) + r)
        for x = x0, x9 do
            local t = len2 > 0 and math.max(0, math.min(1, ((x - x1) * dx + (y - y1) * dy) / len2)) or 0
            local ex, ey = x - (x1 + t * dx), y - (y1 + t * dy)
            if ex * ex + ey * ey <= r * r then
                if x < lo then lo = x end
                hi = x
            end
        end
        if lo <= hi then bb:paintRect(lo, y, hi - lo + 1, 1, color) end
    end
end

local function binarize(bb, box)
    local data = ffi.cast("uint8_t*", bb.data)
    local stride = tonumber(bb.stride)
    for y = box.y, box.y + box.h - 1 do
        local row = data + y * stride
        for x = box.x, box.x + box.w - 1 do
            row[x] = row[x] < INK_THRESHOLD and 0 or 255
        end
    end
end

local function setting(key, default)
    local v = G_reader_settings:readSetting("minesweeper_" .. key)
    if v == nil then return default end
    return v
end

local function clock(seconds)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Glyphs ---------------------------------------------------------------------------------------------

-- A round mine with eight spikes and a shine.
local function mine(bb, cx, cy, s, color, shine)
    local r = s * 0.27
    local w = math.max(2, s * 0.06)
    for k = 0, 3 do
        local a = k * math.pi / 4
        local ox, oy = math.cos(a) * s * 0.4, math.sin(a) * s * 0.4
        capsule(bb, cx - ox, cy - oy, cx + ox, cy + oy, w, color)
    end
    capsule(bb, cx, cy, cx, cy, r, color)
    capsule(bb, cx - r * 0.35, cy - r * 0.35, cx - r * 0.35, cy - r * 0.35, r * 0.22, shine)
end

-- Pennant on a pole standing on a little base.
local function flag(bb, cx, cy, s, color)
    local w = math.max(2, s * 0.05)
    local px = cx - s * 0.12
    capsule(bb, px, cy - s * 0.32, px, cy + s * 0.28, w, color)
    bb:paintRect(math.floor(cx - s * 0.28), math.floor(cy + s * 0.26), math.floor(s * 0.5), math.max(3, math.floor(s * 0.08)), color)
    local top, h = cy - s * 0.34, s * 0.34
    for y = math.floor(top), math.floor(top + h) do
        local t = 1 - math.abs((y - top) / h * 2 - 1)
        bb:paintRect(math.floor(px), y, math.floor(s * 0.42 * t) + 1, 1, color)
    end
end

-- Shovel: handle with a grip, then a rounded blade.
local function shovel(bb, cx, cy, s, color)
    local w = math.max(2, s * 0.06)
    capsule(bb, cx - s * 0.3, cy - s * 0.3, cx + s * 0.08, cy + s * 0.08, w, color)
    capsule(bb, cx - s * 0.4, cy - s * 0.2, cx - s * 0.2, cy - s * 0.4, w, color)
    capsule(bb, cx + s * 0.14, cy + s * 0.14, cx + s * 0.26, cy + s * 0.26, s * 0.15, color)
end

-- Light bulb.
local function bulb(bb, cx, cy, s, color, paper)
    capsule(bb, cx, cy - s * 0.1, cx, cy - s * 0.1, s * 0.27, color)
    capsule(bb, cx, cy - s * 0.1, cx, cy - s * 0.1, s * 0.27 - math.max(3, s * 0.07), paper)
    bb:paintRect(math.floor(cx - s * 0.13), math.floor(cy + s * 0.18), math.floor(s * 0.26), math.floor(s * 0.08), color)
    bb:paintRect(math.floor(cx - s * 0.1), math.floor(cy + s * 0.3), math.floor(s * 0.2), math.floor(s * 0.07), color)
end

local function chevron(bb, cx, cy, s, pen)
    capsule(bb, cx + s * 0.5, cy - s, cx - s * 0.5, cy, pen, BLACK)
    capsule(bb, cx - s * 0.5, cy, cx + s * 0.5, cy + s, pen, BLACK)
end

local function closeIcon(bb, cx, cy, size)
    local h = size / 2
    capsule(bb, cx - h, cy - h, cx + h, cy + h, math.max(2, size / 12), BLACK)
    capsule(bb, cx - h, cy + h, cx + h, cy - h, math.max(2, size / 12), BLACK)
end

local function switch(bb, x, cy, w, on)
    local h = math.floor(w * 0.52)
    local y = math.floor(cy - h / 2)
    local kr = math.floor(h / 2) - 7
    if on then
        bb:paintRoundedRect(x, y, w, h, BLACK, math.floor(h / 2))
        capsule(bb, x + w - h / 2, cy, x + w - h / 2, cy, kr, WHITE)
    else
        bb:paintBorder(x, y, w, h, 4, BLACK, math.floor(h / 2))
        capsule(bb, x + h / 2, cy, x + h / 2, cy, kr, BLACK)
    end
end

-- Widget ---------------------------------------------------------------------------------------------

local MinesWidget = InputContainer:extend{
    covers_fullscreen = true,
    is_minesweeper = true,
}

function MinesWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.game = G_reader_settings:readSetting(SAVE_KEY)
    self.mode = "home"
    self.flagging = false
    self.hits = {}
    local all = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }
    local function zone(id, ges, handler)
        return { id = "minesweeper_" .. id, ges = ges, screen_zone = all, handler = handler }
    end
    self:registerTouchZones({
        zone("tap", "tap", function(g) return self:onTap(g.pos) end),
        zone("hold", "hold", function(g) return self:onHold(g.pos) end),
        zone("hold_release", "hold_release", function() return true end),
        zone("swipe", "swipe", function() return true end),
        zone("pan", "pan", function() return true end),
    })
end

function MinesWidget:gameLayout()
    local W, H = self.dimen.w, self.dimen.h
    local g = self.game
    local m = math.floor(math.min(W, H) * 0.03)
    local header = math.floor(math.min(W, H) * 0.1)
    local cell = math.floor(math.min((W - 2 * m) / g.cols, (H - header - 2 * m) / g.rows))
    local bw, bh = cell * g.cols, cell * g.rows
    return {
        m = m, header = header, cell = cell,
        gx = math.floor((W - bw) / 2),
        gy = header + math.floor((H - header - bh) / 2),
    }
end

function MinesWidget:cellBox(i)
    local L = self.layout
    local r, c = Logic.rc(self.game, i)
    return Geom:new{ x = L.gx + (c - 1) * L.cell, y = L.gy + (r - 1) * L.cell, w = L.cell, h = L.cell }
end

function MinesWidget:cellAt(pos)
    local L, g = self.layout, self.game
    local c = math.floor((pos.x - L.gx) / L.cell) + 1
    local r = math.floor((pos.y - L.gy) / L.cell) + 1
    if r < 1 or c < 1 or r > g.rows or c > g.cols then return nil end
    return Logic.index(g, r, c)
end

function MinesWidget:hit(x, y, w, h, fn)
    self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, fn = fn }
end

-- Painting -------------------------------------------------------------------------------------------

function MinesWidget:renderFrame()
    local W, H = self.dimen.w, self.dimen.h
    if not self.frame then self.frame = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8) end
    local bb = self.frame
    self.hits = {}
    bb:fill(WHITE)
    if self.mode == "game" then
        self:paintHeader(bb)
        self:paintBoard(bb)
        if self.game.done then self:paintWin(bb) end
    else
        self:paintHome(bb)
    end
end

function MinesWidget:paintTo(bb, x, y)
    self:renderFrame()
    binarize(self.frame, self.dimen)
    bb:blitFrom(self.frame, x, y, 0, 0, self.dimen.w, self.dimen.h)
end

-- Letter tiles, alternating solid and outlined; a mine stands in for the I.
function MinesWidget:paintTiles(bb, word, cx, cy, t)
    local gap = math.floor(t * 0.12)
    local x = math.floor(cx - (#word * t + (#word - 1) * gap) / 2)
    for i = 1, #word do
        local solid = i % 2 == 1
        local y = math.floor(cy - t / 2)
        if solid then
            bb:paintRoundedRect(x, y, t, t, BLACK, math.floor(t * 0.18))
        else
            bb:paintBorder(x, y, t, t, math.max(3, math.floor(t * 0.06)), BLACK, math.floor(t * 0.18))
        end
        local ch = word:sub(i, i)
        if ch == "*" then
            mine(bb, x + t / 2, cy, t * 0.9, solid and WHITE or BLACK, solid and BLACK or WHITE)
        else
            textCentered(bb, ch, x + t / 2, cy, t * 0.62, true, solid and WHITE or BLACK)
        end
        x = x + t + gap
    end
end

-- Thumbnail of a board: hidden cells solid, open cells a dot.
local function miniBoard(bb, x, y, w, h, g)
    local cell = math.min(w / g.cols, h / g.rows)
    local s = math.max(1, math.floor(cell * 0.8))
    local d = math.max(2, math.floor(cell * 0.24))
    x = x + (w - cell * g.cols) / 2
    for i = 1, g.rows * g.cols do
        local r, c = Logic.rc(g, i)
        local cx, cy = math.floor(x + (c - 1) * cell), math.floor(y + (r - 1) * cell)
        if Logic.cell(g, i) == "o" then
            bb:paintRect(cx + math.floor((s - d) / 2), cy + math.floor((s - d) / 2), d, d, BLACK)
        else
            bb:paintRect(cx, cy, s, s, BLACK)
        end
    end
end

function MinesWidget:paintHome(bb)
    local W, H = self.dimen.w, self.dimen.h
    local S = math.min(W, H)
    local m = math.floor(S * 0.05)
    local t = math.floor(math.min((S - 2 * m) / 7.5, H * 0.08))
    local y = m + t / 2

    self:paintTiles(bb, "M*NES", W / 2, y, t)
    y = y + t * 0.5
    local wins = setting("wins", 0)
    if wins > 0 then
        local streak = setting("streak", 0)
        local line = wins .. " " .. (wins == 1 and _("board cleared") or _("boards cleared"))
        if streak > 1 then line = line .. "  ·  " .. streak .. " " .. _("in a row") end
        textCentered(bb, line, W / 2, y + t * 0.4, t * 0.32, true)
        y = y + t * 0.6
    end
    closeIcon(bb, W - m, m, math.floor(t * 0.45))
    self:hit(W - m - t, 0, t + m, t + m, function() self:onClose() end)
    y = y + m * 0.8

    local g = self.game
    if g and not g.done and g.bomb then
        local ch = math.floor(t * 1.9)
        local pad = math.floor(ch * 0.12)
        bb:paintRoundedRect(m, y, W - 2 * m, ch, BLACK, 28)
        local th = ch - 2 * pad
        local tw = math.floor(th * g.cols / g.rows)
        bb:paintRoundedRect(m + pad - 6, y + pad - 6, tw + 12, th + 12, WHITE, 12)
        miniBoard(bb, m + pad, y + pad, tw, th, g)
        local tx = m + 2 * pad + tw + pad
        text(bb, g.boom and _("Try again") or _("Continue"), tx, y + ch * 0.3, t * 0.55, true, WHITE)
        text(bb, Logic.diff(g.diff).name .. "  ·  " .. Logic.size(g.size).name, tx, y + ch * 0.58, t * 0.36, false, WHITE)
        local left = g.mines - Logic.flags(g)
        mine(bb, tx + t * 0.18, y + ch * 0.8, t * 0.38, WHITE, BLACK)
        text(bb, tostring(left), tx + t * 0.45, y + ch * 0.8, t * 0.34, true, WHITE)
        self:hit(m, y, W - 2 * m, ch, function() self:startGame() end)
        y = y + ch + m * 0.8
    end

    -- Difficulty: one segmented pill, the chosen part filled.
    local diff = setting("diff", "normal")
    local ph = math.floor(t * 0.9)
    local pw = W - 2 * m
    bb:paintBorder(m, y, pw, ph, 4, BLACK, math.floor(ph / 2))
    local sw = pw / #Logic.DIFFS
    for k, d in ipairs(Logic.DIFFS) do
        local sx = math.floor(m + (k - 1) * sw)
        local on = d.key == diff
        if on then bb:paintRoundedRect(sx, y, math.floor(sw), ph, BLACK, math.floor(ph / 2)) end
        textCentered(bb, d.name, sx + sw / 2, y + ph / 2, t * 0.38, true, on and WHITE or BLACK)
        self:hit(sx, y, math.floor(sw), ph, function()
            G_reader_settings:saveSetting("minesweeper_diff", d.key)
            UIManager:setDirty(self, "ui")
        end)
    end
    y = y + ph + m * 0.7

    -- Sizes: a board-shaped card each, its grid drawn to scale, best time underneath.
    local best = setting("best", {})
    local gap = math.floor(m * 0.4)
    local cw = math.floor((W - 2 * m - 3 * gap) / 4)
    local chh = math.floor(cw * 1.45)
    for k, size in ipairs(Logic.SIZES) do
        local cx = m + (k - 1) * (cw + gap)
        bb:paintBorder(cx, y, cw, chh, 4, BLACK, 20)
        local gw = cw * 0.62
        local cell = gw / size.cols
        local gx, gy = cx + (cw - gw) / 2, y + cw * 0.18
        for r = 0, size.rows do
            bb:paintRect(math.floor(gx), math.floor(gy + r * cell), math.floor(gw), 2, BLACK)
        end
        for c = 0, size.cols do
            bb:paintRect(math.floor(gx + c * cell), math.floor(gy), 2, math.floor(cell * size.rows), BLACK)
        end
        local ly = gy + cell * size.rows + (y + chh - gy - cell * size.rows) * 0.38
        textCentered(bb, size.name, cx + cw / 2, ly, t * 0.36, true)
        local b = best[size.key .. "_" .. diff]
        textCentered(bb, b and (_("Best") .. " " .. clock(b)) or (size.cols .. "×" .. size.rows), cx + cw / 2, ly + t * 0.42,
            t * 0.28, false)
        self:hit(cx, y, cw, chh, function() self:newGame(size.key) end)
    end
    y = y + chh + m * 0.6

    local rh = math.floor(t * 0.8)
    local on = setting("logical", true)
    text(bb, _("No guessing"), m, y + rh / 2, t * 0.4, false)
    switch(bb, W - m - math.floor(t), math.floor(y + rh / 2), math.floor(t), on)
    self:hit(0, y, W, rh, function()
        G_reader_settings:saveSetting("minesweeper_logical", not on)
        UIManager:setDirty(self, "ui")
    end)
    bb:paintRect(m, y + rh, W - 2 * m, 2, BLACK)
    y = y + rh + m

    -- How to play, as glyph rows.
    local gs = t * 0.55
    local rows = {
        { function(x, cy) shovel(bb, x, cy, gs, BLACK) end, _("Tap to dig") },
        { function(x, cy) flag(bb, x, cy, gs, BLACK) end, _("Hold to flag") },
        { function(x, cy) textCentered(bb, "3", x, cy, gs * 0.8, true) end, _("Tap a number to clear around it") },
    }
    for _, row in ipairs(rows) do
        if y + gs > H - m then break end
        row[1](m + gs / 2, y + gs / 2)
        text(bb, row[2], m + gs * 1.4, y + gs / 2, t * 0.32, false)
        y = y + gs * 1.25
    end
end

function MinesWidget:paintHeader(bb)
    local g, L = self.game, self.layout
    local W, h = self.dimen.w, L.header
    local cy = h * 0.5
    local pen = math.max(3, math.floor(h * 0.03))
    chevron(bb, L.m + h * 0.15, cy, h * 0.18, pen)
    self:hit(0, 0, L.m + h, h, function() self:goHome() end)

    if g.boom then
        -- Lost: the header turns into the choices, the board stays readable below.
        local bw, bh = math.floor(W * 0.25), math.floor(h * 0.62)
        local x = L.m + h
        bb:paintRoundedRect(x, cy - bh / 2, bw, bh, BLACK, math.floor(bh / 2))
        textCentered(bb, _("Undo"), x + bw / 2, cy, h * 0.28, true, WHITE)
        self:hit(x, 0, bw, h, function() self:move(Logic.undo(g), true) end)
        x = x + bw + L.m * 0.6
        bb:paintBorder(x, cy - bh / 2, bw, bh, 4, BLACK, math.floor(bh / 2))
        textCentered(bb, _("New game"), x + bw / 2, cy, h * 0.28, true)
        self:hit(x, 0, bw, h, function() self:newGame(g.size) end)
        mine(bb, W - L.m - h * 0.35, cy, h * 0.6, BLACK, WHITE)
        return
    end

    local left = g.mines - Logic.flags(g)
    local mx = W / 2 - h * 0.6
    mine(bb, mx, cy, h * 0.55, BLACK, WHITE)
    text(bb, tostring(left), mx + h * 0.4, cy, h * 0.38, true)

    -- Dig/flag toggle: what a tap does, the active half filled.
    local tw, th = math.floor(h * 1.7), math.floor(h * 0.64)
    local tx, ty = math.floor(W - L.m - tw - h * 0.9), math.floor(cy - th / 2)
    bb:paintBorder(tx, ty, tw, th, 4, BLACK, math.floor(th / 2))
    local half = math.floor(tw / 2)
    local fx = self.flagging and tx + half or tx
    bb:paintRoundedRect(fx, ty, half, th, BLACK, math.floor(th / 2))
    shovel(bb, tx + half / 2, cy, th * 0.7, self.flagging and BLACK or WHITE)
    flag(bb, tx + half * 1.5, cy, th * 0.7, self.flagging and WHITE or BLACK)
    self:hit(tx, 0, tw, h, function()
        self.flagging = not self.flagging
        self:showBoxes({ Geom:new{ x = tx - 4, y = ty - 4, w = tw + 8, h = th + 8 } })
    end)

    if g.bomb and not g.done then
        local bx = W - L.m - h * 0.35
        bulb(bb, bx, cy, h * 0.6, BLACK, WHITE)
        self:hit(bx - h * 0.5, 0, W - bx + h * 0.5, h, function() self:hint() end)
    end
end

-- One hatched tile (45° lines on white), built once per cell size and blitted for every hidden cell:
-- per-row hatching for a whole board was hundreds of thousands of paintRect calls.
function MinesWidget:hatchTile(side)
    if self.hatch and self.hatch_side == side then return self.hatch end
    if self.hatch then self.hatch:free() end
    local tile = Blitbuffer.new(side, side, Blitbuffer.TYPE_BB8)
    tile:fill(WHITE)
    local step = math.max(6, math.floor(side * 0.32 + 0.5))
    local w = math.max(1, math.floor(side * 0.035 + 0.5))
    for y = 0, side - 1 do
        for x = (step - y % step) % step, side - 1, step do
            tile:paintRect(x, y, math.min(w, side - x), 1, BLACK)
        end
    end
    self.hatch, self.hatch_side = tile, side
    return tile
end

function MinesWidget:paintBoard(bb)
    local g, L = self.game, self.layout
    local cell = L.cell
    local gap = math.max(2, math.floor(cell * 0.07))
    local side = cell - 2 * gap
    local px = cell * 0.58
    local lost = g.boom ~= nil
    local hatch = self:hatchTile(side)

    -- Tiny dots along every grid line; tiles cover them, so they show in the gaps and the open area.
    local dot = math.max(2, math.floor(cell * 0.025))
    local step = cell / 5
    for r = 0, g.rows do
        local y = math.floor(L.gy + r * cell - dot / 2)
        for k = 0, g.cols * 5 do
            bb:paintRect(math.floor(L.gx + k * step - dot / 2), y, dot, dot, BLACK)
        end
    end
    for c = 0, g.cols do
        local x = math.floor(L.gx + c * cell - dot / 2)
        for k = 0, g.rows * 5 do
            bb:paintRect(x, math.floor(L.gy + k * step - dot / 2), dot, dot, BLACK)
        end
    end

    for i = 1, g.rows * g.cols do
        local b = self:cellBox(i)
        local cx, cy = b.x + cell / 2, b.y + cell / 2
        local s = Logic.cell(g, i)
        local is_mine = g.bomb and g.bomb[i]
        if s == "o" and i == g.boom then
            bb:paintRect(b.x + gap, b.y + gap, side, side, BLACK)
            mine(bb, cx, cy, cell * 0.8, WHITE, BLACK)
        elseif s == "o" then
            local n = Logic.count(g, i)
            if n > 0 then textCentered(bb, tostring(n), cx, cy, px, true) end
        elseif lost and is_mine and s ~= "f" then
            mine(bb, cx, cy, cell * 0.7, BLACK, WHITE)
        elseif s == "f" then
            flag(bb, cx, cy, cell * 0.72, BLACK)
            if lost and not is_mine then closeIcon(bb, cx, cy, cell * 0.8) end
        else
            bb:blitFrom(hatch, b.x + gap, b.y + gap, 0, 0, side, side)
            if i == g.hint then
                capsule(bb, cx, cy, cx, cy, cell * 0.24, WHITE)
                capsule(bb, cx, cy, cx, cy, cell * 0.16, BLACK)
            end
        end
    end
end

function MinesWidget:paintWin(bb)
    local W, H = self.dimen.w, self.dimen.h
    local g = self.game
    local rnd = Logic.rng(g.seed or 1)
    for _ = 1, 60 do
        local x, y, s = rnd(W), rnd(H), 6 + rnd(16)
        if rnd(2) == 1 then
            capsule(bb, x, y, x, y, s, BLACK)
        else
            bb:paintRect(x, y, s * 2, s, BLACK)
        end
    end
    local S = math.min(W, H)
    local pw, ph = math.floor(S * 0.86), math.floor(S * 0.8)
    local px, py = math.floor((W - pw) / 2), math.floor((H - ph) / 2)
    bb:paintRoundedRect(px - 10, py - 10, pw + 20, ph + 20, WHITE, 44)
    bb:paintBorder(px, py, pw, ph, 8, BLACK, 36)
    local t = math.floor(pw / 8.5)
    local y = py + ph * 0.15
    self:paintTiles(bb, "CLEAR", W / 2, y, t)

    local stars = Logic.stars(g)
    local ss = math.floor(t * 1.05)
    y = y + t * 0.85
    for i = 1, 3 do
        local icon = IconWidget:new{ icon = i <= stars and "star.full" or "star.empty", width = ss, height = ss }
        icon:paintTo(bb, math.floor(W / 2 + (i - 2) * ss * 1.15 - ss / 2), math.floor(y))
        icon:free()
    end
    y = y + ss + t * 0.45
    textCentered(bb, clock(g.elapsed or 0), W / 2, y, t * 0.75, true)
    y = y + t * 0.7
    local note = Logic.diff(g.diff).name .. "  ·  " .. Logic.size(g.size).name
    if g.record then note = _("New best!") .. "  ·  " .. note end
    textCentered(bb, note, W / 2, y, t * 0.36, g.record, BLACK)

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

-- State ----------------------------------------------------------------------------------------------

function MinesWidget:tick()
    if not self.started then return end
    local now = os.time()
    self.game.elapsed = (self.game.elapsed or 0) + now - self.started
    self.started = now
end

function MinesWidget:save()
    if not self.game then return end
    self:tick()
    G_reader_settings:saveSetting(SAVE_KEY, self.game)
end

function MinesWidget:startGame()
    self.mode = "game"
    self.layout = self:gameLayout()
    self:resumeClock()
    UIManager:setDirty(self, "ui")
end

function MinesWidget:resumeClock()
    local g = self.game
    self.started = (g.bomb and not g.done and not g.boom) and os.time() or nil
end

function MinesWidget:newGame(size_key)
    self.game = Logic.new(size_key, setting("diff", "normal"), os.time())
    self.flagging = false
    self:save()
    self:startGame()
end

function MinesWidget:goHome()
    self:save()
    self.started = nil
    self.mode = "home"
    UIManager:setDirty(self, "ui")
end

function MinesWidget:finish()
    local g = self.game
    self:tick()
    self.started = nil
    if g.done then
        local key = g.size .. "_" .. g.diff
        local best = setting("best", {})
        if not best[key] or g.elapsed < best[key] then
            best[key] = g.elapsed
            g.record = true
            G_reader_settings:saveSetting("minesweeper_best", best)
        end
        G_reader_settings:saveSetting("minesweeper_wins", setting("wins", 0) + 1)
        G_reader_settings:saveSetting("minesweeper_streak", setting("streak", 0) + 1)
    else
        G_reader_settings:saveSetting("minesweeper_streak", 0)
    end
end

-- Applies a move's changed cells: header always, the cells' box, or a full repaint on game end.
function MinesWidget:move(changed, force)
    local g = self.game
    if #changed == 0 and not force then return end
    if g.hint and Logic.cell(g, g.hint) ~= "h" then g.hint = nil end
    local was_live = self.started ~= nil
    if g.done or g.boom then
        if was_live then self:finish() end
    elseif not self.started and g.bomb then
        self:resumeClock()
    end
    if g.done then
        UIManager:setDirty(self, "ui")
    else
        local box = Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.layout.header }
        for _, i in ipairs(changed) do box = box:combine(self:cellBox(i)) end
        if g.boom then
            -- Every mine shows: repaint the whole board area.
            box = self.dimen
        end
        self:showBoxes({ box })
    end
    self:save()
    UIManager:scheduleIn(0.3, function() G_reader_settings:flush() end)
end

function MinesWidget:hint()
    local g = self.game
    local i = Logic.hint(g)
    if not i then return end
    g.hints = g.hints + 1
    local old = g.hint
    g.hint = i
    self:move(old and { i, old } or { i })
end

function MinesWidget:isOnTop()
    local stack = UIManager._window_stack
    return stack[#stack] and stack[#stack].widget == self
end

-- Copies boxes of a fresh frame to the screen and refreshes each with DU.
function MinesWidget:showBoxes(boxes)
    if not self:isOnTop() then
        UIManager:setDirty(self, "ui")
        return
    end
    self:renderFrame()
    for _, box in ipairs(boxes) do
        box = box:intersect(self.dimen)
        if box.w > 0 and box.h > 0 then
            binarize(self.frame, box)
            Screen.bb:blitFrom(self.frame, box.x, box.y, box.x, box.y, box.w, box.h)
            Screen:refreshFast(box.x, box.y, box.w, box.h)
        end
    end
end

-- Touch ----------------------------------------------------------------------------------------------

function MinesWidget:act(pos, flagging)
    local g = self.game
    local i = self:cellAt(pos)
    if not i then return false end
    local s = Logic.cell(g, i)
    if s == "o" then
        self:move(Logic.chord(g, i))
    elseif flagging then
        self:move(Logic.flag(g, i))
    elseif s == "h" then
        self:move(Logic.dig(g, i, setting("logical", true)))
    end
    return true
end

function MinesWidget:onTap(pos)
    for k = #self.hits, 1, -1 do
        local h = self.hits[k]
        if pos.x >= h.x and pos.x < h.x + h.w and pos.y >= h.y and pos.y < h.y + h.h then
            h.fn()
            return true
        end
    end
    if self.mode == "game" and not self.game.done then self:act(pos, self.flagging) end
    return true
end

function MinesWidget:onHold(pos)
    -- Hold always marks or unmarks, whatever the toggle says.
    if self.mode == "game" and not self.game.done then self:act(pos, true) end
    return true
end

function MinesWidget:onFlushSettings()
    self:save()
end

function MinesWidget:onClose()
    UIManager:close(self, "ui")
    return true
end

function MinesWidget:onCloseWidget()
    self:save()
    if self.frame then
        self.frame:free()
        self.frame = nil
    end
    if self.hatch then
        self.hatch:free()
        self.hatch = nil
    end
end

local Minesweeper = WidgetContainer:extend{
    name = "minesweeper",
}

function Minesweeper:init()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
end

-- Looks the page up by flag, not by a module field: `ink reload` swaps the module.
function Minesweeper:open()
    for _, w in ipairs(UIManager._window_stack) do
        if w.widget.is_minesweeper then return w.widget end
    end
    local widget = MinesWidget:new{}
    UIManager:show(widget, "ui")
    return widget
end

function Minesweeper:addToMainMenu(menu_items)
    menu_items.minesweeper = {
        text = _("Minesweeper"),
        sorting_hint = "tools",
        callback = function() self:open() end,
    }
end

return Minesweeper
