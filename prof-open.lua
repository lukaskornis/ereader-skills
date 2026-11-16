-- Book open profiler: `ink -d kobo eval - < prof-open.lua`, open a book, then `ink eval 'table.concat(_G.PO.log, "\n")'`.
local time = require("ui/time")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local ReaderUI = require("apps/reader/readerui")
local DocumentRegistry = require("document/documentregistry")
local FileManager = require("apps/filemanager/filemanager")
_G.PO = _G.PO or { orig = {} }
local P = _G.PO
P.log = {}
local function note(fmt, ...)
  if not P.t0 then return end
  table.insert(P.log, string.format("%6.3f " .. fmt, time.to_s(time.now() - P.t0), ...))
end
local function wrap(tbl, name, label)
  if not P.orig[label] then P.orig[label] = tbl[name] end
  local f = P.orig[label]
  tbl[name] = function(...)
    if label == "RUI.showReader" then P.t0 = time.now(); P.log = {} end
    local s = time.now()
    local r = table.pack(f(...))
    note("%-24s dur %.3f", label, time.to_s(time.now() - s))
    return table.unpack(r, 1, r.n)
  end
end
wrap(ReaderUI, "showReader", "RUI.showReader")
wrap(ReaderUI, "doShowReader", "RUI.doShowReader")
wrap(ReaderUI, "init", "RUI.init")
wrap(DocumentRegistry, "openDocument", "DR.openDocument")
wrap(FileManager, "onClose", "FM.onClose")
wrap(UIManager, "forceRePaint", "UI.forceRePaint")
wrap(UIManager, "_repaint", "UI._repaint")
if not P.orig.mech then P.orig.mech = Screen.mech_refresh end
local mech = P.orig.mech
Screen.mech_refresh = function(self, refreshtype, waveform, x, y, w, h, dither)
  note("refresh type %s wf %s %dx%d+%d+%d", tostring(refreshtype), tostring(waveform), w or -1, h or -1, x or -1, y or -1)
  return mech(self, refreshtype, waveform, x, y, w, h, dither)
end
-- plugin/module inits inside ReaderUI:init
if not P.orig.registerModule then P.orig.registerModule = ReaderUI.registerModule end
local reg = P.orig.registerModule
ReaderUI.registerModule = function(self, name, ui_module, always_active)
  note("module %s", tostring(name))
  return reg(self, name, ui_module, always_active)
end
local CreDocument = require("document/credocument")
wrap(CreDocument, "loadDocument", "Cre.loadDocument")
wrap(CreDocument, "render", "Cre.render")
wrap(require("readhistory"), "addItem", "History.addItem")
local BookList = require("ui/widget/booklist")
wrap(BookList, "setBookInfoCache", "BookList.setBookInfoCache")
if not P.orig.handleEvent then P.orig.handleEvent = ReaderUI.handleEvent end
local he = P.orig.handleEvent
local timed = { DocSettingsLoad = true, ReadSettings = true, ReaderReady = true, SetDimensions = true, PageUpdate = true, PosUpdate = true }
ReaderUI.handleEvent = function(self, ev)
  if not timed[ev.handler and ev.handler:sub(3)] then return he(self, ev) end
  local s = time.now()
  local r = he(self, ev)
  note("event %-18s dur %.3f", ev.handler, time.to_s(time.now() - s))
  return r
end
return "ok"
