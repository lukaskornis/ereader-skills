# Sleep quote

KOReader plugin: the sleep screen shows "Last held on <date>" with a battery icon and percent, and
under it one highlighted passage with the book title. Works on any KOReader device; the battery
hides itself where `Device:hasBattery()` is false.

## How it works
- Wraps `Screensaver.show` once (guarded by `Screensaver._sleepquote_orig_show`, so `ink reload`
  never double-wraps). Plain suspends only; power-off and reboot screens stay KOReader's own. A
  build error logs a warning and falls back to the normal sleep screen.
- Portrait forced like KOReader's image modes; honours the "gesture" unlock.
- Books, in order: the open book (live `ui.annotation.annotations`), then `lastfile` and the read
  history (up to 30 sidecars). Highlights are annotations with a `drawer`; bookmarks and page marks
  are skipped. Text is whitespace-collapsed and cut at 420 characters on a word.
- `logic.lua` (pure, tested with `luajit sleepquote/logic_test.lua`): the current book's unseen
  highlights first; once all are seen, a random pick from its older half, so the last one never
  comes back next. A book with a single highlight falls through to older books. The "shown" memory
  is `G_reader_settings.sleepquote_shown` (keys, newest first, 300 max).
- Quote font: Noto Serif, largest size from 3.6% down to 1.8% of the screen height that fits.

## Settings
- Menu: Settings > Screen > "Sleep screen: highlight" (on by default, `sleepquote_enabled`).

## Only KOReader highlights
Highlights made in Kobo's stock reader (Nickel, `KoboReader.sqlite` Bookmark table) are not read.
On 2026-11-18 the Kobo had none in either place.

## Verified (Kobo Aura One, 2026-11-18)
- Real suspend path (`Screensaver:setup(); show()`): header painted, widget closed cleanly.
- Off-screen render with a sample highlight: centred serif quote, title, battery icon.
