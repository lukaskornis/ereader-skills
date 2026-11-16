#!/bin/sh
# Boot into KOReader through KFMon, so it starts exactly as a tap on koreader.png would (Nickel env, Nickel back on exit).
DIR=/mnt/onboard/.adds/koboot
KO=/mnt/onboard/.adds/koreader
KFMON_IPC=/usr/local/kfmon/bin/kfmon-ipc
LOG="$DIR/koboot.log"
CRASHES="$DIR/crashes"
CANCEL_MS=3000
SETTLE_S=4

log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >> "$LOG"; }
# A white band across the middle of Nickel's screen: bold title, smaller line under it.
banner() {
	band="top=786,left=0,width=1404,height=300"
	"$KO/fbink" -q -b -k "$band"
	"$KO/fbink" -q -b -m -t "regular=$KO/fonts/noto/NotoSerif-Bold.ttf,size=16,top=850" "$1"
	[ -n "$2" ] && "$KO/fbink" -q -b -m -t "regular=$KO/fonts/noto/NotoSerif-Regular.ttf,size=11,top=970" "$2"
	"$KO/fbink" -q -s "$band"
} >/dev/null 2>&1

[ -f "$LOG" ] && tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
log "boot"

if [ -e "$DIR/SKIP" ]; then
	log "skip flag set"
	exit 0
fi

failed=$(cat "$CRASHES" 2>/dev/null)
failed=${failed:-0}
if [ "$failed" -ge 2 ]; then
	log "skipped: $failed starts never reached a clean run"
	banner "KOReader autostart paused" "Two starts failed. Turn it back on in the menu."
	exit 0
fi

i=0
until pidof nickel >/dev/null; do
	i=$((i + 1))
	[ $i -gt 240 ] && { log "no nickel, giving up"; exit 0; }
	usleep 500000
done
log "nickel up"

# Nickel opening its library DB is the last step before its home screen; killing it earlier risks the DB.
i=0
until ls -l "/proc/$(pidof -s nickel)/fd" 2>/dev/null | grep -q KoboReader.sqlite; do
	i=$((i + 1))
	[ $i -gt 240 ] && { log "nickel never opened its DB, giving up"; exit 0; }
	usleep 500000
done
log "nickel db open"
sleep $SETTLE_S

if pgrep -f reader.lua >/dev/null; then
	log "KOReader already running"
	exit 0
fi

banner "Starting KOReader" "Tap to stay in Nickel"
cd "$KO" || exit 0
if ./luajit "$DIR/tap-wait.lua" $CANCEL_MS; then
	log "tap: staying in Nickel"
	banner "Staying in Nickel"
	exit 0
fi

watch=$(printf 'list\n' | "$KFMON_IPC" 2>/dev/null | grep ':koreader.png:' | cut -d: -f1)
if [ -z "$watch" ]; then
	log "no KFMon watch for koreader.png"
	banner "KOReader autostart failed" "KFMon has no KOReader entry"
	exit 0
fi

echo $((failed + 1)) > "$CRASHES"
sync
log "start watch $watch (attempt $((failed + 1)))"
printf 'start:%s\n' "$watch" | "$KFMON_IPC" >/dev/null 2>&1

# A start counts as clean once KOReader has stayed up for 30 s.
up=0
i=0
while [ $i -lt 90 ]; do
	i=$((i + 1))
	sleep 1
	if pgrep -f reader.lua >/dev/null; then
		up=$((up + 1))
	else
		up=0
	fi
	if [ $up -ge 30 ]; then
		rm -f "$CRASHES"
		sync
		log "clean run"
		exit 0
	fi
done
log "KOReader not up for 30 s; failure count kept"
