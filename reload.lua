-- Hot-reloads one plugin inside the running KOReader; `ink reload` prepends `local NAME = "<plugin>"`.
-- Reloads main.lua and every module loaded from the plugin's folder, then reopens the file manager
-- (or the book), which creates the plugin instance afresh. Returns the milliseconds it took.
local PluginLoader = require("pluginloader")
local time = require("ui/time")
local t0 = time.now()

local index, old
for i, plugin in ipairs(PluginLoader.enabled_plugins or {}) do
    if plugin.name == NAME then index, old = i, plugin end
end
if not old then error("plugin not loaded: " .. NAME) end

local own = old.path .. "/?.lua"
for module in pairs(package.loaded) do
    if package.searchpath(module, own) then package.loaded[module] = nil end
end
local new = dofile(old.path .. "/main.lua")
local ok_meta, meta = pcall(dofile, old.path .. "/_meta.lua")
if ok_meta and type(meta) == "table" then
    for k, v in pairs(meta) do
        if k ~= "name" then new[k] = v end
    end
end
new.path, new.name = old.path, old.name
PluginLoader.enabled_plugins[index] = new

local FileManager = require("apps/filemanager/filemanager")
local ReaderUI = require("apps/reader/readerui")
if FileManager.instance then
    local path = FileManager.instance.file_chooser.path
    FileManager.instance:onClose()
    FileManager:showFiles(path)
elseif ReaderUI.instance then
    ReaderUI.instance:reloadDocument()
end
return string.format("reloaded %s in %d ms", NAME, time.to_ms(time.since(t0)))
