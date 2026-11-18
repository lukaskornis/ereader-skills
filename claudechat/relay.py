#!/usr/bin/env python3
"""Claude chat relay: the e-reader posts a prompt, this runs `claude -p` on the Mac with the
subscription token and returns the reply as an HTML fragment.

  relay.py serve            run the relay (the LaunchAgent does this)
  relay.py login            one-time: `claude setup-token`, token saved to the login keychain
  relay.py install          LaunchAgent (starts at login, restarts on crash) + pair every reader
  relay.py pair [DEVICE]    tell a reader the relay address and key (ink eval)
"""
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
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
INSTALLED = os.path.expanduser("~/.local/bin/claudechat-relay")
LOG = os.path.expanduser("~/Library/Logs/claudechat-relay.log")
MODELS = {"sonnet", "opus", "haiku"}
TIMEOUT_S = 600

SYSTEM_PROMPT = """You are a thoughtful companion whose replies are read on an e-ink reader, like pages of a well-edited book.
Write flowing, warm, precise prose: real paragraphs, a clear line of thought, concrete images and examples.
Output an HTML fragment only, using just these tags: p, em, strong, h3, ul, ol, li, blockquote.
No markdown, no tables, no code blocks unless explicitly asked, no images, no emoji, no preamble like "Great question".
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


def ask_claude(prompt, session_id, model):
    token = read_token()
    if not token:
        return {"error": "No subscription token on the Mac. Run: relay.py login"}
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC"))}
    env.update(CLAUDE_CONFIG_DIR=CLAUDE_HOME, CLAUDE_CODE_OAUTH_TOKEN=token)
    cmd = [claude_bin(), "-p", prompt, "--model", model, "--output-format", "json",
           "--tools", "", "--system-prompt", SYSTEM_PROMPT]
    if session_id:
        cmd += ["--resume", session_id]
    try:
        out = subprocess.run(cmd, cwd=WORK_DIR, env=env, capture_output=True, text=True,
                             timeout=TIMEOUT_S, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return {"error": "Claude took longer than 10 minutes."}
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"error": (out.stderr or out.stdout or "claude failed").strip()[-400:]}
    if data.get("is_error"):
        return {"error": str(data.get("result") or data.get("terminal_reason"))[:400]}
    return {"session_id": data.get("session_id"), "html": FENCE.sub("", data.get("result") or "")}


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
        if self.path != "/chat":
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
        result = ask_claude(prompt, req.get("session_id"), model)
        self.reply(502 if "error" in result else 200, result)

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
    if not match:
        die("No token found in the setup-token output.")
    subprocess.run(["security", "add-generic-password", "-U", "-a", os.environ.get("USER", "me"),
                    "-s", KEYCHAIN_SERVICE, "-w", match.group(0)], check=True)
    print("Token saved to the keychain.")


def pair(device=None):
    host = f"{lan_ip()}:{PORT}"
    lua = ('do local s = G_reader_settings:readSetting("claudechat") or {} '
           f's.host = "{host}" s.key = "{read_key()}" '
           'G_reader_settings:saveSetting("claudechat", s) G_reader_settings:flush() end')
    cmd = ["ink"] + (["-d", device] if device else []) + ["eval", lua]
    ok = subprocess.run(cmd).returncode == 0
    print(f"{device or 'default'}: {'paired with ' + host if ok else 'not reachable, pair later'}")


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
    subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", PLIST], check=True)
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
