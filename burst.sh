# usage: burst.sh N GAP_MS ; runs in koreader dir with fb env. Ends on the idle report of patches/2-ink-eval.lua,
# armed after the last swipe, because the UI goes idle between swipes too.
N=$1; GAP=$2
up() { cut -d' ' -f1 /proc/uptime; }
t0=$(up)
i=0; while [ $i -lt $N ]; do ./luajit /tmp/inject.lua ${touchSwapAxes:-0} ${touchMirrorX:-0} ${touchMirrorY:-0} $viewWidth $viewHeight swipe 1100 900 300 900 80 >/dev/null; [ $i -lt $((N-1)) ] && usleep $((GAP*1000)); i=$((i+1)); done
t1=$(up)
rm -f /tmp/ink-idle /tmp/ink-idle.armed /tmp/ink-idle.painted
printf '\0\0\0\0\0\0\0\0\4\0\3\0INI\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' > /dev/input/event0
i=0; while [ ! -e /tmp/ink-idle ] && [ $i -lt 3000 ]; do usleep 10000; i=$((i+1)); [ $i -ge 60 ] && [ ! -e /tmp/ink-idle.painted ] && break; done
if [ -e /tmp/ink-idle ]; then read p d < /tmp/ink-idle
  awk "BEGIN{printf \"swipes sent %.2f s, last page painted %.2f s after the last swipe, panel done %.2f s\n\", $t1-$t0, $p-$t1, $d-$t1}"
else echo "swipes sent $(awk "BEGIN{print $t1-$t0}") s; last page was painted before the last swipe returned"; fi
