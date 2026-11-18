# Building a KOReader app (playbook, 2026-11-18)

Learned from three apps built in one day: Claude chat, Word search, Paint. Read this before starting a new plugin app; drawing and touch details are in `koreader-patches.md`.

## Start
- Read one sibling plugin (`wordsearch` for a full-screen game, `claudechat` for a reader add-on) and the koreader-src files you need in one batch. Word search was written about 4 minutes after that one read.
- Settle anything external first: auth, a Mac relay, a server. The chat's real-reply test sat blocked about 8 minutes across four wrap-ups waiting on login.
- Branch `feat/<app>` from `main`, not from whatever is checked out. If another session owns the main checkout, `git worktree add ../ereader-<app>` and never switch branches there.
- `brew install luajit` up front. Paint ran three slices without it, so nothing could be syntax-checked or replayed on the Mac.
- Shell helper: `k(){ ink -d kobo "$@"; }`. `K="ink -d kobo"; $K shot` fails in zsh ("command not found"), since zsh doesn't word-split.

## Layout (every app ships all of it)
- `<app>/<app>.koplugin/{_meta.lua, main.lua, logic.lua, <data>.lua}`, `<app>/logic_test.lua`, `<app>/<app>.md`, one `_index.md` row.
- `logic.lua` has no KOReader requires: rules, generation, recognition, math. Test it with `luajit <app>/logic_test.lua` (seeded invariants, golden tape). 2400 Word search boards in 0.1 s caught a placement bug before the device.
- Split `main.lua` before ~600 lines. Paint's grew to 1000, and each new chat re-read all of it, about 100K tokens before the first edit.
- Shelf Apps tile by default, not only the Tools menu (he asked "is this in Apps?"). Add a Tabler outline icon (24 px, stroke 2, `currentColor` → `#000000`) as `shelf/shelf.koplugin/icons/shelf.<name>.svg`, then `if self.ui.<app> then tiles[#tiles+1] = self:appTile(size, "<name>", "<Label>", fn) end` in `buildApps`. Shelf may be dirty from another session: check `git status` first.
- State lives in `G_reader_settings` (plain table, flushed after each meaningful change and on close). Home screen offers Continue. Save after the refresh, not before it, so the save never delays the paint.
- The plugin instance from `ink eval`: `(require("apps/filemanager/filemanager").instance or require("apps/reader/readerui").instance).<app>`. FileManager is nil while a book is open, and opening from there can put the app under the book.
- `CHANGELOG.md` and `MERGE-CHECKLIST.md` are gitignored. Don't `git add` them, or the chained commit aborts.

## UI rules he set
- Mock first (HTML or SVG, saved in the repo, path named in the handoff) and get an OK before wiring. For looks (a logo, icons), render 2 or 3 variants for him to pick.
- Calm, slim icon strip; options in a popover per tool, rare actions (Save, Open, Clear) behind one menu.
- Input apps react on finger-down with no full repaints. Pure black and white: threshold every frame, so A2 shows it exactly and nothing flashes. Pencil-like live strokes. Keep the shape of the user's stroke when snapping (move it onto the target, straighten only as needed).
- Progress as shapes that fill (hollow squares), not a bar plus "N left".
- On an open question he usually types a message instead of answering a picker: pick the default, say it in one line, go.

## Dev loop
- Pure logic on the Mac, the reader only for touch, panel and look. "Why are you testing every time on the real tablet?"
- One shell line per check: push or `ink reload`, `ink eval` setup, input, one `ink shot` at the end. No `sleep`: reload, time and eval return once settled. Paint kept adding `sleep 1.5` after he complained.
- Push one file: `ink sh "cat > <koreader>/plugins/<app>.koplugin/main.lua" < file`, then `ink reload <app>` (about 140 ms).
- Lua syntax check: `luajit -bl file.lua >/dev/null`, or after a reload `ink log 40 | grep -iE "error|traceback"`.
- `ink eval` code must not start with an assignment (`_G.X = {}` gives "'<eof>' expected"): start with `local`, `return`, or wrap it in `do … end`. Multi-line code: `ink eval - <<'EOF'`.
- `ink eval` output can carry an extra line: quote it, and pick fields with `head -1`, before passing it to `ink tap`.
- Test a handler by calling it directly (`ui.claudechat:onSteer("example")`). If the call works but the tap doesn't, something sits on top. List `UIManager._window_stack` before chasing the bug: a leftover Paint widget ate the chat's taps, and another session's book kept closing Paint.
- To debug a hook, wrap it so it appends to a `_G` log, then `ink eval 'table.concat(_G.LOG," ")'`; restore the original afterwards.
- Don't end a test with `ui:onClose()` or `ink restart` after closing KOReader yourself: with no file manager underneath, KOReader quits and the Kobo drops off Wi-Fi (several rescans). Close your widgets, delete test files, leave the reader open.
- Backends: a 20-line Python mock server that writes the last prompt to a file lets the whole UI be tested without the real service. Wait on the backend's log or page count, never a fixed 20 to 30 s sleep (a real reply takes about 4 s).
- For human-only checks (feel, multitouch), write `<app>/checklist-sliceN.md`: short, numbered, expected results.

## Seeing the screen cheaply
- Check state as text first: `ink eval` returning page numbers, a mode, a window-stack name list. One line, against an image.
- Find tap targets by probing, not by reading pixels: scan `ui.link:getLinkFromGes({pos = Geom:new{x=…, y=…, w=0, h=0}})` over a grid and return "x y".
- Pixel questions: `bb:getPixel(x, y):getColor8().a` in hex settles it in one call where a zoomed shot stays ambiguous.
- Cut table dumps: `| cut -c1-600`. A `pairs(widget)` dump of ReaderUI is hundreds of keys.
- No PIL on the Mac: crop and zoom with `sips -c H W --cropOffset Y X` and `sips -Z`.
- When the owner is reading, render the app off screen: `paintTo` a `Blitbuffer.new(w, h, Screen.bb:getType())`, write a PNG, pull it.

## Handoffs between slices
- Carry: plan path, branch and worktree, mock file path, settings schema, function anchors for the big files ("`onPan` near line 410"), the next step, and which checks still need him.
- Write lessons into this pack at the end of each slice, not once at the end of the app.

## KOReader extension points found
- In-book links: a custom scheme (`<a href="claude:deeper">`) caught by wrapping the instance's `ReaderLink.onGotoLink`. `showLinkBox` is never reached for it. Check a hook landed with `rawget(ui.link, "onGotoLink")`.
- Selection buttons: `ui.highlight:addToHighlightDialog(id, fn)` and `ReaderDictionary:addToDictButtons`. Ids sort alphabetically, so prefix an index (`"claude_" .. i .. "_" .. id`).
- crengine HTML: state in a leading `<!--app {json}-->` comment survives renames. `page-break-inside: avoid` keeps a button row on one page. `white-space: nowrap; hyphens: none` keeps link labels whole. Jump with `doc:getPageFromXPointer("#id")`.
- `JSON.decode(s:gsub(…))` passes gsub's count as a second argument and fails silently: put the gsub result in a local first.
- No `drawNow` on widgets: force a repaint with `UIManager:setDirty("all", "full")`.
- Cut UTF-8 safely: `s:gsub("[\192-\255][\128-\191]*$", "")`.
- Pan events arrive duplicated, and "touch" and "tap" both fire: draw once per `nextTick`, not once per event.
- Raw multitouch: set `Device.input.gesture_detector.feedEvent` as an instance field to see contacts before gestures, pass non-canvas contacts to the class method, clear the field on close. Map coordinates with `translateCoordinates` and `Screen:getTouchRotation()`; fake events need the same transform. The Aura One panel tracks only 2 contacts: a third finger takes the second's slot.
- A2 can't show greys: light ink is invisible while drawing. Draw it black live and let the clean-up pass turn it grey.
- Bucket fill: FFI scanline over the BB8 `data` pointer, walls at 0x80 so anti-aliased edges hold.
- Icons: `ImageWidget` renders the SVG into a white BB8 tile; cache the tile per widget.

## Mac helpers
- A LaunchAgent can't read `~/Documents`: `install` copies the script to `~/.local/bin` and the agent runs that copy.
- `claude setup-token` headless: Python `pty.fork()` fed by a FIFO (`script -q` fails on a socket). Its token wraps across lines: after stripping newlines, cut at "Store" and check the length. A 401 with a token that looks fine means glued text.
