#!/bin/sh
# deploy.sh            build for the router, install /usr/bin/claudechat and the service, start it
# deploy.sh pair [DEV] point a reader (or every reader in ink's devices.json) at the router relay
set -eu
ROUTER=root@192.168.50.1
HOST=192.168.50.1:8787
HERE=$(cd "$(dirname "$0")" && pwd)
TARGET=aarch64-unknown-linux-musl

pair_one() {
	key=$(ssh -o BatchMode=yes "$ROUTER" cat /etc/claudechat/key)
	lua="do local s = G_reader_settings:readSetting(\"claudechat\") or {} s.host = \"$HOST\" s.key = \"$key\" G_reader_settings:saveSetting(\"claudechat\", s) G_reader_settings:flush() end"
	if ink ${1:+-d "$1"} eval "$lua"; then echo "${1:-default}: paired with $HOST"; else echo "${1:-default}: not reachable, pair later"; fi
}

if [ "${1:-}" = pair ]; then
	if [ -n "${2:-}" ]; then pair_one "$2"; exit; fi
	for dev in $(python3 -c 'import json,os;print(" ".join(json.load(open(os.path.expanduser("~/.config/ink/devices.json")))["devices"]))'); do
		pair_one "$dev" || true
	done
	exit
fi

cd "$HERE"
cargo zigbuild --release --target "$TARGET"
BIN="target/$TARGET/release/claudechat"
ssh -o BatchMode=yes "$ROUTER" '/etc/init.d/claudechat stop 2>/dev/null; mkdir -p /etc/claudechat && chmod 700 /etc/claudechat'
# OpenWrt's dropbear has no sftp server, so copy with cat.
ssh -o BatchMode=yes "$ROUTER" 'cat > /usr/bin/claudechat && chmod 755 /usr/bin/claudechat' < "$BIN"
ssh -o BatchMode=yes "$ROUTER" 'cat > /etc/init.d/claudechat && chmod 755 /etc/init.d/claudechat' < claudechat.init
ssh -o BatchMode=yes "$ROUTER" 'grep -qx /etc/claudechat/ /etc/sysupgrade.conf || echo /etc/claudechat/ >> /etc/sysupgrade.conf
/etc/init.d/claudechat enable && /etc/init.d/claudechat start'
echo "Deployed: $(wc -c < "$BIN") bytes."
