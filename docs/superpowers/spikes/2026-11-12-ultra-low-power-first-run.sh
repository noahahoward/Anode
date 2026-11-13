#!/bin/bash
# THROWAWAY SPIKE: measure what each ultra-low-power lever saves. Restores everything on any exit.
# ULP_FREEZE: egrep pattern of the executable paths to stop.  ULP_KEEP: egrep pattern never to stop (the editor in use).
: "${ULP_FREEZE:?set ULP_FREEZE}"; : "${ULP_KEEP:?set ULP_KEEP}"
D="$(cd "$(dirname "$0")" && pwd)"
ANODE=/Users/noahhoward/Downloads/Programs/Projects/Anode/.build/release/anode
ORIG="$("$D/bright" get)"
PIDS="$D/frozen.pids"; : > "$PIDS"; HZPID=""
mark() { echo "$(date +%s) $1" >> "$D/run1.marks"; }
thaw() { [ -s "$PIDS" ] && xargs kill -CONT < "$PIDS" 2>/dev/null; : > "$PIDS"; }
hz_off() { [ -n "$HZPID" ] && kill -TERM "$HZPID" 2>/dev/null; HZPID=""; sleep 1; }
cleanup() { thaw; hz_off; "$D/bright" set "$ORIG" >/dev/null; mark "end"; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
freeze() {
    ps -axo pid=,uid=,comm= | awk '$2==501' \
      | grep -E "$ULP_FREEZE" \
      | grep -v -E "$ULP_KEEP|\.appex/|FinderSync|FinderHelper|Anode" | awk '{print $1}' > "$PIDS"
    xargs kill -STOP < "$PIDS" 2>/dev/null
    echo "froze $(wc -l < "$PIDS") processes" >> "$D/run1.log"
}
hz_on() { "$D/hz" 600 app >> "$D/run1.log" 2>&1 & HZPID=$!; sleep 1; }
: > "$D/run1.marks"; : > "$D/run1.log"
echo "start $(date +%s) brightness $ORIG" >> "$D/run1.log"
"$ANODE" --raillog 640 1 > "$D/run1.csv" 2>/dev/null &
RAIL=$!
sleep 2
mark "base";            sleep 60
mark "bright100";       "$D/bright" set 1.0 >/dev/null;  sleep 60; "$D/bright" set "$ORIG" >/dev/null
mark "base";            sleep 40
mark "bright25";        "$D/bright" set 0.25 >/dev/null; sleep 60; "$D/bright" set "$ORIG" >/dev/null
mark "base";            sleep 40
mark "hz48";            hz_on;  sleep 75; hz_off
mark "base";            sleep 40
mark "freeze";          freeze; sleep 75; thaw
mark "base";            sleep 40
mark "hz48+freeze";     hz_on; freeze; sleep 75; thaw; hz_off
mark "base";            sleep 40
kill "$RAIL" 2>/dev/null
echo "stopped after: $(ps -axo pid=,stat=,comm= | awk '$2 ~ /T/' | wc -l) processes still stopped" >> "$D/run1.log"
