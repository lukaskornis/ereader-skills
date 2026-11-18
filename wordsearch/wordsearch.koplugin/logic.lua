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
-- Reads like a book: left to right or top to bottom.
local EASY = { { 0, 1 }, { 1, 0 } }
local HARD_STRAIGHT = { { 0, -1 }, { -1, 0 } }
local HARD_ALL = { { 0, -1 }, { -1, 0 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } }
-- Unlisted theme words hidden on every board.
Logic.BONUS = 2
-- Share of listed words, the shortest, laid the easy way so the first finds come fast.
Logic.EASY_SHARE = 0.4
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

-- Every place word reads out of cells (nil cells never match), along any of the eight lines. A
-- palindrome reads both ways along the same cells, so only half the lines count for it.
local function occurrences(cells, n, word)
    local len, first = #word, word:sub(1, 1)
    local dirs = word == word:reverse() and { ALL[1], ALL[2], ALL[5], ALL[7] } or ALL
    local found = {}
    for r = 1, n do
        for c = 1, n do
            if cells[(r - 1) * n + c] == first then
                for _, d in ipairs(dirs) do
                    local r2, c2 = r + d[1] * (len - 1), c + d[2] * (len - 1)
                    if r2 >= 1 and r2 <= n and c2 >= 1 and c2 <= n then
                        local k = 2
                        while k <= len and cells[(r + d[1] * (k - 1) - 1) * n + c + d[2] * (k - 1)] == word:sub(k, k) do
                            k = k + 1
                        end
                        if k > len then found[#found + 1] = { r, c, d[1], d[2] } end
                    end
                end
            end
        end
    end
    return found
end

local function anyRepeat(cells, n, words)
    for _, w in ipairs(words) do
        local occ = occurrences(cells, n, w.w)
        if #occ > 1 then return w, occ end
    end
end

-- Starts of listed words written into free lines, so the eye catches on near misses. Each is dropped
-- again if it completes a second copy of any listed word.
local function placeDecoys(cells, n, words, dirs, rnd)
    local long = {}
    for _, w in ipairs(words) do
        if #w.w >= 4 then long[#long + 1] = w.w end
    end
    if #long == 0 then return end
    for _ = 1, 2 + rnd(4) do
        local word = long[rnd(#long)]
        local part = word:sub(1, math.min(#word - 1, 2 + rnd(3)))
        local before = {}
        for k, v in pairs(cells) do before[k] = v end
        if tryPlace(cells, n, part, dirs, rnd) and anyRepeat(cells, n, words) then
            for k in pairs(cells) do cells[k] = before[k] end
        end
    end
end

-- Places word and adds it to hidden (every word on the board), or undoes it when it would make some
-- hidden word read twice: a word inside another (RED in REDWOOD), or one crossing into a copy.
local function placeUnique(cells, n, word, dirs, all, rnd, hidden)
    local before = {}
    for i, v in pairs(cells) do before[i] = v end
    -- A crowded board may have no room in the preferred directions; any direction beats a missing word.
    local placed = tryPlace(cells, n, word, dirs, rnd) or (dirs ~= all and tryPlace(cells, n, word, all, rnd))
    if not placed then return nil end
    hidden[#hidden + 1] = placed
    if anyRepeat(cells, n, hidden) then
        hidden[#hidden] = nil
        for i in pairs(cells) do cells[i] = before[i] end
        return nil
    end
    return placed
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
    local first_easy = #candidates - math.ceil(#candidates * Logic.EASY_SHARE) + 1
    for i = size.words + 1, #pool do candidates[#candidates + 1] = pool[i] end

    local cells = {}
    local all = diagonals and ALL or STRAIGHT
    local hard = diagonals and HARD_ALL or HARD_STRAIGHT
    local words, hidden, used = {}, {}, {}
    for k, w in ipairs(candidates) do
        if #words >= size.words then break end
        local dirs = k > size.words and all or k >= first_easy and EASY or hard
        local placed = placeUnique(cells, n, w, dirs, all, rnd, hidden)
        if placed then
            words[#words + 1] = placed
            used[w] = true
        end
    end
    table.sort(words, function(a, b) return a.w < b.w end)
    -- Theme words that are hidden but not listed: a reward for whoever spots them.
    local bonus = {}
    for _, w in ipairs(candidates) do
        if #bonus >= Logic.BONUS then break end
        if not used[w] then bonus[#bonus + 1] = placeUnique(cells, n, w, all, all, rnd, hidden) end
    end
    placeDecoys(cells, n, hidden, all, rnd)

    local letters = {}
    for i = 1, n * n do
        local k = rnd(#FILL)
        letters[i] = cells[i] or FILL:sub(k, k)
    end
    -- Filler can spell a listed word a second time; the fixed cells never do, so a copy always holds
    -- a filler cell to change.
    while true do
        local w, occ = anyRepeat(letters, n, hidden)
        if not w then break end
        local spot
        for _, o in ipairs(occ) do
            for k = 0, #w.w - 1 do
                local i = (o[1] + o[3] * k - 1) * n + o[2] + o[4] * k
                if not cells[i] then spot = i break end
            end
            if spot then break end
        end
        local k = rnd(#FILL)
        letters[spot] = FILL:sub(k, k)
    end
    return {
        size = size_key, n = n, theme = theme.name, diagonals = diagonals and true or false,
        letters = table.concat(letters), words = words, bonus = bonus, elapsed = 0, done = false, seed = seed,
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

-- The unfound word, listed or bonus, whose ends best match a stroke from (sx, sy) to (ex, ey), in
-- cell units, either way round. A stroke may start or stop a cell or two off the ends; longer words
-- forgive more. Returns the word and whether it is a bonus word.
function Logic.snap(game, sx, sy, ex, ey)
    if dist(sx, sy, ex, ey) < 0.6 then return nil end
    local best, best_score, best_bonus
    for pass, list in ipairs({ game.words, game.bonus or {} }) do
        for _, w in ipairs(list) do
            if not w.found then
                local ax, ay, bx, by = w.c1 - 0.5, w.r1 - 0.5, w.c2 - 0.5, w.r2 - 0.5
                local score = math.min(dist(sx, sy, ax, ay) + dist(ex, ey, bx, by),
                    dist(sx, sy, bx, by) + dist(ex, ey, ax, ay))
                local limit = math.max(1.6, 0.3 * #w.w)
                if score <= limit and (not best_score or score < best_score) then
                    best, best_score, best_bonus = w, score, pass == 2
                end
            end
        end
    end
    return best, best_bonus
end

function Logic.bonusFound(game)
    local found = 0
    for _, w in ipairs(game.bonus or {}) do
        if w.found then found = found + 1 end
    end
    return found
end

-- How far a fitted stroke may wander off the word's centre line, in cells.
Logic.MAX_WOBBLE = 0.22
local PATH_POINTS = 24

-- Fits a drawn stroke (points in cell units, in drawing order) onto word w, keeping its shape: each
-- point becomes (t along the word from r1,c1 to r2,c2, signed offset d across it). The stroke's own
-- ends map onto the word's ends, and the wobble is scaled down only as far as needed to stay on the
-- word. Returns a flat list t1, d1, t2, d2, ...; nil for a stroke too short to have a shape.
function Logic.fitStroke(pts, w)
    local n = #pts
    if n < 2 then return nil end
    local sx, sy, ex, ey = pts[1][1], pts[1][2], pts[n][1], pts[n][2]
    local ux, uy = ex - sx, ey - sy
    local len2 = ux * ux + uy * uy
    if len2 < 0.09 then return nil end
    local len = math.sqrt(len2)
    -- Drawn from the word's far end: walk the word backwards.
    local ax, ay, bx, by = w.c1 - 0.5, w.r1 - 0.5, w.c2 - 0.5, w.r2 - 0.5
    local reversed = dist(sx, sy, bx, by) + dist(ex, ey, ax, ay) < dist(sx, sy, ax, ay) + dist(ex, ey, bx, by)
    local raw, max_d = {}, 0
    local step = math.max(1, (n - 1) / (PATH_POINTS - 1))
    local i = 1
    while true do
        local k = math.min(n, math.floor(i + 0.5))
        local px, py = pts[k][1] - sx, pts[k][2] - sy
        local t = math.max(0, math.min(1, (px * ux + py * uy) / len2))
        local d = (px * uy - py * ux) / len
        if reversed then t, d = 1 - t, -d end
        raw[#raw + 1] = { t, d }
        max_d = math.max(max_d, math.abs(d))
        if k == n then break end
        i = i + step
    end
    local scale = max_d > Logic.MAX_WOBBLE and Logic.MAX_WOBBLE / max_d or 1
    if reversed then
        local flipped = {}
        for j = #raw, 1, -1 do flipped[#flipped + 1] = raw[j] end
        raw = flipped
    end
    local out = {}
    for _, p in ipairs(raw) do
        out[#out + 1] = math.floor(p[1] * 1000 + 0.5) / 1000
        out[#out + 1] = math.floor(p[2] * scale * 1000 + 0.5) / 1000
    end
    return out
end

-- Points of a found word's line in cell units, from just before its first letter to just after its
-- last; follows the saved stroke shape when there is one, else a straight line.
function Logic.strokePoints(w, over)
    local ax, ay, bx, by = w.c1 - 0.5, w.r1 - 0.5, w.c2 - 0.5, w.r2 - 0.5
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    local ux, uy = dx / len, dy / len
    ax, ay, bx, by = ax - ux * over, ay - uy * over, bx + ux * over, by + uy * over
    dx, dy = bx - ax, by - ay
    local path = w.path or { 0, 0, 1, 0 }
    local pts = {}
    for j = 1, #path - 1, 2 do
        local t, d = path[j], path[j + 1]
        -- Normal (-uy, ux) matches fitStroke's sign of d.
        pts[#pts + 1] = { ax + dx * t - uy * d, ay + dy * t + ux * d }
    end
    return pts
end

return Logic
