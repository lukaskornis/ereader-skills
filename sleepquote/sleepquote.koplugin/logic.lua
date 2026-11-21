--[[
Sleep quote logic, no KOReader requires: cleans highlight text, picks one highlight, keeps the
"shown" memory. Books come in priority order (current book first, then recently read ones).
]]
local M = {}

M.MAX_CHARS = 420
M.MEMORY = 300

function M.clean(text)
    if type(text) ~= "string" then return nil end
    local s = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if s == "" then return nil end
    if #s > M.MAX_CHARS then
        s = s:sub(1, M.MAX_CHARS):gsub("[\192-\255][\128-\191]*$", ""):gsub("%s+%S*$", "") .. "…"
    end
    return s
end

function M.key(file, text)
    return (file:match("[^/]+$") or file) .. "|" .. text:sub(1, 120)
end

-- Position of key in the shown list, 1 = shown last; nil = never (or forgotten).
local function age(shown, key)
    for i = 1, #shown do
        if shown[i] == key then return i end
    end
end

local function entries(book)
    local list = {}
    for _, text in ipairs(book.highlights) do
        list[#list + 1] = { file = book.file, title = book.title, text = text, key = M.key(book.file, text) }
    end
    return list
end

local function fresh(list, shown)
    local out = {}
    for _, e in ipairs(list) do
        if not age(shown, e.key) then out[#out + 1] = e end
    end
    return out
end

-- Random pick among the older half, so the one shown last never comes back next.
local function oldest(list, shown, rng)
    table.sort(list, function(a, b)
        local x, y = age(shown, a.key) or math.huge, age(shown, b.key) or math.huge
        if x ~= y then return x > y end
        return a.key < b.key
    end)
    return list[rng(math.ceil(#list / 2))]
end

--- books: { {file, title, highlights = {text…}}, … } in priority order.
--- shown: keys, most recent first. rng(n) returns 1..n.
function M.pick(books, shown, rng)
    local pools = {}
    for _, b in ipairs(books) do
        if #b.highlights > 0 then pools[#pools + 1] = entries(b) end
    end
    if #pools == 0 then return nil end

    for _, pool in ipairs(pools) do
        local f = fresh(pool, shown)
        if #f > 0 then return f[rng(#f)] end
        if #pool >= 2 then return oldest(pool, shown, rng) end
    end
    local all = {}
    for _, pool in ipairs(pools) do
        for _, e in ipairs(pool) do all[#all + 1] = e end
    end
    if #all == 1 then return all[1] end
    return oldest(all, shown, rng)
end

function M.remember(shown, key)
    for i = #shown, 1, -1 do
        if shown[i] == key then table.remove(shown, i) end
    end
    table.insert(shown, 1, key)
    while #shown > M.MEMORY do table.remove(shown) end
    return shown
end

return M
