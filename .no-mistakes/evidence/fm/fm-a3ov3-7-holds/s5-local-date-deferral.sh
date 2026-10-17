#!/usr/bin/env bash
# Scenario 5: a technical hold deferred with --until in America/Chicago.
# tasks-axi gates --until on the local calendar date, so the evening before
# (already the deferral date in UTC) must neither prompt nor release; the hold
# routes once on the local date. Release recovery must refuse a deferral to the
# next local date during that same evening window.
# Run with BIN_ROOT=<extracted old bin parent> to replay a previous revision.
set -u
. "$(dirname "$0")/lab-lib.sh"
WT=${BIN_ROOT:-$WT}
cd "$WT" || exit 1
export LAB_TZ=America/Chicago
LAB=$(lab_new) || exit 1
echo "host: $(uptime | sed "s/.*load/load/")   timing allowance: $([ -n "${LAB_ALLOWANCE:-}" ] && echo "widened read/row/check bounds" || echo "production bounds")"
echo "lab home: $LAB   code under test: $WT   TZ=$LAB_TZ"

echo; echo '== hold dated --until 2098-10-20 at 2098-10-19T20:00:00Z (15:00 CDT Oct 19)'
hold_cli "$LAB" 2098-10-19T20:00:00Z hold dated --title 'Dated technical call' \
  --decision-owner ep-firstmate --timeout-seconds 60 --until 2098-10-20 --reason "$UPDATE" >/dev/null \
  || echo 'FAIL  could not defer the technical hold'
check 'deferral spooled for routing' yes "$([ -f "$LAB/state/hold-domain/pending/dated.body" ] && echo yes || echo no)"
check 'supervision required while the deferral is pending' yes "$(supervision_needed "$LAB")"

echo; echo '== real watcher cycle at 2098-10-20T00:00:00Z (19:00 CDT Oct 19; already Oct 20 in UTC)'
watch_once "$LAB" 2098-10-20T00:00:00Z > "$LAB/watch-evening.out" 2>&1
echo "watcher wake: $(tr '\n' ' ' < "$LAB/watch-evening.out")"
check 'no owner prompt before the local deferral date' 0 "$(prompts "$LAB")"
check 'hold keeps its date' 2098-10-20 "$(field "$LAB" dated hold_until | tr -d '"')"
check 'no routing resolution recorded in the evening' no "$(body_has "$LAB" dated 'Resolution mode:')"
check 'pending deferral survives the evening' yes "$([ -f "$LAB/state/hold-domain/pending/dated.body" ] && echo yes || echo no)"

echo; echo '== real watcher cycle at 2098-10-20T07:00:00Z (02:00 CDT Oct 20, the local date)'
watch_once "$LAB" 2098-10-20T07:00:00Z > "$LAB/watch-due.out" 2>&1
echo "watcher wake: $(tr '\n' ' ' < "$LAB/watch-due.out")"
check 'routed on the local date: released' no "$(field "$LAB" dated held)"
check 'work stays queued' queued "$(field "$LAB" dated state)"
check 'exactly one owner prompt' 1 "$(prompts "$LAB")"
hold_cli "$LAB" 2098-10-20T07:05:00Z route-due dated
check 'replay adds no prompt' 1 "$(prompts "$LAB")"
check 'supervision retired' no "$(supervision_needed "$LAB")"

echo; echo '== release recovery: owner prompted but unhold fails (19:01 UTC hold, 60s timeout)'
hold_cli "$LAB" 2098-10-19T20:00:00Z hold recovering --title 'Release recovery' \
  --decision-owner ep-firstmate --timeout-seconds 60 --reason "$UPDATE" >/dev/null || echo 'FAIL  could not hold'
cat > "$LAB/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = unhold ] && [ -f "$FM_HOME/fail-unhold" ]; then echo 'backend unavailable' >&2; exit 1; fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$LAB/fakebin/tasks-axi"
touch "$LAB/fail-unhold"
hold_cli "$LAB" 2098-10-19T20:01:00Z route-due recovering > "$LAB/seed.out" 2>&1
echo "route-due with failing unhold: exit $? -- $(tr '\n' ' ' < "$LAB/seed.out")"
check 'owner prompted once for recovering' 2 "$(prompts "$LAB")"
before=$(tasks "$LAB" show recovering --full)
echo; echo '== evening re-hold with --until 2098-10-20 at 2098-10-20T00:30:00Z (19:30 CDT Oct 19)'
hold_cli "$LAB" 2098-10-20T00:30:00Z hold recovering --until 2098-10-20 --reason "$UPDATE" > "$LAB/defer.out" 2>&1
rc=$?
echo "re-hold exit $rc: $(tr '\n' ' ' < "$LAB/defer.out")"
check 'next-local-date deferral refused during release recovery' 1 "$([ "$rc" -ne 0 ] && grep -q 'finish releasing it' "$LAB/defer.out" && echo 1 || echo 0)"
check 'refused deferral left the routed hold unchanged' same "$([ "$before" = "$(tasks "$LAB" show recovering --full)" ] && echo same || echo changed)"
rm -f "$LAB/fail-unhold"
hold_cli "$LAB" 2098-10-20T00:31:00Z route-due recovering; echo "retry route-due exit $?"
check 'retry released recovering' no "$(field "$LAB" recovering held)"
check 'retry did not prompt again' 2 "$(prompts "$LAB")"
echo '-- owner transport log:'; cat "$LAB/owner.log"
echo "FAILS=${LAB_FAILS:-0}"
