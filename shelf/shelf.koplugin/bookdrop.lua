--[[--
Client for bookdrop.cc (book-drop, a send2ereader fork): get a 4-letter key,
poll it for uploaded files, download them, upload to another reader's key. Calls block.
--]]--

local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local Profile = require("profile")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")

local BASE = "https://bookdrop.cc"
-- The server ties a key to the User-Agent that made it (status 404s on a mismatch).
local USER_AGENT = Profile.bookdrop_user_agent

local Bookdrop = {
    host = "bookdrop.cc",
}

local function request(method, path, sink, block_timeout, total_timeout)
    socketutil:set_timeout(block_timeout or 5, total_timeout or 10)
    local code = socket.skip(1, http.request{
        url = BASE .. path,
        method = method,
        headers = {
            ["User-Agent"] = USER_AGENT,
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Content-Length"] = method == "POST" and "0" or nil,
        },
        sink = sink,
    })
    socketutil:reset_timeout()
    return code
end

local function requestJson(method, path)
    local body = {}
    -- ltn12.sink.table also returns the table; keep it out of the timeout arguments.
    local code = request(method, path, (ltn12.sink.table(body)))
    if code ~= 200 then return nil, code end
    local data = rapidjson.decode(table.concat(body))
    if type(data) ~= "table" then return nil, "bad json" end
    return data
end

-- Returns the new key, or nil and the HTTP code or error.
function Bookdrop.generate()
    local data, err = requestJson("POST", "/generate")
    if not data then return nil, err end
    if type(data.key) ~= "string" then return nil, "no key" end
    return data.key
end

-- Returns the list of file names waiting on the key, or nil and the code (404 = key expired).
function Bookdrop.files(key)
    local data, err = requestJson("GET", "/status/" .. key)
    if not data then return nil, err end
    local names = {}
    for _, file in ipairs(data.files or {}) do
        if type(file.name) == "string" then table.insert(names, file.name) end
    end
    return names
end

-- The name comes from the server; keep it to one plain file name.
local function safeName(name)
    name = name:gsub("[/\\%z]", "_"):gsub("^%.+", "")
    if name == "" then name = "book" end
    return name
end

local function urlEncode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Saves the file into dir through a .part file. Returns the final path and its size, or nil and the error.
function Bookdrop.download(key, name, dir)
    local path = dir .. "/" .. safeName(name)
    local part = path .. ".part"
    local file = io.open(part, "wb")
    if not file then return nil, "cannot write " .. part end
    local code = request("GET", "/" .. urlEncode(name) .. "?key=" .. key, ltn12.sink.file(file), 10, 120)
    -- The sink closes the file at the end of the body, but not when the transfer fails midway.
    if io.type(file) == "file" then file:close() end
    if code ~= 200 then
        os.remove(part)
        return nil, code
    end
    os.remove(path)
    local ok, err = os.rename(part, path)
    if not ok then return nil, err end
    return path, lfs.attributes(path, "size")
end

-- The server rejects anything larger.
local UPLOAD_MAX = 50 * 1024 * 1024
local CHUNK = 64 * 1024

-- Uploads the file at path to the reader showing key. on_progress(sent, total) is called after each
-- 64 KB chunk. Returns true, or nil and the HTTP code or a short error.
function Bookdrop.upload(key, path, on_progress)
    if type(key) ~= "string" or not key:match("^%w%w%w%w$") then return nil, "bad key" end
    local size = lfs.attributes(path, "size")
    if not size then return nil, "no file" end
    if size > UPLOAD_MAX then return nil, "too big" end
    local file = io.open(path, "rb")
    if not file then return nil, "cannot read" end

    local name = path:match("([^/]+)$"):gsub('[%c"\\]', "_")
    local mime = name:lower():match("%.epub$") and "application/epub+zip" or "application/octet-stream"
    local boundary = "----ShelfBoundary" .. string.format("%08x%08x", os.time(), math.random(0, 0x7fffffff))
    local head = "--" .. boundary .. "\r\n"
        .. 'Content-Disposition: form-data; name="key"\r\n\r\n'
        .. key:upper() .. "\r\n"
        .. "--" .. boundary .. "\r\n"
        .. 'Content-Disposition: form-data; name="file"; filename="' .. name .. '"\r\n'
        .. "Content-Type: " .. mime .. "\r\n\r\n"
    local tail = "\r\n--" .. boundary .. "--\r\n"

    local sent = 0
    local function fileSource()
        local chunk = file:read(CHUNK)
        if not chunk then return nil end
        sent = sent + #chunk
        if on_progress then on_progress(sent, size) end
        return chunk
    end

    local body = {}
    socketutil:set_timeout(10, 600)
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = BASE .. "/upload",
            method = "POST",
            headers = {
                ["User-Agent"] = USER_AGENT,
                ["X-Requested-With"] = "XMLHttpRequest",
                ["Origin"] = BASE,
                ["Referer"] = BASE .. "/",
                ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
                ["Content-Length"] = tostring(#head + size + #tail),
            },
            source = ltn12.source.cat(ltn12.source.string(head), fileSource, ltn12.source.string(tail)),
            sink = (ltn12.sink.table(body)),
        })
    end)
    socketutil:reset_timeout()
    file:close()
    if not ok then return nil, tostring(code) end
    if code ~= 200 then
        logger.warn("shelf: bookdrop upload", code, table.concat(body):sub(1, 200))
        return nil, code
    end
    if sent ~= size then return nil, "short read" end
    return true
end

return Bookdrop
