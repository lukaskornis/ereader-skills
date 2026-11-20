# Claude chat (Kobo verified 2026-11-18 with real replies; Kindle unverified)

Chat with Claude from the reader on the Claude subscription. Each chat is a book: one HTML file in `<home>/Claude`, opened in the normal reader with its fonts, margins, page turns, and a table of contents of the questions.

## Use
- Shelf > Apps > Claude: New chat, the five newest chats, All chats.
- Tools menu > Claude: New chat (on-screen keyboard), Chats (opens the folder), Model (Sonnet default, Opus, Haiku), Mac relay address.
- While Claude writes, the reply appears on a full-screen page within about 2 s, a few words at a time. You stay on the page you are reading; only that page repaints when new text lands on it. The X cancels; once it says Done, the X opens the reply as a book.
- End of every reply: Go deeper, Example, Simpler, Shorter, Counterpoint, then Ask… (keyboard) and New chat. Tap one; the reply is appended and the book opens at the new section.
- Select text: hold a word (dictionary popup) or hold and drag a phrase (highlight dialog). Both get Explain simply, More on that, Etymology, Similar concepts. The phrase and about 25 words around it go to Claude. In a chat it continues the chat; in any other book it starts a new chat about the passage, named after the book.
- Chats are plain files: rename, move or delete them in the file browser. The state rides inside the file, so a moved chat still continues.

## How it works
1. The subscription only works through Claude Code, so the Mac relays. `relay.py serve` (LaunchAgent `com.lukas.claudechat-relay`, port 8787, starts at login, restarts on crash; a watchdog agent `com.lukas.claudechat-relay-watchdog` reloads it within 5 minutes if it is ever unloaded) takes `POST /chat/stream {prompt, session_id, model}` with header `X-Key` and runs `claude -p --resume <session> --tools "" --system-prompt <book prose, HTML fragment> --output-format stream-json --include-partial-messages`. It answers one JSON object per line as Claude writes: `{delta}` for each piece of text, then `{session_id, html}` the moment Claude stops writing (the CLI's own result line comes ~1.5 s later) or `{error}`. If the reader hangs up, Claude is killed. `POST /chat` still returns the whole reply in one object.
2. It runs Claude with its own config dir (`~/.config/claudechat/claude-home`) plus `CLAUDE_CODE_DISABLE_CLAUDE_MDS` and `CLAUDE_CODE_DISABLE_AUTO_MEMORY` (the config dir alone still loaded `~/.claude/CLAUDE.md` and rules, 2026-11-20), so the global CLAUDE.md, hooks, plugins and output style never reach the chat, and with `CLAUDE_CODE_OAUTH_TOKEN` from the keychain item `claudechat-token` (made by `relay.py login`, which wraps `claude setup-token`; the normal CLI login expires and needs a browser).
3. launchd may not read `~/Documents`, so `install` copies the relay to `~/.local/bin/claudechat-relay` and the agent runs that copy. Re-run `install` after editing `relay.py`.
4. The plugin posts from a forked subprocess (`ffiutil.runInSubProcess` with a pipe) that copies the relay's bytes into the pipe; the UI reads what is there every 0.4 s and re-renders the reply so far in a `ScrollHtmlWidget` (cut-off tags dropped), keeping the reader's page and refreshing only it (or just the scroll bar). On the final line it saves the chat. The subprocess speaks raw HTTP over a socket because luasocket's `http.request` only hands over 2 KB blocks. Silence is tolerated for 60 s (a cold Mac can take ~15 s to start Claude Code). No answer at all (Wi-Fi waking, relay restarting) is retried after 2, 4, 8 and 16 s; any other failure shows Retry / Edit / Close. A typed question is kept in the `claudechat.unsent` setting until a reply arrives and prefills the next question box, so it survives failures, cancels and crashes.
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
