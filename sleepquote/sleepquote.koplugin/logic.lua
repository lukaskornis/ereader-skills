--[[
Sleep screen logic, no KOReader requires: cleans highlight text and picks one highlight per sleep.
Books come in recency order (current book first, then recently read ones).
]]
local M = {}

M.MAX_CHARS = 420

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

--- Balanced pick, no randomness: books[r] weighs 1/r (newest first), split evenly over its
--- highlights. Each sleep every highlight earns its share as credit; the one with the most credit
--- is shown and pays 1 (smooth weighted round robin), so a highlight's frequency tracks its share
--- and a new highlight joins level with the current leader, so it comes up next instead of
--- catching up on years of history.
--- Ties go to the one shown longest ago; the previous one is skipped whenever another exists.
--- books: { {file, title, highlights = {text…}}, … } in recency order.
--- state: { credit = {key=n}, seen = {key=seq}, seq = n, prev = key }, updated in place.
function M.pick(books, state)
    local list, weights, total = {}, {}, 0
    local rank = 0
    for _, b in ipairs(books) do
        if #b.highlights > 0 then
            rank = rank + 1
            total = total + 1 / rank
            for _, text in ipairs(b.highlights) do
                list[#list + 1] = { file = b.file, title = b.title, text = text, key = M.key(b.file, text) }
                weights[#list] = 1 / rank / #b.highlights
            end
        end
    end
    if #list == 0 then return nil end

    local old_credit, old_seen = state.credit or {}, state.seen or {}
    local credit, seen = {}, {}
    local start = 0
    for _, e in ipairs(list) do
        start = math.max(start, old_credit[e.key] or 0)
    end
    local best
    for i, e in ipairs(list) do
        -- Two books can share a highlight text only by file name collision; first one wins.
        if credit[e.key] == nil then
            credit[e.key] = (old_credit[e.key] or start) + weights[i] / total
            seen[e.key] = old_seen[e.key]
            if e.key ~= state.prev or #list == 1 then
                if not best then
                    best = e
                else
                    local c, bc = credit[e.key], credit[best.key]
                    if c > bc + 1e-9 or (c > bc - 1e-9 and (seen[e.key] or -1) < (seen[best.key] or -1)) then
                        best = e
                    end
                end
            end
        end
    end
    best = best or list[1]

    credit[best.key] = credit[best.key] - 1
    state.seq = (state.seq or 0) + 1
    seen[best.key] = state.seq
    state.credit, state.seen, state.prev = credit, seen, best.key
    return best
end

return M
