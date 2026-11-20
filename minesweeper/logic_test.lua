-- Mac-side checks for the minesweeper rules: `luajit minesweeper/logic_test.lua`.
local dir = arg[0]:match("(.*/)") or "./"
package.path = dir .. "minesweeper.koplugin/?.lua;" .. package.path
local Logic = require("logic")

local fails = 0
local function check(ok, msg)
    if not ok then fails = fails + 1 print("FAIL " .. msg) end
end

-- Invariants over many seeds: mine count, first dig opens an area, logical boards really solve
-- by digging only hinted cells, and the game is won exactly when every safe cell is open.
for _, size in ipairs(Logic.SIZES) do
    for _, diff in ipairs(Logic.DIFFS) do
        local t0, logical, seeds = os.clock(), 0, 40
        for seed = 1, seeds do
            local g = Logic.new(size.key, diff.key, seed)
            local tag = size.key .. " " .. diff.key .. " seed " .. seed
            local first = Logic.index(g, math.floor(g.rows / 2), math.floor(g.cols / 2))
            local opened = Logic.dig(g, first, true)
            local n = 0
            for _ in pairs(g.bomb) do n = n + 1 end
            check(n == g.mines, tag .. " has " .. n .. " mines")
            check(not g.boom and Logic.count(g, first) == 0 and #opened > 1, tag .. " first dig not an opening")
            if g.logical then logical = logical + 1 end
            if g.logical and seed <= 3 then

                local steps = 0
                while not g.done and steps < 2000 do
                    local h = Logic.hint(g)
                    check(h and not g.bomb[h], tag .. " hint is a mine or missing")
                    if not h then break end
                    Logic.dig(g, h)
                    steps = steps + 1
                end
                check(g.done and not g.boom, tag .. " logical board not solved by hints")
            end
        end
        local ms = (os.clock() - t0) * 1000 / seeds
        print(string.format("%-6s %-6s %3d%% logical  %5.1f ms/board", size.key, diff.key, math.floor(logical * 100 / seeds), ms))
        check(logical >= seeds * 0.9, size.key .. " " .. diff.key .. " too few logical boards")
    end
end

-- Determinism: same seed and first dig give the same mines.
local a, b = Logic.new("big", "hard", 7), Logic.new("big", "hard", 7)
Logic.dig(a, 50, true) Logic.dig(b, 50, true)
for i = 1, a.rows * a.cols do check(a.bomb[i] == b.bomb[i], "seed 7 differs at " .. i) end

-- Flag, chord, boom and undo on a hand-made 3 x 3: one mine in the corner.
local g = Logic.new("small", "easy", 1)
g.rows, g.cols, g.mines, g.state, g.bomb = 3, 3, 1, string.rep("h", 9), { [1] = true }
Logic.dig(g, 5)
check(g.state == "hhhhohhhh", "a number cell opened more than itself: " .. g.state)
Logic.flag(g, 1)
Logic.chord(g, 5)
check(g.done and not g.boom, "chord with the right flag did not win")
local h = Logic.new("small", "easy", 1)
h.rows, h.cols, h.mines, h.state, h.bomb = 3, 3, 1, string.rep("h", 9), { [1] = true }
Logic.dig(h, 1)
check(h.boom == 1, "digging the mine did not boom")
Logic.undo(h)
check(not h.boom and h.undos == 1 and Logic.cell(h, 1) == "h" and Logic.stars(h) == 2, "undo")

print(fails == 0 and "PASS" or (fails .. " failures"))
os.exit(fails == 0 and 0 or 1)
