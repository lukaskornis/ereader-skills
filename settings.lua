-- Read or change a KOReader settings file with KOReader's own LuaSettings, so
-- the file keeps its normal serialization. Run from the KOReader folder:
--   ./luajit - FILE keys | get KEY | set KEY VALUE | unset KEY
-- VALUE is a Lua literal (true, 42, {1, 2}, "text"); anything else is a string.
-- KOReader's library loader prints debug lines; keep them out of the answer.
local print_ = print
print = function() end
require("setupkoenv")
local dump = require("dump")
local LuaSettings = require("luasettings")
print = print_

local file, op, key, value = ...

local function fail(msg)
    io.stderr:write(msg .. "\n")
    os.exit(1)
end

local function parse(text)
    local chunk = loadstring("return " .. text)
    if not chunk then return text end
    setfenv(chunk, {})
    local ok, result = pcall(chunk)
    if ok and result ~= nil then return result end
    return text
end

if not file or not op then fail("usage: FILE keys|get KEY|set KEY VALUE|unset KEY") end
local settings = LuaSettings:open(file)

if op == "keys" then
    local keys = {}
    for k in pairs(settings.data) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    print(table.concat(keys, "\n"))
elseif op == "get" then
    if not key then fail("get needs a key") end
    local current = settings:readSetting(key)
    if current == nil then fail("no setting " .. key) end
    print(type(current) == "table" and dump(current) or tostring(current))
elseif op == "set" then
    if not key or not value then fail("set needs a key and a value") end
    settings:saveSetting(key, parse(value))
    settings:flush()
    print(dump(settings:readSetting(key)))
elseif op == "unset" then
    if not key then fail("unset needs a key") end
    settings:delSetting(key)
    settings:flush()
    print("unset " .. key)
else
    fail("unknown op " .. op)
end
