## E-reader skills (any KOReader reader; tested on Kindle and Kobo)

Make an old e-reader fast and modern with KOReader, then develop and test on it over Wi-Fi with no cables and no tapping.

| Doc / script | Read when |
|---|---|
| `kindle-jailbreak.md` | Jailbreaking a Kindle and making it update-proof |
| `koreader-install.md` | Installing KOReader with SSH, a launcher and the Wi-Fi drop folder |
| `speed.md` | Speeding up the reader: CPU, stock UI off, refresh, layout, memory |
| `kobo.md` | Anything Kobo; it lists what is verified and what isn't |
| `kindle.md` | Anything Kindle: ink hookup, what is verified, home folder, page-turn quality, safety |
| `speed-kobo.md` | Kobo speed settings, measurements, CPU and page-turn patches |
| `koreader-patches.md` | Writing user patches or plugins: stages, menu items, refresh, busybox gotchas |
| `koreader-redraw.md` | How KOReader repaints and refreshes: setDirty, modes, promotion, e-ink settings, measured timings. Read before uimanager.lua |
| `minesweeper/minesweeper.md` | The Minesweeper plugin: four sizes, three difficulties, no-guess boards, hints, undo, Mac logic test |
| `typewriter/typewriter.md` | The typewriter: type on the Kobo with the Mac keyboard (`ink type`), plugin, relay, latency |
| `koboot/koboot.md` | Kobo boots straight into KOReader (tap to stay in Nickel): udev hook, crash guard, skip flag, recovery |
| `shelf/shelf.md` | The Shelf plugin: library home screen with covers, tiles or names |
| `patch-cpu-performance.lua` | KOReader user patch, installed as `patches/2-cpu-performance.lua` on Kobo and Kindle: full CPU clock, with a Settings > Device > Full CPU speed toggle (off: interactive on Kobo, ondemand on Kindle); skipped without a writable governor |
| `patch-fast-page-turn.lua` | KOReader user patch, installed as `patches/2-fast-page-turn.lua` on Kobo and Kindle (e-ink only): page turns use the DU waveform (toggle: reader gear tab, "Page turns: Fast / Quality", or a gesture; Kindle defaults to Quality), and fast swipe bursts are coalesced into one refresh per 0.3 s |
| `patch-menu-prebuild.lua` | KOReader user patch, installed as `patches/2-menu-prebuild.lua` on Kobo and Kindle: reader menu built right after a book opens |
| `patch-ink-eval.lua` | Dev-only KOReader user patch, installed as `patches/2-ink-eval.lua` on Kobo and Kindle: lets `ink eval` and `ink reload` run Lua inside the running KOReader, and reports when the UI is idle and the panel done, so `ink time`, `restart`, `reload` and `burst.sh` stop at once |
| `prof-timers.lua` | `ink -d kobo eval - < prof-timers.lua`: wraps reader close, file manager, `_repaint`, shelf paint and every refresh mode with timers; read `_G.PROF.log` / `_G.PROF.rlog` after the action |
| `prof-open.lua` | `ink -d kobo eval - < prof-open.lua`, open a book, then read `_G.PO.log`: each book-open stage (popup, document open, every module, crengine load and render, events) and every panel refresh with its waveform |
| `burst.sh`, `burst-timers.lua`, `panel-probe.lua` | Swipe-burst test: `ink sh 'cat > /tmp/burst.sh' < burst.sh` (plus `inject.lua` to `/tmp/inject.lua`), then `ink sh 'cd <koreader> && eval $(./fbink -e); set -- 10 140; . /tmp/burst.sh'`; it prints when the last page was painted and the panel done after the last swipe. For per-turn detail, `ink eval - <` the two Lua files first and read `_G.BT.log` |
| `reload.lua` | Plugin hot-reload script `ink reload` runs inside KOReader; no direct use |
| `ink` | The Wi-Fi dev kit CLI, symlinked to `~/.local/bin/ink` |
| `inject.lua` | Touch injector `ink` runs on the device; no direct use |
| `fbz.lua` | Screenshot grabber `ink shot` runs on the device: zstd-compresses the framebuffer; no direct use |
| `settings.lua` | Settings editor `ink get/set` runs on the device through KOReader's own LuaSettings; no direct use |
| `kindle-push`, `kindle-push.plist.template` | Drop-folder pusher and its LaunchAgent (installed copies live in `~/.local/bin` and `~/Library/LaunchAgents`) |
| `KOReader.sh` | Kindle library launcher: fast CPU, stock UI off |
| `downloads/` | Exact installer files that worked: hotfix, KUAL (PEKI), MRPI, renameotabin, KOReader for Kindle and Kobo |

### ink: the dev kit

`ink [-d DEVICE] <command>`. Devices are listed in `~/.config/ink/devices.json`. Each entry has its own SSH key, a host-key alias and an IP cache. The host key is how two readers on one network are told apart.

| Command | What it does |
|---|---|
| `ink shot [OUT] [--max N]` | Screenshot to a PNG, default `/tmp/ink_<dev>_shot.png`, already shrunk to 400 px on the long side (`--max 0` keeps full res); prints the path and the tap scale, then `Read` it |
| `ink tap X Y` | Tap, in screenshot pixel coordinates |
| `ink time X Y [S=0.6] [--shot OUT]` | Tap, then the seconds to the last paint and to the panel done, timed on the device. With the Kobo hook it returns the moment KOReader is idle (no task due within 0.35 s) and the panel has finished; book open about 2 s wall, was 4 to 5. Without the hook (Kindle) it watches the framebuffer until unchanged for S s; pass 2 for book opens. Gives up after 3 s with no change. `--shot OUT` takes the screenshot after |
| `ink hold X Y [MS=800]` | Long press |
| `ink swipe X1 Y1 X2 Y2 [MS=120]` | Swipe; above ~200 ms it reads as a pan, so keep it fast |
| `ink push FILE… [--to DIR]` | Copy into the documents folder |
| `ink install [shelf\|patches\|all]` | Put the Shelf plugin (`plugins/shelf.koplugin`, replaced whole) and every `patch-X.lua` (as `patches/2-X.lua`, ink-eval included) on the device, then restart if KOReader runs. Compares md5s first: nothing changed means no copy and no restart (0.4 s). Default `all` |
| `ink log [N]` | Tail of KOReader's crash.log, which is also its stdout log |
| `ink restart` | Restart KOReader; returns once the first screen is painted and the panel done (3.4 s on the Kobo with the hook, 5.5 s without). The stock UI stays off (Kindle) |
| `ink stop`, `ink start` | Stop or start KOReader on its own; dropbear keeps SSH up while it is stopped |
| `ink get [KEY]` | A setting's value from `settings.reader.lua`; with no key, every key |
| `ink set KEY VALUE` | Change a setting. VALUE is a Lua literal (`true`, `42`, `{1, 2}`) or plain text. If KOReader is running it is stopped, edited and relaunched (about 7 s) |
| `ink unset KEY` | Remove a setting so KOReader uses its default |
| `ink awake on\|off\|status` | Stop the device from sleeping (Kindle, powerd) |
| `ink info` | Model, screen, battery, free memory, governor, whether KOReader is running |
| `ink sh CMD` | Run a shell command on the device; piped stdin is passed on, so `< file` uploads work. Under an agent, text over 150 lines is cut and the whole saved to `/tmp/ink-sh-full.txt` (`INK_ALL=1` lifts it; pipes pass whole) |
| `ink find` | Rescan the /24 subnet when the IP changed |
| `ink eval CODE` | Run Lua inside the running KOReader and print the result; a bare expression prints its value; wrap a statement in `do ... end`; `-` reads stdin. 0.2 s. Needs `patches/2-ink-eval.lua` (`ink install patches`) |
| `ink type` | Type on the reader with this keyboard; the typewriter page opens on the first key. Ctrl-C ends. See `typewriter/typewriter.md` |
| `ink reload NAME [DIR]` | Push the local plugin folder DIR (optional), reload plugin NAME's Lua modules in place, reopen the file manager (or the book), return once painted. 2.0 s, against 7 s for push plus restart |

### Speed (Kobo, 2026-11-15)
All calls share one SSH connection per device (kept 5 min), so a call costs one ~0.05 s round trip instead of a ~0.35 s handshake, and each command is a single round trip. Before → after, seconds: tap 1.6 → 0.25, shot 2.4 → 0.36, sh 1.2 → 0.14, log 1.0 → 0.13, get 1.2 → 0.23, info 1.7 → 0.25, stop 3.8 → 1.3 (KOReader's own exit), restart 4.3 (returned before the screen was ready, then a 6 s sleep) → 5.5 painted, start 2.0 (unready) → 4.6 painted.

### Dev loop (autonomous)
1. `ink awake on` at the start of a session. Set it `off` when done, because it drains the battery.
2. Change the code on the Mac. Push it with `ink push file --to <koreader>/plugins/x.koplugin` or with `ink sh` plus stdin.
3. Plugin change: `ink reload NAME DIR` (2 s, no restart). Patch change: `ink install patches` (copies and restarts). Settings or a broken hook still need `ink restart` (3.4 s). Then `ink shot` and `Read` the PNG; it comes out 400 px on the long side, and the printed scale (4.68 on the Kobo) maps a point in it to full-res taps. A tap plus its result is one call: `ink time X Y --shot OUT`.
4. Drive it with `tap`, `swipe` and `hold`, and screenshot after each step. Use `ink time X Y` as the tap when the next step needs the screen settled: it returns once it is. Never add sleeps: `restart`, `start` and `set` already return with the screen painted.
5. When something breaks, run `ink log 80`.
6. Testing Wi-Fi off cuts ink's link: first `ink eval` a `UIManager:scheduleIn` that takes `Screen:shot("/tmp/x.png")` and later calls `NetworkMgr:toggleWifiOn()`, then tap; fetch the PNG once it is back (about 30 s).

### How `ink eval` works
`patches/2-ink-eval.lua` wraps `Device.input.handleMiscEv`. ink writes the code to `/tmp/ink-eval.lua`, then one EV_MSC/MSC_RAW event with value "INK" (0x494E4B) to the FIFO `/tmp/ink-kick` with busybox printf. The patch makes that FIFO at start and hands it to KOReader's input loop with `Input:fdopen`, holding it read-write so it never hits EOF; the patch runs the file on the next tick and writes `/tmp/ink-eval.out`. Nothing polls, so idle cost is zero. A FIFO, not a real input node, because the kernel drops event types a node doesn't declare: the Kindle touch panel (KOReader's only node there) has no EV_MSC, and EV_SYN/SYN_CONFIG is dropped too (tried 2026-11-16). ink checks KOReader is running first, since a write to the FIFO with no reader blocks. A reload drops the plugin's module-level state (the Shelf cover cache), so the first view after it is cold.

### Idle report (2026-11-15)
The same patch arms an idle report on an "INI" event (0x494E49), and it starts armed at boot. Every panel update passes through `Screen.mech_refresh`, which the patch wraps to note the time (plus `/tmp/ink-idle.painted` on the first, so ink can tell "still working" from "the tap did nothing"). In `Input.waitEvent`, the point where KOReader is about to block, it reports when something was painted and no task is due within 0.35 s: it waits on the last refresh marker, then writes `<last paint> <panel done>` uptimes to `/tmp/ink-idle`. ink takes its start time from `/proc/uptime` too. Pitfalls: the UI is idle between swipes, so `burst.sh` arms after the last swipe; once, a PDF open's marker wait hit the kernel's 5 s timeout and blocked the UI that long. Kindle has no hook yet, so it keeps the framebuffer method.

### Agent routing (2026-11-15)
- Screenshots stay with the main agent: judging them is the decision, and a subagent's cold start (10 s or more) costs more than a 400 px image.
- Searching the KOReader source (the local copy in `koreader-src/<version>`, matching the installed release; check `ink sh 'cat <koreader>/git-rev'`) for where something lives: haiku Explore agent, low effort, when it takes more than two or three greps.
- Web research (waveforms, firmware, KOReader issues): sonnet agent, medium effort; bring back the answer only.
- Profiler and log output: filter with grep before it reaches the context; a full module list once cost 60 lines.
- Doc and changelog updates stay inline: they need this session's measurements.

### Routing rules
- A device reports "not found": KOReader is closed or the device is asleep. dropbear survives a KOReader exit, so `ink sh` usually still works. Relaunch with `ink sh 'setsid sh /mnt/us/documents/KOReader.sh </dev/null >/dev/null 2>&1 &'`.
- KOReader rewrites `settings.reader.lua` on exit, so never edit it by hand while it runs. Use `ink set`, which stops it first. For several changes, `ink stop`, then the `set` calls, then `ink start`: one relaunch instead of one per key.
- `ink get` reads the file, which KOReader saves on exit and every 15 minutes. A change made in the UI a moment ago may not show yet.
- Large scanned PDFs crash KOReader: malloc fails at 256 MB of RAM. Shrink them on the Mac first.
- Never chain taps. One `ink time` per tap, then a screenshot, and the next tap's coordinates come from that screenshot. A dialog that closes or reopens moves what lies under the next tap: on 2026-11-15 six chained taps on the typewriter settings fell through to the Shelf, opened a PDF, and the Kobo dropped off Wi-Fi.
- After `ink reload`, check the window stack (`ink eval` over `UIManager._window_stack`) before tapping: the old plugin's widgets can stay open under or over the reopened file manager.
- Never tap blind inside a PDF: its reader menu sits elsewhere, and taps at the epub's menu spots (700,60 then 957,53) once turned on USB Mass Storage. Screenshot first. Recovery: kill `usbms`, then `ink restart`.
- Never force-eject the Kindle's USB disk. Run `sync; diskutil unmount` first. A force unmount once corrupted KOReader files.

## Token-lean habits
- Read KOReader source from `koreader-src/<version>` with Grep and Read, never `ink sh sed`/`cat`: it was 80% of ink's token cost (measured 2026-11-16 over 38 sessions), mostly the same uimanager, readerui and framebuffer regions read again and again. For redraw questions, read `koreader-redraw.md` first.
- One call per tap: `ink time X Y --shot OUT`. Screenshots stay at 400 px; full res only to check fine detail.
- `ink eval` returns one value: ask for the exact field (`#list`, a flag), not a table dump.
