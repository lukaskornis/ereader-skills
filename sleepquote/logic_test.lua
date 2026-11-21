-- luajit sleepquote/logic_test.lua
local DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local L = dofile(DIR .. "sleepquote.koplugin/logic.lua")

local seed = 12345
local function rng(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n + 1
end

local function book(file, n)
    local h = {}
    for i = 1, n do h[i] = file .. " line " .. i end
    return { file = "/b/" .. file, title = file, highlights = h }
end

local function run(books, steps)
    local shown, out = {}, {}
    for i = 1, steps do
        local e = L.pick(books, shown, rng)
        out[i] = e and e.text
        if e then L.remember(shown, e.key) end
    end
    return out
end

-- Never the same highlight twice in a row, whenever more than one exists.
for _, shape in ipairs({ { 2 }, { 5 }, { 1, 1 }, { 1, 3 }, { 0, 4 }, { 3, 0, 2 }, { 1, 0, 1 } }) do
    local books = {}
    for i, n in ipairs(shape) do books[i] = book("B" .. i, n) end
    local out = run(books, 200)
    for i = 2, #out do
        assert(out[i] ~= out[i - 1], "repeat in a row, shape " .. table.concat(shape, ","))
    end
end

-- Current book wins while it has two or more highlights; each is shown before any repeats.
do
    local out = run({ book("Cur", 4), book("Old", 9) }, 40)
    local seen = {}
    for i = 1, 4 do
        assert(out[i]:find("^Cur"), "left the current book")
        assert(not seen[out[i]], "repeat before the cycle ended"); seen[out[i]] = true
    end
    for i = 5, 40 do assert(out[i]:find("^Cur"), "left the current book later") end
end

-- A current book with one highlight alternates with the older books instead of repeating it.
do
    local out = run({ book("Cur", 1), book("Old", 3) }, 4)
    assert(out[1] == "Cur line 1" and out[2]:find("^Old"), "single highlight did not fall through")
end

-- No books with highlights: nothing to show.
assert(L.pick({ book("A", 0) }, {}, rng) == nil)
assert(#run({ book("Solo", 1) }, 3) == 3, "single highlight must still show")

-- Cleaning: whitespace collapsed, long text cut on a word with an ellipsis, empty dropped.
assert(L.clean("  a\n\n b\t c ") == "a b c")
assert(L.clean(" \n ") == nil)
local long = L.clean(string.rep("word ", 200))
assert(#long <= L.MAX_CHARS + 3 and long:sub(-3) == "…" and long:sub(-4, -4) == "d")

-- Memory is bounded.
local shown = {}
for i = 1, L.MEMORY + 50 do L.remember(shown, "k" .. i) end
assert(#shown == L.MEMORY and shown[1] == "k" .. (L.MEMORY + 50))

print("sleepquote logic ok")
