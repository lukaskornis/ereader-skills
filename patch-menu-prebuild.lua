-- The reader's menu table is built 1 s after a book opens, so the first menu tap skips ~190 ms.
local UIManager = require("ui/uimanager")
local ReaderMenu = require("apps/reader/modules/readermenu")

local original_on_reader_ready = ReaderMenu.onReaderReady
ReaderMenu.onReaderReady = function(self, ...)
    UIManager:scheduleIn(1, function()
        if self.tab_item_table == nil then
            self:setUpdateItemTable()
        end
    end)
    return original_on_reader_ready(self, ...)
end
