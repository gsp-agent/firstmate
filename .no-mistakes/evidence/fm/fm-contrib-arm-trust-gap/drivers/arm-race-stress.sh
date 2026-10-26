#!/usr/bin/env bash
# Live A/B stress: real fm-contributions.sh arm, re-armed in a loop with a shim
# that changes on every arm, while the real watcher (fm-watch-checkpoint.sh)
# sweeps continuously. No fake mv/cp/sleep: only the forge (gh) is a fixture.
# Counts the rejection wakes the watcher queues for the contributions check.
# usage: arm-race-stress.sh <bin-root> <fixture-root> <seconds> <label>
set -u
ROOT=$1 FIX_ROOT=$2 SECS=$3 LABEL=$4
# shellcheck source=/dev/null
. "$(dirname "$0")/fixture.sh"
home=$(new_home "$LABEL")
forge_home "$home"
mv "$home/fakebin/gh" "$home/fakebin/gh.real"
cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in 'api repos/o/r/pulls/8') printf 'x' >> "$FORGE/polls" ;; esac
exec "$(dirname "$0")/gh.real" "$@"
SH
chmod +x "$home/fakebin/gh"
with_home "$home" "$ROOT/bin/fm-contributions.sh" arm >/dev/null || { echo "fixture: first arm failed"; exit 1; }
with_home "$home" bash "$home/state/contributions.check.sh" >/dev/null 2>&1 || true
: > "$home/forge/polls"

(
  n=0
  while [ ! -e "$home/stop" ]; do
    if with_home "$home" env FM_CONTRIBUTIONS_BUDGET=$((20 + n % 2)) \
      "$ROOT/bin/fm-contributions.sh" arm >/dev/null 2>>"$home/arm.err"; then
      n=$((n + 1))
    else
      printf 'arm failed\n' >> "$home/arm.fail"
    fi
    printf '%s\n' "$n" > "$home/arms"
  done
) &
armpid=$!

deadline=$((SECONDS + SECS))
checkpoints=0 wakes=0
while [ "$SECONDS" -lt "$deadline" ]; do
  left=$((deadline - SECONDS))
  [ "$left" -ge 2 ] || break
  rc=0
  with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$left" >> "$home/watcher.out" 2>> "$home/watcher.err" || rc=$?
  checkpoints=$((checkpoints + 1))
  [ "$rc" -ne 0 ] || wakes=$((wakes + 1))
done
: > "$home/stop"
wait "$armpid"

rejections=$(awk -F '\t' 'NF >= 5 && $4 == "unauthenticated-state-checks" { c++ } END { print c + 0 }' "$home/state/.wake-queue" 2>/dev/null || echo 0)
printf 'label=%s seconds=%s\n' "$LABEL" "$SECS"
printf 'changed-shim arms completed: %s\n' "$(cat "$home/arms" 2>/dev/null || echo 0)"
printf 'arm failures: %s\n' "$(cat "$home/arm.fail" 2>/dev/null | wc -l | tr -d ' ')"
printf 'authenticated contributions-check runs (forge polls): %s\n' "$(wc -c < "$home/forge/polls" | tr -d ' ')"
printf 'watcher checkpoints: %s (ended on a wake: %s)\n' "$checkpoints" "$wakes"
printf 'queued rejection wakes for the contributions check: %s\n' "$rejections"
printf 'watcher rejection lines:\n'
grep -F 'rejected unauthenticated state checks' "$home/watcher.out" | sed "s|$FIX_ROOT|<fixture>|g" | sort | uniq -c || printf '  (none)\n'
printf 'leftover stage dirs: %s\n' "$(find "$home/state" -maxdepth 1 -name '.contributions-arm.*' | wc -l | tr -d ' ')"
printf 'leftover publish lock: %s\n' "$([ -e "$home/state/.check-publish-contributions.lock" ] && echo yes || echo no)"
printf 'final pair authenticates: '
( FM_STATE=$home/state; . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
  fm_custom_check_registered "$FM_STATE" contributions && echo yes || echo no )
printf 'watcher stderr (non-empty lines): %s\n' "$(grep -c . "$home/watcher.err" 2>/dev/null || echo 0)"
