# Speed: making a 256 MB e-reader feel fast

All of this was verified on the KT2, which has 256 MB of RAM, a single 984 MHz core and 8-bit Y8 e-ink. None of it changes how pages look unless noted.

## Ditch the stock OS while reading
- KOReader runs with `--framework_stop`.
  - It stops the Amazon framework (Xorg, the Java UI and its services), which frees RAM and CPU for the reader.
  - When KOReader exits, the framework comes back.
- `ink restart` kills the launcher loop before KOReader. That way the framework never restarts in between, and a restart takes about 5 s instead of about 60.

## CPU
- `KOReader.sh` sets the `performance` governor (984 MHz all the time) while KOReader runs, and puts `ondemand` back on exit.
- Battery: the CPU is off during sleep at any governor. Screen refresh and Wi-Fi use most of the power. The guessed cost is 10–20% more drain while actively reading; it hasn't been measured yet (see `ink info` battery).

## Layout and refresh (settings.reader.lua, KOReader closed)
- `copt_font_kerning = 2`: HarfBuzz light kerning. EPUB layout is cheaper than "best" and looks the same. The launcher adds it if it's missing.
- `full_refresh_count = 20`: fewer full black flashes.
- `avoid_flashing_ui = true`, `flash_ui = false`: menus redraw without flashing.
- `refresh_on_pages_with_images = false`.
- `plugins_disabled`: coverbrowser, newsdownloader, wallabag. Each one costs RAM and startup time.
- Skipped on purpose because they change the look: crop "none" and background cleanup.

## Memory limits
- Scanned PDFs: KOReader crashed on a 350 MB scanned PDF. MuPDF failed a 37 MB malloc while computing the content-width zoom. The fix is to shrink scans on the Mac before they go to the device: grayscale JPEG at about 1000 px, through the planned PDF shrinker in `kindle-push`.
- Watch free memory with `ink info`; about 170 MB free is normal while it's idle in the file browser.

## Ideas not done yet
- Measure the battery cost of `performance` against `ondemand` over an hour of reading.
- System-level SSH through USBNetwork (via MRPI), so access doesn't depend on KOReader ever having started.
