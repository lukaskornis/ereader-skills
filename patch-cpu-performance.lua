-- ink speed patch: pin the CPU at full clock while KOReader runs (the launcher restores the old governor on exit).
-- Measured on the Aura ONE 2026-11-15: page turns ~0.25 s faster than interactive. See ereader-skills/speed-kobo.md.
-- Toggle: Settings > Device > Full CPU speed (setting cpu_performance, on by default). Off uses the saving
-- governor (interactive on Kobo, ondemand on Kindle), which saves battery. Without a writable governor, nothing.
local MenuSorter = require("ui/menusorter")
local _ = require("gettext")

local CPUFREQ = "/sys/devices/system/cpu/cpu0/cpufreq/"

local function readFile(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local available = readFile(CPUFREQ .. "scaling_available_governors") or ""
if not available:find("performance", 1, true) then return end
local saving_governor = available:find("interactive", 1, true) and "interactive" or "ondemand"

local function applyGovernor()
    local f = io.open(CPUFREQ .. "scaling_governor", "w")
    if not f then return end
    f:write(G_reader_settings:nilOrTrue("cpu_performance") and "performance" or saving_governor)
    f:close()
end
applyGovernor()

local cpu_performance_item = {
    text = _("Full CPU speed"),
    help_text = _("Keep the CPU at full clock. Pages and menus react a little faster; off saves battery."),
    checked_func = function() return G_reader_settings:nilOrTrue("cpu_performance") end,
    callback = function()
        G_reader_settings:flipNilOrTrue("cpu_performance")
        applyGovernor()
    end,
}

-- The menu tables are rebuilt with dofile on every menu setup, and MenuSorter consumes them,
-- so the item is added just before each sort.
local original_merge_and_sort = MenuSorter.mergeAndSort
MenuSorter.mergeAndSort = function(self, name, items, order)
    local device = order.device
    if device then
        items.cpu_performance = cpu_performance_item
        local listed = false
        local position = #device + 1
        for i, id in ipairs(device) do
            if id == "cpu_performance" then listed = true end
            if id == "autostandby" then position = i end
        end
        if not listed then table.insert(device, position, "cpu_performance") end
    end
    return original_merge_and_sort(self, name, items, order)
end
