#!/usr/bin/env bash
# fm-cursor-cap.sh - the daily cap on Cursor code beads.
#   fm-cursor-cap.sh take <bead-id>   before a cursor spawn; exit 1 + one stderr line to refuse
#   fm-cursor-cap.sh give <bead-id>   give the slot back when that spawn failed
#
# state/cursor-dispatch.json = {"day": "<America/Chicago YYYY-MM-DD>", "beads": {"<id>": launches}}.
# A NEW bead is refused once distinct beads today >= cursor_daily_cap (crew-dispatch.json;
# absent = no cap). A relaunch of a bead already counted today is allowed, but its 3rd launch
# in one day is refused. Overrides for tests: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_CURSOR_DAY.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
op=${1:-}; id=${2:-}
[ -n "$id" ] && { [ "$op" = take ] || [ "$op" = give ]; } || { echo "usage: fm-cursor-cap.sh take|give <bead-id>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cursor cap: jq required" >&2; exit 1; }
F="$STATE/cursor-dispatch.json"; LOCK="$STATE/cursor-dispatch.lock"
DAY=${FM_CURSOR_DAY:-$(TZ=America/Chicago date +%F)}
mkdir -p "$STATE"
tries=0
until mkdir "$LOCK" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -le 100 ] || { echo "cursor cap: refused $id, could not take $LOCK" >&2; exit 1; }
  sleep 0.1
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
cur='{}'
[ ! -s "$F" ] || cur=$(cat "$F")
cur=$(jq -c --arg d "$DAY" 'if (.day? == $d) and ((.beads? | type) == "object") then . else {day: $d, beads: {}} end' <<<"$cur" 2>/dev/null) \
  || { echo "cursor cap: refused $id, $F is not valid JSON" >&2; exit 1; }
if [ "$op" = give ]; then
  new=$(jq -c --arg id "$id" 'if (.beads[$id] // 0) > 1 then .beads[$id] -= 1 else del(.beads[$id]) end' <<<"$cur")
else
  cap=
  [ ! -r "$CONFIG/crew-dispatch.json" ] || cap=$(jq -r '.cursor_daily_cap // empty' "$CONFIG/crew-dispatch.json" 2>/dev/null)
  n=$(jq -r --arg id "$id" '.beads[$id] // 0' <<<"$cur")
  distinct=$(jq -r '.beads | length' <<<"$cur")
  if [ "$n" -ge 2 ]; then
    echo "cursor cap: refused $id, already launched $n times today ($DAY); a 3rd launch needs a blocked: note, not another run" >&2; exit 1
  fi
  if [ "$n" -eq 0 ] && [ -n "$cap" ] && [ "$distinct" -ge "$cap" ]; then
    echo "cursor cap: refused $id, $distinct of $cap Cursor beads already today ($DAY)" >&2; exit 1
  fi
  new=$(jq -c --arg id "$id" '.beads[$id] = ((.beads[$id] // 0) + 1)' <<<"$cur")
fi
printf '%s\n' "$new" > "$F.tmp.$$" && mv "$F.tmp.$$" "$F"
