#!/bin/sh
# deploy.sh [DEV]  build the relay for the Kobo (armv7), install it on the reader with the subscription token,
#                  and point the plugin at 127.0.0.1:8787. Needs the reader awake with KOReader open.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=${1:-kobo}
TARGET=armv7-unknown-linux-musleabihf
D=/mnt/onboard/.adds/claudechat
(cd "$HERE/../router" && cargo zigbuild --release --target "$TARGET")
BIN="$HERE/../router/target/$TARGET/release/claudechat"
ink -d "$DEV" sh "mkdir -p $D/data; [ -f $D/claudechat ] && kill \$(cat /tmp/claudechat.pid 2>/dev/null) 2>/dev/null; sleep 1; cat > $D/claudechat; chmod 755 $D/claudechat" < "$BIN"
ink -d "$DEV" sh "cat > $D/start.sh" < "$HERE/start.sh"
ink -d "$DEV" sh "cat > /mnt/onboard/.adds/koreader/plugins/claudechat.koplugin/main.lua" < "$HERE/../claudechat.koplugin/main.lua"
KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
printf %s "$KEY" | ink -d "$DEV" sh "umask 077; cat > $D/data/key"
security find-generic-password -s claudechat-token -w | tr -d '\n' | ink -d "$DEV" sh "umask 077; cat > $D/data/oauth_token"
ink -d "$DEV" eval "do local s = G_reader_settings:readSetting(\"claudechat\") or {} s.host = \"127.0.0.1:8787\" s.key = \"$KEY\" G_reader_settings:saveSetting(\"claudechat\", s) G_reader_settings:flush() end"
echo "$DEV: local relay installed ($(wc -c < "$BIN") bytes)"
