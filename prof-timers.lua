local time = require("ui/time")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
_G.PROF = _G.PROF or { log = {} }
local P = _G.PROF
P.log = {}
P.t0 = nil
local function wrap(tbl, name, label)
  P.orig = P.orig or {}
  local key = label
  if not P.orig[key] then P.orig[key] = tbl[name] end
  local f = P.orig[key]
  tbl[name] = function(...)
    local s = time.now()
    if label == "RUI.onClose" or label == "RUI.onHome" then if not P.t0 or (s - P.t0) > time.s(5) then P.log = {} end P.t0 = P.t0 and (s - P.t0) < time.s(5) and P.t0 or s end
    if label == "RUI.onClose" then local fh = io.open("/proc/uptime"); P.up = fh:read("*n"); fh:close() end
    local r = table.pack(f(...))
    local e = time.now()
    if label:sub(1,2) == "R." then P.rlog = P.rlog or {}; table.insert(P.rlog, string.format("%s %.3f dur %.3f %s", label, time.to_s(s), time.to_s(e - s), tostring((...) and select(4, ...) or ""))) end
    if P.t0 then
      table.insert(P.log, string.format("%-22s start %6.3f dur %6.3f", label, time.to_s(s - P.t0), time.to_s(e - s)))
    end
    return table.unpack(r, 1, r.n)
  end
end
wrap(ReaderUI, "onHome", "RUI.onHome")
wrap(ReaderUI, "onClose", "RUI.onClose")
wrap(ReaderUI, "closeDocument", "RUI.closeDocument")
wrap(ReaderUI, "saveSettings", "RUI.saveSettings")
wrap(FileManager, "showFiles", "FM.showFiles")
wrap(FileManager, "init", "FM.init")
wrap(UIManager, "_repaint", "UI._repaint")
for _, n in ipairs({"refreshFull","refreshPartial","refreshFlashPartial","refreshUI","refreshFlashUI","refreshFast"}) do
  if Screen[n] then wrap(Screen, n, "S."..n) end
end
local SW = package.loaded["shelfwidget"]
if SW then wrap(SW, "paintTo", "Shelf.paintTo") end
wrap(FileManager, "paintTo", "FM.paintTo")
local rep = P.orig["UI._repaint"]
for i = 1, 60 do
  local n, v = debug.getupvalue(rep, i)
  if not n then break end
  if n == "refresh_methods" then
    for mode, fn in pairs(v) do
      local holder = { f = P.orig["R."..mode] or fn }
      P.orig["R."..mode] = holder.f
      P.orig["R."..mode] = nil
      local base = holder.f
      P.orig["R."..mode] = base
      wrap(holder, "f", "R."..mode)
      v[mode] = holder.f
    end
  end
end
return "ok"
