-- Page turns refresh with the "fast" waveform (DU on Kobo Mk6 and Kindle) instead of "partial" (AUTO).
-- The full_refresh_count flash still happens: the promotion turn is passed through as "partial".
-- Fast swipes are coalesced: a turn within TURN_WINDOW of the last refreshed one only redraws the
-- framebuffer, and one refresh at the end of the window shows the latest page. Without it the panel
-- queues every update and the last page lands ~1 s after a burst of 10 swipes.
-- Toggle: reader menu, gear tab, first item "Page turns: Fast / Quality" (setting fast_page_turn),
-- and the gesture action "Toggle fast page turns". Default fast, except Kindle: its DU text looks jagged.
-- Only on e-ink screens.
local Device = require("device")
if not Device:hasEinkScreen() then return end

local UIManager = require("ui/uimanager")
local time = require("ui/time")
local ReaderRolling = require("apps/reader/modules/readerrolling")
local ReaderPaging = require("apps/reader/modules/readerpaging")
local MenuSorter = require("ui/menusorter")
local Dispatcher = require("dispatcher")
local Notification = require("ui/widget/notification")
local _ = require("gettext")

local function isFast()
    local fast = G_reader_settings:readSetting("fast_page_turn")
    if fast == nil then return not Device:isKindle() end
    return fast
end

local function pageTurnLabel()
    return isFast() and _("Page turns: Fast") or _("Page turns: Quality")
end

local function toggleFast()
    G_reader_settings:saveSetting("fast_page_turn", not isFast())
end

local page_turn_item = {
    text_func = pageTurnLabel,
    help_text = _("Fast turns use the black-and-white waveform: quicker, but text edges look jagged until the next full refresh. Quality turns use greys."),
    keep_menu_open = true,
    callback = function(touchmenu)
        toggleFast()
        touchmenu:updateItems()
    end,
    separator = true,
}

-- The menu tables are rebuilt with dofile on every menu setup, and MenuSorter consumes them,
-- so the item is added just before each sort. The order table is a cached module, so insert once.
local original_merge_and_sort = MenuSorter.mergeAndSort
MenuSorter.mergeAndSort = function(self, name, items, order)
    if name == "reader" and order.setting then
        items.page_turn_mode = page_turn_item
        if order.setting[1] ~= "page_turn_mode" then
            table.insert(order.setting, 1, "page_turn_mode")
        end
    end
    return original_merge_and_sort(self, name, items, order)
end

Dispatcher:registerAction("toggle_fast_page_turn",
    { category = "none", event = "ToggleFastPageTurn", title = _("Toggle fast page turns"), reader = true })

local function onToggleFastPageTurn()
    toggleFast()
    Notification:notify(pageTurnLabel(), Notification.SOURCE_DISPATCHER)
    return true
end

local turning_page = false

local function wrapPageTurn(module)
    local original = module.onGotoViewRel
    module.onGotoViewRel = function(...)
        turning_page = true
        local ok, result = pcall(original, ...)
        turning_page = false
        if not ok then error(result, 0) end
        return result
    end
end
wrapPageTurn(ReaderRolling)
wrapPageTurn(ReaderPaging)
ReaderRolling.onToggleFastPageTurn = onToggleFastPageTurn
ReaderPaging.onToggleFastPageTurn = onToggleFastPageTurn

local TURN_WINDOW = time.s(0.3)
local last_turn_refresh = 0
local flush_scheduled = false
local swallow_fallback = false

local function flushDeferredTurn()
    flush_scheduled = false
    last_turn_refresh = 0
    turning_page = true
    UIManager:setDirty(nil, "partial")
    turning_page = false
end

local original_repaint = UIManager._repaint
UIManager._repaint = function(self)
    original_repaint(self)
    swallow_fallback = false
end

local original_refresh = UIManager._refresh
UIManager._refresh = function(self, mode, region, dither)
    -- _repaint's own catch-all "partial" for a page whose refresh was deferred.
    if swallow_fallback and not turning_page and mode == "partial" and not region then
        swallow_fallback = false
        return
    end
    if turning_page and mode == "partial" and not region and not self.currently_scrolling then
        local now = time.now()
        if now - last_turn_refresh < TURN_WINDOW then
            swallow_fallback = true
            if not flush_scheduled then
                flush_scheduled = true
                UIManager:scheduleIn(time.to_s(TURN_WINDOW - (now - last_turn_refresh)), flushDeferredTurn)
            end
            return
        end
        last_turn_refresh = now
    end
    -- Only the reader's whole-screen repaint; regional and scrolling refreshes keep their own modes.
    if not turning_page or not isFast() or mode ~= "partial" or region or self.currently_scrolling or self.refresh_counted then
        return original_refresh(self, mode, region, dither)
    end
    local count = self.FULL_REFRESH_COUNT
    if count > 0 and (self.refresh_count + 1) % count == count - 1 then
        return original_refresh(self, mode, region, dither)
    end
    if count > 0 then
        self.refresh_count = (self.refresh_count + 1) % count
    end
    self.refresh_counted = true
    return original_refresh(self, "fast", region, dither)
end
