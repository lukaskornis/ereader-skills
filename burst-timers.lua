local time = require("ui/time")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local RR = require("apps/reader/modules/readerrolling")
local RV = require("apps/reader/modules/readerview")
_G.BT = _G.BT or { orig = {} }
local B = _G.BT
B.log = {}
B.t0 = nil
local function wrap(tbl, name, label)
  if not B.orig[label] then B.orig[label] = tbl[name] end
  local f = B.orig[label]
  tbl[name] = function(...)
    local s = time.now()
    if not B.t0 then B.t0 = s end
    local r = table.pack(f(...))
    local e = time.now()
    table.insert(B.log, string.format("%-18s %6.3f %6.3f", label, time.to_s(s - B.t0), time.to_s(e - s)))
    return table.unpack(r, 1, r.n)
  end
end
wrap(RR, "onGotoViewRel", "RR.gotoViewRel")
wrap(RV, "paintTo", "RV.paintTo")
wrap(UIManager, "_repaint", "UI._repaint")
for _, n in ipairs({"refreshFull","refreshPartial","refreshUI","refreshFast","refreshFlashUI","refreshFlashPartial"}) do
  if Screen[n] then wrap(Screen, n, "S."..n) end
end
return "ok"
