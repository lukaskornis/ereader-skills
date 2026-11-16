#!/bin/sh
# Name: KOReader
# Author: KOReader
# DontUseFBInk
GOV=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
SETTINGS=/mnt/us/koreader/settings.reader.lua
# HarfBuzz light kerning: noticeably cheaper EPUB layout than the default "best".
grep -q copt_font_kerning "$SETTINGS" || sed -i 's/^return {$/return {\n    ["copt_font_kerning"] = 2,/' "$SETTINGS"
cd /mnt/us/koreader
(
    echo performance > "$GOV"
    sh /mnt/us/koreader/koreader.sh --kual --framework_stop
    echo ondemand > "$GOV"
) >/dev/null 2>&1 &
