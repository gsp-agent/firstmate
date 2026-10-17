#!/usr/bin/env bash
# Scenario 6: inside a secondmate home every hold publishes a parent-channel
# needs-decision key. When routing reached the owner but the release failed,
# a re-hold, Dale's answer, or a reconciliation on top of that routed hold must
# name the same occurrence, so the eventual release closes every parent
# decision and nothing resurfaces to Dale.
# Run with BIN_ROOT=<extracted old bin parent> to replay a previous revision.
set -u
. "$(dirname "$0")/lab-lib.sh"
WT=${BIN_ROOT:-$WT}
cd "$WT" || exit 1
LAB=$(lab_new) || exit 1
echo "host: $(uptime | sed "s/.*load/load/")   timing allowance: $([ -n "${LAB_ALLOWANCE:-}" ] && echo "widened read/row/check bounds" || echo "production bounds")"
echo "lab home: $LAB   code under test: $WT"
mkdir -p "$LAB/parent/state"
printf 'router-mate\n' > "$LAB/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB/parent" > "$LAB/.fm-secondmate-parent"
status="$LAB/parent/state/router-mate.status"
open_decisions() { ( . "$WT/bin/fm-classify-lib.sh"; status_open_decisions "$status" ) | tr '\n' ' '; }

for id in rehold answered reconciled; do
  hold_cli "$LAB" 2026-10-14T02:00:00Z hold "$id" --title "Recovery $id" \
    --decision-owner ep-firstmate --timeout-seconds 60 --reason "$UPDATE" >/dev/null || echo "FAIL  hold $id"
done
echo "parent channel after holds:"; sed 's/^/  /' "$status"

cat > "$LAB/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = unhold ] && [ -f "$FM_HOME/fail-unhold" ]; then echo 'backend unavailable' >&2; exit 1; fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$LAB/fakebin/tasks-axi"
touch "$LAB/fail-unhold"
echo; echo '== sweep at 02:01:00Z reaches the owners but every release fails'
hold_cli "$LAB" 2026-10-14T02:01:00Z route-due > "$LAB/routed.out" 2>&1; echo "route-due exit $?"
check 'three owner prompts' 3 "$(prompts "$LAB")"

echo; echo '== on top of the unreleased routed holds: re-hold, captain answer, reconciliation'
hold_cli "$LAB" 2026-10-14T02:01:30Z hold rehold --reason "$UPDATE" > "$LAB/rehold.out" 2>&1
echo "re-hold exit $? (expected non-zero while unhold fails): $(tr '\n' ' ' < "$LAB/rehold.out" | cut -c1-200)"
printf 'Ship the update now.\n' > "$LAB/decision.txt"
hold_cli "$LAB" 2026-10-14T02:01:40Z answer answered --decision-file "$LAB/decision.txt" >/dev/null; echo "answer exit $?"
hold_cli "$LAB" '' bind board >/dev/null
printf 'reconciled\n' | hold_cli "$LAB" '' reconcile-requests --source-id board --source 'captured board result' >/dev/null
echo "reconcile-requests exit $?"
printf 'The branch already merged upstream.\n' > "$LAB/evidence.txt"
hold_cli "$LAB" 2026-10-14T02:01:50Z reconcile close reconciled --evidence-file "$LAB/evidence.txt" >/dev/null
echo "reconcile close exit $?"
echo "open parent decisions before release: $(open_decisions)"

echo; echo '== backend restored; sweep at 02:02:00Z finishes the releases'
rm -f "$LAB/fail-unhold"
hold_cli "$LAB" 2026-10-14T02:02:00Z route-due; echo "route-due exit $?"
echo "parent channel after release:"; sed 's/^/  /' "$status"
check 'no parent decision left open' '' "$(open_decisions)"
for id in rehold answered reconciled; do
  check "$id resolved its first occurrence" 1 "$(grep -cF "resolved [key=captain-hold-$id-1]" "$status")"
done
check 'releases added no owner prompt' 3 "$(prompts "$LAB")"

echo; echo '== a genuinely new lifecycle opens and closes the next occurrence'
hold_cli "$LAB" 2026-10-14T03:00:00Z hold rehold --decision-owner ep-firstmate --timeout-seconds 60 --reason "$UPDATE" >/dev/null
hold_cli "$LAB" 2026-10-14T03:01:00Z route-due rehold
check 'new lifecycle published key 2' 1 "$(grep -cF 'needs-decision [key=captain-hold-rehold-2]' "$status")"
check 'new lifecycle closed key 2' 1 "$(grep -cF 'resolved [key=captain-hold-rehold-2]' "$status")"
check 'still no parent decision open' '' "$(open_decisions)"
echo "FAILS=${LAB_FAILS:-0}"
