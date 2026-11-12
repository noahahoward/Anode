#!/bin/zsh
# READ-ONLY snapshot for Plan 0. Usage: ./snapshot.sh <label>   (run with sudo for the root SMC view)
set -u
D="$(cd "$(dirname "$0")" && pwd)"; L="${1:?label}"; O="$D/snap-$L"; mkdir -p "$O"
"$D/snapshot/smcdump" > "$O/smc.txt"
grep -vFf <(sed 's/$/ /' "$D/noise-keys.txt") "$O/smc.txt" > "$O/smc-quiet.txt"
pmset -g batt > "$O/pmset-batt.txt"; pmset -g battlimit > "$O/pmset-battlimit.txt"; pmset -g > "$O/pmset.txt"
ioreg -rn AppleSmartBattery | grep -E '"(ExternalConnected|IsCharging|FullyCharged|CurrentCapacity|NotChargingReason|ChargerInhibitReason|ChargingOverride|AdapterDetails)"' > "$O/ioreg.txt"
ioreg -rn AppleSmartBattery | grep -oE '"(NotChargingReason|ChargerInhibitReason)"=[0-9]+' >> "$O/ioreg.txt"
"$D/powerui/read" > "$O/powerui.txt" 2>&1
date > "$O/when.txt"; echo "$O"
