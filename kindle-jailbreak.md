# Kindle jailbreak

Verified on a Kindle Basic 7th gen (KT2, "Bourbon", Wario platform) running firmware 5.12.2.1.1, on 2026-11-15. Every file comes from `downloads/fetch.sh`, which checks the tested hashes.

## Pick the method for your firmware
- Find your firmware under Settings > Device Info (or Device Options > Device Info).
- KindleBreak, used here, works on older firmware such as 5.12.2.1.1 and does NOT work on 5.12.2.2. It is listed as "Legacy" at https://kindlemodding.org/jailbreaking/Legacy/KindleBreak/.
- Newer firmware needs another method (WinterBreak below 5.18.1, AdBreak 5.18.1 to 5.18.5.0.1, others). Use the wizard at https://kindlemodding.org/jailbreak-wizard.html; this pack has not tested those. Steps 2 to 5 below are the same after any jailbreak.

## Before anything
- Turn on airplane mode, and keep it on until step 5 is done. An automatic update can close the jailbreak hole.
- NEVER let a KT2 go to 5.12.2.2. Its only recovery is Popcorn, which needs hardware access.
- Stuck or frozen? Never hold power for 40 s while the Kindle may be writing. Use Settings > Restart, or wait.
- Mac: put an empty `.metadata_never_index` file in the Kindle root before copying anything (see USB hygiene below).

## Order that worked
1. **KindleBreak** (`jb-kindlebreak.zip`, `file__0.localstorage`, by tryol)
   1. Airplane mode on. Connect USB.
   2. Unzip `jb-kindlebreak.zip` into the Kindle root, next to `documents`.
   3. Copy `file__0.localstorage` to `.active_content_sandbox/browser/resource/LocalStorage/` in the root (create the folders if missing, overwrite the file). The folder is hidden: in Finder press Cmd-Shift-. to see it.
   4. Eject safely.
   5. Open the Experimental Browser (Menu > Experimental Browser). It freezes and crashes. That is expected.
   6. Wait up to 5 minutes. The Kindle reboots and shows an "Application Error" or "Collecting Debug Info" popup: the jailbreak worked. If not, read `kindlebreak_log.txt` in the USB root, check your firmware is one KindleBreak supports, restart (Settings > Restart) and repeat from step 1.5 once. Still failing: ask at https://kindlemodding.org.
2. **Universal hotfix** (`Update_hotfix_universal.bin`, KindleModding, GPL-3). Copy it to the Kindle root, eject, then go Home > Menu (≡) > Settings > Menu (≡) > Update Your Kindle. Airplane mode stays on: the update file is local. It keeps the jailbreak through updates and adds the "Run Hotfix" booklet to the library; open that booklet once.
3. **KUAL** (`PEKI.zip`, Penguins' Epic KUAL Installer). Unzip it to the root. It provides `extensions/` and the KUAL launcher in the library.
4. **MRPI** (`kual-mrinstaller-khf.zip`, NiLuJe). Unzip it to the root; it puts `extensions/MRInstaller` and `mrpackages/` there.
5. **Block OTA** (`renameotabin.zip`, hius07). Unzip it into `extensions/`, then run KUAL > Rename OTA Binaries > Rename.
   - `/usr/bin` is not visible over USB. Once ink works (README step 3), verify: `ink -d kindle sh ls /usr/bin/ota*` shows `.bck` names.
   - After that, airplane mode can be turned off.

Next: `koreader-install.md`.

## USB copy hygiene (macOS)
- Put `.metadata_never_index` in the Kindle root. Spotlight indexing during an unmount once corrupted 8 files.
- Eject with `sync; diskutil unmount /Volumes/Kindle`. Force only if mds_stores blocks it, then remount and diff to verify.
- `FSCK0000.REN` files at the root mean an earlier unclean unmount.
