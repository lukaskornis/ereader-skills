#!/usr/bin/env python3
"""ink: drive a KOReader e-reader (Kindle or Kobo) over Wi-Fi SSH.

Usage: ink [-d DEVICE] <command> [args]
  shot [OUT.png] [--max N]     screenshot, longest side shrunk to N px (400; 0 = full); prints path and tap scale
  tap X Y                      touch at framebuffer pixel X,Y
  hold X Y [MS=800]            long press
  swipe X1 Y1 X2 Y2 [MS=120]   drag (slower than ~200 ms reads as a pan)
  time X Y [S=0.6] [--shot OUT] tap, then seconds until the screen stops changing for S s; --shot also screenshots
  push FILE... [--to DIR]      copy books into the documents folder
  log [LINES=40]               tail KOReader's crash.log
  restart | stop | start       restart, stop or start KOReader without touching the device
  get [KEY]                    a setting's value, or every key when none is given
  set KEY VALUE                change a setting; VALUE is a Lua literal or plain text
  unset KEY                    remove a setting (KOReader falls back to its default)
  awake on|off|status          keep the device from sleeping (Kindle)
  info                         model, screen, battery, memory, governor
  sh CMD...                    run a shell command on the device; under an agent, output over 150 lines is cut (INK_ALL=1 lifts it)
  eval CODE | -                run Lua inside the running KOReader, print the result (needs the ink-eval patch)
  reload NAME [DIR]            push plugin DIR (optional), hot-reload plugin NAME, return once painted
  install [shelf|patches|all]  put the Shelf plugin and/or the speed patches on the device, restart if changed (all)
  type                         type on the reader with this keyboard (typewriter plugin); Ctrl-C ends
  find                         rescan the subnet for the device

Devices live in ~/.config/ink/devices.json. SSH needs KOReader's SSH server
(port 2222) running on the device, or any dropbear it left behind.
"""
import hashlib
import io
import json
import os
import stat
import shlex
import struct
import subprocess
import sys
import tarfile
import zlib
from compression import zstd
from concurrent.futures import ThreadPoolExecutor

KNOWN_HOSTS = os.path.expanduser("~/.ssh/kindle_known_hosts")

HERE = os.path.dirname(os.path.realpath(__file__))
CONFIG = os.path.expanduser("~/.config/ink/devices.json")
DEFAULT_CONFIG = {
    "default": "kindle",
    "devices": {
        "kindle": {
            "key": "~/.ssh/kindle_ed25519",
            "port": 2222,
            "host_alias": "kindle",
            "ip_cache": "~/Library/Caches/kindle-push.ip",
        },
        "kobo": {
            "key": "~/.ssh/kobo_ed25519",
            "port": 2222,
            "host_alias": "kobo",
        },
    },
}
PLATFORMS = {
    "kindle": {
        "marker": "/mnt/us/koreader",
        "koreader": "/mnt/us/koreader",
        "docs": "/mnt/us/documents",
        # Hotfix scriptlet: CPU governor + framework stop, see ereader-skills/speed.md.
        "launch": "setsid sh /mnt/us/documents/KOReader.sh",
        "loop": "[/]var/tmp/koreader.sh",
    },
    "kobo": {
        "marker": "/mnt/onboard/.adds/koreader",
        "koreader": "/mnt/onboard/.adds/koreader",
        "docs": "/mnt/onboard",
        # Without Nickel running, koreader.sh lacks the Wi-Fi env Nickel exports; stop_koreader saves it.
        # KFMon spawns a second KOReader when this one's file browser opens koreader.png; its
        # block_spawns only covers readers it launched itself, so it goes (a reboot restores it).
        "launch": "killall kfmon 2>/dev/null; cd /mnt/onboard/.adds/koreader && "
                  "{ [ -f /tmp/ink-koenv ] && export $(cat /tmp/ink-koenv); setsid sh ./koreader.sh; }",
        # koreader.sh re-execs itself from /tmp; with Nickel gone its exit tail reboots, so it dies first.
        "loop": "[/]tmp/koreader.sh",
        # gpio-keys node: KOReader reads it, and its EV_MSC carries typewriter keys.
        "buttons": "/dev/input/event0",
        "env": "DBUS_SESSION_BUS_ADDRESS|NICKEL_HOME|WIFI_MODULE|LANG|INTERFACE|PRODUCT|PLATFORM|KO_DONT_GRAB_INPUT",
    },
}


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_config():
    if not os.path.exists(CONFIG):
        os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
        with open(CONFIG, "w") as f:
            json.dump(DEFAULT_CONFIG, f, indent=2)
    with open(CONFIG) as f:
        return json.load(f)


class Device:
    def __init__(self, name, cfg):
        self.name = name
        self.key = os.path.expanduser(cfg["key"])
        self.port = int(cfg.get("port", 2222))
        self.alias = cfg.get("host_alias", name)
        self.ip_cache = os.path.expanduser(cfg.get("ip_cache", f"~/Library/Caches/ink-{name}.ip"))
        self.ip = None
        self.platform = None

    # One shared connection per device: a fresh handshake costs ~0.35 s, a reused one ~0.05 s.
    def ssh_args(self, ip, timeout=3):
        return ["ssh", "-i", self.key, "-p", str(self.port), "-o", "BatchMode=yes",
                "-o", f"ConnectTimeout={timeout}", "-o", "IdentitiesOnly=yes",
                "-o", "ControlMaster=auto", "-o", f"ControlPath=~/.ssh/cm-ink-{self.alias}-%C",
                "-o", "ControlPersist=300", "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2",
                "-o", f"HostKeyAlias={self.alias}",
                "-o", f"UserKnownHostsFile={KNOWN_HOSTS}",
                "-o", "StrictHostKeyChecking=accept-new", f"root@{ip}"]

    # The host key check is what tells two readers on the same subnet apart.
    # ssh pins a new host key before auth, so a scan could pin another reader under this
    # alias; an unpinned alias is therefore only pinned after our key logs in.
    def answers(self, ip):
        pinned = _pinned_keys()
        if self.alias in pinned:
            probe = self.ssh_args(ip) + ["echo ok"]
            # DEVNULL: an inherited stdin lets a probe swallow the start of a piped upload.
            return subprocess.run(probe, capture_output=True, text=True,
                                  stdin=subprocess.DEVNULL).stdout.strip() == "ok"
        scan = subprocess.run(["ssh-keyscan", "-T", "3", "-t", "ed25519", "-p", str(self.port), ip],
                              capture_output=True, text=True).stdout
        scan = next((line.split() for line in scan.splitlines() if line and not line.startswith("#")), [])
        if len(scan) < 3 or scan[2] in pinned.values():
            return False
        probe = self.ssh_args(ip)
        probe[probe.index("ControlMaster=auto")] = "ControlMaster=no"
        probe[probe.index(f"UserKnownHostsFile={KNOWN_HOSTS}")] = "UserKnownHostsFile=/dev/null"
        probe[probe.index("StrictHostKeyChecking=accept-new")] = "StrictHostKeyChecking=no"
        if subprocess.run(probe + ["echo ok"], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL).stdout.strip() != "ok":
            return False
        with open(KNOWN_HOSTS, "a") as f:
            f.write(f"{self.alias} {scan[1]} {scan[2]}\n")
        return True

    def connect(self, rescan=False):
        marker_test = " || ".join(f"(test -d {p['marker']} && echo {n})" for n, p in PLATFORMS.items())
        cached = None if rescan else _read(self.ip_cache)
        # The pinned host key makes the platform probe double as the "is it still our reader" check.
        tried = bool(cached and _pinned_keys().get(self.alias))
        if tried:
            self.ip = cached
            self.platform = self.run(marker_test, check=False).stdout.strip()
        if self.platform not in PLATFORMS:
            self.ip = cached if cached and not tried and self.answers(cached) else self._scan()
            with open(self.ip_cache, "w") as f:
                f.write(self.ip + "\n")
            self.platform = self.run(marker_test).stdout.strip()
        if self.platform not in PLATFORMS:
            die(f"{self.name} at {self.ip} has no KOReader folder")
        return self

    def _scan(self):
        iface = _out(["route", "-n", "get", "default"]).split("interface:")[-1].split()[0]
        prefix = _out(["ipconfig", "getifaddr", iface]).strip().rsplit(".", 1)[0]
        hosts = [f"{prefix}.{i}" for i in range(1, 255)]

        def port_open(ip):
            return subprocess.run(["nc", "-z", "-G", "1", ip, str(self.port)],
                                  capture_output=True).returncode == 0
        with ThreadPoolExecutor(64) as pool:
            open_hosts = [ip for ip, ok in zip(hosts, pool.map(port_open, hosts)) if ok]
        for ip in open_hosts:
            if self.answers(ip):
                return ip
        die(f"{self.name} not found on {prefix}.0/24. Is KOReader open and the device awake?")

    def run(self, cmd, stdin=None, binary=False, check=True):
        feed = {"input": stdin} if stdin is not None else {"stdin": subprocess.DEVNULL}
        r = subprocess.run(self.ssh_args(self.ip) + [cmd], capture_output=True, text=not binary, **feed)
        if check and r.returncode != 0:
            err = r.stderr if not binary else r.stderr.decode(errors="replace")
            die(f"device command failed ({r.returncode}): {err.strip()}")
        return r

    @property
    def paths(self):
        return PLATFORMS[self.platform]

    # fbink -e prints shell assignments; eval'ing them inside the command saves a round trip.
    def fb_env(self):
        return f"eval $({self.paths['koreader']}/fbink -e); "

    def fbinfo(self):
        raw = self.run(f"{self.paths['koreader']}/fbink -e").stdout
        info = {}
        for part in raw.strip().split(";"):
            if "=" in part:
                k, v = part.split("=", 1)
                info[k] = v.strip("'")
        return info


def _pinned_keys():
    try:
        with open(KNOWN_HOSTS) as f:
            return {parts[0]: parts[2] for parts in (line.split() for line in f) if len(parts) >= 3}
    except FileNotFoundError:
        return {}


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def _out(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def write_gray_png(path, width, height, rows):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
    raw = b"".join(b"\x00" + row for row in rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def to_gray_row(line, bpp, width, inverted):
    if bpp == 8:
        row = line[:width]
        return bytes(255 - b for b in row) if inverted else row
    if bpp == 16:
        px = struct.unpack(f"<{width}H", line[:width * 2])
        return bytes((((p >> 11) & 31) * 77 * 255 // 31 + ((p >> 5) & 63) * 150 * 255 // 63
                      + (p & 31) * 29 * 255 // 31) >> 8 for p in px)
    if bpp == 32:
        return bytes((line[i + 2] * 77 + line[i + 1] * 150 + line[i] * 29) >> 8
                     for i in range(0, width * 4, 4))
    die(f"unsupported framebuffer depth {bpp} bpp")


SHOT_MAX = 400
SH_LINES = 150
SH_FULL = "/tmp/ink-sh-full.txt"


def take_flag(args, flag, default=None):
    if flag not in args:
        return args, default
    i = args.index(flag)
    if i + 1 >= len(args):
        die(f"{flag} needs a value")
    return args[:i] + args[i + 2:], args[i + 1]


def cmd_shot(dev, args):
    args, max_side = take_flag(args, "--max", SHOT_MAX)
    if not str(max_side).isdigit():
        die("--max needs a whole number of pixels")
    out = os.path.abspath(args[0]) if args else f"/tmp/ink_{dev.name}_shot.png"
    # Raw frames are ~2.6 MB (1 s over Wi-Fi); fbz.lua zstd-compresses them on the device to ~0.1 MB.
    with open(os.path.join(HERE, "fbz.lua"), "rb") as f:
        script = f.read()
    blob = dev.run(f"cd {dev.paths['koreader']} && {dev.fb_env()}"
                   "echo $viewWidth $viewHeight $lineLength $BPP $viewHoriOrigin $viewVertOrigin "
                   "${invertedGrayscale:-0}; ./luajit - $((lineLength * (viewVertOrigin + viewHeight)))",
                   stdin=script, binary=True).stdout
    header, kind, data = blob.split(b"\n", 2)
    w, h, stride, bpp, x0, y0, inv = (int(v) for v in header.split())
    if kind == b"Z":
        data = zstd.decompress(data)
    if len(data) < stride * (y0 + h):
        die(f"short framebuffer read: {len(data)} bytes")
    inverted = inv == 1
    skip = x0 * bpp // 8
    rows = [to_gray_row(data[(y0 + y) * stride + skip:(y0 + y + 1) * stride], bpp, w, inverted)
            for y in range(h)]
    write_gray_png(out, w, h, rows)
    # A full frame costs ~10x the image tokens of a 400 px one and rarely shows more; the scale maps it back to taps.
    max_side = int(max_side)
    if max_side and max(w, h) > max_side:
        subprocess.run(["sips", "-Z", str(max_side), out], capture_output=True, check=True)
        print(f"{out} scale {max(w, h) / max_side:.2f}")
    else:
        print(out)


FB_HASH = "dd if=/dev/fb0 bs=$lineLength count=$((viewVertOrigin + viewHeight)) 2>/dev/null | md5sum"
INJECT_FB_ARGS = "${touchSwapAxes:-0} ${touchMirrorX:-0} ${touchMirrorY:-0} $viewWidth $viewHeight"


def cmd_gesture(dev, gesture, args):
    needed = {"tap": 2, "hold": 2, "swipe": 4}[gesture]
    if len(args) < needed or not all(a.lstrip("-").isdigit() for a in args):
        die(f"{gesture} needs {needed} integer coordinates")
    defaults = {"hold": ["800"], "swipe": ["120"]}.get(gesture, [])
    args = args + defaults[len(args) - needed:]
    with open(os.path.join(HERE, "inject.lua"), "rb") as f:
        script = f.read()
    r = dev.run(f"cd {dev.paths['koreader']} && {dev.fb_env()}./luajit - {INJECT_FB_ARGS} "
                + " ".join([gesture] + args), stdin=script, binary=True)
    print(r.stdout.decode().strip())


IDLE_OUT = "/tmp/ink-idle"
# The hook's FIFO input device; with no KOReader reading it a write would block, so writes check first.
KICK_FIFO = "/tmp/ink-kick"
KICK_READY = f"[ -p {KICK_FIFO} ] && [ -n \"$(pgrep -f '[r]eader.lua')\" ]"
# EV_MSC/MSC_RAW "INI" arms the idle report in patches/2-ink-eval.lua; same layout as EVAL_KICK below.
IDLE_KICK = "printf '\\0\\0\\0\\0\\0\\0\\0\\0\\4\\0\\3\\0INI\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0'"
UP_SH = "up() { cut -d' ' -f1 /proc/uptime; }; "


def idle_arm_sh(dev):
    # Sets ok=1 once KOReader has armed the idle report; stays empty without the hook.
    return (f"rm -f {IDLE_OUT} {IDLE_OUT}.armed {IDLE_OUT}.painted; ok=; "
            f"{KICK_READY} && {IDLE_KICK} > {KICK_FIFO} && "
            f"{{ i=0; while [ ! -e {IDLE_OUT}.armed ] && [ $i -lt 50 ]; do usleep 10000; i=$((i+1)); done; "
            f"[ -e {IDLE_OUT}.armed ] && ok=1; }}; ")


def idle_wait_sh(give_up=300, cap=2000):
    # Expects t0; waits in ~10 ms steps for the idle report. Gives up after give_up steps if nothing
    # was painted, or cap steps in all; prints like the framebuffer probe.
    return (f"i=0; while [ ! -e {IDLE_OUT} ] && [ $i -lt {cap} ]; do usleep 10000; i=$((i+1)); "
            f"[ $i -ge {give_up} ] && [ ! -e {IDLE_OUT}.painted ] && break; done; "
            f"if [ -e {IDLE_OUT} ]; then read p d < {IDLE_OUT}; "
            "awk \"BEGIN{printf \\\"settled %.2f s, panel done %.2f s\\\", $p-$t0, $d-$t0}\"; "
            f"elif [ -e {IDLE_OUT}.painted ]; then echo 'no idle after 20 s'; else echo 'no screen change'; fi")


def cmd_time(dev, args):
    args, shot = take_flag(args, "--shot")
    if len(args) not in (2, 3) or not all(a.isdigit() for a in args[:2]):
        die("time needs 2 integer coordinates and an optional settle time in seconds")
    settle = float(args[2]) if len(args) == 3 else 0.6
    tap = f"./luajit - {INJECT_FB_ARGS} tap {' '.join(args[:2])} >/dev/null; "
    # Timed on the device from /proc/uptime so ssh latency stays out of the figure.
    # With the KOReader hook, "settled" is the last paint before the UI went idle. Without it, the
    # framebuffer must stay unchanged for S s (book opens hold a popup, so they need 2). Stops after 20 s.
    probe = (f"cd {dev.paths['koreader']}; {dev.fb_env()}{UP_SH}"
             + idle_arm_sh(dev)
             + "if [ -n \"$ok\" ]; then t0=$(up); " + tap + idle_wait_sh() + "; else "
             f"h() {{ {FB_HASH}; }}; "
             "last=$(h); t0=$(up); " + tap +
             "changed=; while :; do now=$(h); t=$(up); "
             "if [ \"$now\" != \"$last\" ]; then last=$now; changed=$t; "
             f"elif [ -n \"$changed\" ]; then awk \"BEGIN{{exit !($t-$changed>={settle})}}\" && break; fi; "
             "awk \"BEGIN{exit !($t-$t0>20)}\" && break; "
             # A tap that changes nothing would otherwise wait out the full 20 s.
             "[ -z \"$changed\" ] && awk \"BEGIN{exit !($t-$t0>3)}\" && break; done; "
             "[ -n \"$changed\" ] && awk \"BEGIN{printf \\\"settled %.2f s\\\", $changed-$t0}\" || echo 'no screen change'; fi")
    with open(os.path.join(HERE, "inject.lua"), "rb") as f:
        out = dev.run(probe, stdin=f.read(), binary=True).stdout.decode().strip()
    print(out)
    if shot:
        cmd_shot(dev, [shot])


EVAL_SCRIPT, EVAL_OUT = "/tmp/ink-eval.lua", "/tmp/ink-eval.out"
# One EV_MSC/MSC_RAW event with value "INK", then SYN_REPORT; 16-byte input_event on these 32-bit readers.
EVAL_KICK = "printf '\\0\\0\\0\\0\\0\\0\\0\\0\\4\\0\\3\\0KNI\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0'"


def eval_lua(dev, code, settle=None):
    """Runs code inside KOReader via patches/2-ink-eval.lua; with settle, also waits for the screen."""
    wait = ("i=0; while [ ! -e {out} ] && [ $i -lt 500 ]; do usleep 20000; i=$((i+1)); done; "
            "cat {out} 2>/dev/null || echo 'error: no answer; is patches/2-ink-eval.lua installed?'").format(out=EVAL_OUT)
    pre = ""
    if settle is not None:
        # The idle report if the hook arms; else the framebuffer settle.
        pre = UP_SH + idle_arm_sh(dev) + f"{dev.fb_env()}h() {{ {FB_HASH}; }}; last=$(h); t0=$(up); "
        wait += f"; if [ -n \"$ok\" ]; then {idle_wait_sh()}; else {settle_sh(settle)}; fi"
    cmd = (f"{pre}rm -f {EVAL_OUT}; cat > {EVAL_SCRIPT} && "
           f"{{ {KICK_READY} || {{ echo 'error: KOReader is not running, or patches/2-ink-eval.lua is missing'; exit; }}; }} && "
           f"{EVAL_KICK} > {KICK_FIFO} && {wait}")
    r = dev.run(cmd, stdin=code.encode(), binary=True, check=False)
    return r.stdout.decode().strip()


def settle_sh(settle):
    # Expects h() and last=$(h) set before the action; prints how long the screen kept changing.
    return ("up() { cut -d' ' -f1 /proc/uptime; }; t0=$(up); changed=; while :; do now=$(h); t=$(up); "
            "if [ \"$now\" != \"$last\" ]; then last=$now; changed=$t; "
            f"elif [ -n \"$changed\" ]; then awk \"BEGIN{{exit !($t-$changed>={settle})}}\" && break; fi; "
            "awk \"BEGIN{exit !($t-$t0>20)}\" && break; "
            "[ -z \"$changed\" ] && awk \"BEGIN{exit !($t-$t0>3)}\" && break; done; "
            "[ -n \"$changed\" ] && awk \"BEGIN{printf \\\"painted %.2f s\\\", $changed-$t0}\" || echo 'no screen change'")


def cmd_eval(dev, args):
    if not args:
        die("eval needs Lua code, or - to read it from stdin")
    code = sys.stdin.read() if args == ["-"] else " ".join(args)
    # A bare expression prints its value, like a REPL.
    if not code.lstrip().startswith(("return", "local", "for", "if", "do", "while")) and "\n" not in code.strip():
        code = "return " + code
    out = eval_lua(dev, code)
    print(out)
    if out.startswith("error"):
        sys.exit(1)


def cmd_reload(dev, args):
    if len(args) not in (1, 2):
        die("reload needs a plugin NAME and an optional local plugin DIR to push first")
    name = args[0]
    if len(args) == 2:
        src = os.path.abspath(args[1].rstrip("/"))
        folder = os.path.basename(src)
        tar = subprocess.run(["tar", "cf", "-", "-C", os.path.dirname(src), folder],
                             capture_output=True, env={**os.environ, "COPYFILE_DISABLE": "1"})
        plugins = f"{dev.paths['koreader']}/plugins"
        dev.run(f"cd {plugins} && rm -rf {shlex.quote(folder)} && tar xf -", stdin=tar.stdout, binary=True)
    with open(os.path.join(HERE, "reload.lua")) as f:
        code = f"local NAME = {json.dumps(name)}\n" + f.read()
    out = eval_lua(dev, code, settle=0.6)
    print(out)
    if out.startswith("error"):
        sys.exit(1)


def cmd_type(dev, args):
    buttons = dev.paths.get("buttons")
    if not buttons:
        die(f"type is not set up for {dev.platform} yet")
    with open(os.path.join(HERE, "typewriter", "tw-writer.lua"), "rb") as f:
        dev.run("cat > /tmp/tw-writer.lua", stdin=f.read(), binary=True)
    # Its own connection with a pty: ssh turns on TCP_NODELAY for tty sessions, so each key leaves at
    # once, and ssh puts this terminal in raw mode itself. The remote pty goes raw too, so bytes pass as typed.
    ssh = dev.ssh_args(dev.ip)
    ssh[ssh.index("ControlMaster=auto")] = "ControlMaster=no"
    ssh[ssh.index(next(a for a in ssh if a.startswith("ControlPath=")))] = "ControlPath=none"
    remote = f"stty raw -echo; cd {dev.paths['koreader']} && exec ./luajit /tmp/tw-writer.lua {buttons}"
    print("Typing on the reader. Ctrl-C to stop.")
    os.execvp("ssh", ["ssh", "-tt", "-e", "none", "-o", "LogLevel=QUIET"] + ssh[1:] + [remote])


def cmd_push(dev, args):
    dest = dev.paths["docs"]
    if "--to" in args:
        i = args.index("--to")
        if i + 1 >= len(args):
            die("--to needs a folder")
        dest, args = args[i + 1], args[:i] + args[i + 2:]
    if not args:
        die("push needs at least one file")
    for path in args:
        if not os.path.isfile(path):
            die(f"not a file: {path}")
        name = shlex.quote(os.path.basename(path))
        tmp = shlex.quote(f"{dest}/.ink-incoming")
        with open(path, "rb") as f:
            dev.run(f"mkdir -p {shlex.quote(dest)} && cat > {tmp} && mv {tmp} {shlex.quote(dest)}/{name}",
                    stdin=f.read(), binary=True)
        print(f"sent {os.path.basename(path)}")


# Paths relative to the KOReader folder, mapped to local files.
def install_files(what):
    files = {}
    if what in ("shelf", "all"):
        src = os.path.join(HERE, "shelf", "shelf.koplugin")
        for root, dirs, names in os.walk(src):
            for n in names:
                if n == ".DS_Store":
                    continue
                local = os.path.join(root, n)
                files["plugins/shelf.koplugin/" + os.path.relpath(local, src)] = local
    if what in ("patches", "all"):
        # The 2- prefix runs them after KOReader's UI is up; ink-eval is in too, ink needs it.
        for n in sorted(os.listdir(HERE)):
            if n.startswith("patch-") and n.endswith(".lua"):
                files["patches/2-" + n[len("patch-"):]] = os.path.join(HERE, n)
    return files


def cmd_install(dev, args):
    what = args[0] if args else "all"
    if len(args) > 1 or what not in ("shelf", "patches", "all"):
        die("install takes shelf, patches or all")
    files = install_files(what)
    wanted = {}
    for rel, local in files.items():
        with open(local, "rb") as f:
            wanted[rel] = hashlib.md5(f.read()).hexdigest()
    # Stale files in the old plugin folder count as a change, so the folder is listed whole.
    listing = "find plugins/shelf.koplugin -type f 2>/dev/null; " if what != "patches" else ""
    patches = [r for r in wanted if r.startswith("patches/")]
    if patches:
        listing += "ls " + " ".join(shlex.quote(r) for r in patches) + " 2>/dev/null; "
    out = dev.run(f"cd {dev.paths['koreader']} && {{ {listing}}} | "
                  "while read f; do md5sum \"$f\"; done", check=False).stdout
    have = {}
    for line in out.splitlines():
        digest, _, rel = line.partition("  ")
        if rel and not rel.endswith(".DS_Store"):
            have[rel] = digest
    if have == wanted:
        print(f"{what} up to date")
        return
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for rel, local in files.items():
            tar.add(local, arcname=rel)
    clear = "rm -rf plugins/shelf.koplugin && " if what != "patches" else ""
    dev.run(f"cd {dev.paths['koreader']} && {clear}mkdir -p patches plugins && tar xf -",
            stdin=buf.getvalue(), binary=True)
    changed = sorted(r for r in wanted if have.get(r) != wanted[r]) + sorted(r for r in have if r not in wanted)
    print(f"installed {what}: {len(changed)} file(s) changed")
    if not koreader_running(dev):
        print("KOReader is not running; it picks the change up on next start")
        return
    require_launch(dev)
    stop_koreader(dev)
    start_koreader(dev)
    print("ok restart")


def cmd_log(dev, args):
    lines = int(args[0]) if args else 40
    print(dev.run(f"tail -n {lines} {dev.paths['koreader']}/crash.log").stdout, end="")


def koreader_running(dev):
    return dev.run("pgrep -f '[r]eader.lua' >/dev/null && echo up", check=False).stdout.strip() == "up"


def stop_koreader(dev):
    # Kill the launcher loop first so it can't bring the stock UI back up (or reboot, on Kobo),
    # then KOReader itself; dropbear is detached and survives both.
    env = dev.paths.get("env")
    save_env = (f"p=$(pgrep -f '[r]eader.lua' | head -1); [ -n \"$p\" ] && "
                f"tr '\\0' '\\n' </proc/$p/environ | grep -E '^({env})=' >/tmp/ink-koenv.new; "
                # A reader started without Nickel's env (e.g. by KFMon) must not overwrite a good copy.
                f"grep -q KO_DONT_GRAB_INPUT /tmp/ink-koenv.new && mv /tmp/ink-koenv.new /tmp/ink-koenv; ") if env else ""
    dev.run(save_env +
            f"for p in $(pgrep -f '{dev.paths['loop']}'); do kill -KILL $p; done; "
            "for p in $(pgrep -f '[r]eader.lua'); do kill -TERM $p; done; killall -TERM luajit 2>/dev/null; "
            # TERM lets KOReader save settings and book position; it exits in ~0.8 s.
            "i=0; while pgrep -f '[r]eader.lua' >/dev/null && [ $i -lt 100 ]; do usleep 50000; i=$((i+1)); done; "
            "for p in $(pgrep -f '[r]eader.lua'); do kill -KILL $p; done; killall -KILL luajit 2>/dev/null",
            check=False)


def start_koreader(dev):
    # Returns once the first screen is painted (~4 s on the Aura ONE). With patches/2-ink-eval.lua the
    # reader reports it itself: the hook starts armed, so its first idle report means the panel is done.
    # Without it, watch the framebuffer: KOReader clears the panel to white ~0.6 s after launch, then
    # paints in a ~0.4 s burst. Waiting for white first matters because a restart usually repaints the
    # very frame that was there before.
    hook = f"{dev.paths['koreader']}/patches/2-ink-eval.lua"
    r = dev.run(f"{dev.fb_env()}h() {{ {FB_HASH}; }}; rm -f {IDLE_OUT}; "
                f"{dev.paths['launch']} </dev/null >/dev/null 2>&1 & "
                f"if [ -e {hook} ]; then i=0; while [ ! -e {IDLE_OUT} ] && [ $i -lt 3000 ]; do usleep 10000; i=$((i+1)); done; "
                "else white=$(dd if=/dev/zero bs=$lineLength count=$((viewVertOrigin + viewHeight)) 2>/dev/null "
                "| tr '\\000' '\\377' | md5sum); "
                "i=0; while [ \"$(h)\" != \"$white\" ] && [ $i -lt 30 ]; do i=$((i+1)); done; "
                "last=; same=0; i=0; while [ $i -lt 300 ]; do now=$(h); i=$((i+1)); "
                "if [ \"$now\" = \"$white\" ] || [ \"$now\" != \"$last\" ]; then last=$now; same=0; "
                "else same=$((same+1)); [ $same -ge 3 ] && break; fi; done; fi; "
                "pgrep -f '[r]eader.lua' >/dev/null && echo up", check=False)
    if r.stdout.strip() != "up":
        die("KOReader did not come back; check `ink log`")


def require_launch(dev):
    if not dev.paths["launch"]:
        die(f"starting KOReader is not set up for {dev.platform} yet")


def cmd_restart(dev, args):
    require_launch(dev)
    stop_koreader(dev)
    start_koreader(dev)
    print("ok restart")


def cmd_stop(dev, args):
    stop_koreader(dev)
    print("ok stop")


def cmd_start(dev, args):
    require_launch(dev)
    if koreader_running(dev):
        print("already running")
        return
    start_koreader(dev)
    print("ok start")


def run_settings(dev, *lua_args):
    with open(os.path.join(HERE, "settings.lua"), "rb") as f:
        script = f.read()
    quoted = " ".join(shlex.quote(a) for a in (f"{dev.paths['koreader']}/settings.reader.lua",) + lua_args)
    r = dev.run(f"cd {dev.paths['koreader']} && ./luajit - {quoted}", stdin=script, binary=True, check=False)
    if r.returncode != 0:
        die(r.stderr.decode(errors="replace").strip())
    return r.stdout.decode()


def cmd_get(dev, args):
    if len(args) > 1:
        die("get takes one key, or none to list every key")
    print(run_settings(dev, "get", args[0]) if args else run_settings(dev, "keys"), end="")


def cmd_change(dev, op, args):
    needed = 2 if op == "set" else 1
    if len(args) != needed:
        die("set needs KEY VALUE" if op == "set" else "unset needs KEY")
    # KOReader rewrites its settings on exit, so it must be down while we edit.
    was_running = koreader_running(dev)
    if was_running:
        require_launch(dev)
        stop_koreader(dev)
    print(run_settings(dev, op, *args), end="")
    if was_running:
        start_koreader(dev)
        print("ok restart")


def cmd_awake(dev, args):
    if dev.platform != "kindle":
        die(f"awake is not set up for {dev.platform} yet")
    mode = args[0] if args else "status"
    if mode in ("on", "off"):
        dev.run(f"lipc-set-prop com.lab126.powerd preventScreenSaver {1 if mode == 'on' else 0}")
    elif mode != "status":
        die("awake takes on, off or status")
    state = dev.run("lipc-get-prop com.lab126.powerd preventScreenSaver").stdout.strip()
    print("awake on" if state == "1" else "awake off")


def cmd_info(dev, args):
    fb = dev.fbinfo()
    extra = dev.run("cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; "
                    "(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null || "
                    "cat /sys/class/power_supply/*/capacity 2>/dev/null) | head -1; "
                    "free | awk '/buffers\\/cache/{print $4} /^Mem:/{m=$4} END{if(!m)m=0}'; "
                    "pgrep -f '[r]eader.lua' >/dev/null && echo running || echo stopped",
                    check=False).stdout.split()
    governor, battery, free_kb, koreader = (extra + ["?"] * 4)[:4]
    print(f"{dev.name} ({dev.platform}) {fb.get('deviceName')} {fb.get('deviceCodename')} at {dev.ip}")
    print(f"screen {fb['viewWidth']}x{fb['viewHeight']} {fb['BPP']}bpp {fb.get('DPI')}dpi rota {fb.get('currentRota')}")
    print(f"battery {battery}%  free mem {int(free_kb) // 1024 if free_kb.isdigit() else '?'} MB  "
          f"governor {governor}  koreader {koreader}")


def cmd_sh(dev, args):
    if not args:
        die("sh needs a command")
    # Piped stdin is read whole and sent as bytes; inherited stdin truncated large uploads.
    mode = os.fstat(0).st_mode
    stdin = sys.stdin.buffer.read() if stat.S_ISFIFO(mode) or stat.S_ISREG(mode) else b""
    r = dev.run(" ".join(args), stdin=stdin, binary=True, check=False)
    lines = r.stdout.rstrip(b"\n").split(b"\n")
    # An agent reads this output; one stray cat of a source file would flood its context. Pipes
    # (| grep, | tar) and binary output pass whole, and the full text is kept so nothing is lost.
    if (os.environ.get("CLAUDECODE") and not os.environ.get("INK_ALL") and len(lines) > SH_LINES
            and not stat.S_ISFIFO(os.fstat(1).st_mode) and b"\0" not in r.stdout):
        with open(SH_FULL, "wb") as f:
            f.write(r.stdout)
        r.stdout = b"\n".join(lines[:SH_LINES]) + (f"\n[ink: {len(lines) - SH_LINES} more lines in {SH_FULL}; "
                                                   "or narrow the command, or INK_ALL=1]\n").encode()
    sys.stdout.buffer.write(r.stdout)
    sys.stderr.buffer.write(r.stderr)
    sys.exit(r.returncode)


def main():
    argv = sys.argv[1:]
    config = load_config()
    name = config["default"]
    if argv[:1] == ["-d"]:
        if len(argv) < 2:
            die("-d needs a device name")
        name, argv = argv[1], argv[2:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    if name not in config["devices"]:
        die(f"unknown device {name}; add it to {CONFIG}")
    command, args = argv[0], argv[1:]
    dev = Device(name, config["devices"][name]).connect(rescan=command == "find")
    handlers = {
        "shot": cmd_shot, "push": cmd_push, "log": cmd_log, "restart": cmd_restart,
        "stop": cmd_stop, "start": cmd_start, "get": cmd_get,
        "set": lambda d, a: cmd_change(d, "set", a),
        "unset": lambda d, a: cmd_change(d, "unset", a),
        "awake": cmd_awake, "info": cmd_info, "sh": cmd_sh,
        "find": lambda d, a: print(f"{d.name} ({d.platform}) at {d.ip}"),
        "tap": lambda d, a: cmd_gesture(d, "tap", a),
        "hold": lambda d, a: cmd_gesture(d, "hold", a),
        "swipe": lambda d, a: cmd_gesture(d, "swipe", a),
        "time": cmd_time, "eval": cmd_eval, "reload": cmd_reload, "type": cmd_type,
        "install": cmd_install,
    }
    if command not in handlers:
        die(f"unknown command {command}; run `ink help`")
    handlers[command](dev, args)


if __name__ == "__main__":
    main()
