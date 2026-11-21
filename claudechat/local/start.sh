#!/bin/sh
# Starts the relay on the reader itself unless it already runs. Called by the plugin at KOReader start and before each question.
DIR=/mnt/onboard/.adds/claudechat
PID=/tmp/claudechat.pid
if [ -f "$PID" ] && kill -0 "$(cat $PID)" 2>/dev/null; then exit 0; fi
# Kobo boots with loopback down and no address.
ifconfig lo 127.0.0.1 up
export CLAUDECHAT_DIR="$DIR/data" CLAUDECHAT_BIND=127.0.0.1 CLAUDECHAT_PORT=8787
setsid "$DIR/claudechat" >> /tmp/claudechat.log 2>&1 < /dev/null &
echo $! > "$PID"
