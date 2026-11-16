# Setup

From zero to a fast reader you can drive from the Mac. Tested on a Kindle Basic 7th gen and a Kobo Aura ONE; other KOReader readers should follow the same path (Kobo-like or Kindle-like).

## You need
- A Mac (the dev kit uses `sips`, `launchctl`) with [Homebrew](https://brew.sh). `install.sh` brings Python.
- The reader on the same Wi-Fi as the Mac.
- A USB cable for the first setup only.


## 1. Mac
```bash
git clone https://github.com/lukaskornis/ereader-skills && cd ereader-skills
./install.sh
downloads/fetch.sh
```
`install.sh` installs Python through Homebrew if needed, puts `ink` on your PATH, links the Claude Code skill and makes one SSH key per reader. `fetch.sh` downloads KOReader and the Kindle tools and checks their hashes.

## 2a. Kindle: jailbreak, then KOReader
Read [kindle-jailbreak.md](kindle-jailbreak.md) all the way through first. The one rule: **turn on airplane mode before you start and keep it on until OTA updates are blocked.** An automatic update can close the jailbreak hole, and some updates can't be undone.
Then follow [koreader-install.md](koreader-install.md), Kindle part, and keep [kindle.md](kindle.md) at hand: it lists what works on the Kindle and its safety rules.
Once OTA is blocked (jailbreak step 5), turn airplane mode off.

## 2b. Kobo: KOReader
Kobos need no jailbreak. Follow [kobo.md](kobo.md): install KOReader with NickelMenu, then optionally [koboot](koboot/koboot.md) to boot straight into KOReader.

## 3. Connect ink
1. Start KOReader once (Kindle: open "KOReader" in the library; Kobo: the NickelMenu entry) and join Wi-Fi from its top menu. The first start creates its settings.
2. In KOReader: top menu > settings (gear) tab > Network > SSH server: "Login with key only" on, "Login without password (DANGEROUS)" off, "Start SSH server with KOReader" on.
3. Plug in USB and copy the key `install.sh` made, `~/.ssh/kindle_ed25519.pub` (or `kobo_ed25519.pub`), to `koreader/settings/SSH/authorized_keys` (Kobo: `.adds/koreader/settings/SSH/authorized_keys`). Eject with `sync; diskutil unmount`, never force.
4. Start the SSH server from the same menu (or restart KOReader), then on the Mac:
```bash
ink -d kindle find
ink -d kindle info
ink -d kindle shot
```
`find` scans your Wi-Fi for the reader's SSH port and remembers its address. The first `ink` run writes `~/.config/ink/devices.json` with a `kindle` and a `kobo` entry; `-d` picks one, and without it `ink` uses `kindle`.

## 4. Shelf and the speed patches
```bash
ink -d kindle install
```
Pushes the Shelf plugin and the speed patches, then restarts KOReader. Each patch checks the hardware and skips what your reader lacks. The `ink-eval` patch comes along too: it is what lets `ink eval` and `ink reload` work, and it costs nothing while idle. `install shelf` or `install patches` does one part; running it again changes nothing unless a file differs. Use `-d kobo` for a Kobo.

## Safety
- Never update the Kindle firmware after jailbreaking unless the jailbreak docs say the version is safe.
- Eject USB with `sync; diskutil unmount`, never force it.
- `ink` only touches KOReader's own files and settings. It never writes firmware.

