#!/usr/bin/env bash
# Run one live scenario step and print a reviewer transcript: the title, the
# headroom config line in force, the real spawn transcript from the lab
# primary pane, the reading runs it caused, and the lab snapshot after it.
# Usage: [LAB_PANE=firstmate:N] lab-scenario.sh "<title>" <step> <id> <project> <headroom-line|-absent|-blank>
set -u
TITLE=$1
STEP=$2
ID=$3
PROJ=$4
HEAD=$5
EV=$(cd "$(dirname "$0")" && pwd)
LAB=$(cat "$EV/.lab-path")
F="$LAB/config/project-capacity-headroom"
case "$HEAD" in
  -absent) rm -f -- "$F" ;;
  -blank) printf '   \n\n' > "$F" ;;
  *) printf '%s\n' "$HEAD" > "$F" ;;
esac
echo "### $TITLE"
if [ -e "$F" ]; then
  echo "config/project-capacity-headroom: [$(tr '\n' '|' < "$F")]"
else
  echo "config/project-capacity-headroom: (absent)"
fi
before=$(wc -l < "$LAB/readings/runs.log")
"$EV/lab-step.sh" "$STEP" "$ID" "$PROJ"
echo "-- reading runs caused by this spawn:"
tail -n +"$((before + 1))" "$LAB/readings/runs.log" | sed 's/^/  /'
[ "$(wc -l < "$LAB/readings/runs.log")" -gt "$before" ] || echo "  (none: the reading did not run)"
"$EV/lab-snap.sh" "$LAB" "after $STEP"
echo
