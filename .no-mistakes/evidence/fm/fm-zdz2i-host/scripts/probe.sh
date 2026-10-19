#!/usr/bin/env bash
# One timestamped readiness probe of a lab home: the change's fm-inbox.sh ready
# and the pre-change one side by side, plus the raw state they read.
# Usage: probe.sh <worktree> <lab> <label>
set -u
WT=$(cd "$1" && pwd -P) LAB=$2 LABEL=$3
now=$(date +%s)
beat_age=never
[ -e "$LAB/state/.last-watcher-beat" ] && beat_age=$((now - $(stat -f %m "$LAB/state/.last-watcher-beat")))s
wpid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)
walive=no
[ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && walive=yes
lpid=$(cat "$LAB/state/.lock" 2>/dev/null | head -1 || true)
lease_lock=$(cat "$LAB/state/.fm-lease-command.lock/pid" 2>/dev/null || echo free)
printf '=== %s  %s\n' "$(date -u +%H:%M:%SZ)" "$LABEL"
printf 'lock pid=%s (%s)  watcher pid=%s alive=%s  beacon age=%s  lease-command lock=%s\n' \
  "$lpid" "$(ps -o comm= -p "${lpid:-0}" 2>/dev/null | xargs basename 2>/dev/null)" "${wpid:-none}" "$walive" "$beat_age" "$lease_lock"
# The pre-change fm-inbox.sh runs from the same bin/ (as bin/fm-inbox.base.sh),
# so its watcher identity check compares the same fm-watch.sh path.
for side in change base; do
  if [ "$side" = change ]; then cli=$WT/bin/fm-inbox.sh; else cli=$WT/bin/fm-inbox.base.sh; fi
  out=$(cd "$WT" && env -u FM_SUPERVISION_MODEL -u CLAUDECODE FM_HOME="$LAB" "$cli" ready 2>&1)
  printf '%-6s ready: %s\n' "$side" "$(printf '%s' "$out" | jq -c '{lock: .lock.state, wake_consumer, can_receive}' 2>/dev/null || printf '%s' "$out")"
done
