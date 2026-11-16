# How KOReader redraws the screen (v2026.07.1)

Read this before opening `frontend/ui/uimanager.lua`. Checked against the local source copy on 2026-11-16.

## Two queues, one call
- `UIManager:setDirty(widget, mode, region, dither)` paints nothing. It flags `widget` for repaint and queues a panel refresh. Both drain on the next input loop (`_repaint`).
- `widget` must be a window-level widget, one that was passed to `UIManager:show`. From a child, pass `self.show_parent`. With any other widget, or with `nil`, nothing is repainted: only the refresh is queued. Use `nil` when the framebuffer is already right.
- `"all"` repaints the whole window stack but still honours `region`.
- A repaint calls `paintTo` on the whole widget, not just the region. Widgets above a dirty one are repainted too. Widgets under a `covers_fullscreen` one are skipped.
- `region` (a `Geom`) only limits the panel refresh. Leaving it out means the full screen.
- `mode` can be a function returning `mode, region[, dither]`. It runs after the paint, so `dimen` values are fresh. Use it when the region is only known once laid out: `function() return "ui", self.thing.dimen end`.
- To paint a single child into the framebuffer without repainting its parent, use `UIManager:widgetRepaint(child, x, y)` followed by `setDirty(nil, "ui", child.dimen)`. To invert a highlight, use `widgetInvert`.
- `UIManager:forceRePaint()` drains the queues right away. `waitForVSync()` blocks until the last refresh ioctl has finished.

## Modes (cheapest first)
- `a2`: black or white only, ghosts. Keyboard-style use only.
- `fast`: any content to black and white. Inversion highlights. Grey text or covers look wrong.
- `ui`: mixed content, never flashes and never gets promoted. The default for shelf and menu work.
- `partial`: text on white, the reader's mode. Every Nth one (`full_refresh_count`, default 6) is promoted to `full` with no region, or to `flashui` with a region.
- `flashui`, `flashpartial`, `full`: these flash. `full` with no region resets the promotion counter.
- `[ui]` and `[partial]` ask the driver not to merge the update.
- Overlapping queued refreshes merge into one rectangle, and the stronger mode wins (`update_mode`). A small `fast` refresh next to a full-screen `ui` one becomes part of the `ui` refresh.
- `UIManager:avoidFlashOnNextRepaint()` skips the next promotion.

## User settings that change modes
- `avoid_flashing_ui` (true): `flashui` becomes `ui`, `flashpartial` becomes `partial`, and a regional `partial` becomes `ui`. Menu label: "Avoid mandatory black flashes in UI".
- `flash_ui` (nil counts as true): flashes buttons and menu items on tap. Set it to false for no tap flash. Menu label: "Flash buttons and menu items".
- `full_refresh_count` / `night_full_refresh_count`: the promotion period.
- While ReaderPaging or ReaderScrolling scrolls, every refresh is downgraded to `fast`.

## Measured on the Kobo (2026-11-16, `ink time`)
- Shelf popup open or close, footer tabs, and full-screen `ui`: about 0.15 s until the screen settles, and the panel finishes at about 0.75 s.
- Limiting a `ui` refresh to the header and popup area made no timing difference. The waveform time sets the speed, not the region size. Limit the region to avoid disturbing content below, not to gain speed.
- Real speed gains come from fewer refreshes (one `setDirty` per change, never one per child) and from cheaper `paintTo` work (cache cover blitbuffers, don't rebuild unchanged widgets).

## Where to look in the source
- `frontend/ui/uimanager.lua`: the long doc comment above `setDirty`, then `setDirty`, `_refresh` (promotion, downgrade, merge), `_repaint`, and `widgetRepaint`/`widgetInvert`.
- `frontend/ui/elements/flash_ui.lua`, `avoid_flashing_ui.lua`, and `screen_eink_opt_menu_table.lua`: the e-ink menu.
- `frontend/device/devicelistener.lua` `onRequestSuspend`: sleep the device (`ink eval` with a broadcast `Event:new("RequestSuspend")` on `nextTick`).
