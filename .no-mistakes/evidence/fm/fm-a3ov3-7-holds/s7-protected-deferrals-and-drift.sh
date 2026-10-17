#!/usr/bin/env bash
# Scenario 7: classify before spooling. Protected or human-owned holds, even
# when deferred to a future date, create no routing state and never keep
# supervision awake; a technical deferral that is later changed into a
# production question retires its routing; a hold whose live reason was changed
# underneath its routing fields is refused rather than routed.
set -u
. "$(dirname "$0")/lab-lib.sh"
cd "$WT" || exit 1
LAB=$(lab_new) || exit 1
echo "host: $(uptime | sed "s/.*load/load/")   timing allowance: $([ -n "${LAB_ALLOWANCE:-}" ] && echo "widened read/row/check bounds" || echo "production bounds")"
echo "lab home: $LAB   worktree head: $(git -C "$WT" rev-parse --short HEAD)"

echo '== future-dated protected and human-owned holds (until 2099-01-01)'
hold_cli "$LAB" 2026-10-14T02:00:00Z hold prod-later --title 'Production later' --decision-owner ep-firstmate \
  --timeout-seconds 60 --until 2099-01-01 --reason 'Should I deploy this to production?' >/dev/null || echo 'FAIL  hold prod-later'
hold_cli "$LAB" 2026-10-14T02:00:00Z hold money-later --title 'Money later' --decision-owner ep-firstmate \
  --timeout-seconds 60 --until 2099-01-01 --reason 'Should I spend money to buy more seats?' >/dev/null || echo 'FAIL  hold money-later'
hold_cli "$LAB" 2026-10-14T02:00:00Z hold human-later --title 'Human later' --decision-owner captain \
  --timeout-seconds 60 --until 2099-01-01 --reason "$UPDATE" >/dev/null || echo 'FAIL  hold human-later'
check 'no routing state created for protected or human-owned holds' absent "$([ -e "$LAB/state/hold-domain" ] && echo present || echo absent)"
check 'supervision not kept awake by them' no "$(supervision_needed "$LAB")"
for id in prod-later money-later human-later; do
  check "$id held with its date" 'yes 2099-01-01' "$(field "$LAB" "$id" held) $(field "$LAB" "$id" hold_until | tr -d '"')"
done
watch_once "$LAB" 2099-01-02T00:00:00Z > "$LAB/watch-late.out" 2>&1
echo "watcher wake well after their date: $(tr '\n' ' ' < "$LAB/watch-late.out")"
check 'still no prompt after the date passes' 0 "$(prompts "$LAB")"
for id in prod-later money-later human-later; do
  check "$id not released by routing" no "$(body_has "$LAB" "$id" 'Resolution mode:')"
done

echo; echo '== technical hold, postponed, then changed into a production question'
hold_cli "$LAB" 2026-10-14T02:00:00Z hold postponed --title 'Postponed call' --decision-owner ep-firstmate \
  --timeout-seconds 60 --reason "$UPDATE" >/dev/null
hold_cli "$LAB" 2026-10-14T02:00:30Z hold postponed --until 2099-01-01 --reason "$UPDATE" >/dev/null || echo 'FAIL  postpone'
check 'postponed technical hold pending' yes "$([ -f "$LAB/state/hold-domain/pending/postponed.body" ] && echo yes || echo no)"
check 'supervision required for it' yes "$(supervision_needed "$LAB")"
watch_once "$LAB" 2026-10-14T02:05:00Z > "$LAB/watch-pre.out" 2>&1
check 'no prompt before its date despite elapsed timeout' 0 "$(prompts "$LAB")"
hold_cli "$LAB" 2026-10-14T02:06:00Z hold postponed --until 2099-01-01 --reason 'Should I deploy this to production?' >/dev/null \
  || echo 'FAIL  question change'
check 'question change retired the pending routing' no "$([ -f "$LAB/state/hold-domain/pending/postponed.body" ] && echo yes || echo no)"
check 'supervision released' no "$(supervision_needed "$LAB")"
check 'production question still held' yes "$(field "$LAB" postponed held)"

echo; echo '== live reason changed underneath the routing fields (tasks-axi directly)'
hold_cli "$LAB" 2026-10-14T02:00:00Z hold changed --title 'Changed live reason' --decision-owner ep-firstmate \
  --timeout-seconds 60 --reason "$UPDATE" >/dev/null
(cd "$LAB" && "$REAL_TASKS_AXI" hold changed --kind captain --reason 'Should I deploy to production?' >/dev/null)
hold_cli "$LAB" 2026-10-14T02:02:00Z route-due changed > "$LAB/drift.out" 2>&1
rc=$?
echo "route-due exit $rc: $(cat "$LAB/drift.out")"
check 'stale routing refused (non-zero exit)' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'changed hold still held' yes "$(field "$LAB" changed held)"
check 'no owner prompted for the changed hold' 0 "$(prompts "$LAB")"
echo "FAILS=${LAB_FAILS:-0}"
