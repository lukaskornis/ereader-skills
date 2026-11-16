# Writing KOReader user patches and plugins (learned 2026-11-15)

Applies to the Kindle and the Kobo. Verified on KOReader v2026.07.1.

## Before writing
- Read the on-device Lua, never guess: `ink sh 'grep -n PATTERN /mnt/onboard/.adds/koreader/frontend/...'` (on the Kindle, `/mnt/us/koreader`).
- The device has busybox grep: no `--include`, no `-P`. Use `grep -rn PATTERN dir` or `find … | xargs grep`.

## Patch files
- They live in `<koreader>/patches/N-name.lua`, run in name order, and are logged as "Applying patch" in `ink log`.
- The pack keeps them as `patch-name.lua`; `ink install patches` copies each to `patches/2-name.lua` and restarts.
- The first digit picks the stage: 0 once after an update, 1 early (before the UI), 2 late (UIManager ready, before FileManager or ReaderUI opens), 8 before exit, 9 on exit. Any other digit never runs, with no error (2026-11-15).
- Patch a module by requiring it and replacing a method on the class table. Instances inherit it through the metatable.
- A patch error shows an "Error applying patch" box and the rest of that patch is skipped. Always check `ink log` after `ink restart`.

## Adding a menu item
- Menu tables are rebuilt with `dofile` on every menu setup, and `MenuSorter:mergeAndSort` consumes `menu_items`. A hook after `setUpdateItemTable` finds nothing.
- Hook `MenuSorter.mergeAndSort` instead. Before you call the original, insert into `items.<id>.sub_item_table`. Example: `patch-fast-page-turn.lua`, which adds an item to `screen_eink_opt`.
- `G_reader_settings` is nil at stage 1; a patch that reads settings must be stage 2 (2026-11-15).
- For a checkbox setting with default on, use `G_reader_settings:nilOrTrue(key)` and `flipNilOrTrue(key)`; read it with `isFalse(key)` at the point of use, so the toggle works without a restart.

## Screen refresh
- Refresh types go through `UIManager:_refresh(mode, region, dither)`. Every `full_refresh_count` "partial" refreshes, one is promoted to "full". If you change the mode, keep that counter logic.
- On the Kobo Mk6: partial and ui are AUTO, fast is DU (monochrome), full is GC16. Details in `speed-kobo.md`.
- To change the waveform for one refresh type, replace `Device.screen.refreshUIImp` (or the matching `refresh*Imp`) and call `fb:mech_refresh(is_flashing, waveform, x, y, w, h, dither)`. Check the result on the panel with a phone photo: screenshots read memory, not the panel. GC4 corrupts the Aura ONE's screen.
- Devices without HW dithering (the Kobo Mk6) lose the dither hint in UIManager before the screen sees it. To spot an image view, check the top window's `widget.dithered` instead.
- Probe for speed work: wrap `UIManager.handleInputEvent` (gesture time), `UIManager._repaint` and `Device.screen.mech_refresh` with `ui/time` timers, and log through `logger.info`. Calling `fb:mech_wait_update_complete(fb.marker)` after a refresh adds the panel time. Remove the probe after: the wait blocks the UI.

## Measuring
- `ink time` measures until the framebuffer stops changing, so it covers rendering only. Panel waveform time needs the probe described in `speed-kobo.md`.
- Testing a UI change: `ink restart`, then tap your way to it, then `ink shot` and Read it. Crop with `sips -c H W --cropOffset Y X`, because the Mac Python has no PIL.

## Device shell gotchas
- In busybox 1.31 on the Kobo, `pkill -x` and `pgrep -x` never match. Use `killall NAME` or `pidof NAME`.
- After a restart, KOReader opens whatever was showing on exit: the file browser or the last book.
