-- Mac-side checks for the word search rules: `luajit wordsearch/logic_test.lua`.
local dir = arg[0]:match("(.*/)") or "./"
package.path = dir .. "wordsearch.koplugin/?.lua;" .. package.path
local Logic = require("logic")
local themes = require("words")

local fails = 0
local function check(ok, msg)
    if not ok then fails = fails + 1 print("FAIL " .. msg) end
end

-- Invariant: every theme can fill every board size.
for _, t in ipairs(themes) do
    local fit12, fit8, seen = 0, 0, {}
    for _, w in ipairs(t.words) do
        check(w:match("^[A-Z]+$"), t.name .. " has a bad word " .. w)
        check(not seen[w], t.name .. " repeats " .. w)
        seen[w] = true
        if #w <= 12 then fit12 = fit12 + 1 end
        if #w <= 8 then fit8 = fit8 + 1 end
    end
    check(fit12 >= 22 and fit8 >= 6, t.name .. " is too small")
end

-- Invariants over many seeds: full word count, each word reads out of the grid along a straight
-- or (only when allowed) diagonal line, and a stroke along it snaps to it from either end.
for _, size in ipairs(Logic.SIZES) do
    for _, diag in ipairs({ false, true }) do
        for seed = 1, 300 do
            local g = Logic.generate(themes, size.key, diag, seed)
            local tag = size.key .. (diag and " diag" or "") .. " seed " .. seed
            check(#g.letters == g.n * g.n, tag .. " letter count")
            check(#g.words == size.words, tag .. " placed " .. #g.words .. " of " .. size.words)
            for i, w in ipairs(g.words) do
                local dr, dc = w.r2 - w.r1, w.c2 - w.c1
                check(diag or dr == 0 or dc == 0, tag .. " diagonal in straight mode " .. w.w)
                local steps = math.max(math.abs(dr), math.abs(dc))
                local read = {}
                for k = 0, steps do
                    read[#read + 1] = Logic.letter(g, w.r1 + k * dr / steps, w.c1 + k * dc / steps)
                end
                check(table.concat(read) == w.w, tag .. " reads " .. table.concat(read) .. " not " .. w.w)
                local ax, ay, bx, by = w.c1 - 0.5, w.r1 - 0.5, w.c2 - 0.5, w.r2 - 0.5
                local hit = Logic.snap(g, ax, ay, bx, by)
                check(hit and g.words[hit].w == w.w, tag .. " exact stroke misses " .. w.w)
                hit = Logic.snap(g, bx + 0.3, by - 0.3, ax - 0.2, ay + 0.4)
                check(hit and g.words[hit].w == w.w, tag .. " sloppy backward stroke misses " .. w.w)
            end
        end
    end
end

-- Easy-first: over many boards, at least the planned share of words reads left to right or top to
-- bottom, so a board opens with quick finds.
for _, diag in ipairs({ false, true }) do
    local easy, total = 0, 0
    for seed = 1, 300 do
        for _, w in ipairs(Logic.generate(themes, "huge", diag, seed).words) do
            local dr, dc = w.r2 - w.r1, w.c2 - w.c1
            if (dr == 0 and dc > 0) or (dc == 0 and dr > 0) then easy = easy + 1 end
            total = total + 1
        end
    end
    check(easy / total >= Logic.EASY_SHARE - 0.02, "easy share " .. easy / total .. (diag and " diag" or ""))
end

-- Decoys and filler never spell a listed word twice: each reads out of the grid exactly once, counted
-- on every row, column and diagonal read both ways.
local function lines(g)
    local n, out = g.n, {}
    local function walk(r, c, dr, dc)
        local t = {}
        while r >= 1 and r <= n and c >= 1 and c <= n do
            t[#t + 1] = Logic.letter(g, r, c)
            r, c = r + dr, c + dc
        end
        out[#out + 1] = table.concat(t)
        out[#out + 1] = table.concat(t):reverse()
    end
    for i = 1, n do
        walk(i, 1, 0, 1)
        walk(1, i, 1, 0)
        walk(i, 1, 1, 1)
        walk(i, n, 1, -1)
        if i > 1 then
            walk(1, i, 1, 1)
            walk(1, n - i + 1, 1, -1)
        end
    end
    return out
end
for _, size in ipairs(Logic.SIZES) do
    for seed = 1, 200 do
        local g = Logic.generate(themes, size.key, seed % 2 == 0, seed)
        local ls = lines(g)
        for _, w in ipairs(g.words) do
            local count = 0
            for _, l in ipairs(ls) do
                local at = 1
                while true do
                    local s = l:find(w.w, at, true)
                    if not s then break end
                    count, at = count + 1, s + 1
                end
            end
            if w.w == w.w:reverse() then count = count / 2 end
            check(count == 1, size.key .. " seed " .. seed .. " has " .. count .. " of " .. w.w)
        end
    end
end

-- Determinism: same seed, same board.
local a, b = Logic.generate(themes, "big", true, 42), Logic.generate(themes, "big", true, 42)
check(a.letters == b.letters and a.theme == b.theme, "seed 42 gives two boards")

-- A tap-sized stroke never snaps; found words never snap again.
local g = Logic.generate(themes, "medium", true, 7)
local w = g.words[1]
check(Logic.snap(g, w.c1 - 0.5, w.r1 - 0.5, w.c1 - 0.4, w.r1 - 0.4) == nil, "tap snapped")
for _, x in ipairs(g.words) do x.found = true end
check(Logic.snap(g, w.c1 - 0.5, w.r1 - 0.5, w.c2 - 0.5, w.r2 - 0.5) == nil, "found word snapped again")
check(Logic.remaining(g) == 0, "remaining after all found")

-- Fitted strokes: a wobbly, overshooting, backwards stroke keeps its ends on the word's ends and
-- never wanders further than MAX_WOBBLE off the word's line.
g = Logic.generate(themes, "big", true, 11)
for _, w in ipairs(g.words) do
    local ax, ay, bx, by = w.c1 - 0.5, w.r1 - 0.5, w.c2 - 0.5, w.r2 - 0.5
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    local pts = {}
    for k = 0, 40 do
        local t = 1.15 - 1.3 * k / 40
        local wob = 0.9 * math.sin(k * 0.7)
        pts[#pts + 1] = { ax + dx * t - dy / len * wob, ay + dy * t + dx / len * wob }
    end
    w.path = Logic.fitStroke(pts, w)
    check(w.path and #w.path <= 48, w.w .. " path size")
    check(w.path[1] == 0 and w.path[#w.path - 1] == 1, w.w .. " path ends not on word ends")
    local sp = Logic.strokePoints(w, 0)
    for _, p in ipairs(sp) do
        local off = math.abs((p[1] - ax) * dy - (p[2] - ay) * dx) / len
        check(off <= Logic.MAX_WOBBLE + 1e-3, w.w .. " wanders " .. off)
    end
    check(math.abs(sp[1][1] - ax) < 0.3 and math.abs(sp[#sp][1] - bx) < 0.3, w.w .. " path flipped")
end
check(Logic.fitStroke({ { 1, 1 }, { 1.1, 1.1 } }, g.words[1]) == nil, "dot made a path")

print(fails == 0 and "PASS" or ("FAILED " .. fails))
os.exit(fails == 0 and 0 or 1)
