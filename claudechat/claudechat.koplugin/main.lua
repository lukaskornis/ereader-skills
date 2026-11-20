--[[
Claude chat: each conversation is one HTML file in <home>/Claude, opened in the normal reader so it reads like
a book (fonts, margins, page turns, TOC of questions). The file carries its own state (session id, turns) in a
leading comment, so it survives moves and renames.
Replies come from the Mac relay (claudechat/relay.py), which runs `claude -p` on the subscription.
Steering links at the end of the file use the claude: scheme and are caught before ReaderLink treats them as
external. Selecting text adds Claude buttons to the highlight dialog: in a chat they continue it, in any other
book they start a new chat about the passage.
]]
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local HEADER = "<!--claudechat "
local REQUEST_TIMEOUT_S = 600
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
</style></head><body>]])
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

-- Runs in a forked subprocess (Trapper), so it may block; returns the relay's JSON body as a string.
-- Only "no answer at all" is retried: Wi-Fi waking up or the relay restarting clear within seconds, while a
-- relay error reply means Claude itself failed and gets the Retry button instead.
local function postToRelay(cfg, payload)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local body = JSON.encode(payload)
    local code
    for _, delay in ipairs(RETRY_DELAYS_S) do
        local sink = {}
        socketutil:set_timeout(15, REQUEST_TIMEOUT_S)
        code = socket.skip(1, http.request{
            url = "http://" .. cfg.host .. "/chat",
            method = "POST",
            headers = { ["Content-Type"] = "application/json", ["Content-Length"] = #body, ["X-Key"] = cfg.key },
            source = ltn12.source.string(body),
            sink = socketutil.table_sink(sink),
        })
        socketutil:reset_timeout()
        local text = table.concat(sink)
        if text ~= "" then return text end
        socket.sleep(delay)
    end
    return JSON.encode({ error = T("The Mac relay at %1 did not answer (%2). Is the Mac awake?", cfg.host, tostring(code)) })
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
            require("apps/reader/readerui"):showReader(chat.path)
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
        Trapper:wrap(function()
            local payload = { prompt = prompt, session_id = chat.session_id, model = cfg.model or "sonnet" }
            local completed, body = Trapper:dismissableRunInSubprocess(function()
                return postToRelay(cfg, payload)
            end, _("Claude is writing…"), true)
            if not completed then return end
            local ok, res = pcall(JSON.decode, body or "")
            if not ok or type(res) ~= "table" then
                res = { error = T(_("Unreadable answer from the relay:\n%1"), shorten(tostring(body), 200)) }
            end
            if res.error or not res.html then
                self:showSendFailed(tostring(res.error or _("Empty answer.")), file, chat, prompt, label)
                return
            end
            local done = config()
            done.unsent = nil
            saveConfig(done)
            chat.session_id = res.session_id
            table.insert(chat.turns, { role = "user", text = prompt, label = label })
            table.insert(chat.turns, { role = "assistant", html = res.html })
            local saved, err = saveChat(file, chat)
            if not saved then
                UIManager:show(InfoMessage:new{ text = T(_("Could not save the chat:\n%1"), tostring(err)) })
                return
            end
            self:openChat(file, "t" .. (#chat.turns - 1))
        end)
    end)
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

function ClaudeChat:onSteer(id)
    if id == "ask" then
        self:prompt(_("Ask"), function(text) self:continueOrStart(text) end)
        return
    end
    if id == "new" then
        self:askNewChat()
        return
    end
    for _, s in ipairs(STEER) do
        if s.id == id then
            self:continueOrStart(s.prompt, s.text)
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
