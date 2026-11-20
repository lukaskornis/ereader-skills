--[[
Minesweeper rules with no KOReader dependency, so the Mac can test them with luajit.

A game is a plain table (saved as is in G_reader_settings):
  size, diff, rows, cols, mines (count), seed
  bomb   cell index -> true, filled on the first dig so the first cell is always an opening
  state  string of one char per cell: "h" hidden, "o" open, "f" flagged
  boom   index of the mine that ended the game, done (won), undos, hints, elapsed, logical
Cells are indexed (r - 1) * cols + c.
]]
local Logic = {}

-- Portrait shapes (about 3:4, the panel's own); the layout swaps rows and columns in landscape.
Logic.SIZES = {
    { key = "small", name = "Small", cols = 8, rows = 10 },
    { key = "medium", name = "Medium", cols = 11, rows = 14 },
    { key = "big", name = "Big", cols = 14, rows = 18 },
    { key = "huge", name = "Huge", cols = 17, rows = 22 },
}

Logic.DIFFS = {
    { key = "easy", name = "Easy", density = 0.12 },
    { key = "normal", name = "Normal", density = 0.16 },
    { key = "hard", name = "Hard", density = 0.20 },
}

local function find(list, key)
    for _, v in ipairs(list) do
        if v.key == key then return v end
    end
    return list[1]
end

function Logic.size(key) return find(Logic.SIZES, key) end
function Logic.diff(key) return find(Logic.DIFFS, key) end

function Logic.rng(seed)
    local s = seed % 2147483646 + 1
    return function(n)
        s = s * 16807 % 2147483647
        return s % n + 1
    end
end

function Logic.new(size_key, diff_key, seed)
    local size, diff = Logic.size(size_key), Logic.diff(diff_key)
    local cells = size.rows * size.cols
    return {
        size = size.key, diff = diff.key, rows = size.rows, cols = size.cols,
        mines = math.floor(cells * diff.density + 0.5),
        seed = seed, state = string.rep("h", cells), undos = 0, hints = 0, elapsed = 0,
    }
end

function Logic.index(g, r, c) return (r - 1) * g.cols + c end
function Logic.rc(g, i) return math.floor((i - 1) / g.cols) + 1, (i - 1) % g.cols + 1 end

-- Neighbour indices of cell i, written into `out` (reused to keep the solver allocation-free).
local function neighbours(g, i, out)
    local r, c = Logic.rc(g, i)
    local n = 0
    for dr = -1, 1 do
        for dc = -1, 1 do
            local rr, cc = r + dr, c + dc
            if (dr ~= 0 or dc ~= 0) and rr >= 1 and rr <= g.rows and cc >= 1 and cc <= g.cols then
                n = n + 1
                out[n] = (rr - 1) * g.cols + cc
            end
        end
    end
    return n
end
Logic.neighbours = neighbours

function Logic.count(g, i)
    local nb = {}
    local k = 0
    for j = 1, neighbours(g, i, nb) do
        if g.bomb[nb[j]] then k = k + 1 end
    end
    return k
end

function Logic.cell(g, i) return g.state:sub(i, i) end

local function setCells(g, list, ch)
    if #list == 0 then return end
    local s = {}
    for k = 1, #g.state do s[k] = g.state:sub(k, k) end
    for _, i in ipairs(list) do s[i] = ch end
    g.state = table.concat(s)
end

-- Random mines anywhere but the 3 x 3 around the first dig, so it always opens an area.
local function place(g, first, rnd)
    local keep = { [first] = true }
    local nb = {}
    for j = 1, neighbours(g, first, nb) do keep[nb[j]] = true end
    local pool = {}
    for i = 1, g.rows * g.cols do
        if not keep[i] then pool[#pool + 1] = i end
    end
    local bomb = {}
    for k = 1, math.min(g.mines, #pool) do
        local j = k + rnd(#pool - k + 1) - 1
        pool[k], pool[j] = pool[j], pool[k]
        bomb[pool[k]] = true
    end
    return bomb
end

-- Solver ---------------------------------------------------------------------------------------------
-- Plays from the given open cells using only what a player can see: single-cell counts, then
-- the subset rule between two numbers, then the total mine count. Returns the open set it
-- reached and whether every safe cell got opened, i.e. the board needs no guess.

local function solve(g, open)
    local cells = g.rows * g.cols
    local mine = {}
    local nb = {}
    local safe_left = cells - g.mines
    local opened = 0
    for _ in pairs(open) do opened = opened + 1 end

    local queue = {}
    local function openCell(i)
        if open[i] or mine[i] then return end
        open[i] = true
        opened = opened + 1
        queue[#queue + 1] = i
    end
    -- Zeros cascade like they do for the player.
    local function flood()
        while #queue > 0 do
            local i = table.remove(queue)
            if Logic.count(g, i) == 0 then
                local tmp = {}
                for j = 1, neighbours(g, i, tmp) do openCell(tmp[j]) end
            end
        end
    end
    for i in pairs(open) do queue[#queue + 1] = i end
    flood()

    local progress = true
    while progress and opened < safe_left do
        progress = false
        -- Constraints from open numbers that still touch hidden cells.
        local cons = {}
        for i in pairs(open) do
            local need = Logic.count(g, i)
            local hidden = {}
            for j = 1, neighbours(g, i, nb) do
                local q = nb[j]
                if mine[q] then
                    need = need - 1
                elseif not open[q] then
                    hidden[#hidden + 1] = q
                end
            end
            if #hidden > 0 then cons[#cons + 1] = { need = need, cells = hidden } end
        end
        for _, k in ipairs(cons) do
            if k.need == 0 then
                for _, q in ipairs(k.cells) do openCell(q) progress = true end
            elseif k.need == #k.cells then
                for _, q in ipairs(k.cells) do
                    if not mine[q] then mine[q] = true progress = true end
                end
            end
        end
        flood()
        if not progress then
            -- Subset rule: A's cells inside B's, so B's extra cells hold B.need - A.need mines.
            for a = 1, #cons do
                local A = cons[a]
                local inA = {}
                for _, q in ipairs(A.cells) do inA[q] = true end
                for b = 1, #cons do
                    local B = cons[b]
                    if a ~= b and #B.cells > #A.cells then
                        local extra, inside = {}, 0
                        for _, q in ipairs(B.cells) do
                            if inA[q] then inside = inside + 1 else extra[#extra + 1] = q end
                        end
                        if inside == #A.cells then
                            local m = B.need - A.need
                            if m == 0 then
                                for _, q in ipairs(extra) do openCell(q) end
                                progress = true
                            elseif m == #extra then
                                for _, q in ipairs(extra) do mine[q] = true end
                                progress = true
                            end
                        end
                    end
                    if progress then break end
                end
                if progress then break end
            end
            flood()
        end
        if not progress then
            -- Mine total: every mine found means every other hidden cell is safe, and vice versa.
            local known, hidden = 0, {}
            for i = 1, cells do
                if mine[i] then known = known + 1 elseif not open[i] then hidden[#hidden + 1] = i end
            end
            if known == g.mines and #hidden > 0 then
                for _, q in ipairs(hidden) do openCell(q) end
                progress = true
            elseif g.mines - known == #hidden and #hidden > 0 then
                for _, q in ipairs(hidden) do mine[q] = true end
                progress = true
            end
            flood()
        end
    end
    return open, opened >= safe_left
end

-- Fills the mines around the first dig. With `logical`, retries seeds until the board is solvable
-- without guessing; after `tries` it keeps the last board and says so in g.logical.
function Logic.arm(g, first, logical, tries)
    local rnd = Logic.rng(g.seed)
    tries = logical and (tries or 400) or 1
    for _ = 1, tries do
        g.bomb = place(g, first, rnd)
        if not logical then break end
        local _, ok = solve(g, { [first] = true })
        if ok then
            g.logical = true
            return g
        end
    end
    g.logical = false
    return g
end

-- Player moves ---------------------------------------------------------------------------------------
-- Each returns the list of changed cell indices (for partial redraws).

local function finished(g) return g.done or g.boom end

local function checkWin(g)
    local hidden = 0
    for k = 1, #g.state do
        if g.state:byte(k) ~= 111 then hidden = hidden + 1 end -- 'o'
    end
    if hidden == g.mines then g.done = true end
end

-- Opens cell i (flood-filling zeros). Hitting a mine sets g.boom.
function Logic.dig(g, i, logical)
    if finished(g) or Logic.cell(g, i) ~= "h" then return {} end
    if not g.bomb then Logic.arm(g, i, logical) end
    if g.bomb[i] then
        g.boom = i
        setCells(g, { i }, "o")
        return { i }
    end
    local changed, seen, stack, nb = {}, { [i] = true }, { i }, {}
    while #stack > 0 do
        local j = table.remove(stack)
        changed[#changed + 1] = j
        if Logic.count(g, j) == 0 then
            for k = 1, neighbours(g, j, nb) do
                local q = nb[k]
                if not seen[q] and Logic.cell(g, q) == "h" and not g.bomb[q] then
                    seen[q] = true
                    stack[#stack + 1] = q
                end
            end
        end
    end
    setCells(g, changed, "o")
    checkWin(g)
    return changed
end

-- Tapping an open number whose flags are all placed digs the rest of its neighbours.
function Logic.chord(g, i)
    if finished(g) or Logic.cell(g, i) ~= "o" or not g.bomb then return {} end
    local nb = {}
    local n, flags = neighbours(g, i, nb), 0
    for k = 1, n do
        if Logic.cell(g, nb[k]) == "f" then flags = flags + 1 end
    end
    if flags ~= Logic.count(g, i) then return {} end
    local changed = {}
    for k = 1, n do
        local q = nb[k]
        if Logic.cell(g, q) == "h" then
            for _, c in ipairs(Logic.dig(g, q)) do changed[#changed + 1] = c end
            if g.boom then break end
        end
    end
    return changed
end

function Logic.flag(g, i)
    if finished(g) then return {} end
    local s = Logic.cell(g, i)
    if s == "o" then return {} end
    setCells(g, { i }, s == "f" and "h" or "f")
    return { i }
end

-- Takes back the dig that hit a mine.
function Logic.undo(g)
    if not g.boom then return {} end
    local i = g.boom
    g.boom = nil
    g.undos = g.undos + 1
    setCells(g, { i }, "h")
    return { i }
end

function Logic.flags(g)
    local _, n = g.state:gsub("f", "")
    return n
end

-- A hidden safe cell a player could prove from the open numbers, else any hidden safe cell next
-- to the open area, else any hidden safe cell. Nil before the first dig.
function Logic.hint(g)
    if not g.bomb or finished(g) then return nil end
    local open = {}
    for k = 1, #g.state do
        if g.state:byte(k) == 111 then open[k] = true end
    end
    local before = {}
    for k in pairs(open) do before[k] = true end
    local reached = solve(g, open)
    local nb = {}
    local best, fallback
    for i = 1, g.rows * g.cols do
        if not g.bomb[i] and Logic.cell(g, i) == "h" then
            local edge = false
            for k = 1, neighbours(g, i, nb) do
                if before[nb[k]] then edge = true break end
            end
            if reached[i] and edge then return i end
            if reached[i] and not best then best = i end
            if edge and not fallback then fallback = i end
        end
    end
    return best or fallback
end

-- 3 stars for a clean win, one off per undo or hint, never below 1.
function Logic.stars(g)
    return math.max(1, 3 - g.undos - g.hints)
end

Logic.solve = solve
return Logic
