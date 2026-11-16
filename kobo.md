# Kobo

The reference Kobo is an Aura ONE (product 373, Mk6, 512 MB of RAM) on firmware 4.38.23171, running KOReader v2026.07.1 (updated 2026-11-15), which is launched by KFMon or NickelMenu. Speed tuning is in `speed-kobo.md`.

## Install KOReader (not re-tested from scratch here; the reference Kobo already had it)
1. Mac: put an empty `.metadata_never_index` file in the Kobo root (`/Volumes/KOBOeReader`) before copying anything.
2. NickelMenu: copy its `KoboRoot.tgz` (from https://pgaskin.net/NickelMenu/) to `.kobo/` on the Kobo, eject, and let it reboot and install.
3. Unzip `downloads/koreader-kobo-*.zip` into `.adds/` so you get `.adds/koreader/`.
4. Create `.adds/nm/koreader` containing `menu_item:main:KOReader:cmd_spawn:quiet:exec /mnt/onboard/.adds/koreader/koreader.sh`.
5. Eject with `sync; diskutil unmount /Volumes/KOBOeReader`. KOReader is now in the main menu (bottom right). KFMon (an icon-tap launcher) is optional and needed only for [koboot](koboot/koboot.md).

## Hooking it into ink (verified 2026-11-15)
README step 3 is the short path. What the reference Kobo uses:
1. With the Kobo on USB, copy `~/.ssh/kobo_ed25519.pub` (made by `install.sh`) to `.adds/koreader/settings/SSH/authorized_keys`. In `.adds/koreader/settings.reader.lua` (it exists after KOReader's first start) set `SSH_autostart = true`, `SSH_key_only_auth = true`, `SSH_allow_no_password = false` and `auto_restore_wifi = true`. KOReader is not running during USB mass storage, so editing the file then is safe. After that, KOReader starts SSH and Wi-Fi itself on every launch.
   - Spotlight on the Mac can block the eject for minutes. `.metadata_never_index` in the root prevents it; otherwise wait, never force.
2. `~/.config/ink/devices.json` already has a `kobo` entry from ink's first run.
3. Run `ink -d kobo find`, then `ink -d kobo info`, then `ink -d kobo shot`.

## What works (verified 2026-11-15)
- `find`, `info`, `shot`, `tap`, `time`, `get`, `set`, `stop`, `start` and `restart` all work. `ink sh` takes piped stdin, which is how big files go up.
- Uploads: before 2026-11-15, ink's connection probes inherited stdin and ate the first 24 to 48 KB of a piped upload. Every ssh call now gets a null stdin unless it is fed data. Check a big upload with `md5sum` on the device.
- Host keys: ssh pins a host key before auth, so an early scan pinned the Kindle's key under `kobo`. `ink` now pins an unknown alias only after its own key logs in, and skips hosts whose key is already pinned to another device.
- Screenshots come out upright: 1404x1872, 8 bpp, rota 3.
- Touch: the elan panel uses slotless multitouch ("phoenix" in KOReader). A lift is `ABS_MT_TOUCH_MAJOR 0`, not `TRACKING_ID -1`. `inject.lua` detects this from the missing `ABS_MT_SLOT` axis.
- Stop and start:
  - `koreader.sh` re-execs from `/tmp/koreader.sh` and kills Nickel when it starts. On exit it runs `nickel.sh` if Nickel was running when it started; otherwise it reboots.
  - `ink stop` saves the reader's Nickel-derived env (Wi-Fi module, interface, `KO_DONT_GRAB_INPUT`) to `/tmp/ink-koenv`. It then kills the script loop first, so the exit tail never runs, and then KOReader.
  - `ink start` relaunches with that env, with Nickel down. That takes about 2 s.
  - `ink start` also kills KFMon (2026-11-15). KFMon watches `koreader.png`, and KOReader's file browser at Home opens it, so KFMon spawned a second KOReader 3 s after an `ink start`. Its `block_spawns` only covers readers KFMon launched itself. A reboot brings KFMon back. It uses `killall kfmon`: busybox `pkill -x` and `pgrep -x` never match on this firmware, so the first version silently failed.
  - KOReader launched through KFMon's IPC (`printf 'start:1\n' | /usr/local/kfmon/bin/kfmon-ipc`) while Nickel is down lacks Nickel's env, so it grabs the touchscreen and injected taps are lost. `ink stop` keeps the saved env when the running reader lacks `KO_DONT_GRAB_INPUT`.
  - Exiting KOReader from its menu after an `ink start` reboots the Kobo into Nickel. That is harmless.
  - `/tmp/ink-koenv` is lost on reboot. The first `ink stop` after each KFMon launch writes it again.
- Without `KO_DONT_GRAB_INPUT`, KOReader grabs the touchscreen and injected taps are dropped. That is why the env is carried over.
- `dropbear` survives `ink stop`.

## Boot into KOReader (verified 2026-11-16)
- `koboot/koboot.md`: a udev rule starts KOReader through KFMon IPC after each boot, with a 3 s tap-to-cancel band, a two-strike crash guard, a `SKIP` flag and a NickelMenu toggle. With Nickel up, an IPC launch gets Nickel's env like a tap on `koreader.png`. Tap cancel and exit-to-Nickel still need a hand check.

## Not built for Kobo yet
- `ink awake`: Kobo has no powerd. KOReader's AutoSuspend plugin owns sleep there (`auto_suspend_timeout_seconds`, 900 now).
