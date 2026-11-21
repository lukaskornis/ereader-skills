-- luajit sleepquote/logic_test.lua
local DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local L = dofile(DIR .. "sleepquote.koplugin/logic.lua")

local function book(name, n)
    local h = {}
    for i = 1, n do h[i] = name .. i end
    return { file = "/b/" .. name, title = name, highlights = h }
end

local function library(shape)
    local books = {}
    for i, n in ipairs(shape) do books[i] = book(string.char(64 + i), n) end
    return books
end

local function run(books, steps, state)
    state = state or {}
    local out = {}
    for i = 1, steps do
        local e = L.pick(books, state)
        out[i] = e and e.text
    end
    return out, state
end

-- Golden tape: newest book A (2 highlights) most, then B (3), then C (4); no randomness.
local TAPE = "A1 A2 B1 B2 B3 A1 A2 C1 A1 A2 C2 C3 C4 A1 A2 B1 A1 A2 B2 B3 A1 A2 A1 A2 B1 B2 B3 A1 A2 C1 A1 A2 C2 C3 C4 A1 A2 B1 A1 A2"
local lib = library({ 2, 3, 4 })
local tape = table.concat(run(lib, 40), " ")
assert(tape == TAPE, "tape changed:\n" .. tape)

-- Same input, same sequence.
assert(table.concat(run(lib, 40), " ") == tape, "not deterministic")

-- Never the same highlight twice in a row, whenever more than one exists.
for _, shape in ipairs({ { 2 }, { 5 }, { 1, 1 }, { 1, 3 }, { 0, 4 }, { 3, 0, 2 }, { 1, 0, 1 }, { 1, 40 } }) do
    local out = run(library(shape), 300)
    for i = 2, #out do
        assert(out[i] ~= out[i - 1], "repeat in a row, shape " .. table.concat(shape, ","))
    end
end

-- Shares: newest book shown most, each book near its 1/rank weight, every highlight shown within
-- a bounded number of sleeps of its share.
do
    local shape = { 4, 1, 6, 2, 9 }
    local books = library(shape)
    local steps = 2000
    local out = run(books, steps)
    local per_book, last, max_gap = {}, {}, {}
    for i, text in ipairs(out) do
        local b = text:sub(1, 1)
        per_book[b] = (per_book[b] or 0) + 1
        max_gap[text] = math.max(max_gap[text] or 0, i - (last[text] or 0))
        last[text] = i
    end
    local total = 0
    for r = 1, #shape do total = total + 1 / r end
    for r, n in ipairs(shape) do
        local b = string.char(64 + r)
        local expect = steps / r / total
        assert(math.abs(per_book[b] - expect) <= 3, ("book %s shown %d, share %.1f"):format(b, per_book[b], expect))
        if r > 1 then assert(per_book[b] < per_book["A"], "older book beat the newest") end
        for i = 1, n do
            local every = n * r * total
            assert(max_gap[b .. i] <= 1.5 * every + 2, ("%s%d waited %d sleeps, share every %.1f"):format(b, i, max_gap[b .. i], every))
        end
    end
end

-- A book opened later joins at once without starving the others.
do
    local books = library({ 3, 3 })
    local _, state = run(books, 500)
    table.insert(books, 1, book("N", 2))
    local out = run(books, 30, state)
    local fresh, old = 0, 0
    for _, t in ipairs(out) do
        if t:sub(1, 1) == "N" then fresh = fresh + 1 else old = old + 1 end
    end
    assert(out[1]:sub(1, 1) == "N", "new book did not come first")
    assert(fresh >= 14 and fresh <= 18 and old >= 12, ("new %d old %d"):format(fresh, old))
end

-- Edge cases: nothing to show; a single highlight still shows every time.
assert(L.pick(library({ 0, 0 }), {}) == nil)
assert(#run(library({ 1 }), 3) == 3, "single highlight must still show")

-- Cleaning: whitespace collapsed, long text cut on a word with an ellipsis, empty dropped.
assert(L.clean("  a\n\n b\t c ") == "a b c")
assert(L.clean(" \n ") == nil)
local long = L.clean(string.rep("word ", 200))
assert(#long <= L.MAX_CHARS + 3 and long:sub(-3) == "…" and long:sub(-4, -4) == "d")

print("sleepquote logic ok")
