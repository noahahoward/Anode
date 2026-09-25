#!/bin/bash
# monitor.sh — runs until killed. Every 30 s, one line of Anode's state, so a
# freeze that develops across sleep/wake is timestamped from the inside:
#   storm (WindowServer datagram flood on the main thread — the frozen signature),
#   what each widget claims (AX help) and a hash of its pixels, the main window,
#   and the last pmset event so each line can be placed relative to a wake.
cd "$(dirname "$0")"
OUT="runs/monitor-$(date +%Y%m%d-%H%M%S).log"; mkdir -p runs
echo "writing $OUT"
while true; do
  P=$(pgrep -x AnodeApp | head -1)
  if [ -z "$P" ]; then echo "$(date +%T) NOT RUNNING" >> "$OUT"; sleep 30; continue; fi
  st=$(./storm.sh 2)
  wid=""
  while IFS=$'\t' read -r x y w h help; do
    [ -z "$x" ] && continue
    screencapture -x -R "$x,$y,$w,$h" /tmp/anode-mon.png 2>/dev/null
    hs=$(./probe stat /tmp/anode-mon.png | sed -E 's/.*hash=(.{6}).*/\1/')
    wid="$wid | ${help:0:28}@$x:$hs"
  done <<<"$(./probe items "$P")"
  win=$(./probe windows "$P" | awk -F'\t' '$9=="Anode"{print "win_on="$2" x="$5" y="$6}')
  locked=$(ioreg -n Root -d1 -a 2>/dev/null | grep -c CGSSessionScreenIsLocked)
  lastpm=$(pmset -g log | grep -E " (Sleep|Wake|DarkWake) " | tail -1 | cut -c12-19,27-40)
  echo "$(date +%T) $st $win lockkey=$locked last=[$lastpm]$wid" >> "$OUT"
  # The frozen signature (Sep 8: ~80 datagram samples / 10 s; healthy: 0). On the
  # first sighting per process, capture everything while it is still happening.
  dg=$(sed -E 's/.*datagrams=([0-9]+).*/\1/' <<<"$st")
  if [ "${dg:-0}" -ge 10 ] && [ "$(cat runs/.captured 2>/dev/null)" != "$P" ]; then
    echo "$P" > runs/.captured
    echo "$(date +%T) STORM DETECTED - capturing" >> "$OUT"
    ~/Library/Logs/AnodeWatchdog/capture-now.sh >> "$OUT" 2>&1
    osascript -e 'display notification "Anode storm detected and captured. Tell Claude." with title "Anode monitor"' 2>/dev/null
  fi
  sleep 30
done
