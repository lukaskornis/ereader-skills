local time = require("ui/time")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local B = _G.BT
B.orig.mech = B.orig.mech or Screen.mech_refresh
local orig = B.orig.mech
B.seq = 0
Screen.mech_refresh = function(self, flash, wf, ...)
  local s = time.now()
  orig(self, flash, wf, ...)
  B.seq = B.seq + 1
  local my, marker = B.seq, self.marker
  if not B.t0 then B.t0 = s end
  table.insert(B.log, string.format("refresh wf %3d   %6.3f %6.3f m%d", wf or -1, time.to_s(s - B.t0), time.to_s(time.now() - s), marker))
  UIManager:scheduleIn(0.8, function()
    if B.seq ~= my then return end
    self:mech_wait_update_complete(marker)
    table.insert(B.log, string.format("panel done m%d    %6.3f", marker, time.to_s(time.now() - B.t0)))
  end)
end
return "ok"
