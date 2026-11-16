# Speed: KOReader on the Kobo Aura ONE

Device: Kobo Aura ONE (product 373, codename daylight, Mk6, single-core i.MX6SL, 512 MB RAM, 1404x1872 at 300 dpi).
Firmware 4.38.23171. KOReader v2026.07.1 since 2026-11-15, started by KFMon or NickelMenu. Facts from the USB disk, 2026-11-15.
Each item says UNVERIFIED until it was tested on the device; then it gets the date.

## Measured 2026-11-15 (tap to screen settled; each figure includes about 1 s of ssh and tap overhead)
- Before: book open 4.9 s, page turn 2.4 s, menu 3.4 s.
- After the settings: book open 5.1 s (cached book, no change), page turn 2.3 s, menu 2.8 s.
- With the performance governor: page turn 2.2 s, against 2.5 s on interactive.
- After the update to v2026.07.1, timed with `ink time` on the device, so no ssh overhead: book open 2.8 s, page turn 0.38 s, menu 1.0 s. The old figures were taken from the Mac, so the two sets don't compare one to one.

## What is already true (from koreader.sh source)
- Nickel is not resident while KOReader runs: koreader.sh kills nickel, hindenburg, sickel, adobehost and the rest. No RAM to win there.
- On exit it runs `nickel.sh` (the KFMon ini has `reboot_on_exit=false` in a comment, which the script's grep still matches). Started without Nickel, its exit tail runs `/sbin/reboot`.
- Governor: koreader.sh picks `interactive` if the kernel has it, else `ondemand`, and restores the old one on exit. Our user patch overrides it with performance, see below.
- There is no supported way to boot straight into KOReader on firmware 4.25 or later. KSM and advboot are dead, and boot hacks risk a soft-brick. Cold boot always goes through Nickel first.

## Settings to apply (ink -d kobo stop, sets, start)
1. Fewer flashes (applied 2026-11-15; refresh counts raised to 50 the same day): `full_refresh_count = 50`, `night_full_refresh_count = 50`, `avoid_flashing_ui = true`, `flash_ui = false`, `flash_keyboard = false`, `refresh_on_pages_with_images = false`. This is the biggest felt win.
2. Light kerning (applied 2026-11-15): `copt_font_kerning = 2`. It lays books out faster and looks the same for Latin text.
3. Bigger crengine cache (applied 2026-11-15): `cre_disk_cache_max_size = 256`, in MB (the default is 64). Reopening a book then skips the re-render.
4. Cover Browser off (applied 2026-11-15): add coverbrowser to `plugins_disabled`. That gives a much faster file browser and less background work. It goes anyway once the custom shelf plugin exists.
5. Idle plugins off (applied 2026-11-15): add newsdownloader, wallabag, opds, vocabbuilder, japanese, perceptionexpander, exporter to `plugins_disabled`. Keys are the folder name without `.koplugin`. Keep autosuspend, ssh and statistics.
6. Wi-Fi (applied 2026-11-15): leave it on during dev sessions, since SSH needs it. `auto_restore_wifi = true` is set so it comes back after a restart.

## Shell-level checks
- Governor (2026-11-15): interactive, conservative, ondemand, userspace, powersave and performance are offered, at 396 or 996 MHz. The user patch `patches/2-cpu-performance.lua` (pack copy: `patch-cpu-performance.lua`) sets performance at every KOReader start; Settings > Device > Full CPU speed switches it to interactive at once (setting `cpu_performance`, on by default; verified 2026-11-15). It was stage 1 until the toggle: `G_reader_settings` is nil at stage 1 and survives OTA updates. koreader.sh puts the old governor back on exit. The battery cost is unmeasured.
- Standby: `/sys/power/state` offers `standby mem` (2026-11-15). `auto_standby_timeout_seconds` is still -1. Setting it to 4 is UNVERIFIED: test wake by hand first. Standby is refused while Wi-Fi is on, so dev sessions don't see it.
- Sleep screen: leave `screensaver_type` on `disable`. A cover image adds decode time to every sleep and wake.

## KOReader update (verified 2026-11-15, v2025.10 to v2026.07.1)
- Firmware 4.x takes the normal `kobo` package, not `kobov5`. The zip is in `downloads/`.
- koreader.sh installs `ota/koreader.updated.tar` at its next start with `tar --strip-components=1`, so the tar needs the `koreader/` folder on top. It never touches settings, patches, history or the SSH keys.
- Steps:
  1. On the Mac: `COPYFILE_DISABLE=1 tar -cf koreader.updated.tar --format pax --exclude koreader.png @koreader-kobo-vX.zip`.
  2. `ink -d kobo sh 'cat > <koreader>/ota/koreader.updated.tar.part && md5sum <koreader>/ota/koreader.updated.tar.part' < koreader.updated.tar`, then compare with `md5` on the Mac. 89 MB takes about 90 s.
  3. Rename the `.part` file to `koreader.updated.tar`, then `ink stop` and `ink start`. The install takes under a minute.
- After it: settings, plugins_disabled, the CPU patch, SSH and the stop/start loop name all came through unchanged.

## Measure
- `ink time X Y` taps, then waits for KOReader's own idle report (`patches/2-ink-eval.lua`, 2026-11-15) and prints the seconds to the last paint and to the panel done. Wall time per check: book open 4.2 to 5.0 s down to 1.8 to 2.1 s, book to shelf 1.55 to 1.3 s, restart 5.6 to 3.4 s. The old framebuffer probe (still the fallback) overstated book open: 1.9 to 2.65 s against a last paint at 0.7 to 1.0 s, because each 2.6 MB hash took long while the CPU was busy.
- Panel done is now measured on every check: book open 1.6 to 1.9 s, book to shelf 1.1 s, cold shelf after restart 0.6 s after the last paint.

## Book open breakdown (2026-11-15, `prof-open.lua`, A Brief History of Intelligence, cached)
Seconds from `showReader`: "Opening file" popup painted 0.05 to 0.07, `openDocument` 0.19, reader modules and plugins 0.1, `Cre.loadDocument` 0.68 (crengine reading its 1.2 MB disk cache; engine-bound, the biggest share), render, history and ReaderReady 0.1, first paint 1.25 to 1.3.
- The reader showed itself with a full GC16 flash, and KOReader blocked 0.6 s on it. The Shelf now turns that flash into a partial "ui" (AUTO) when it opens a book: the UI is free 0.6 s sooner and panel done went 2.25 to 2.03 s. Ghosting check by the owner pending.

## Fast page-turn patch (installed 2026-11-15, ghosting check by the owner pending)
- `patches/2-fast-page-turn.lua` (pack copy `patch-fast-page-turn.lua`). Page turns (`onGotoViewRel` in ReaderRolling and ReaderPaging) refresh with "fast" instead of "partial". Every other refresh is unchanged, and the full flash every `full_refresh_count` pages still happens.
- On this Mk6 Kobo, "partial" is AUTO (waveform 257) and "fast" is DU (waveform 1) with `EPDC_FLAG_FORCE_MONOCHROME`. The Aura ONE is not flagged REAGL. DU drops text anti-aliasing on the panel, so letters can look harder and grey text darker until the next full flash.
- Panel time per page turn, measured with the probe, 5 turns each: AUTO 617 to 623 ms, DU 370 to 378 ms. About 250 ms faster, or 40 %. The render before it is about 0.38 s and doesn't change.
- Toggle (2026-11-16): reader menu, gear tab, first item "Page turns: Fast / Quality", plus the gesture action "Toggle fast page turns". Saved as `fast_page_turn`, takes effect at once. Default fast, except Kindle, where DU text looked jagged on the KT2. The patch adds the item inside `MenuSorter.mergeAndSort`, because the menu tables are rebuilt with dofile on every menu setup and the sorter consumes `menu_items`. The item's callback calls `updateItems` itself: a `text_func` item without `checked_func` is not redrawn by TouchMenu.
- To remove it completely: delete the patch file, then `ink restart`.
- Fast swipe bursts coalesced (2026-11-15, feel check by the owner pending). Before: 10 swipes 0.14 s apart all refreshed in turn; the panel queued them and the last page landed 1.1 s after the last swipe (render was never the problem: 0.04 s per page in a test book). Now a page turn within 0.3 s of the last refreshed one only redraws the framebuffer, and one refresh at the end of the window shows the latest page: 10 swipes give 4 to 6 refreshes, and the last page lands 0.4 to 0.7 s after the last swipe. A single turn is never delayed. Window: `TURN_WINDOW` in the patch; the panel drains about one DU update per 0.23 s, so below that the queue comes back. Deferred turns don't count toward `full_refresh_count`.
- Burst test: upload `inject.lua` to `/tmp`, then source a loop of `./luajit /tmp/inject.lua <fb args> swipe 1100 900 300 900 80` with the fbink env in scope (`eval $(./fbink -e); . /tmp/burst.sh`; a child `sh` loses the variables). Timers: wrap `ReaderRolling.onGotoViewRel` and `Screen.mech_refresh` with `ink eval`. A probe that waits on the panel marker blocks input, so only wait after the burst ends.

## Menu speed (2026-11-15)
- Where the time went (probe patch: Lua time per tap plus panel marker wait). Every menu, dialog and file-browser refresh is "ui": AUTO, non-flashing, about 620 ms on the panel. The first reader menu tap per book also spent about 190 ms building the menu table and 140 ms building the bottom settings panel.
- Panel time per waveform, full-screen partial update: AUTO 620, GL16 620, GC16 530, GC4 420, DU 370, A2 365 ms.
- GC4 is broken on this panel: it left old book text inside the menu and faded nearby text (owner's photo, 2026-11-15). Never use it here. GC16 flashes the changed area; DU loses greys. So menus stay on AUTO.
- Kept:
  - `patches/2-menu-prebuild.lua` (pack copy `patch-menu-prebuild.lua`) builds the reader menu table 1 s after a book opens. First menu tap: 0.78 to 0.13 s of Lua time.
  - `show_bottom_menu = false`: tapping the top opens only the top menu; a bottom tap still opens the settings panel. Saves 40 to 140 ms per open.
- Menus feel slower than page turns because they refresh with AUTO (about 0.6 s, fading through grey) while page turns use DU (0.37 s, snaps to black); Lua is 0.1 to 0.15 s for both. The owner is fine with menus as they are (2026-11-15): don't propose DU menus again.
- The panel's 620 ms is now most of every menu tap. The Shelf build was cut from 0.56 to 0.11 s (cover cache, see `shelf/shelf.md`).

## Ideas from web research (2026-11-15, all UNVERIFIED on this device)
- Fast waveform for page turns: Mk6 uses DU (about 260 ms) for "fast" and AUTO for partial. A patch that makes page turns use DU could cut panel time from about 450 ms, at the cost of light ghosting. KOReader has no menu for it.
- Night mode uses GC16 for every update on Mk6, so it is slower. Use the frontlight instead when speed matters.
- KFMon `BAR` file in its config folder skips Nickel's boot progress bar and saves a few seconds at cold boot. The README warns it can break older setups.
- Auto-shutdown is 3 days (`autoshutdown_timeout_seconds = 259200`). Every power-off means a Nickel cold boot.
- `dev_no_sw_dither`: small gain on image pages only.
- Not worth it: REAGL (not used on this model), overclocking (996 MHz is the top step), zram or swap, mount options, editing rcS to boot into KOReader, firmware changes.

## Energy (2026-11-15)
- Idle is clean: 0 % CPU with KOReader open, no polling; the ink hooks cost nothing at idle.
- The battery reports no current, only `capacity` and `voltage_now` under `/sys/class/power_supply/mc13892_bat`, so savings can only be measured as capacity lost over a timed reading run (an afk job).
- Open drains, not yet acted on (owner to pick): standby between pages is off (`auto_standby_timeout_seconds = -1`; 4 s needs his wake test); Wi-Fi stays on and `auto_restore_wifi` brings it back, and it also blocks standby; the performance governor keeps 996 MHz even at idle (the 0.3 s page-turn gain against interactive was measured from the Mac, so re-measure on the device).
- Toggles added 2026-11-15: Full CPU speed (above) and a Wi-Fi button in the Shelf footer.
- Suspend after 15 min and shutdown after 3 days are fine.
