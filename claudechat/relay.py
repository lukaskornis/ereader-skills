#!/usr/bin/env python3
"""Claude chat relay: the e-reader posts a prompt, this runs `claude -p` on the Mac with the
subscription token and returns the reply as an HTML fragment, whole (POST /chat) or as it is written
(POST /chat/stream).

  relay.py serve            run the relay (the LaunchAgent does this)
  relay.py login            one-time: `claude setup-token`, token saved to the login keychain
  relay.py install          LaunchAgent (starts at login, restarts on crash) + pair every reader
  relay.py pair [DEVICE]    tell a reader the relay address and key (ink eval)
"""
import base64
import getpass
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8787
HERE = os.path.dirname(os.path.realpath(__file__))
STATE = os.path.expanduser("~/.config/claudechat")
KEY_FILE = os.path.join(STATE, "key")
# Own config dir: no global CLAUDE.md, hooks, plugins or output style leak into the chat.
CLAUDE_HOME = os.path.join(STATE, "claude-home")
WORK_DIR = os.path.join(STATE, "work")
KEYCHAIN_SERVICE = "claudechat-token"
LABEL = "com.lukas.claudechat-relay"
PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
WATCHDOG_LABEL = f"{LABEL}-watchdog"
WATCHDOG_PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{WATCHDOG_LABEL}.plist")
INSTALLED = os.path.expanduser("~/.local/bin/claudechat-relay")
LOG = os.path.expanduser("~/Library/Logs/claudechat-relay.log")
MODELS = {"sonnet", "opus", "haiku"}
TIMEOUT_S = 600

SYSTEM_PROMPT = """You are a thoughtful companion whose replies are read on a black-and-white e-ink reader, like pages of a well-edited book.
Write flowing, warm, precise prose: real paragraphs, a clear line of thought, concrete images and examples.
Output an HTML fragment only, using just these tags: p, em, strong, h3, ul, ol, li, blockquote, table, tr, th, td, img, svg and SVG shapes.
Use a table when comparing several things along the same dimensions. Use an inline svg diagram (a landscape viewBox about 400 units wide, no width or height attributes, black and grey strokes and fills, text font-size at least 14 in viewBox units, no scripts) when a picture explains it better than words: a mechanism, a shape, a timeline, a graph.
Use img only for a real photo or painting at a URL you are certain exists, preferably on upload.wikimedia.org; add alt text. Never invent URLs.
No markdown, no code blocks unless explicitly asked, no emoji, no preamble like "Great question".
Do not end with offers or questions such as "Would you like..."; the reader has buttons for that.
Aim for about 250 to 600 words unless the request calls for less."""


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def claude_bin():
    found = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
    if not os.path.exists(found):
        die("claude CLI not found")
    return found


def read_token():
    out = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                         capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else ""


def read_key():
    if not os.path.exists(KEY_FILE):
        os.makedirs(STATE, exist_ok=True)
        with open(KEY_FILE, "w") as f:
            f.write(secrets.token_urlsafe(24))
        os.chmod(KEY_FILE, 0o600)
    with open(KEY_FILE) as f:
        return f.read().strip()


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.168.0.1", 9))
        return s.getsockname()[0]
    finally:
        s.close()


FENCE = re.compile(r"^\s*```(?:html)?\s*|\s*```\s*$")
NO_TOKEN = "No subscription token on the Mac. Run: relay.py login"
TOO_SLOW = "Claude took longer than 10 minutes."


def claude_cmd(prompt, session_id, model, output_format):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC"))}
    # A separate config dir alone still loads ~/.claude/CLAUDE.md and rules; these switch that off.
    env.update(CLAUDE_CONFIG_DIR=CLAUDE_HOME, CLAUDE_CODE_OAUTH_TOKEN=read_token(),
               CLAUDE_CODE_DISABLE_CLAUDE_MDS="1", CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    cmd = [claude_bin(), "-p", prompt, "--model", model, "--output-format", output_format,
           "--tools", "", "--system-prompt", SYSTEM_PROMPT]
    if output_format == "stream-json":
        cmd += ["--verbose", "--include-partial-messages"]
    if session_id:
        cmd += ["--resume", session_id]
    return cmd, env


IMG = re.compile(r"""<img\b[^>]*?\bsrc=["'](https?://[^"']+)["'][^>]*>""", re.I)
IMG_MAX_BYTES = 8 * 1024 * 1024
IMG_TIMEOUT_S = 8
# Wider than any reader screen; JPEG keeps the chat file small.
IMG_MAX_PX = 1200


# Wikimedia only serves a few thumbnail widths; the original behind a thumb URL always exists.
WIKI_THUMB = re.compile(r"^(https://upload\.wikimedia\.org/wikipedia/[^/]+)/thumb(/[0-9a-f]/[0-9a-f]{2}/[^/]+)/[^/]+$")


def download(url):
    req = urllib.request.Request(url, headers={"User-Agent": "claudechat-relay/1.0 (e-reader chat)"})
    try:
        with urllib.request.urlopen(req, timeout=IMG_TIMEOUT_S) as resp:
            return resp.headers.get_content_type(), resp.read(IMG_MAX_BYTES + 1)
    except (OSError, ValueError):
        return None, b""


def fetch_image(url):
    """The image at url as a data: URI the reader can show offline, or None."""
    mime, body = download(url)
    thumb = WIKI_THUMB.match(url)
    if not mime and thumb:
        mime, body = download(thumb.group(1) + thumb.group(2))
    if not mime:
        return None
    if not mime.startswith("image/") or len(body) > IMG_MAX_BYTES:
        return None
    if mime != "image/svg+xml":
        with tempfile.TemporaryDirectory() as tmp:
            src, out = os.path.join(tmp, "in"), os.path.join(tmp, "out.jpg")
            with open(src, "wb") as f:
                f.write(body)
            done = subprocess.run(["sips", "-Z", str(IMG_MAX_PX), "-s", "format", "jpeg",
                                   "-s", "formatOptions", "70", src, "--out", out], capture_output=True)
            if done.returncode != 0 or not os.path.exists(out):
                return None
            with open(out, "rb") as f:
                body, mime = f.read(), "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(body).decode()}"


def inline_images(html):
    """The reader is offline from the web: images are fetched here and embedded; ones that fail are dropped."""
    urls = list(dict.fromkeys(IMG.findall(html)))
    if not urls:
        return html
    with ThreadPoolExecutor(max_workers=4) as pool:
        found = dict(zip(urls, pool.map(fetch_image, urls)))
    return IMG.sub(lambda m: m.group(0).replace(m.group(1), found[m.group(1)]) if found[m.group(1)] else "", html)


def finish(data):
    if data.get("is_error"):
        return {"error": str(data.get("result") or data.get("terminal_reason"))[:400]}
    return {"session_id": data.get("session_id"), "html": inline_images(FENCE.sub("", data.get("result") or ""))}


def ask_claude(prompt, session_id, model):
    if not read_token():
        return {"error": NO_TOKEN}
    cmd, env = claude_cmd(prompt, session_id, model, "json")
    try:
        out = subprocess.run(cmd, cwd=WORK_DIR, env=env, capture_output=True, text=True,
                             timeout=TIMEOUT_S, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return {"error": TOO_SLOW}
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"error": (out.stderr or out.stdout or "claude failed").strip()[-400:]}
    return finish(data)


def stream_claude(prompt, session_id, model, emit):
    """Calls emit({"delta": text}) as Claude writes, then emit() once more with the reply or an error.
    emit raising (the reader hung up) stops Claude."""
    if not read_token():
        return emit({"error": NO_TOKEN})
    cmd, env = claude_cmd(prompt, session_id, model, "stream-json")
    proc = subprocess.Popen(cmd, cwd=WORK_DIR, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    timer = threading.Timer(TIMEOUT_S, proc.kill)
    timer.start()
    result = None
    text = []
    try:
        for line in proc.stdout:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "result":
                result = result or event
                continue
            if event.get("type") != "stream_event" or result:
                continue
            inner = event.get("event") or {}
            delta = inner.get("delta") or {}
            if delta.get("type") == "text_delta":
                text.append(delta["text"])
                emit({"delta": delta["text"]})
            elif inner.get("type") == "message_stop":
                # The result line comes ~1.5 s later; the reader needn't wait. Claude keeps running
                # until it has saved the session, so the next --resume finds it.
                result = {"session_id": event.get("session_id"), "result": "".join(text)}
                emit(finish(result))
        proc.wait()
        if result and "is_error" not in result:
            return
        if result:
            return emit(finish(result))
        if not timer.is_alive():
            return emit({"error": TOO_SLOW})
        emit({"error": (proc.stderr.read() or "claude failed").strip()[-400:]})
    finally:
        timer.cancel()
        if proc.poll() is None:
            proc.kill()
            proc.wait()


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        return secrets.compare_digest(self.headers.get("X-Key", ""), self.server.key)

    def do_GET(self):
        if self.path != "/ping":
            return self.reply(404, {"error": "not found"})
        if not self.authorized():
            return self.reply(403, {"error": "Wrong relay key. Run: relay.py pair"})
        self.reply(200, {"ok": True, "token": bool(read_token())})

    def do_POST(self):
        if self.path not in ("/chat", "/chat/stream"):
            return self.reply(404, {"error": "not found"})
        if not self.authorized():
            return self.reply(403, {"error": "Wrong relay key. Run: relay.py pair"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (ValueError, json.JSONDecodeError):
            return self.reply(400, {"error": "bad request"})
        prompt = (req.get("prompt") or "").strip()
        model = req.get("model") if req.get("model") in MODELS else "sonnet"
        if not prompt:
            return self.reply(400, {"error": "empty prompt"})
        if self.path == "/chat":
            result = ask_claude(prompt, req.get("session_id"), model)
            return self.reply(502 if "error" in result else 200, result)
        # One JSON object per line, flushed as Claude writes; the connection closes after the last one.
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(obj):
            self.wfile.write(json.dumps(obj).encode() + b"\n")
            self.wfile.flush()
        try:
            stream_claude(prompt, req.get("session_id"), model, emit)
        except (BrokenPipeError, ConnectionResetError):
            self.log_message("reader hung up, Claude stopped")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def serve():
    os.makedirs(CLAUDE_HOME, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.key = read_key()
    print(f"claudechat relay on {lan_ip()}:{PORT}", file=sys.stderr, flush=True)
    server.serve_forever()


def login():
    # setup-token is interactive (browser); `script` keeps its tty while we capture the output.
    with tempfile.NamedTemporaryFile(suffix=".log", delete=False) as f:
        capture = f.name
    subprocess.run(["script", "-q", capture, claude_bin(), "setup-token"])
    with open(capture, errors="ignore") as f:
        text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\r|\n", "", f.read())
    os.unlink(capture)
    match = re.search(r"sk-ant-oat[A-Za-z0-9_\-]+", text)
    # The token wraps across lines, so newlines are dropped; that glues the next sentence onto it.
    token = match.group(0).split("Store")[0] if match else getpass.getpass("Paste the token it printed: ").strip()
    if not token:
        die("No token.")
    subprocess.run(["security", "add-generic-password", "-U", "-a", os.environ.get("USER", "me"),
                    "-s", KEYCHAIN_SERVICE, "-w", token], check=True)
    print("Token saved to the keychain.")


def pair(device=None):
    host = f"{lan_ip()}:{PORT}"
    lua = ('do local s = G_reader_settings:readSetting("claudechat") or {} '
           f's.host = "{host}" s.key = "{read_key()}" '
           'G_reader_settings:saveSetting("claudechat", s) G_reader_settings:flush() end')
    cmd = ["ink"] + (["-d", device] if device else []) + ["eval", lua]
    ok = subprocess.run(cmd).returncode == 0
    print(f"{device or 'default'}: {'paired with ' + host if ok else 'not reachable, pair later'}")


def install_watchdog(uid):
    # KeepAlive only covers crashes; this reloads the relay if it ever gets unloaded.
    check = (f"/bin/launchctl print gui/{uid}/{LABEL} >/dev/null 2>&1 || "
             f"/bin/launchctl bootstrap gui/{uid} {PLIST}")
    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{WATCHDOG_LABEL}</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>{check}</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
"""
    with open(WATCHDOG_PLIST, "w") as f:
        f.write(plist)
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{WATCHDOG_LABEL}"], capture_output=True)
    for _ in range(20):
        if subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", WATCHDOG_PLIST],
                          capture_output=True).returncode == 0:
            return
        time.sleep(0.5)
    die("Watchdog failed to load.")


def install():
    read_key()
    # launchd may not read ~/Documents (privacy rules), so the agent runs an installed copy.
    shutil.copy2(os.path.realpath(__file__), INSTALLED)
    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>{INSTALLED}</string><string>serve</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>{os.path.expanduser('~/.local/bin')}:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>{LOG}</string>
  <key>StandardOutPath</key><string>{LOG}</string>
</dict></plist>
"""
    with open(PLIST, "w") as f:
        f.write(plist)
    uid = str(os.getuid())
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], capture_output=True)
    # Bootstrap right after bootout races launchd teardown and fails, leaving the relay unloaded.
    for _ in range(20):
        if subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", PLIST], capture_output=True).returncode == 0:
            break
        time.sleep(0.5)
    else:
        die("launchctl bootstrap kept failing; the relay is not running.")
    install_watchdog(uid)
    print(f"Relay running on {lan_ip()}:{PORT}, starts at login.")
    with open(os.path.expanduser("~/.config/ink/devices.json")) as f:
        for name in json.load(f)["devices"]:
            pair(name)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    actions = {"serve": serve, "login": login, "install": install,
               "pair": lambda: pair(sys.argv[2] if len(sys.argv) > 2 else None)}
    if cmd not in actions:
        die(__doc__)
    actions[cmd]()
