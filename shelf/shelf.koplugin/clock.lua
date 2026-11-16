--[[--
Header clock: "14:05 Mon", shown only while the device time can be trusted.
A reset clock fails the year guard; when online, one HEAD to bookdrop.cc compares
the device time with the server's Date header. The verdict lasts until KOReader restarts.
--]]--

local datetime = require("datetime")
local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local MIN_YEAR = 2025
local MAX_SKEW_SECONDS = 120
local CHECK_URL = "https://bookdrop.cc/"
-- A failed check blocks for seconds, so it is not retried on every shelf rebuild.
local RETRY_SECONDS = 600

local Clock = {
    -- nil = not checked yet, true/false = the server check's verdict.
    verified = nil,
    last_attempt = nil,
}

-- Seconds between this zone's local time and UTC at `now` (os.time reads date tables as local).
local function utcOffset(now)
    local utc = os.date("!*t", now)
    utc.isdst = false
    local here = os.date("*t", now)
    here.isdst = false
    return os.time(here) - os.time(utc)
end

local function parseHttpDate(value)
    local months = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
    local day, month, year, hour, min, sec = value:match("(%d+) (%a+) (%d+) (%d+):(%d+):(%d+)")
    if not (day and months[month]) then return nil end
    local t = { year = tonumber(year), month = months[month], day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec), isdst = false }
    return os.time(t) + utcOffset(os.time())
end

function Clock.trusted()
    if Clock.verified ~= nil then return Clock.verified end
    return tonumber(os.date("%Y")) >= MIN_YEAR
end

function Clock.needsCheck()
    if Clock.verified ~= nil then return false end
    return not Clock.last_attempt or os.time() - Clock.last_attempt >= RETRY_SECONDS
end

-- Blocks for up to a few seconds. Leaves the verdict unset when the server can't be reached.
function Clock.check()
    if not Clock.needsCheck() then return end
    Clock.last_attempt = os.time()
    socketutil:set_timeout(3, 5)
    local code, headers = socket.skip(1, http.request{ url = CHECK_URL, method = "HEAD" })
    socketutil:reset_timeout()
    local server = headers and headers.date and parseHttpDate(headers.date)
    if not server then
        logger.warn("shelf: clock check failed", code)
        return
    end
    local skew = os.time() - server
    Clock.verified = math.abs(skew) <= MAX_SKEW_SECONDS
    logger.info("shelf: clock skew", skew, "trusted", Clock.verified)
end

function Clock.text()
    local hour = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    return hour .. " " .. os.date("%a")
end

function Clock.secondsToNextMinute()
    return 60 - os.time() % 60
end

return Clock
