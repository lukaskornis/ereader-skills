-- Waits up to arg[1] ms for a touch, with the touchscreen grabbed so Nickel never sees it.
-- Holds the grab until the finger lifts, so Nickel gets no stray release. Exit 0 = touched, 1 = timed out.
local ffi = require("ffi")
ffi.cdef[[
int open(const char *path, int flags);
int close(int fd);
int ioctl(int fd, unsigned long req, ...);
long read(int fd, void *buf, unsigned long n);
struct kb_pollfd { int fd; short events; short revents; };
int poll(struct kb_pollfd *fds, unsigned long n, int timeout);
struct kb_timespec { long sec; long nsec; };
int clock_gettime(int clk, struct kb_timespec *ts);
struct kb_ev { int32_t sec, usec; uint16_t type, code; int32_t value; };
]]
local C = ffi.C
local O_NONBLOCK, EVIOCGRAB, CLOCK_MONOTONIC = 0x800, 0x40044590, 1
local EV_KEY, EV_ABS, BTN_TOUCH, ABS_MT_TOUCH_MAJOR = 0x01, 0x03, 0x14A, 0x30

local function touch_node()
    local f = io.open("/proc/bus/input/devices")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    for block in text:gmatch("(.-)\n\n") do
        if block:find('Name="[^"]*touch') or block:find('Name="[^"]*[Ee]lan') then
            local ev = block:match("Handlers=.-(event%d+)")
            if ev then return "/dev/input/" .. ev end
        end
    end
end

local function now_ms()
    local ts = ffi.new("struct kb_timespec")
    C.clock_gettime(CLOCK_MONOTONIC, ts)
    return tonumber(ts.sec) * 1000 + tonumber(ts.nsec) / 1e6
end

local node = touch_node()
if not node then io.stderr:write("no touchscreen\n") os.exit(1) end
local fd = C.open(node, O_NONBLOCK)
if fd < 0 then io.stderr:write("cannot open " .. node .. "\n") os.exit(1) end
if C.ioctl(fd, EVIOCGRAB, ffi.cast("int", 1)) ~= 0 then io.stderr:write("cannot grab\n") end

local evs = ffi.new("struct kb_ev[64]")
local pfd = ffi.new("struct kb_pollfd[1]")
pfd[0].fd, pfd[0].events = fd, 1

-- Returns "down", "up" or nil for one batch of events.
local function read_batch()
    local n = tonumber(C.read(fd, evs, ffi.sizeof(evs)))
    if n <= 0 then return nil end
    local state
    for i = 0, n / ffi.sizeof("struct kb_ev") - 1 do
        local e = evs[i]
        if (e.type == EV_KEY and e.code == BTN_TOUCH) or (e.type == EV_ABS and e.code == ABS_MT_TOUCH_MAJOR) then
            state = e.value > 0 and "down" or "up"
        elseif e.type == EV_ABS and not state then
            state = "down"
        end
    end
    return state
end

local function wait_for(want, ms)
    local deadline = now_ms() + ms
    while true do
        local left = math.floor(deadline - now_ms())
        if left <= 0 then return false end
        if C.poll(pfd, 1, left) > 0 and read_batch() == want then return true end
    end
end

local touched = wait_for("down", tonumber(arg[1]) or 3000)
if touched then wait_for("up", 3000) end
C.ioctl(fd, EVIOCGRAB, ffi.cast("int", 0))
C.close(fd)
os.exit(touched and 0 or 1)
