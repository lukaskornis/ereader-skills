-- Dev hook behind `ink eval`, `ink reload`, `ink time` and `ink restart`. Event-driven, so it costs
-- nothing at idle. Installed as patches/2-ink-eval.lua; delete it to remove the hook.
-- 1. eval: runs /tmp/ink-eval.lua inside the running KOReader when ink writes a magic EV_MSC "INK"
--    event to /tmp/ink-kick. That is a FIFO this hook opens as an extra input device, because real
--    nodes drop event types they don't declare (the Kindle touch panel has no EV_MSC).
-- 2. idle report: an "INI" event arms it (and it starts armed at boot). Once something has been painted
--    and the UI is idle (nothing dirty, no task due within HORIZON), it waits for the panel to finish and
--    writes "<painted uptime> <panel done uptime>" to /tmp/ink-idle, so tests stop the moment the screen
--    is done instead of watching the framebuffer for a fixed settle time.
local ffi = require("ffi")
local Device = require("device")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local C = ffi.C
require("ffi/posix_h")
pcall(ffi.cdef, "int mkfifo(const char *path, unsigned int mode);")

local MSC_RAW, EVAL_MAGIC, IDLE_MAGIC = 3, 0x494E4B, 0x494E49 -- "INK", "INI"
local SCRIPT, OUT = "/tmp/ink-eval.lua", "/tmp/ink-eval.out"
local IDLE_OUT = "/tmp/ink-idle"
-- Longer than the 0.3 s page-turn coalescing flush, shorter than the 1 s menu prebuild, which paints nothing.
local HORIZON = time.s(0.35)

local function run()
    local ok, result
    local chunk, err = loadfile(SCRIPT)
    if chunk then
        ok, result = pcall(chunk)
    else
        ok, result = false, err
    end
    local f = io.open(OUT .. ".part", "w")
    f:write(ok and "" or "error: ", tostring(result), "\n")
    f:close()
    os.rename(OUT .. ".part", OUT)
end

-- /proc/uptime is the clock the ink shell side reads, so both ends compare the same numbers.
local function uptime()
    local f = io.open("/proc/uptime")
    local s = f:read("*l")
    f:close()
    return s:match("^%S+")
end

local function writeAtomic(path, text)
    local f = io.open(path .. ".part", "w")
    f:write(text, "\n")
    f:close()
    os.rename(path .. ".part", path)
end

local armed, painted = true, nil

local function arm()
    armed, painted = true, nil
    writeAtomic(IDLE_OUT .. ".armed", uptime())
end

local input = Device.input

-- Opened read-write so the hook holds a writer too: the FIFO never hits EOF, and an `ink` write never blocks while KOReader runs.
local KICK = "/tmp/ink-kick"
os.remove(KICK)
if C.mkfifo(KICK, 384) ~= 0 then error("ink-eval: mkfifo " .. KICK .. " failed") end
local kick_fd = C.open(KICK, bit.bor(C.O_RDWR, C.O_NONBLOCK, C.O_CLOEXEC))
if kick_fd < 0 then error("ink-eval: open " .. KICK .. " failed") end
input:fdopen(kick_fd, KICK, "ink-kick")

local handleMiscEv = input.handleMiscEv
input.handleMiscEv = function(this, ev)
    if ev.code == MSC_RAW and ev.value == EVAL_MAGIC then
        UIManager:nextTick(run)
        return
    end
    if ev.code == MSC_RAW and ev.value == IDLE_MAGIC then
        arm()
        return
    end
    return handleMiscEv(this, ev)
end

-- Every panel update on mxcfb readers goes through mech_refresh; dirty flags can't be used, because
-- widgets that are covered or closed stay in UIManager._dirty.
local screen = Device.screen
local mechRefresh = screen.mech_refresh
if mechRefresh then
    screen.mech_refresh = function(...)
        if armed then
            -- The .painted file lets ink tell "still working" from "the tap did nothing".
            if not painted then writeAtomic(IDLE_OUT .. ".painted", uptime()) end
            painted = uptime()
        end
        return mechRefresh(...)
    end
end

local waitEvent = input.waitEvent
input.waitEvent = function(this, now, deadline)
    if armed and painted and (not deadline or deadline - now > HORIZON) then
        armed = false
        if screen.mech_wait_update_complete and screen.marker then
            screen:mech_wait_update_complete(screen.marker)
        end
        writeAtomic(IDLE_OUT, painted .. " " .. uptime())
    end
    return waitEvent(this, now, deadline)
end
