# KOReader install with the conveniences

## Kindle
1. Unzip `downloads/koreader-kindlepw2-*.zip` into the Kindle root. That gives `koreader/` plus `extensions/koreader`. The KT2 uses the `kindlepw2` build; newer builds come from the KOReader GitHub releases.
2. Copy `KOReader.sh` from this pack to `/mnt/us/documents/`.
   - It shows up in the library as "KOReader". Opening it runs it as a scriptlet (the universal hotfix from the jailbreak allows that), so KUAL isn't needed.
   - What it does is described in [speed.md](speed.md).
3. SSH, key only. This is what `ink` and the drop folder rely on.
   - Copy `~/.ssh/kindle_ed25519.pub` (made by `install.sh`) to `koreader/settings/SSH/authorized_keys`.
   - Easiest: README step 3 (KOReader's SSH menu). Or in `koreader/settings.reader.lua` (it exists after KOReader's first start; edit only while KOReader is closed), set `["SSH_autostart"] = true` and `["SSH_key_only_auth"] = true`. That gives port 2222, user root.
   - On first connect, the host key is stored under alias `kindle` in `~/.ssh/kindle_known_hosts`.
4. Wi-Fi drop folder on the Mac:
   - Copy `kindle-push` to `~/.local/bin/`, then write the LaunchAgent: `sed "s#__HOME__#$HOME#g" kindle-push.plist.template > ~/Library/LaunchAgents/local.ereader.kindle-push.plist`.
   - Run `mkdir -p ~/Kindle\ Inbox/Sent`.
   - Run `launchctl load ~/Library/LaunchAgents/local.ereader.kindle-push.plist`.
   - It runs on a folder change plus every 60 s. Sent files move to `Sent`, and you get a notification. Log: `~/Library/Logs/kindle-push.log`.
5. Dev kit: `install.sh` already put `ink` in `~/.local/bin`. The first run writes `~/.config/ink/devices.json`.
6. Check it: run `ink -d kindle find`, then `ink -d kindle info`.

## Kobo
See [kobo.md](kobo.md). The paths differ: KOReader lives in `/mnt/onboard/.adds/koreader`.
