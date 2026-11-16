--[[--
Power save and automatic front light. Module state, so it keeps running while a book is open.

Power save turns Wi-Fi and the light off and drops the CPU governor (interactive on Kobo, ondemand on Kindle);
turning it off restores what was on before. Auto light is Off, Schedule (on between two times)
or Sensor (on when the room is dark, read from the ambient light sensor once a minute, where there is one).
Auto light acts only when its wish changes, so a manual change sticks until the next switch-over.
Every state change broadcasts ShelfPowerChanged.
--]]--

local Device = require("device")
local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Profile = require("profile")
local logger = require("logger")

local TICK_SECONDS = 60
-- Sensor readings: about 300 covered, about 950 in room light. Two thresholds so dusk doesn't flicker the light.
local DARK_BELOW = 400
local BRIGHT_ABOVE = 650
local DEFAULT_FROM = 19 * 60
local DEFAULT_TO = 7 * 60

local Power = {
    started = false,
    wants_light = nil, -- auto light's last wish, nil until its first tick
}

local function powerd()
    return Device:getPowerDevice()
end

local function broadcast()
    UIManager:broadcastEvent(Event:new("ShelfPowerChanged"))
end

local function writeGovernor(name)
    if not Profile.governor_file then return end
    local f = io.open(Profile.governor_file, "w")
    if not f then
        logger.warn("shelf: cannot write governor", name)
        return
    end
    f:write(name)
    f:close()
end

function Power.hasSensor()
    return Profile.sensor_file ~= nil
end

function Power.sensorValue()
    if not Profile.sensor_file then return nil end
    local f = io.open(Profile.sensor_file, "r")
    if not f then return nil end
    local value = f:read("*number")
    f:close()
    return value
end

function Power.saving()
    return G_reader_settings:isTrue("shelf_power_save")
end

function Power.autoMode()
    local mode = G_reader_settings:readSetting("shelf_light_auto") or "off"
    if mode == "sensor" and not Power.hasSensor() then return "off" end
    return mode
end

-- Minutes after midnight.
function Power.schedule()
    return G_reader_settings:readSetting("shelf_light_from") or DEFAULT_FROM,
        G_reader_settings:readSetting("shelf_light_to") or DEFAULT_TO
end

function Power.setSchedule(from, to)
    G_reader_settings:saveSetting("shelf_light_from", from)
    G_reader_settings:saveSetting("shelf_light_to", to)
    Power.wants_light = nil
    Power.tick()
end

local function inSchedule(now_min, from, to)
    if from <= to then return now_min >= from and now_min < to end
    return now_min >= from or now_min < to
end

-- nil when auto light has no opinion this tick.
local function autoWish()
    local mode = Power.autoMode()
    if mode == "schedule" then
        local from, to = Power.schedule()
        local t = os.date("*t")
        return inSchedule(t.hour * 60 + t.min, from, to)
    elseif mode == "sensor" then
        local value = Power.sensorValue()
        if not value then return nil end
        if value < DARK_BELOW then return true end
        if value > BRIGHT_ABOVE then return false end
        return Power.wants_light
    end
    return nil
end

function Power.tick()
    UIManager:unschedule(Power.tick)
    if Power.saving() or Power.autoMode() == "off" then return end
    local wish = autoWish()
    if wish ~= nil and wish ~= Power.wants_light then
        Power.wants_light = wish
        if wish then powerd():turnOnFrontlight() else powerd():turnOffFrontlight() end
    end
    UIManager:scheduleIn(TICK_SECONDS, Power.tick)
end

function Power.setAutoMode(mode)
    G_reader_settings:saveSetting("shelf_light_auto", mode)
    Power.wants_light = nil
    Power.tick()
    broadcast()
end

-- Called on every plugin init; acts once per KOReader run.
function Power.start()
    if Power.started then return end
    Power.started = true
    -- The cpu-performance patch sets the governor at startup; power save outranks it.
    if Power.saving() then writeGovernor(Profile.saving_governor) end
    Power.tick()
end

function Power.onResume()
    Power.tick()
end

-- 0 when the light is off; native scale, 0..100 on Kobo.
function Power.brightness()
    return powerd():frontlightIntensity()
end

function Power.setBrightness(value)
    local pd = powerd()
    if value <= pd.fl_min then
        pd:turnOffFrontlight()
        return
    end
    pd:setIntensity(value)
    if pd:isFrontlightOff() then pd:turnOnFrontlight() end
end

function Power.setSaving(on)
    if on == Power.saving() then return end
    if on then
        local pd = powerd()
        G_reader_settings:saveSetting("shelf_power_restore", {
            wifi = NetworkMgr:isWifiOn(),
            light = Device:hasFrontlight() and pd:isFrontlightOn(),
        })
        G_reader_settings:makeTrue("shelf_power_save")
        UIManager:unschedule(Power.tick)
        if Device:hasFrontlight() then pd:turnOffFrontlight() end
        if NetworkMgr:isWifiOn() then NetworkMgr:toggleWifiOff(nil, true) end
        writeGovernor(Profile.saving_governor)
    else
        local restore = G_reader_settings:readSetting("shelf_power_restore") or {}
        G_reader_settings:makeFalse("shelf_power_save")
        G_reader_settings:delSetting("shelf_power_restore")
        writeGovernor(G_reader_settings:nilOrTrue("cpu_performance") and "performance" or Profile.saving_governor)
        if restore.light then powerd():turnOnFrontlight() end
        if restore.wifi and not NetworkMgr:isWifiOn() then NetworkMgr:toggleWifiOn(nil, false, true) end
        Power.wants_light = nil
        Power.tick()
    end
    broadcast()
end

return Power
