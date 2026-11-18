--[[
Word search rules with no KOReader dependency, so they run under plain LuaJIT on the Mac
(`luajit wordsearch/logic_test.lua`). Rows and columns are 1-based; a point in "cell units" has the
centre of cell (r, c) at (c - 0.5, r - 0.5).
]]
local Logic = {}

Logic.SIZES = {
    { key = "small", name = "Small", n = 8, words = 6 },
    { key = "medium", name = "Medium", n = 11, words = 10 },
    { key = "big", name = "Big", n = 14, words = 15 },
    { key = "huge", name = "Huge", n = 18, words = 22 },
}

local STRAIGHT = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }
local ALL = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } }
-- Filler weighted by English letter frequency, so the noise looks like words and hides the answers.
local FILL = "EEEEEEEEEEEETTTTTTTTTAAAAAAAAOOOOOOOIIIIIIINNNNNNNSSSSSSHHHHHHRRRRRRDDDDLLLLCCCUUUMMMWWFFGGYYPPBBVKJXQZ"
local PLACE_TRIES = 300

function Logic.size(key)
    for _, s in ipairs(Logic.SIZES) do
        if s.key == key then return s end
    end
    error("unknown board size " .. tostring(key))
end

-- Park-Miller: exact in doubles, so the same seed gives the same board on every device.
function Logic.rng(seed)
    local s = seed % 2147483646 + 1
    return function(n)
        s = s * 16807 % 2147483647
        return s % n + 1
    end
end

local function shuffle(t, rnd)
    for i = #t, 2, -1 do
        local j = rnd(i)
        t[i], t[j] = t[j], t[i]
    end
end

local function tryPlace(cells, n, word, dirs, rnd)
    local len = #word
    for _ = 1, PLACE_TRIES do
        local d = dirs[rnd(#dirs)]
        local dr, dc = d[1], d[2]
        local r, c = rnd(n), rnd(n)
        local r2, c2 = r + dr * (len - 1), c + dc * (len - 1)
        if r2 >= 1 and r2 <= n and c2 >= 1 and c2 <= n then
            local fits = true
            for i = 0, len - 1 do
                local cell = cells[(r + dr * i - 1) * n + c + dc * i]
                if cell and cell ~= word:sub(i + 1, i + 1) then
                    fits = false
                    break
                end
            end
            if fits then
                for i = 0, len - 1 do
                    cells[(r + dr * i - 1) * n + c + dc * i] = word:sub(i + 1, i + 1)
                end
                return { w = word, r1 = r, c1 = c, r2 = r2, c2 = c2, found = false }
            end
        end
    end
end

-- Returns a game table, plain data only so it can be saved in KOReader's settings as is.
function Logic.generate(themes, size_key, diagonals, seed, avoid_theme)
    local size = Logic.size(size_key)
    local n = size.n
    local rnd = Logic.rng(seed)
    local ti = rnd(#themes)
    if themes[ti].name == avoid_theme then ti = ti % #themes + 1 end
    local theme = themes[ti]
    local pool = {}
    for _, w in ipairs(theme.words) do
        if #w <= n then pool[#pool + 1] = w end
    end
    shuffle(pool, rnd)
    -- Longest first fits best; the rest of the pool backs up words that found no room.
    local candidates = {}
    for i = 1, math.min(#pool, size.words) do candidates[i] = pool[i] end
    table.sort(candidates, function(a, b) return #a > #b end)
    for i = size.words + 1, #pool do candidates[#candidates + 1] = pool[i] end

    local cells = {}
    local dirs = diagonals and ALL or STRAIGHT
    local words = {}
    for _, w in ipairs(candidates) do
        if #words >= size.words then break end
        local placed = tryPlace(cells, n, w, dirs, rnd)
        if placed then words[#words + 1] = placed end
    end
    table.sort(words, function(a, b) return a.w < b.w end)

    local letters = {}
    for i = 1, n * n do
        local k = rnd(#FILL)
        letters[i] = cells[i] or FILL:sub(k, k)
    end
    return {
        size = size_key, n = n, theme = theme.name, diagonals = diagonals and true or false,
        letters = table.concat(letters), words = words, elapsed = 0, done = false, seed = seed,
    }
end

function Logic.letter(game, r, c)
    local i = (r - 1) * game.n + c
    return game.letters:sub(i, i)
end

function Logic.remaining(game)
    local left = 0
    for _, w in ipairs(game.words) do
        if not w.found then left = left + 1 end
    end
    return left
end

local function dist(x1, y1, x2, y2)
    return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

-- The unfound word whose ends best match a stroke from (sx, sy) to (ex, ey), in cell units, either
-- way round. A stroke may start or stop a cell or two off the ends; longer words forgive more.
function Logic.snap(game, sx, sy, ex, ey)
    if dist(sx, sy, ex, ey) < 0.6 then return nil end
    local best, best_score
    for i, w in ipairs(game.words) do
        if not w.found then
            local ax, ay, bx, by = w.c1 - 0.5, w.r1 - 0.5, w.c2 - 0.5, w.r2 - 0.5
            local score = math.min(dist(sx, sy, ax, ay) + dist(ex, ey, bx, by),
                dist(sx, sy, bx, by) + dist(ex, ey, ax, ay))
            local limit = math.max(1.6, 0.3 * #w.w)
            if score <= limit and (not best_score or score < best_score) then
                best, best_score = i, score
            end
        end
    end
    return best
end

-- The end cell of a stroke from cell (r, c) towards point (ex, ey), on the nearest allowed line.
function Logic.lineEnd(game, r, c, ex, ey)
    local dx, dy = ex - (c - 0.5), ey - (r - 0.5)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.5 then return r, c end
    local step = game.diagonals and math.pi / 4 or math.pi / 2
    local angle = math.floor(math.atan2(dy, dx) / step + 0.5) * step
    local ux, uy = math.floor(math.cos(angle) + 0.5), math.floor(math.sin(angle) + 0.5)
    local k = math.floor(((ux ~= 0 and uy ~= 0) and len / math.sqrt(2) or len) + 0.5)
    local n = game.n
    while k > 0 do
        local r2, c2 = r + uy * k, c + ux * k
        if r2 >= 1 and r2 <= n and c2 >= 1 and c2 <= n then return r2, c2 end
        k = k - 1
    end
    return r, c
end

return Logic
