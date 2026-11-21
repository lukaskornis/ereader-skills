# Sleep screen

KOReader plugin (folder `sleepquote`): the sleep screen shows a picture, the battery percent and one
highlighted passage with its book title. Each part can be switched off; parts that are off give their
space to the others. Works on any KOReader device; the battery hides itself where
`Device:hasBattery()` is false.

## Layout
- All on: picture at the top (68% of the width), a thin rule, the quote in Noto Serif Italic, the
  title in grey Noto Serif, battery percent small top-right. The quote takes the largest size from
  3.6% down to 1.8% of the screen height that fits; a quote too long even then shrinks the picture.
- Picture only (or no highlight found): picture centred at 80% of the width.
- Quote only: quote and title centred on the page.
- Default picture `eye.svg` (generator `mock/eye.py`). KOReader's NanoSVG ignores `clipPath` and
  fills the clip shape black, so the SVG uses no clipping. Custom pictures (png, jpg, gif, svg, webp,
  bmp) scale to fit, keeping their aspect.

## How it works
- Wraps `Screensaver.show` once (guarded by `Screensaver._sleepquote_orig_show`, so `ink reload`
  never double-wraps). Plain suspends only; power-off and reboot screens stay KOReader's own. A
  build error logs a warning and falls back to the normal sleep screen.
- Portrait forced like KOReader's image modes; honours the "gesture" unlock.
- Books, newest first: the open book (live `ui.annotation.annotations`), then `lastfile` and the
  read history (up to 30 sidecars). Highlights are annotations with a `drawer`; bookmarks and page
  marks are skipped. Text is whitespace-collapsed and cut at 420 characters on a word.
- `logic.lua` (pure, tested with `luajit sleepquote/logic_test.lua`) picks without randomness: the
  r-th book with highlights weighs 1/r, split evenly over its highlights. Each sleep every highlight
  earns its share as credit; the one with the most is shown and pays 1 (smooth weighted round
  robin). New highlights join level with the leader, so a newly highlighted book comes up next.
  Ties go to the one shown longest ago; the previous one is never shown twice in a row. State
  (credit, last shown, previous) is `G_reader_settings.sleepquote_balance`, pruned to the current
  highlights each sleep.

## Settings
- Shelf Apps tile "Sleep" (moon): On, Preview (the next sleep screen; tap to close), Picture,
  Choose… (file picker, images only), Reset (back to the eye, shown only with a custom picture),
  Highlight, Battery. Keys: `sleepquote_enabled`, `sleepquote_picture`, `sleepquote_picture_file`,
  `sleepquote_highlight`, `sleepquote_battery`; switches are on by default.
- Menu: Settings > Screen > "Sleep screen" (the On switch).

## Only KOReader highlights
Highlights made in Kobo's stock reader (Nickel, `KoboReader.sqlite` Bookmark table) are not read.
On 2026-11-18 the Kobo had none in either place.

## Verified (Kobo Aura One)
- 2026-11-18: real suspend path (`Screensaver:setup(); show()`) painted and closed cleanly.
- 2026-11-21: all-on, long quote, quote-only and picture-only renders; balance state survives a
  settings save and reload with quotes, brackets and non-ASCII in keys.
