--[[
Claude chat: each conversation is one HTML file in <home>/Claude, shown in a full-screen chat view (one question
and its reply at a time, steering buttons below) and also readable as a book (fonts, margins, TOC of questions).
The file carries its own state (session id, turns) in a leading comment, so it survives moves and renames.
Replies come from the Mac relay (claudechat/relay.py), which runs `claude -p` on the subscription, and are shown
live as Claude writes them.
In the book, steering links at the end use the claude: scheme and are caught before ReaderLink treats them as
external. Selecting text adds Claude buttons to the highlight dialog: in a chat they continue it, in any other
book they start a new chat about the passage.
]]
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LeftContainer = require("ui/widget/container/leftcontainer")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template
local Screen = Device.screen

local HEADER = "<!--claudechat "
local REQUEST_TIMEOUT_S = 600
local CONNECT_TIMEOUT_S = 15
-- Longest silence before giving up; Claude Code can take ~15 s to start on a cold Mac.
local READ_TIMEOUT_S = 60
-- How often the live page picks up new text: about one e-ink partial refresh.
local LIVE_REFRESH_S = 0.4
-- Wait after each failed attempt; the last entry is just the pause before giving up.
local RETRY_DELAYS_S = { 2, 4, 8, 16, 0 }
local MODELS = { { id = "sonnet", text = "Sonnet" }, { id = "opus", text = "Opus" }, { id = "haiku", text = "Haiku" } }

local STEER = {
    { id = "deeper", text = _("Go deeper"),
      prompt = "Go deeper into what you just said: the mechanisms, the nuances, the parts that are less obvious." },
    { id = "example", text = _("Example"),
      prompt = "Give one vivid, concrete example or short story that makes your last answer tangible." },
    { id = "simpler", text = _("Simpler"),
      prompt = "Explain your last answer again in simple terms for a curious newcomer, with an everyday analogy." },
    { id = "shorter", text = _("Shorter"),
      prompt = "Condense your last answer to its essence in one short paragraph." },
    { id = "counter", text = _("Counterpoint"),
      prompt = "Give the strongest counterpoint or opposing view to your last answer, argued fairly." },
}

local LOOKUP = {
    { id = "simple", text = _("Explain simply"), label = "In simple terms: %s",
      prompt = "Explain \"%s\" in simple terms, briefly, with an everyday analogy." },
    { id = "more", text = _("More on that"), label = "More on %s",
      prompt = "Tell me more about \"%s\": what matters about it and why." },
    { id = "etymology", text = _("Etymology"), label = "Etymology of %s",
      prompt = "Give the etymology of \"%s\": its roots, how its meaning shifted, and related words. Keep it short." },
    { id = "similar", text = _("Similar concepts"), label = "Concepts near %s",
      prompt = "Name and briefly explain concepts similar or closely related to \"%s\", and how each differs." },
}

local ClaudeChat = WidgetContainer:extend{
    name = "claudechat",
    is_doc_only = false,
}

local function config()
    return G_reader_settings:readSetting("claudechat") or {}
end

local function saveConfig(cfg)
    G_reader_settings:saveSetting("claudechat", cfg)
end

local function chatsDir()
    local home = G_reader_settings:readSetting("home_dir") or require("device").home_dir or DataStorage:getDataDir()
    local dir = home .. "/Claude"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

local function escape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Shared by the book and the chat view: what Claude may use besides prose.
local CONTENT_CSS = [[
table { border-collapse: collapse; margin: 0.8em 0; }
th, td { border: 1px solid black; padding: 0.2em 0.5em; text-align: left; vertical-align: top; }
img, svg { max-width: 100%; }
img { display: block; margin: 0.8em auto; }
]]

local function shorten(text, max)
    text = util.cleanupSelectedText(text):gsub("%s+", " ")
    if #text <= max then return text end
    local cut = text:sub(1, max):gsub("[\192-\255][\128-\191]*$", "") -- never split a UTF-8 character
    return cut .. "…"
end

-- Reads the state comment at the top of a chat file; nil for any other file.
local function loadChat(file)
    if not file or not file:match("%.html$") then return end
    local f = io.open(file, "r")
    if not f then return end
    local first = f:read("*l")
    f:close()
    if not first or first:sub(1, #HEADER) ~= HEADER then return end
    local state = first:sub(#HEADER + 1):gsub("%-%->$", "")
    local ok, chat = pcall(JSON.decode, state)
    if ok and type(chat) == "table" then return chat end
end

local function render(chat)
    local out = {}
    -- "--" ends an HTML comment; in JSON it can only sit inside a string, where - decodes back to "-".
    local state = JSON.encode(chat):gsub("%-%-", "-\\u002d")
    table.insert(out, HEADER .. state .. "-->")
    table.insert(out, [[<html><head><meta charset="utf-8"/><title>]] .. escape(chat.title) .. [[</title><style>
h1 { font-size: 1.4em; text-align: center; margin: 1em 0 1.5em; }
h2 { font-size: 1em; font-style: italic; font-weight: normal; text-align: left; page-break-before: auto;
     margin: 2.2em 0 0.9em; padding-top: 0.6em; border-top: 1px solid #888; }
h3 { font-size: 1em; font-variant: small-caps; margin: 1.2em 0 0.4em; }
p { text-indent: 0; margin: 0 0 0.7em; text-align: justify; }
blockquote { margin: 0.6em 1.5em; font-style: italic; }
p.steer { text-align: center; margin-top: 2.5em; line-height: 2.2; text-indent: 0; page-break-inside: avoid; }
p.steer a { text-decoration: none; font-weight: bold; white-space: nowrap; hyphens: none; }
]] .. CONTENT_CSS .. [[</style></head><body>]])
    table.insert(out, "<h1>" .. escape(chat.title) .. "</h1>")
    for i, turn in ipairs(chat.turns) do
        if turn.role == "user" then
            table.insert(out, '<h2 id="t' .. i .. '">' .. escape(turn.label or turn.text) .. "</h2>")
        else
            table.insert(out, '<div id="t' .. i .. '">' .. turn.html .. "</div>")
        end
    end
    local links = {}
    for _, s in ipairs(STEER) do
        table.insert(links, '<a href="claude:' .. s.id .. '">' .. escape(s.text) .. "</a>")
    end
    table.insert(out, '<p class="steer">' .. table.concat(links, " · ") .. "<br/>"
        .. '<a href="claude:ask">' .. escape(_("Ask…")) .. '</a> · <a href="claude:new">'
        .. escape(_("New chat")) .. "</a></p></body></html>")
    return table.concat(out, "\n")
end

local function saveChat(file, chat)
    local f, err = io.open(file .. ".part", "w")
    if not f then return false, err end
    f:write(render(chat))
    f:close()
    return os.rename(file .. ".part", file)
end

-- One plain HTTP POST that hands body bytes to on_body the moment they arrive (luasocket's http.request
-- waits for 2 KB blocks). Returns the error, or nil once the relay closed the connection.
local function postStreaming(host, path, headers, body, on_body)
    local socket = require("socket")
    local address, port = host:match("^([^:]+):?(%d*)$")
    local sock = socket.tcp()
    sock:settimeout(CONNECT_TIMEOUT_S)
    local ok, err = sock:connect(address, tonumber(port) or 80)
    if not ok then return err end
    local request = { "POST " .. path .. " HTTP/1.0", "Host: " .. host, "Content-Length: " .. #body }
    for name, value in pairs(headers) do
        table.insert(request, name .. ": " .. value)
    end
    sock:send(table.concat(request, "\r\n") .. "\r\n\r\n" .. body)
    sock:settimeout(0.2)
    local head, in_body, idle_since = "", false, socket.gettime()
    while true do
        local data, recv_err, partial = sock:receive(8192)
        local chunk = data or partial or ""
        if chunk ~= "" then
            idle_since = socket.gettime()
            if in_body then
                on_body(chunk)
            else
                head = head .. chunk
                local split = head:find("\r\n\r\n", 1, true)
                if split then
                    in_body = true
                    if #head > split + 3 then on_body(head:sub(split + 4)) end
                end
            end
        end
        if recv_err == "closed" then break end
        if recv_err and recv_err ~= "timeout" then
            sock:close()
            return recv_err
        end
        if socket.gettime() - idle_since > READ_TIMEOUT_S then
            sock:close()
            return "timeout"
        end
    end
    sock:close()
end

-- Runs in a forked subprocess: streams the relay's reply (one JSON object per line) into fd as it arrives.
-- Only "no answer at all" is retried: Wi-Fi waking up or the relay restarting clear within seconds, while a
-- relay error reply means Claude itself failed and gets the Retry button instead.
local function streamFromRelay(cfg, payload, fd)
    local socket = require("socket")
    local body = JSON.encode(payload)
    local headers = { ["Content-Type"] = "application/json", ["X-Key"] = cfg.key }
    local err
    for _, delay in ipairs(RETRY_DELAYS_S) do
        local received = false
        err = postStreaming(cfg.host, "/chat/stream", headers, body, function(chunk)
            received = true
            ffiutil.writeToFD(fd, chunk)
        end)
        if received then return end
        socket.sleep(delay)
    end
    ffiutil.writeToFD(fd, JSON.encode({
        error = T("The Mac relay at %1 did not answer (%2). Is the Mac awake?", cfg.host, tostring(err)) }))
end

local function readAvailable(fd)
    local size = ffiutil.getNonBlockingReadSize(fd) or 0
    if size <= 0 then return "" end
    local buffer = ffi.new("char[?]", size)
    local got = tonumber(ffi.C.read(fd, buffer, size))
    return got > 0 and ffi.string(buffer, got) or ""
end

-- A half-written reply: drop a code fence Claude may open with, a tag cut off mid-name, web images (the relay
-- embeds them at the end) and a diagram still being drawn.
local function partialHtml(html)
    html = html:gsub("^%s*```%w*%s*", "")
    html = html:gsub("<[^>]*$", "")
    html = html:gsub("<img[^>]-https?://[^>]*>", "")
    local last_svg
    for pos in html:gmatch("()<svg") do last_svg = pos end
    if last_svg and not html:find("</svg>", last_svg, true) then
        html = html:sub(1, last_svg - 1)
    end
    return html
end

-- MuPDF's default page margin is about an inch, and it sizes an svg by its width attribute, ignoring percentages.
local VIEW_CSS = [[
@page { margin: 0; }
body { margin: 0; }
svg { width: 100%; }
h2 { font-size: 1em; font-style: italic; font-weight: normal; margin: 0 0 1em; padding-bottom: 0.5em;
     border-bottom: 1px solid #888; }
h3 { font-variant: small-caps; }
p { margin: 0 0 0.7em; text-align: justify; }
p.thinking { font-style: italic; }
blockquote { margin: 0.6em 1.5em; font-style: italic; }
]] .. CONTENT_CSS

-- Reading settings, all changed in the settings pane; size and margin are in unscaled pixels.
local TEXT_DEFAULTS = { text_size = 24, line_spacing = 1.4, margin = 14 }

local function textSetting(cfg, key)
    return cfg[key] or TEXT_DEFAULTS[key]
end

-- Footer items default to shown.
local function shown(cfg, key)
    return cfg[key] ~= false
end

-- Full-screen chat: one question and its reply at a time, text only. Page turns run through a reply and on into
-- the next or previous one. A tap on the top edge brings up the header; the footer shows the page and usage.
-- While Claude writes, the new reply grows in place without ever moving the page being read.
local ChatView = InputContainer:extend{
    chat = nil,
    on_steer = nil, -- function(id)
    on_book = nil, -- function(exchange)
    on_close = nil,
    covers_fullscreen = true,
}

function ChatView:init()
    local cfg = config()
    local width, height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }
    self.title_bar = TitleBar:new{
        width = width,
        title = self.chat.title,
        subtitle = " ",
        with_bottom_line = true,
        left_icon = "book.opened",
        left_icon_tap_callback = function()
            if not self.pending then self.on_book(self.index) end
        end,
        show_parent = self,
        close_callback = function() self.on_close() end,
    }
    self.header = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, self.title_bar,
    }
    self.margin = Screen:scaleBySize(textSetting(cfg, "margin"))
    self.font_size = Screen:scaleBySize(textSetting(cfg, "text_size"))
    self.css = VIEW_CSS .. string.format("body { line-height: %.2f; }", textSetting(cfg, "line_spacing"))
    self.footer_face = Font:getFace("smallffont")
    self.footer_height = 2 * self.footer_face.size
    self.buttons = self:newButtons(width)
    self.body_width = width - 2 * self.margin
    self.body_height = height - self.margin - self.footer_height - self.buttons:getSize().h
    self.body = FrameContainer:new{
        bordersize = 0, padding = self.margin, padding_bottom = 0, self:newBox(""),
    }
    self.footer = FrameContainer:new{ bordersize = 0, padding = 0, self:newFooter() }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{ align = "left", self.body, self.buttons, self.footer },
    }
    self.top_edge = math.floor(height / 12)
    -- Reached only when the reply itself cannot turn further, or for sideways swipes it ignores.
    self.ges_events = {
        TurnSwipe = { GestureRange:new{ ges = "swipe", range = function() return self.body.dimen end } },
        TurnTap = { GestureRange:new{ ges = "tap", range = function() return self.body.dimen end } },
    }
    self.key_events = {
        TurnForward = { { Device.input.group.PgFwd } },
        TurnBack = { { Device.input.group.PgBack } },
    }
    self.index = self:exchangeCount()
end

-- The header sits over the text; while it is up it gets the first look at every gesture.
function ChatView:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    if self.header_shown then self.header:paintTo(bb, x, y) end
end

function ChatView:handleEvent(event)
    if self.header_shown and event.handler == "onGesture" and self.header:handleEvent(event) then return true end
    return InputContainer.handleEvent(self, event)
end

function ChatView:setHeaderShown(show)
    self.header_shown = show
    UIManager:setDirty(self, function() return "ui", self.title_bar.dimen end)
end

function ChatView:newButtons(width)
    local function button(id, text)
        return { text = text, enabled_func = function() return not self.pending end,
                 callback = function() self.on_steer(id) end }
    end
    local row1, row2 = {}, {}
    for i, s in ipairs(STEER) do
        table.insert(i <= 4 and row1 or row2, button(s.id, s.text))
    end
    table.insert(row2, button("ask", _("Ask…")))
    table.insert(row2, button("new", _("New chat")))
    return ButtonTable:new{ width = width, buttons = { row1, row2 }, zero_sep = true, show_parent = self }
end

function ChatView:newBox(html)
    local box = HtmlBoxWidget:new{
        dimen = Geom:new{ w = self.body_width, h = self.body_height },
        dialog = self,
    }
    box:setContent(html, self.css, self.font_size)
    return box
end

-- Context used on the left, the page in the middle, the 5-hour limit on the right; small grey sans.
function ChatView:newFooter()
    local cfg = config()
    local usage = self.chat.usage or {}
    local box = self.body[1]
    local left, center, right = "", "", ""
    if shown(cfg, "show_context") and usage.context and usage.window and usage.window > 0 then
        left = T(_("context %1%"), math.floor(100 * usage.context / usage.window + 0.5))
    end
    if self.pending and self.index == self:lastIndex() then
        center = _("writing…")
    elseif shown(cfg, "show_pages") and box.page_count > 1 then
        center = box.page_number .. " / " .. box.page_count
    end
    if shown(cfg, "show_five_hour") and usage.five_hour then
        right = T(_("5h %1%"), math.floor(100 * usage.five_hour + 0.5))
    end
    local inner = Geom:new{ w = self.body_width, h = self.footer_height }
    local function text(s)
        return TextWidget:new{ text = s, face = self.footer_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    end
    return FrameContainer:new{
        bordersize = 0, padding = 0, padding_left = self.margin, padding_right = self.margin,
        OverlapGroup:new{
            dimen = inner,
            LeftContainer:new{ dimen = inner, text(left) },
            CenterContainer:new{ dimen = inner, text(center) },
            RightContainer:new{ dimen = inner, text(right) },
        },
    }
end

function ChatView:updateFooter()
    local old = self.footer[1]
    self.footer[1] = self:newFooter()
    old:free()
    UIManager:setDirty(self, function() return "ui", self.footer.dimen end)
end

function ChatView:exchangeCount()
    return math.floor(#self.chat.turns / 2)
end

-- Question i with its reply; the one being written (past the saved ones) shows the text so far.
function ChatView:exchangeHtml(i)
    local question, reply
    if i <= self:exchangeCount() then
        local user = self.chat.turns[2 * i - 1]
        question, reply = user.label or user.text, self.chat.turns[2 * i].html
    else
        question = self.pending.question
        reply = self.pending.html ~= "" and partialHtml(self.pending.html)
            or '<p class="thinking">' .. _("Thinking") .. string.rep(".", self.pending.dots) .. "</p>"
    end
    reply = reply:gsub("<svg[^>]*>", function(tag)
        for _, attr in ipairs({ "width", "height" }) do
            tag = tag:gsub("%s" .. attr .. "%s*=%s*([\"'])[^\"']*%1", "")
        end
        return tag
    end)
    return "<h2>" .. escape(question) .. "</h2>" .. reply
end

function ChatView:lastIndex()
    return self:exchangeCount() + (self.pending and 1 or 0)
end

function ChatView:updateSubtitle()
    local text
    if self.pending and self.index == self:lastIndex() then
        text = _("Claude is writing…")
    elseif self:lastIndex() > 1 then
        text = T(_("Exchange %1 of %2"), self.index, self:lastIndex())
    else
        text = " "
    end
    if text ~= self.subtitle then
        self.subtitle = text
        self.title_bar:setSubTitle(text)
    end
end

-- Puts a new box for exchange i in place of the old one and returns the old one, still to be freed.
function ChatView:replaceBox(i, page)
    local old = self.body[1]
    local box = self:newBox(self:exchangeHtml(i))
    box:setPageNumber(math.max(1, math.min(page, box.page_count)))
    self.body[1] = box
    return old
end

-- Shows exchange i at its first page, or at its last when paging back into it.
function ChatView:show(i, at_end)
    self.index = i
    self:replaceBox(i, at_end and math.huge or 1):free()
    self:updateSubtitle()
    UIManager:setDirty(self, function() return "ui", self.body.dimen end)
    self:updateFooter()
end

-- Re-renders the exchange in view keeping the reader on their page: that page is repainted only when new text
-- lands on it; otherwise just the footer's page count changes.
function ChatView:refresh()
    local box = self.body[1]
    local was_last = box.page_number == box.page_count
    self:replaceBox(self.index, box.page_number):free()
    if was_last then
        UIManager:setDirty(self, function() return "ui", self.body.dimen end)
    end
    self:updateFooter()
end

function ChatView:turn(direction)
    local box = self.body[1]
    local page = box.page_number + direction
    if page >= 1 and page <= box.page_count then
        box:setPageNumber(page)
        box:freeBb()
        UIManager:setDirty(self, function() return "partial", self.body.dimen end)
        self:updateFooter()
        return true
    end
    local next_index = self.index + direction
    if next_index >= 1 and next_index <= self:lastIndex() then
        self:show(next_index, direction < 0)
    end
    return true
end

function ChatView:onTurnSwipe(_, ges)
    local forward = { west = 1, north = 1, east = -1, south = -1 }
    return self:turn(forward[ges.direction] or 0)
end

-- The top edge toggles the header; while the header is up, any other tap just closes it.
function ChatView:onTurnTap(_, ges)
    if ges.pos.y < self.top_edge or self.header_shown then
        self:setHeaderShown(not self.header_shown)
        return true
    end
    return self:turn(ges.pos.x < Screen:getWidth() / 2 and -1 or 1)
end

function ChatView:onTurnForward() return self:turn(1) end
function ChatView:onTurnBack() return self:turn(-1) end

function ChatView:repaintButtons()
    UIManager:setDirty(self, function() return "ui", self.buttons.dimen end)
end

-- A new question goes out: it gets its own exchange, shown at once with "Thinking" until text arrives.
function ChatView:beginPending(question)
    self.pending = { question = question, html = "", dots = 1 }
    self:show(self:lastIndex())
    self:repaintButtons()
end

function ChatView:updatePending(html, dots)
    if html ~= "" then dots = self.pending.dots end
    if html == self.pending.html and dots == self.pending.dots then return end
    self.pending.html, self.pending.dots = html, dots
    if self.index == self:lastIndex() then self:refresh() end
end

-- The reply was saved into the chat (or failed): the exchange stays in view either way, as saved text or gone.
function ChatView:endPending()
    local was_live = self.index == self:lastIndex()
    self.pending = nil
    self:repaintButtons()
    if self:exchangeCount() == 0 then return end
    if was_live and self.index <= self:exchangeCount() then
        self:refresh()
    else
        self:show(math.min(self.index, self:exchangeCount()))
    end
    self:updateSubtitle()
end

function ChatView:onCloseWidget()
    self.body[1]:free()
end

function ClaudeChat:init()
    self.ui.menu:registerToMainMenu(self)
    if not self.ui.document then return end
    self:addHighlightButtons()
    if loadChat(self.ui.document.file) then
        self:catchSteerLinks()
    end
end

function ClaudeChat:addToMainMenu(menu_items)
    menu_items.claudechat = {
        text = _("Claude"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("New chat…"), keep_menu_open = false, callback = function() self:askNewChat() end },
            { text = _("Chats"), callback = function() self:showChats() end },
            {
                text_func = function() return T(_("Model: %1"), config().model or "sonnet") end,
                sub_item_table_func = function()
                    local items = {}
                    for _, m in ipairs(MODELS) do
                        table.insert(items, {
                            text = m.text,
                            radio = true,
                            checked_func = function() return (config().model or "sonnet") == m.id end,
                            callback = function()
                                local cfg = config()
                                cfg.model = m.id
                                saveConfig(cfg)
                            end,
                        })
                    end
                    return items
                end,
            },
            {
                text_func = function() return T(_("Mac relay: %1"), config().host or _("not paired")) end,
                keep_menu_open = true,
                callback = function(touchmenu) self:editRelay(touchmenu) end,
            },
        },
    }
end

function ClaudeChat:editRelay(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("Mac relay address"),
        input = config().host or "",
        input_hint = "192.168.1.10:8787",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local cfg = config()
                cfg.host = dialog:getInputText()
                saveConfig(cfg)
                UIManager:close(dialog)
                if touchmenu then touchmenu:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ClaudeChat:showChats()
    local dir = chatsDir()
    if self.ui.document then
        self.ui:onClose()
        self.ui:showFileManager(dir .. "/")
        return
    end
    self.ui.file_chooser:changeToPath(dir)
end

local RECENT_CHATS = 5

-- The Shelf's Claude tile: New chat, the newest chats, and the folder.
function ClaudeChat:open()
    local dir = chatsDir()
    local chats = {}
    for name in lfs.dir(dir) do
        if name:match("%.html$") then
            local path = dir .. "/" .. name
            table.insert(chats, { path = path, name = name:gsub("%.html$", ""),
                mtime = lfs.attributes(path, "modification") or 0 })
        end
    end
    table.sort(chats, function(a, b) return a.mtime > b.mtime end)
    local dialog
    local buttons = {{ { text = _("New chat…"), callback = function()
        UIManager:close(dialog)
        self:askNewChat()
    end } }}
    for i = 1, math.min(RECENT_CHATS, #chats) do
        local chat = chats[i]
        local state = loadChat(chat.path)
        table.insert(buttons, {{ text = state and state.title or chat.name, align = "left", callback = function()
            UIManager:close(dialog)
            self:openChatView(chat.path)
        end }})
    end
    if #chats > RECENT_CHATS then
        table.insert(buttons, {{ text = _("All chats"), callback = function()
            UIManager:close(dialog)
            self:showChats()
        end }})
    end
    dialog = ButtonDialog:new{ title = _("Claude"), buttons = buttons }
    UIManager:show(dialog)
end

-- Asks for text with the on-screen keyboard, then calls on_text(text). Starts from text, or else from the
-- last typed question that never got an answer.
function ClaudeChat:prompt(title, on_text, text)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = text or config().unsent,
        input_hint = _("Your question"),
        allow_newline = true,
        -- A fixed two-line box: one that grows line by line jumps around and repaints as you type.
        text_height = 2 * math.floor(1.3 * Font:getFace("x_smallinfofont").size + 0.5),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Send"), is_enter_default = true, callback = function()
                local text = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                if text ~= "" then on_text(text) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ClaudeChat:askNewChat()
    self:prompt(_("New chat"), function(text) self:startChat(shorten(text, 70), text) end)
end

function ClaudeChat:startChat(title, prompt, label)
    local file = string.format("%s/%s %s.html", chatsDir(), os.date("%Y-%m-%d %H%M"),
        util.getSafeFilename(shorten(title, 40)))
    self:send(file, { title = title, turns = {} }, prompt, label)
end

-- Sends prompt in chat, saves the reply into file and opens it at the new question.
function ClaudeChat:send(file, chat, prompt, label)
    local cfg = config()
    if not cfg.host or not cfg.key then
        UIManager:show(InfoMessage:new{ text = _("Not paired with the Mac. On the Mac run:\nrelay.py pair") })
        return
    end
    -- Typed questions (no label) are kept until answered, so a failure, a dismiss or a crash never loses them.
    if not label then
        cfg.unsent = prompt
        saveConfig(cfg)
        G_reader_settings:flush()
    end
    NetworkMgr:runWhenOnline(function()
        self:streamReply(file, chat, prompt, label, cfg)
    end)
end

-- The chat view for file, opened if it is not already up.
function ClaudeChat:showChatView(file, chat)
    if self.view and self.view.file == file then return self.view end
    if self.view then self:closeChatView() end
    local view
    view = ChatView:new{
        chat = chat,
        on_steer = function(id) self:onSteer(id, view) end,
        on_book = function(exchange)
            self:closeChatView()
            self:openChat(file, "t" .. (2 * exchange - 1))
        end,
        on_close = function() self:closeChatView() end,
    }
    view.file = file
    self.view = view
    if view:exchangeCount() > 0 then view:show(view.index) end
    UIManager:show(view, "full")
    return view
end

function ClaudeChat:closeChatView()
    if not self.view then return end
    if self.cancel then self.cancel() end
    UIManager:close(self.view)
    self.view = nil
end

function ClaudeChat:openChatView(file)
    local chat = loadChat(file)
    if not chat then
        require("apps/reader/readerui"):showReader(file)
        return
    end
    self:showChatView(file, chat)
end

-- Fetches the reply in a forked subprocess (the UI never blocks) and shows it live; on the last line saves it.
function ClaudeChat:streamReply(file, chat, prompt, label, cfg)
    local payload = { prompt = prompt, session_id = chat.session_id, model = cfg.model or "sonnet",
                      effort = cfg.effort, opening = cfg.opening }
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        streamFromRelay(cfg, payload, write_fd)
    end, true)
    if not pid then
        self:showSendFailed(_("Could not start the request."), file, chat, prompt, label)
        return
    end
    local view = self:showChatView(file, chat)
    view:beginPending(label or shorten(prompt, 120))
    local tick
    local pending, html, result, ticks = "", "", nil, 0
    local function reap()
        if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end
    end
    local function take(line)
        local ok, obj = pcall(JSON.decode, line)
        if not ok or type(obj) ~= "table" then
            result = { error = T(_("Unreadable answer from the relay:\n%1"), shorten(line, 200)) }
        elseif obj.delta then
            html = html .. obj.delta
        else
            result = obj
        end
    end
    local function stop()
        self.cancel = nil
        UIManager:unschedule(tick)
        ffiutil.terminateSubProcess(pid)
        ffi.C.close(fd)
        reap()
    end
    self.cancel = stop
    tick = function()
        ticks = ticks + 1
        local done = ffiutil.isSubProcessDone(pid)
        pending = pending .. (done and ffiutil.readAllFromFD(fd) or readAvailable(fd))
        for line in pending:gmatch("([^\n]*)\n") do
            take(line)
        end
        pending = pending:match("[^\n]*$")
        if done and pending ~= "" then take(pending) end
        if result and result.html then html = result.html end
        -- "Thinking" gains a dot each second until the first words arrive.
        view:updatePending(html, 1 + math.floor(ticks * LIVE_REFRESH_S))
        if not done and not result then
            UIManager:scheduleIn(LIVE_REFRESH_S, tick)
            return
        end
        if done then
            self.cancel = nil
        else
            stop()
        end
        result = result or { error = _("The connection dropped before Claude finished.") }
        local saved = self:saveReply(result, file, chat, prompt, label)
        view:endPending()
        if not saved and view:exchangeCount() == 0 then self:closeChatView() end
    end
    UIManager:scheduleIn(LIVE_REFRESH_S, tick)
end

-- Saves the reply into the chat; on failure shows why and returns false.
function ClaudeChat:saveReply(res, file, chat, prompt, label)
    if res.error or not res.html then
        self:showSendFailed(tostring(res.error or _("Empty answer.")), file, chat, prompt, label)
        return false
    end
    local done = config()
    done.unsent = nil
    saveConfig(done)
    chat.session_id = res.session_id
    -- Context tokens and window, 5-hour limit used: shown in the chat view's footer.
    chat.usage = res.usage
    table.insert(chat.turns, { role = "user", text = prompt, label = label })
    table.insert(chat.turns, { role = "assistant", html = res.html })
    local saved, err = saveChat(file, chat)
    if not saved then
        UIManager:show(InfoMessage:new{ text = T(_("Could not save the chat:\n%1"), tostring(err)) })
        return false
    end
    return true
end

function ClaudeChat:showSendFailed(err, file, chat, prompt, label)
    local dialog
    local buttons = {{
        { text = _("Close"), callback = function() UIManager:close(dialog) end },
        { text = _("Retry"), callback = function()
            UIManager:close(dialog)
            self:send(file, chat, prompt, label)
        end },
    }}
    if not label then
        table.insert(buttons[1], 2, { text = _("Edit"), callback = function()
            UIManager:close(dialog)
            self:prompt(_("Edit question"), function(text) self:send(file, chat, text) end, prompt)
        end })
    end
    dialog = ButtonDialog:new{
        title = err .. "\n\n" .. (label and _("Not sent.") or _("Your question is kept.")),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ClaudeChat:openChat(file, anchor)
    local go_to_anchor = function(ui)
        ui.link:onGotoLink({ xpointer = "#" .. anchor }, true)
    end
    if self.ui.document and self.ui.document.file == file then
        self.ui:reloadDocument(nil, true, go_to_anchor)
    elseif self.ui.document then
        self.ui:switchDocument(file, true, go_to_anchor)
    else
        require("apps/reader/readerui"):showReader(file, nil, true, nil, go_to_anchor)
    end
end

-- Continues the open chat, or starts a new one when the open book is not a chat.
function ClaudeChat:continueOrStart(prompt, label)
    local file = self.ui.document.file
    local chat = loadChat(file)
    if chat then
        self:send(file, chat, prompt, label)
        return
    end
    local title = self.ui.doc_props and self.ui.doc_props.display_title or ""
    self:startChat(label, prompt .. (title ~= "" and T("\n\n(From the book \"%1\".)", title) or ""), label)
end

-- From the chat view (view given) or from a claude: link in the open book.
function ClaudeChat:onSteer(id, view)
    local continue = function(prompt, label)
        if view then
            self:send(view.file, view.chat, prompt, label)
        else
            self:continueOrStart(prompt, label)
        end
    end
    if id == "ask" then
        self:prompt(_("Ask"), function(text) continue(text) end)
        return
    end
    if id == "new" then
        self:askNewChat()
        return
    end
    for _, s in ipairs(STEER) do
        if s.id == id then
            continue(s.prompt, s.text)
            return
        end
    end
end

-- claude: links never reach ReaderLink's external-link handling.
function ClaudeChat:catchSteerLinks()
    local link = self.ui.link
    local steerId = function(l)
        local target = type(l) == "table" and (l.xpointer or l.uri or (l.link and l.link.uri)) or ""
        return tostring(target):match("claude:(%a+)")
    end
    local orig_goto = link.onGotoLink
    link.onGotoLink = function(this, l, ...)
        local id = steerId(l)
        if id then
            UIManager:nextTick(function() self:onSteer(id) end)
            return true
        end
        return orig_goto(this, l, ...)
    end
end

function ClaudeChat:askAbout(action, selected, before, after)
    if selected == "" then return end
    local phrase = shorten(selected, 300)
    local prompt = string.format(action.prompt, phrase)
    if before or after then
        prompt = prompt .. T("\n\nIt appears in this passage: \"…%1 %2 %3…\"", before or "", phrase, after or "")
    end
    self:continueOrStart(prompt, string.format(action.label, shorten(selected, 50)))
end

-- Multi-word selections open the highlight dialog; a single held word opens the dictionary popup.
function ClaudeChat:addHighlightButtons()
    for i, action in ipairs(LOOKUP) do
        self.ui.highlight:addToHighlightDialog("13_claude_" .. i .. "_" .. action.id, function(hl)
            return {
                text = action.text,
                callback = function()
                    local selected = hl.selected_text and hl.selected_text.text or ""
                    local before, after = hl:getSelectedWordContext(25)
                    hl:onClose()
                    self:askAbout(action, selected, before, after)
                end,
            }
        end)
        self.ui.dictionary:addToDictButtons{
            id = "claude_" .. i .. "_" .. action.id, -- ordered pairs: keeps rows in LOOKUP order
            text = action.text,
            conditional = true,
            row_group = i <= 2 and "claude_a" or "claude_b",
            callback = function(lookup)
                local before, after = self.ui.highlight:getSelectedWordContext(25)
                local word = lookup.word or ""
                lookup:onClose()
                self.ui.highlight:clear()
                self:askAbout(action, word, before, after)
            end,
        }
    end
end

return ClaudeChat
