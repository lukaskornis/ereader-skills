# Claude chat (Kobo verified 2026-11-18 with a mock relay; Kindle unverified)

Chat with Claude from the reader on the Claude subscription. Each chat is a book: one HTML file in `<home>/Claude`, opened in the normal reader with its fonts, margins, page turns, and a table of contents of the questions.

## Use
- Tools menu > Claude: New chat (on-screen keyboard), Chats (opens the folder), Model (Sonnet default, Opus, Haiku), Mac relay address.
- End of every reply: Go deeper, Example, Simpler, Shorter, Counterpoint, then Ask… (keyboard) and New chat. Tap one; the reply is appended and the book opens at the new section.
- Select text: hold a word (dictionary popup) or hold and drag a phrase (highlight dialog). Both get Explain simply, More on that, Etymology, Similar concepts. The phrase and about 25 words around it go to Claude. In a chat it continues the chat; in any other book it starts a new chat about the passage, named after the book.
- Chats are plain files: rename, move or delete them in the file browser. The state rides inside the file, so a moved chat still continues.

## How it works
1. The subscription only works through Claude Code, so the Mac relays. `relay.py serve` (LaunchAgent `com.lukas.claudechat-relay`, port 8787, starts at login, restarts on crash) takes `POST /chat {prompt, session_id, model}` with header `X-Key` and runs `claude -p --resume <session> --tools "" --system-prompt <book prose, HTML fragment>`.
2. It runs Claude with its own config dir (`~/.config/claudechat/claude-home`) so the global CLAUDE.md, hooks, plugins and output style never reach the chat, and with `CLAUDE_CODE_OAUTH_TOKEN` from the keychain item `claudechat-token` (made by `relay.py login`, which wraps `claude setup-token`; the normal CLI login expires and needs a browser).
3. launchd may not read `~/Documents`, so `install` copies the relay to `~/.local/bin/claudechat-relay` and the agent runs that copy. Re-run `install` after editing `relay.py`.
4. The plugin posts from a forked subprocess (`Trapper:dismissableRunInSubprocess`), so the UI never blocks and a tap on "Claude is writing…" cancels.
5. The file's first line is `<!--claudechat {json}-->` with the title, session id and turns; the HTML below is rendered from it on each save. `--` inside the JSON is written as `--` so it can't end the comment.
6. `claude:` links are caught by wrapping the instance's `ReaderLink.onGotoLink`, before KOReader calls them invalid external links. Selection buttons use `ReaderHighlight:addToHighlightDialog` and `ReaderDictionary:addToDictButtons` (conditional rows).

## Setup
- `relay.py login` once (browser opens), `relay.py install` (agent plus pairing every reader in `~/.config/ink/devices.json`), `relay.py pair kindle` for a reader that was off.
- The plugin: copy `claudechat.koplugin` to `<koreader>/plugins/`, restart KOReader.

## Pitfalls
- The Mac must be awake and on the same Wi-Fi. A DHCP change on the Mac needs `relay.py pair` again.
- `JSON.decode(s:gsub(...))` passes gsub's count as a second argument and fails silently: assign the gsub result to a local first (2026-11-18).
- Closing the reader with `ui:onClose()` from `ink eval` when no file manager is underneath quits KOReader, and the Kobo drops off Wi-Fi (2026-11-18).
- Mock relay for UI work without spending the subscription: a 20-line Python server on another port returning `{"session_id", "html"}`, then point the reader's host at it.

## Later
- Streaming: replies arrive whole; e-ink would repaint on every chunk anyway.
