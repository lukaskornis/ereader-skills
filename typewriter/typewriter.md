# Typewriter (Kobo, pilot, 2026-11-15)

Type on the Kobo with the Mac's keyboard. The Kobo has no Bluetooth, so the Mac relays keys over Wi-Fi.

## Use
- On the Mac, in a terminal: `ink -d kobo type`. Every key goes to the reader; Ctrl-C ends.
- The first key opens the typewriter page on the reader (also in the main menu, Tools > Typewriter).
- Append and Backspace only, at the end of the text. Enter starts a new paragraph. Arrows and Escape are ignored.
- Tap the page: a toolbar strip. Icons: new note, notes list, save as (on-screen keyboard), portrait/landscape, one or two pages (landscape only), Aa (opens font, A2/DU, size, line spacing and margin rows), close. Typing hides it. The strip follows the page's rotation; closing restores the reader's own rotation.
- Swipe left or right pages through earlier spreads; the next key jumps back to the last one.
- Notes live in `/mnt/onboard/notes/*.txt` (the old `typewriter.txt` moves there on first run). New notes are named by date and time. The open note is remembered. Editing is append and backspace at the end.
- No caret: moving it left A2 smears on the panel (2026-11-16).
- Landscape shows two pages side by side. Text turns over a whole spread (one page in portrait) at a time, never scrolls.
- The note is saved 2.5 s after the last key, on close and before switching notes.

## How it works
1. `ink type` uploads `tw-writer.lua` and opens its own ssh connection with a pty (`-tt`, no mux): ssh puts the terminal in raw mode and sets TCP_NODELAY, so each key leaves at once. The remote pty goes raw too.
2. `tw-writer.lua` (luajit on the reader) turns each byte into an EV_MSC/MSC_RAW event, value `0x5457xxxx` ("TW" + byte), written to `/dev/input/event0`: the same trick as `ink eval`. Backspace becomes 8, Enter 10, Tab a space; escape sequences are dropped. The evdev client buffer holds about 64 events and drops the rest, so pastes go out 16 keys at a time with a 30 ms pause.
3. `typewriter.koplugin` wraps `Input.handleMiscEv` once per run and hands bytes to the newest plugin instance, which assembles UTF-8 and edits the page.
4. Per key: greedy word wrap from two lines back, then only the changed tail of each touched line is cleared and redrawn straight into `Screen.bb`, and that rect is refreshed with A2. Keys arriving in one input batch share one refresh (nextTick). 2.5 s after the last key the touched area gets one AUTO refresh to bring back anti-aliasing, and the text is saved. A full spread turns over to a blank one.
5. When a dialog covers the page, keys only change the text; the page catches up when it is uncovered.

## Measured (2026-11-15)
- Device: key received to refresh submitted 1 ms (`_G.TW_LAT`, ms per key).
- Panel, one glyph rect: A2 about 145 ms, DU about 300 ms. A2 is the default.
- Wi-Fi ping: 8 ms min, 29 avg, 192 max (power saving spikes).
- Incremental drawing is pixel-identical to a full repaint after wrap, unwrap by backspace and a page turn (screenshot diff).

## Pitfalls
- `ink reload typewriter` reopens the file manager but leaves an open page from the old module on top; `open()` finds pages by the `is_typewriter` flag so a second one is not stacked.
- Fast blind taps on the settings dialog once fell through to the Shelf and opened a PDF. Screenshot before tapping around it.

- Piping text into `ink type` drops whatever is still queued when stdin closes (only the first 16-key batch lands). Hold the stream open: `{ printf '...'; sleep 3; } | ink -d kobo type`. (2026-11-16)

- Closing windows by `ink eval`: match only `is_typewriter`. A broad match (`title_bar`) closed the file manager too, KOReader quit and the Kobo dropped off Wi-Fi (2026-11-16).

## Later
- Global key capture on the Mac (menu bar app, needs Accessibility), Android phone as the relay (same ssh stream).
- Ghosting with A2 needs an owner's look on the panel.
