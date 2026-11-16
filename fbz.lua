-- Reads N bytes of /dev/fb0 and writes "Z\n" plus a zstd frame, or "R\n" plus raw bytes
-- when KOReader ships no libzstd. Run by `ink shot` from the KOReader folder.
local ffi = require("ffi")
local raw = assert(io.open("/dev/fb0", "rb")):read(tonumber(arg[1]))
local ok, z = pcall(ffi.load, "libs/libzstd.so.1")
if not ok then
    io.stdout:write("R\n", raw)
    return
end
ffi.cdef[[
size_t ZSTD_compressBound(size_t srcSize);
size_t ZSTD_compress(void* dst, size_t dstCapacity, const void* src, size_t srcSize, int level);
]]
local cap = z.ZSTD_compressBound(#raw)
local buf = ffi.new("uint8_t[?]", cap)
io.stdout:write("Z\n", ffi.string(buf, z.ZSTD_compress(buf, cap, raw, #raw, 1)))
