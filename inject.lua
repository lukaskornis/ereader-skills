-- Injects touch gestures into the e-reader's touchscreen evdev node.
-- Runs on the device under KOReader's LuaJIT, fed through stdin by `ink`.
-- Usage: luajit - <swap> <mirror_x> <mirror_y> <view_w> <view_h> tap X Y
--                                                          hold X Y MS
--                                                          swipe X1 Y1 X2 Y2 MS
-- Coordinates are framebuffer pixels, the same space `ink shot` returns.
local ffi = require("ffi")
local bit = require("bit")
ffi.cdef[[
int open(const char *path, int flags);
int close(int fd);
int ioctl(int fd, unsigned long request, void *arg);
long write(int fd, const void *buf, unsigned long n);
int usleep(unsigned int usec);
struct absinfo { int32_t value, minimum, maximum, fuzz, flat, resolution; };
struct input_event { long sec; long usec; uint16_t type; uint16_t code; int32_t value; };
]]

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local ABS_X, ABS_Y, ABS_PRESSURE = 0x00, 0x01, 0x18
local ABS_MT_TOUCH_MAJOR, ABS_MT_WIDTH_MAJOR = 0x30, 0x32
local ABS_MT_SLOT, ABS_MT_X, ABS_MT_Y, ABS_MT_TRACKING_ID = 0x2f, 0x35, 0x36, 0x39
local SYN_MT_REPORT = 2
local BTN_TOUCH, BTN_TOOL_FINGER = 0x14a, 0x145
local O_RDWR = 2
local EVIOCGABS_BASE = 0x80184540 -- _IOR('E', 0x40 + abs, struct absinfo)

local function abs_max(fd, code)
    local info = ffi.new("struct absinfo")
    if ffi.C.ioctl(fd, EVIOCGABS_BASE + code, info) ~= 0 then return 0 end
    return info.maximum
end

-- The touchscreen is the first node reporting a real X range, multitouch or not.
local function find_touch()
    for i = 0, 15 do
        local fd = ffi.C.open("/dev/input/event" .. i, O_RDWR)
        if fd >= 0 then
            local mt_x, mt_y = abs_max(fd, ABS_MT_X), abs_max(fd, ABS_MT_Y)
            if mt_x > 0 then return fd, true, mt_x, mt_y end
            local st_x, st_y = abs_max(fd, ABS_X), abs_max(fd, ABS_Y)
            if st_x > 0 then return fd, false, st_x, st_y end
            ffi.C.close(fd)
        end
    end
    error("no touchscreen found under /dev/input")
end

local swap, mirror_x, mirror_y = arg[1] == "1", arg[2] == "1", arg[3] == "1"
local view_w, view_h = tonumber(arg[4]), tonumber(arg[5])
local gesture = arg[6]
local fd, multitouch, max_x, max_y = find_touch()
-- Slotless multitouch (Kobo Aura ONE's elan, KOReader's "phoenix" protocol) marks a lift with
-- TOUCH_MAJOR 0 instead of TRACKING_ID -1, and repeats the tracking id on every frame.
local slotless = multitouch and abs_max(fd, ABS_MT_SLOT) == 0
local ev = ffi.new("struct input_event")
local ev_size = ffi.sizeof(ev)

local function emit(type, code, value)
    ev.type, ev.code, ev.value = type, code, value
    assert(ffi.C.write(fd, ev, ev_size) == ev_size, "evdev write failed")
end

-- Inverse of KOReader's input adjustments: it swaps axes first, then mirrors.
local function to_raw(x, y)
    if mirror_x then x = view_w - 1 - x end
    if mirror_y then y = view_h - 1 - y end
    local w, h = view_w, view_h
    if swap then x, y, w, h = y, x, h, w end
    return math.floor(x * max_x / (w - 1) + 0.5), math.floor(y * max_y / (h - 1) + 0.5)
end

local function contact(pressed)
    emit(EV_ABS, ABS_MT_TRACKING_ID, 0)
    emit(EV_ABS, ABS_MT_TOUCH_MAJOR, pressed and 1 or 0)
    emit(EV_ABS, ABS_MT_WIDTH_MAJOR, pressed and 1 or 0)
end

local last_x, last_y
local function move(x, y)
    last_x, last_y = x, y
    if slotless then contact(true) end
    local rx, ry = to_raw(x, y)
    emit(EV_ABS, multitouch and ABS_MT_X or ABS_X, rx)
    emit(EV_ABS, multitouch and ABS_MT_Y or ABS_Y, ry)
    if slotless then emit(EV_SYN, SYN_MT_REPORT, 0) end
end

local function down(x, y)
    if multitouch and not slotless then
        emit(EV_ABS, ABS_MT_SLOT, 0)
        emit(EV_ABS, ABS_MT_TRACKING_ID, bit.band(os.time(), 0x7fff))
    end
    move(x, y)
    if not multitouch then emit(EV_ABS, ABS_PRESSURE, 100) end
    emit(EV_KEY, BTN_TOUCH, 1)
    emit(EV_KEY, BTN_TOOL_FINGER, 1)
    emit(EV_SYN, 0, 0)
end

local function up()
    if slotless then
        contact(false)
        local rx, ry = to_raw(last_x, last_y)
        emit(EV_ABS, ABS_MT_X, rx)
        emit(EV_ABS, ABS_MT_Y, ry)
        emit(EV_SYN, SYN_MT_REPORT, 0)
    elseif multitouch then
        emit(EV_ABS, ABS_MT_TRACKING_ID, -1)
    else
        emit(EV_ABS, ABS_PRESSURE, 0)
    end
    emit(EV_KEY, BTN_TOUCH, 0)
    emit(EV_KEY, BTN_TOOL_FINGER, 0)
    emit(EV_SYN, 0, 0)
end

local n = function(i) return tonumber(arg[i]) end
if gesture == "tap" or gesture == "hold" then
    down(n(7), n(8))
    ffi.C.usleep((gesture == "hold" and n(9) or 60) * 1000)
    up()
elseif gesture == "swipe" then
    local x1, y1, x2, y2, ms = n(7), n(8), n(9), n(10), n(11)
    local steps = 10
    down(x1, y1)
    for s = 1, steps do
        ffi.C.usleep(math.floor(ms * 1000 / steps))
        move(x1 + (x2 - x1) * s / steps, y1 + (y2 - y1) * s / steps)
        emit(EV_SYN, 0, 0)
    end
    up()
else
    error("unknown gesture " .. tostring(gesture))
end
ffi.C.close(fd)
print("ok " .. gesture)
