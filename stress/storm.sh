#!/bin/bash
# storm.sh [seconds] — how hard is WindowServer hammering Anode's main thread?
# Healthy: 0. The Sep 8 frozen process: ~80 datagram / ~70 remote-context samples per 10 s.
S=${1:-3}; P=$(pgrep -x AnodeApp | head -1); f=$(mktemp -t storm)
sample "$P" "$S" 1 -file "$f" >/dev/null 2>&1
c() { n=$(grep -F "$1" "$f" | head -1 | sed -E 's/^[ +!:|]*([0-9]+).*/\1/'); echo "${n:-0}"; }
echo "datagrams=$(c dispatchMainQueueDatagrams) remotectx=$(c remote_context_notify) structural=$(c displayCycleUpdateStructuralRegions) commit=$(c 'CA::Transaction::commit()') cpu=$(ps -o %cpu= -p $P | tr -d ' ')"
rm -f "$f"
