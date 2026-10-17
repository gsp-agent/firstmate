#!/usr/bin/env bash
# Run inside the lab primary pane: one real bin/fm-spawn.sh ship spawn of
# <id> on the lab project, its worker launched as the raw command `sleep 900`.
# Writes the transcript to <evidence>/spawn-<step>.log and touches
# <evidence>/.done-<step> when the spawn has returned.
# Usage: lab-spawn.sh <step> <id> [project-name]
set -u
STEP=$1
ID=$2
PROJ=${3:-project}
EV=$(cd "$(dirname "$0")" && pwd)
LOG="$EV/spawn-$STEP.log"
start=$(date +%s)
{
  printf '$ FM_HOME=%s bin/fm-spawn.sh %s %s --mode local-only --yolo off --harness '"'"'sleep 900'"'"'\n' "$FM_HOME" "$ID" "$FM_HOME/projects/$PROJ"
  bin/fm-spawn.sh "$ID" "$FM_HOME/projects/$PROJ" --mode local-only --yolo off --harness 'sleep 900' 2>&1
  rc=$?
  printf '[exit %s after %ss]\n' "$rc" "$(( $(date +%s) - start ))"
} > "$LOG" 2>&1
: > "$EV/.done-$STEP"
