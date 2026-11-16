#!/bin/sh
# NickelMenu entry: flips KOReader autostart; turning it on also clears the failed-start count.
DIR=/mnt/onboard/.adds/koboot
if [ -e "$DIR/SKIP" ]; then
	rm -f "$DIR/SKIP" "$DIR/crashes"
	echo "KOReader autostart: on"
else
	touch "$DIR/SKIP"
	echo "KOReader autostart: off"
fi
sync
