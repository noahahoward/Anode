#!/bin/bash
# THROWAWAY SPIKE, gate step 2: what Low Power Mode saves, alone and with every other part.
D="$(cd "$(dirname "$0")" && pwd)"
ANODE=/Users/noahhoward/Downloads/Programs/Projects/Anode/.build/release/anode
: "${ULP_FREEZE:?}"; : "${ULP_KEEP:?}"
PIDS="$D/frozen.pids"; : > "$PIDS"; HZPID=""; ORIG="$("$D/bright" get)"
mode() { pmset -g | awk '/powermode/{print $2}'; }
mark() { echo "$(date +%s) $1" >> "$D/gateB.marks"; }
thaw() { [ -s "$PIDS" ] && xargs kill -CONT < "$PIDS" 2>/dev/null; : > "$PIDS"; }
hz_off() { [ -n "$HZPID" ] && kill -TERM "$HZPID" 2>/dev/null; HZPID=""; }
cleanup() { thaw; hz_off; "$D/bright" set "$ORIG" >/dev/null; kill "$RAIL" 2>/dev/null; mark end; echo "mode at end: $(mode); stopped: $(ps -axo stat= | grep -c T)" >> "$D/gateB.log"; }
trap cleanup EXIT; trap 'exit 1' INT TERM HUP
: > "$D/gateB.marks"; echo "start $(date +%s) mode $(mode) brightness $ORIG" > "$D/gateB.log"
"$ANODE" --raillog 520 1 > "$D/gateB.csv" 2>/dev/null & RAIL=$!
sleep 2
mark base; sleep 45
osascript -e 'do shell script "pmset -b powermode 1; (sleep 215; pmset -b powermode 2) >/dev/null 2>&1 &" with prompt "Anode test: Low Power Mode on for under 4 minutes, then back to High Power." with administrator privileges' >> "$D/gateB.log" 2>&1 &
for i in $(seq 1 150); do [ "$(mode)" = "1" ] && break; sleep 1; done
if [ "$(mode)" != "1" ]; then echo "no password: stopping" >> "$D/gateB.log"; exit 2; fi
mark lpm; sleep 90
mark lpm+all
awk -v b="$ORIG" 'BEGIN{exit !(b>0.5)}' && "$D/bright" set 0.5 >/dev/null
"$D/hz" 600 app >> "$D/gateB.log" 2>&1 & HZPID=$!
ps -axo pid=,uid=,comm= | awk '$2==501' | grep -E "$ULP_FREEZE" | grep -v -E "$ULP_KEEP|\.appex/|FinderSync|FinderHelper|Anode" | awk '{print $1}' > "$PIDS"
xargs kill -STOP < "$PIDS"; echo "froze $(wc -l < "$PIDS")" >> "$D/gateB.log"
sleep 115; thaw; hz_off; "$D/bright" set "$ORIG" >/dev/null
mark lpm-after
for i in $(seq 1 60); do [ "$(mode)" != "1" ] && break; sleep 1; done
mark base; sleep 45
