-- Device side of `ink type`: reads raw keystrokes from stdin (a raw pty over ssh) and injects each
-- one as an EV_MSC/MSC_RAW event with value 0x5457xxxx ("TW" + byte) into the gpio-keys node, which
-- KOReader reads; typewriter.koplugin picks them up. Everything a read returns goes out in one write,
-- so KOReader gets a burst in one input batch.
local ffi = require("ffi")
ffi.cdef[[
struct tw_ev { int32_t sec, usec; uint16_t type, code; int32_t value; };
int open(const char *path, int flags);
long write(int fd, const void *buf, unsigned long n);
long read(int fd, void *buf, unsigned long n);
int usleep(unsigned int us);
]]
local C = ffi.C
local fd = C.open(arg[1] or "/dev/input/event0", 1)
assert(fd >= 0, "cannot open the buttons node")
local MAGIC = 0x54570000
local inbuf = ffi.new("uint8_t[256]")
local evs = ffi.new("struct tw_ev[512]")
local esc = 0 -- 1 after ESC, 2 inside a CSI/SS3 sequence: arrow and function keys are dropped
while true do
    local n = tonumber(C.read(0, inbuf, 256))
    if n <= 0 then break end
    local count = 0
    for i = 0, n - 1 do
        local b = inbuf[i]
        if esc == 1 then
            esc = (b == 0x5B or b == 0x4F) and 2 or 0
            b = nil
        elseif esc == 2 then
            if b >= 0x40 and b <= 0x7E then esc = 0 end
            b = nil
        elseif b == 0x1B then
            esc, b = 1, nil
        elseif b == 0x03 or b == 0x04 then
            os.exit(0)
        elseif b == 0x7F or b == 0x08 then
            b = 8
        elseif b == 0x0D or b == 0x0A then
            b = 10
        elseif b == 0x09 then
            b = 0x20
        elseif b < 0x20 then
            b = nil
        end
        if b then
            -- The evdev client buffer holds about 64 events and drops the rest, so a paste goes out
            -- in chunks with a pause for KOReader to read them; typing never fills one.
            if count == 32 then
                C.write(fd, evs, count * ffi.sizeof("struct tw_ev"))
                C.usleep(30000)
                count = 0
            end
            evs[count].type, evs[count].code, evs[count].value = 4, 3, MAGIC + b
            evs[count + 1].type, evs[count + 1].code, evs[count + 1].value = 0, 0, 0
            count = count + 2
        end
    end
    if count > 0 then C.write(fd, evs, count * ffi.sizeof("struct tw_ev")) end
end
