# koboot: boot the Kobo straight into KOReader

After every boot, Nickel comes up as usual, then a white band says "Starting KOReader / Tap to stay in Nickel" for 3 s. A tap keeps Nickel; no tap launches KOReader through KFMon, exactly as a tap on `koreader.png` would. Exiting KOReader brings Nickel back (`reboot_on_exit=false` in `.adds/kfmon/config/koreader.ini`).

Built for the Aura ONE (1404 px wide band), firmware 4.38.23171, KFMon 1.4.6, NickelMenu. Tested on the Aura ONE only; other models need the band width changed.

Needs KFMon (https://github.com/NiLuJe/kfmon, launches KOReader from the `koreader.png` icon) and NickelMenu installed, and ink working (README step 3).

## Files
| Here | On the Kobo | Job |
|---|---|---|
| `rootfs/99-koboot.rules` | `/etc/udev/rules.d/` | Runs the launcher on `mmcblk0` events |
| `rootfs/koboot-launch.sh` | `/usr/local/koboot/` (755) | Once per boot (`/tmp/koboot.once`), detaches, waits for `/mnt/onboard`, runs the onboard script if it exists |
| `onboard/koboot.sh` | `/mnt/onboard/.adds/koboot/` | The logic below |
| `onboard/tap-wait.lua` | same | Grabs the touchscreen (EVIOCGRAB) for N ms; exit 0 on a touch. Holds the grab until the finger lifts, so Nickel never sees the tap. Run with KOReader's luajit |
| `onboard/toggle.sh` | same | Flips the `SKIP` flag; turning on also clears `crashes` |
| `onboard/nm/koboot` | `/mnt/onboard/.adds/nm/` | NickelMenu entry "KOReader autostart on/off" |

Install or reinstall (also after a firmware update, which wipes the rootfs part), from this folder:
```
for f in koboot.sh tap-wait.lua toggle.sh; do ink -d kobo sh "mkdir -p /mnt/onboard/.adds/koboot; cat > /mnt/onboard/.adds/koboot/$f" < onboard/$f; done
ink -d kobo sh 'cat > /mnt/onboard/.adds/nm/koboot' < onboard/nm/koboot
ink -d kobo sh 'mkdir -p /usr/local/koboot && cat > /usr/local/koboot/koboot-launch.sh && chmod 755 /usr/local/koboot/koboot-launch.sh' < rootfs/koboot-launch.sh
ink -d kobo sh 'cat > /etc/udev/rules.d/99-koboot.rules; sync' < rootfs/99-koboot.rules
```
SSH is root with a writable rootfs, so no KoboRoot.tgz is needed.

## Why this hook
- Nothing offers an autostart: KFMon has no on-boot action, NickelMenu none.
- KFMon itself boots by replacing `/etc/init.d/on-animator.sh`; editing that would be lost on a KFMon update.
- rcS (non-freescale platforms, this one is `mx6sl-ntx`) restores `/dev` from `/etc/udev.tgz` instead of an early `udevadm trigger`, then runs `udevadm trigger &` right after starting Nickel. A rule in `/etc/udev/rules.d` therefore fires once Nickel is starting, and survives KFMon and NickelMenu updates. A firmware update wipes it: safe failure, Nickel boots as normal.
- Launch path: KFMon IPC (`start:<id>`, id looked up by `list` for `koreader.png`, currently 1). With Nickel running, `koreader.sh` sees KFMon as its parent, siphons Nickel's env and sets `KO_DONT_GRAB_INPUT`, so ink taps work and exit restarts Nickel. The older note that an IPC launch lacks the env only applies when Nickel is down.

## koboot.sh flow
1. `SKIP` exists → log, stop.
2. `crashes` ≥ 2 → band "KOReader autostart paused", stop.
3. Wait for the `nickel` process, then for Nickel to open `KoboReader.sqlite` (its last step before the home screen), then 4 s.
4. KOReader already running → stop.
5. Band, `tap-wait.lua 3000`. Touch → band "Staying in Nickel" (it stays until Nickel repaints that area), stop.
6. `crashes` += 1, sync, IPC start. Once KOReader has stayed up 30 s, `crashes` is deleted.

So a KOReader that crashes or reboots the device during start is tried twice, then autostart pauses until the menu toggle turns it back on.

## Recovery
- Over USB: create `.adds/koboot/SKIP`, or delete `.adds/koboot` entirely (the launcher then does nothing). Nickel and USB mass storage are untouched by the hook.
- `.adds/kfmon/config/BLOCK` stops KFMon spawning anything.
- Log: `.adds/koboot/koboot.log`, uptime-stamped, last 200 lines.

## Measured (2026-11-16, first boot)
Uptime: script start 6.1 s, Nickel process 6.2 s, Nickel DB open 11.7 s, KOReader started 19.0 s (4 s settle + 3 s tap window), clean run 51 s. SSH back about 49 s after the reboot command.

## Verified
- 2026-11-16: rule matches (`udevadm test /block/mmcblk0`), launcher returns in 10 ms and runs once per boot, full boot into KOReader with Nickel's env (`KO_DONT_GRAB_INPUT`, `NICKEL_HOME`), clean-run reset, SKIP path, crash-guard path, toggle script, tap-wait timeout with grab.
- Pending, needs a finger: tap cancel on boot, exit to Nickel from an autostarted KOReader, the NickelMenu entry.
