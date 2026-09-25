#!/bin/bash
# Stress Anode through the paths the field reports implicate, and check after
# every step that what the app BELIEVES reached the screen.
#
#   ./run.sh <scenario> [iterations]      scenarios: see the case at the bottom
#
# Two failure detectors, one per reported symptom:
#   window  — after an open, the main window must be on screen in WindowServer
#             AND its pixels must be non-blank. "Anode in the menu bar, in Cmd-Tab,
#             transparent in Mission Control" fails the second test, not the first.
#   widgets — each widget's tooltip (AX help) is what the app last rendered. If it
#             changes and the widget's pixels do not, the widget is frozen.
#
# Needs: the installed app running, Accessibility + Screen Recording for the host.
set -u
cd "$(dirname "$0")"
HERE="$PWD"
RUN="$HERE/runs/$(date +%Y%m%d-%H%M%S)-${1:-x}"
mkdir -p "$RUN"
LOG="$RUN/log.tsv"
FAILS=0

pid() { pgrep -x AnodeApp | head -1; }
log() { printf '%s\t%s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }
osa() { osascript -e "$1" 2>&1; }
front() { osa 'tell application "System Events" to get name of first process whose frontmost is true'; }

fail() {
  FAILS=$((FAILS + 1))
  log "FAIL $*"
  screencapture -x "$RUN/fail-$FAILS.png"
  { ./probe items "$(pid)"; echo; ./probe windows "$(pid)"; echo; front; } > "$RUN/fail-$FAILS.txt" 2>&1
  sample "$(pid)" 3 -f "$RUN/fail-$FAILS-sample.txt" >/dev/null 2>&1
}

main_win() { ./probe windows "$(pid)" | awk -F'\t' '$9=="Anode"{print; exit}'; }

# Item whose tooltip starts with $1 -> "x y w h"
item_rect() { ./probe items "$(pid)" | awk -F'\t' -v k="$1" 'index($5,k)==1{print $1,$2,$3,$4; exit}'; }

click_item() {  # $1 tooltip prefix, $2 left|right
  read -r x y w h <<<"$(item_rect "$1")"
  [ -z "${x:-}" ] && { fail "no menu bar item '$1'"; return 1; }
  echo "click $1 at $((x + w / 2)),$((y + h / 2))" >> "$RUN/clicks.log"
  ./click $((x + w / 2)) $((y + h / 2)) "${2:-left}"
}

check_window_shown() {  # $1 label
  local row id on
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    row=$(main_win); on=$(cut -f2 <<<"$row")
    [ "$on" = 1 ] && break
    sleep 0.3
  done
  id=$(cut -f1 <<<"$row")
  [ "$on" = 1 ] || { fail "$1: main window not on screen ($row) front=$(front)"; return 1; }
  sleep 0.6   # let the first frame land
  screencapture -x -o -l "$id" "$RUN/w.png" 2>/dev/null
  local st sd
  st=$(./probe stat "$RUN/w.png"); sd=$(sed -E 's/.*sd=([0-9.]+).*/\1/' <<<"$st")
  if awk -v s="$sd" 'BEGIN{exit !(s < 4)}'; then
    fail "$1: window on screen but BLANK ($st) front=$(front)"; return 1
  fi
  [ "$(front)" = AnodeApp ] || log "note $1: window shown but front=$(front)"
  return 0
}

check_window_hidden() {
  local on; on=$(main_win | cut -f2)
  [ "$on" = 1 ] && { fail "$1: window still on screen after close"; return 1; }
  return 0
}

# ── widget freshness ─────────────────────────────────────────────────────────
# bash 3.2 (the one macOS ships) has no associative arrays, so state is files.
ST="$RUN/state"; mkdir -p "$ST"
get() { cat "$ST/$1" 2>/dev/null; }
put() { printf '%s' "$2" > "$ST/$1"; }
check_widgets() {  # $1 label
  local p; p=$(pid)
  local items; items=$(./probe items "$p")
  [ -z "$items" ] || [ "$items" = NO_EXTRAS_BAR ] && { fail "$1: no widgets in AX"; return 1; }
  local n=0
  while IFS=$'\t' read -r x y w h help; do
    n=$((n + 1))
    [ "$w" -le 0 ] && { fail "$1: widget $n zero width ($help)"; continue; }
    screencapture -x -R "$x,$y,$w,$h" "$RUN/i$n.png" 2>/dev/null
    local hs; hs=$(./probe stat "$RUN/i$n.png" | sed -E 's/.*hash=//')
    local key; key=$(printf '%s' "${help%%:*}" | tr -c 'A-Za-z0-9' '_')
    local lh lx stuck
    lh=$(get "$key.help"); lx=$(get "$key.hash"); stuck=$(get "$key.stuck"); stuck=${stuck:-0}
    if [ -n "$lh" ] && [ "$lh" != "$help" ] && [ "$lx" = "$hs" ]; then
      stuck=$((stuck + 1))
      log "warn $1: '$key' value moved ($lh -> $help) but pixels did not (#$stuck)"
      [ "$stuck" -ge 3 ] && fail "$1: widget '$key' FROZEN on screen"
    elif [ "$lx" != "$hs" ]; then
      stuck=0
    fi
    put "$key.help" "$help"; put "$key.hash" "$hs"; put "$key.stuck" "$stuck"
  done <<<"$items"
}

close_window() {
  osa 'tell application "System Events" to tell process "AnodeApp" to set frontmost to true' >/dev/null
  sleep 0.2
  osa 'tell application "System Events" to keystroke "w" using command down' >/dev/null
  sleep 0.8
}

# ── scenarios ────────────────────────────────────────────────────────────────
N=${2:-50}
[ -z "$(pid)" ] && { echo "Anode not running"; exit 1; }
log "start scenario=$1 n=$N pid=$(pid) $(sw_vers -productVersion)"

case "$1" in
  clickcycle)   # widget click -> window -> Cmd-W -> accessory, the reported path
    for i in $(seq "$N"); do
      sleep "${GAP:-0}"
      click_item "Battery rate"
      if ! check_window_shown "click#$i"; then
        sleep 2; click_item "Battery rate"
        if check_window_shown "retry#$i"; then log "RECOVERED click#$i on retry"; else log "PERSISTENT click#$i"; fi
      fi
      close_window; check_window_hidden "close#$i"
      check_widgets "cycle#$i"
    done ;;
  reopen)       # app already running, launched again (Dock / Finder / Spotlight)
    for i in $(seq "$N"); do
      close_window
      open "$HOME/Applications/Anode.app"; check_window_shown "reopen#$i"
      check_widgets "reopen#$i"
    done ;;
  minimize)     # Cmd-M then widget click must deminiaturize
    for i in $(seq "$N"); do
      click_item "Battery rate"; check_window_shown "open#$i"
      osa 'tell application "System Events" to keystroke "m" using command down' >/dev/null; sleep 1.2
      click_item "Battery rate"; check_window_shown "unminimize#$i"
      close_window
    done ;;
  menus)        # group menu and right-click menu open/close
    for i in $(seq "$N"); do
      click_item "Unknown metric" && sleep 0.8; osa 'tell application "System Events" to key code 53' >/dev/null; sleep 0.4
      click_item "Swap" right && sleep 0.8; osa 'tell application "System Events" to key code 53' >/dev/null; sleep 0.4
      check_widgets "menus#$i"
    done ;;
  appearance)   # dark/light flip re-creates every status item scene on macOS 26+
    orig=$(osa 'tell application "System Events" to tell appearance preferences to get dark mode')
    for i in $(seq "$N"); do
      osa 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode' >/dev/null
      sleep 3; check_widgets "appearance#$i"
      if [ $((i % 5)) = 0 ]; then click_item "Battery rate"; check_window_shown "appearance-open#$i"; close_window; fi
    done
    osa "tell application \"System Events\" to tell appearance preferences to set dark mode to $orig" >/dev/null ;;
  displaymode)  # display reconfigure, as every display wake does: flip resolution and back
    home=${HOME_MODE:-66}; alt=${ALT_MODE:-54}
    for i in $(seq "$N"); do
      if [ $((i % 2)) = 0 ]; then click_item "Battery rate"; check_window_shown "pre-open#$i"; fi  # half with window up
      ./dmode set "$alt" >/dev/null; sleep 3; ./dmode set "$home" >/dev/null; sleep 4
      [ "$(main_win | cut -f2)" = 1 ] && close_window
      check_widgets "after-reconfig#$i"
      click_item "Battery rate"; check_window_shown "open-after-reconfig#$i"
      close_window; check_window_hidden "close#$i"
    done
    ./dmode set "$home" >/dev/null ;;
  soak)         # just watch, every 10 s, for N minutes
    end=$(( $(date +%s) + N * 60 ))
    while [ "$(date +%s)" -lt "$end" ]; do check_widgets soak; sleep 10; done ;;
  *) echo "unknown scenario"; exit 2 ;;
esac
log "done scenario=$1 fails=$FAILS"
exit $FAILS
