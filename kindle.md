# Kindle

The reference Kindle is a Touch 2014 (KT2, "Basic Bourbon", 600x800, 8 bpp, no front light, one slow core) running KOReader v2026.07.1. Jailbreak and install are in `kindle-jailbreak.md` and `koreader-install.md`; speed in `speed.md`.

## Hooking it into ink (verified 2026-11-16)
1. Put `~/.ssh/kindle_ed25519.pub` (made by `install.sh`) in `koreader/settings/SSH/authorized_keys` over USB. Eject with `sync; diskutil unmount`, never force.
2. `~/.config/ink/devices.json` already has a `kindle` entry from ink's first run.
3. Launch KOReader from the library with `KOReader.sh` (in `documents/`): it sets the `performance` governor and keeps the stock UI off.
4. `ink -d kindle find`, then `info`, `shot`, `install`.
5. `ink awake on` while working, `off` when done: it drains the battery.

## What works (verified 2026-11-16)
- Every ink command, including `eval`, `reload` and `install`. Screenshots are 600x800, tap scale 2.00.
- Touch: KOReader opens only `/dev/input/event1` (zforce2). That node has no EV_MSC, so `ink eval` kicks KOReader through a FIFO instead (see `_index.md`).
- `ink install shelf` then `ink install patches`: Shelf is home, all four patches load. In `ink eval`, plugin modules load by bare name (`package.loaded["profile"]`); `require("plugins/shelf.koplugin/...")` dumps a huge error.
- No front light: `hasFrontlight()` and `hasNaturalLight()` are false, so the Shelf hides the sun icon, the light popup, the edge swipes, and says "Wi-Fi off, slower CPU" in power save.
- Governors: ondemand, userspace, powersave, performance. Power save writes `ondemand`.
- Home folder: KOReader's `Device.home_dir` is `/mnt/us`, which made the Shelf scan KOReader's and the system's folders. `profile.lua` fixes it to `/mnt/us/documents`, the Send folder too.
- Covers: Cover Browser's extraction ran about 5 min of CPU for 59 books, 43 got covers. One-time; until it finishes, covers are blank.
- Every Shelf view at 600x800: covers, tiles, names, sort, Wi-Fi and battery popups, Apps (no Writer tile without the typewriter plugin), History, book long-press menu, page swipe. The header fits at this width.
- Send: code shows, an upload from the Mac arrived in `documents` and showed its card. EPUBs arrive as uploaded (plain UA).
- Page turns: DU text looked jagged on this panel, so Kindle defaults to Quality (reader menu, gear tab, first item; or the "Toggle fast page turns" gesture). The owner confirmed Quality looks good.

## Safety
- Touch only `/mnt/us/koreader` and `/mnt/us/documents`. Never firmware, OTA or `/usr`.
- Never force-eject the USB disk; a force unmount once corrupted KOReader files.
- Never chain taps; never toggle Wi-Fi off from the Mac (it cuts ink).
- Back up `koreader/` before big changes (`tar` over `ink sh`).
- `ink reload` reopens the book if one is open.
