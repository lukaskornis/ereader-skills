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

-- Preview line: snaps to 45 degrees with diagonals, 90 without, and stays on the board.
g.diagonals = true
local r, c = Logic.lineEnd(g, 1, 1, 3.4, 3.6)
check(r == 4 and c == 4, "diagonal preview " .. r .. "," .. c)
g.diagonals = false
r, c = Logic.lineEnd(g, 1, 1, 3.4, 3.6)
check((r == 1 or c == 1) and not (r == 1 and c == 1), "straight preview " .. r .. "," .. c)
r, c = Logic.lineEnd(g, 1, 1, 40, 0.5)
check(r == 1 and c == g.n, "preview clamps to edge " .. r .. "," .. c)

print(fails == 0 and "PASS" or ("FAILED " .. fails))
os.exit(fails == 0 and 0 or 1)
