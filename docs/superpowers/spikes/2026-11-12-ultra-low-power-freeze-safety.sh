#!/bin/bash
# THROWAWAY SPIKE, gate step 1: is freezing safe on a quiet Mac? base 120 s | frozen 300 s | base 120 s.
D="$(cd "$(dirname "$0")" && pwd)"
ANODE=/Users/noahhoward/Downloads/Programs/Projects/Anode/.build/release/anode
: "${ULP_FREEZE:?}"; : "${ULP_KEEP:?}"
PIDS="$D/frozen.pids"; : > "$PIDS"
mark() { echo "$(date +%s) $1" >> "$D/gateA.marks"; }
thaw() { [ -s "$PIDS" ] && xargs kill -CONT < "$PIDS" 2>/dev/null; : > "$PIDS"; }
cleanup() { thaw; kill "$RAIL" "$TOP" 2>/dev/null; mark end; }
trap cleanup EXIT; trap 'exit 1' INT TERM HUP
: > "$D/gateA.marks"; echo "start $(date +%s)" > "$D/gateA.log"
"$ANODE" --raillog 560 1 > "$D/gateA.csv" 2>/dev/null & RAIL=$!
top -l 56 -s 10 -o cpu -n 10 -stats pid,command,cpu > "$D/gateA.top" 2>/dev/null & TOP=$!
sleep 2
mark base;   sleep 120
ps -axo pid=,uid=,comm= | awk '$2==501' | grep -E "$ULP_FREEZE" | grep -v -E "$ULP_KEEP|\.appex/|FinderSync|FinderHelper|Anode" | awk '{print $1}' > "$PIDS"
ps -o pid=,comm= -p $(tr '\n' ',' < "$PIDS" | sed 's/,$//') | awk '{n=split($0,a,"/"); print a[n]}' | sort | uniq -c >> "$D/gateA.log"
mark freeze; xargs kill -STOP < "$PIDS"; sleep 300; thaw
mark base;   sleep 120
echo "still stopped: $(ps -axo stat= | grep -c T)" >> "$D/gateA.log"
