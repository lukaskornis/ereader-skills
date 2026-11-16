--[[--
Online covers from Open Library, shown in place of the book's own cover when found:
they are usually sharper, and some books have none.

Fetched in a subprocess while connected, scaled to the shelf's cover size and saved
as PNG, one file per book, so the shelf only decodes a small image.
A book with no online match gets an empty .none marker and is retried after a week.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local FFIUtil = require("ffi/util")
local RenderImage = require("ui/renderimage")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local md5 = require("ffi/sha2").md5
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")

local DIR = DataStorage:getDataDir() .. "/cache/shelf-covers"
local SEARCH_URL = "https://openlibrary.org/search.json?limit=1&fields=cover_i,title"
local COVERS_URL = "https://covers.openlibrary.org/b/"
-- Open Library asks clients to say who they are.
local USER_AGENT = "KOReader-Shelf/1.0"
local MISS_RETRY_SECONDS = 7 * 24 * 3600
local MAX_REDIRECTS = 4
-- Open Library's M covers are about 180 px wide, L about 500; the smaller one is cheaper to decode.
local MEDIUM_MAX_W = 180

local Covers = {}

local function baseName(path)
    return DIR .. "/" .. md5(path)
end

local function urlEncode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Covers redirect to archive.org; LuaSocket won't follow an https redirect itself.
local function get(url)
    for _ = 1, MAX_REDIRECTS do
        local body = {}
        socketutil:set_timeout(5, 20)
        local ok, code, headers = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                headers = { ["User-Agent"] = USER_AGENT },
                sink = (ltn12.sink.table(body)),
                redirect = false,
            })
        end)
        socketutil:reset_timeout()
        if not ok then return nil, tostring(code) end
        if code == 200 then return table.concat(body) end
        local location = headers and headers.location
        if not (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) or not location then
            return nil, code
        end
        url = location
    end
    return nil, "too many redirects"
end

-- "The Hobbit: or There and Back Again" → "the hobbit"
local function normalize(title)
    title = title:gsub("[:;(%[].*$", ""):lower():gsub("[^%w]+", " ")
    return util.trim(title)
end

-- Search can return a different book; only trust it when one title contains the other.
local function sameTitle(a, b)
    a, b = normalize(a), normalize(b)
    if a == "" or b == "" then return false end
    return a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

local function searchCoverId(book)
    local data = get(SEARCH_URL .. "&title=" .. urlEncode(book.title) .. "&author=" .. urlEncode(book.author))
    if not data then return nil end
    local ok, result = pcall(rapidjson.decode, data)
    local doc = ok and type(result) == "table" and type(result.docs) == "table" and result.docs[1]
    if type(doc) ~= "table" or type(doc.cover_i) ~= "number" or type(doc.title) ~= "string" then return nil end
    if not sameTitle(doc.title, book.title) then return nil end
    return string.format("%d", doc.cover_i)
end

local function download(book, size)
    if book.isbn then
        -- default=false makes a missing cover a 404 instead of a blank image.
        local data = get(COVERS_URL .. "isbn/" .. book.isbn .. "-" .. size .. ".jpg?default=false")
        if data then return data end
    end
    if not book.author then return nil end
    local id = searchCoverId(book)
    if not id then return nil end
    return get(COVERS_URL .. "id/" .. id .. "-" .. size .. ".jpg?default=false")
end

-- Scaled to fit the cover box once here, so the shelf never decodes a full-size JPEG.
local function save(data, file, specs)
    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then return false end
    local w, h = bb:getWidth(), bb:getHeight()
    local factor = math.min(specs.max_cover_w / w, specs.max_cover_h / h, 1)
    w, h = math.max(1, math.floor(w * factor)), math.max(1, math.floor(h * factor))
    bb = RenderImage:scaleBlitBuffer(bb, w, h, true)
    if not Device.screen:isColorEnabled() and bb:getType() ~= Blitbuffer.TYPE_BB8 then
        local gray = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        gray:blitFrom(bb, 0, 0, 0, 0, w, h)
        bb:free()
        bb = gray
    end
    local part = file .. ".part"
    local ok = pcall(bb.writePNG, bb, part)
    bb:free()
    if not ok then
        os.remove(part)
        return false
    end
    return os.rename(part, file)
end

local function fetch(book, specs)
    local base = baseName(book.path)
    local size = specs.max_cover_w <= MEDIUM_MAX_W and "M" or "L"
    local data = download(book, size)
    if data and save(data, base .. ".png", specs) then
        os.remove(base .. ".none")
        return
    end
    local marker = io.open(base .. ".none", "w")
    if marker then marker:close() end
end

--- The saved online cover for the book, or nil.
function Covers.load(path)
    local file = baseName(path) .. ".png"
    if lfs.attributes(file, "mode") ~= "file" then return nil end
    return RenderImage:renderImageFile(file, false)
end

--- True when the book has no online cover yet and was not looked up in the last week.
function Covers.wanted(path)
    local base = baseName(path)
    if lfs.attributes(base .. ".png", "mode") == "file" then return false end
    local missed = lfs.attributes(base .. ".none", "modification")
    return not missed or os.time() - missed > MISS_RETRY_SECONDS
end

function Covers.has(path)
    return lfs.attributes(baseName(path) .. ".png", "mode") == "file"
end

-- The lookup outlives the shelf: the file manager, and the shelf with it, closes whenever a book opens.
local running = nil -- { pid, books }

function Covers.busy()
    return running ~= nil
end

--- Looks up each { path, title, author, isbn } in a subprocess. Returns false when it cannot start.
function Covers.fetchInBackground(books, specs)
    if running then return false end
    local wanted = {}
    for _, book in ipairs(books) do
        if Covers.wanted(book.path) then table.insert(wanted, book) end
    end
    books = wanted
    if #books == 0 then return false end
    util.makePath(DIR)
    local pid = FFIUtil.runInSubProcess(function()
        for _, book in ipairs(books) do
            fetch(book, specs)
        end
    end)
    if not pid then
        logger.warn("shelf: cannot start cover subprocess")
        return false
    end
    running = { pid = pid, books = books }
    return true
end

--- nil while the lookup runs, else the paths that got an online cover.
function Covers.collectFinished()
    if not running or not FFIUtil.isSubProcessDone(running.pid) then return nil end
    local found = {}
    for _, book in ipairs(running.books) do
        if Covers.has(book.path) then table.insert(found, book.path) end
    end
    running = nil
    return found
end

-- "urn:isbn:978-0-14-032872-1" → "9780140328721"
function Covers.isbn(identifiers)
    if type(identifiers) ~= "string" then return nil end
    for token in identifiers:gmatch("[%dXx][%dXx%-]+") do
        local digits = token:gsub("%-", ""):upper()
        if (#digits == 13 and digits:match("^97[89]%d+$")) or (#digits == 10 and digits:match("^%d+X?$")) then
            return digits
        end
    end
    return nil
end

return Covers
