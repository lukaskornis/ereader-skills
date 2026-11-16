#!/bin/sh
# Run by udev. Detaches at once so udev never waits, starts koboot once per boot (/tmp is a fresh tmpfs each boot),
# and does nothing when the onboard script is gone: deleting .adds/koboot over USB uninstalls it.
if [ "$1" != "detached" ]; then
	mkdir /tmp/koboot.once 2>/dev/null || exit 0
	setsid /bin/sh "$0" detached </dev/null >/dev/null 2>&1 &
	exit 0
fi
i=0
while ! mountpoint -q /mnt/onboard; do
	i=$((i + 1))
	[ $i -gt 240 ] && exit 0
	usleep 500000
done
[ -f /mnt/onboard/.adds/koboot/koboot.sh ] && exec /bin/sh /mnt/onboard/.adds/koboot/koboot.sh
