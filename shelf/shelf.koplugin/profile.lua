--[[--
Per-device paths and values. Detected from the device class and from which files exist,
never from model names, so any Kobo or Kindle KOReader runs on gets the right one.
Named profile, not device, so it can't shadow KOReader's own device module.
--]]--

local Device = require("device")

local function exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

local GOVERNOR_FILE = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
local KOBO_SENSOR_FILE = "/sys/devices/virtual/input/input3/als_vis_data"
-- bookdrop.cc ties a key to the User-Agent that made it, and converts EPUBs to kepub for a Kobo UA.
-- Any UA without "Kobo" or "Kindle" gets the file as uploaded.
local KOBO_USER_AGENT = "Mozilla/5.0 (Linux; U; Android 2.0; en-us;) AppleWebKit/538.1 (KHTML, like Gecko) Version/4.0 Mobile Safari/538.1 (Kobo Touch 0373/4.38.21908)"
local PLAIN_USER_AGENT = "Mozilla/5.0 (X11; Linux armv7l) KOReader Shelf"

local Profile = {
    home_dir = Device.home_dir or "/mnt/onboard",
    send_dir = "/mnt/onboard/Books",
    sensor_file = nil,
    governor_file = exists(GOVERNOR_FILE) and GOVERNOR_FILE or nil,
    -- Power save drops to this; Kobo's kernel has interactive, the Kindle's only ondemand.
    saving_governor = "interactive",
    bookdrop_user_agent = PLAIN_USER_AGENT,
}

if Device:isKobo() then
    Profile.sensor_file = exists(KOBO_SENSOR_FILE) and KOBO_SENSOR_FILE or nil
    Profile.bookdrop_user_agent = KOBO_USER_AGENT
elseif Device:isKindle() then
    -- KOReader's Kindle home_dir is /mnt/us, which holds its own folders and the system's; books live in documents.
    Profile.home_dir = "/mnt/us/documents"
    Profile.send_dir = "/mnt/us/documents"
    Profile.saving_governor = "ondemand"
end

return Profile
