#!/usr/bin/env bash
# Scenario 6 (adversarial, commit 2eb4c129): in a secondmate home, an
# agent-routed release that dies after `tasks-axi unhold` and before its parent
# resolution must refuse a re-hold until route-due finishes it, so the parent
# channel never keeps a captain decision Dale does not owe.
# Failure injection: a tasks-axi wrapper that applies the real unhold and then
# exits 1 while $LAB/unhold-dies exists. OLD_ROOT=<tree> runs the pre-fix code.
set -u
. "$(dirname "$0")/lab-lib.sh"
cd "$WT" || exit 1
LAB=$(lab_new) || exit 1
echo "lab home: $LAB"
echo "code under test: ${OLD_ROOT:-current head $(git -C "$WT" rev-parse --short HEAD)}"
status="$LAB/parent/state/router-mate.status"
mkdir -p "$LAB/parent/state"
printf 'router-mate\n' > "$LAB/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB/parent" > "$LAB/.fm-secondmate-parent"

echo; echo '== 02:00:00Z hold work (technical, owner ep-firstmate, 60s)'
hold_cli "$LAB" 2026-10-14T02:00:00Z hold work --title 'Update branch' \
  --decision-owner ep-firstmate --timeout-seconds 60 --reason "$UPDATE" >/dev/null; echo "hold exit $?"
cat > "$LAB/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = unhold ] && [ -f "$FM_HOME/unhold-dies" ]; then
  "$REAL_TASKS_AXI" "$@" >/dev/null
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$LAB/fakebin/tasks-axi"
touch "$LAB/unhold-dies"
echo; echo '== 02:01:00Z route-due; the release dies right after unhold'
hold_cli "$LAB" 2026-10-14T02:01:00Z route-due > "$LAB/routed.out" 2>&1; echo "route-due exit $? $(tr '\n' ' ' < "$LAB/routed.out")"
rm "$LAB/unhold-dies"
before=$(tasks "$LAB" show work --full)
check 'the release was applied before dying' yes "$(printf '%s' "$before" | grep -q '^  held: no' && echo yes || echo no)"
check 'agent-routed record present' yes "$(printf '%s' "$before" | grep -q 'Resolution mode: agent-routed' && echo yes || echo no)"
echo "-- parent channel after the dead release:"; cat "$status"

echo; echo '== 02:01:30Z re-hold over the unfinished routed release'
hold_cli "$LAB" 2026-10-14T02:01:30Z hold work --decision-owner ep-firstmate --timeout-seconds 60 \
  --reason "$UPDATE" > "$LAB/rehold.out" 2>&1; rc=$?
echo "re-hold exit $rc: $(tr '\n' ' ' < "$LAB/rehold.out")"
check 're-hold refused' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'refusal names the route-due recovery pass' yes "$(grep -q 'route-due' "$LAB/rehold.out" && echo yes || echo no)"
check 'refused re-hold left the task unchanged' yes "$([ "$before" = "$(tasks "$LAB" show work --full)" ] && echo yes || echo no)"
check 'no second parent occurrence opened' no "$(grep -q 'captain-hold-work-2' "$status" && echo yes || echo no)"

echo; echo '== 02:02:00Z route-due recovery pass'
hold_cli "$LAB" 2026-10-14T02:02:00Z route-due; echo "route-due exit $?"
check 'recovery resolved occurrence 1 in the parent channel' yes "$(grep -Fq 'resolved [key=captain-hold-work-1]' "$status" && echo yes || echo no)"

echo; echo '== 03:00:00Z re-hold after recovery, 03:01:00Z route-due work'
hold_cli "$LAB" 2026-10-14T03:00:00Z hold work --decision-owner ep-firstmate --timeout-seconds 60 \
  --reason "$UPDATE" >/dev/null; echo "re-hold exit $?"
hold_cli "$LAB" 2026-10-14T03:01:00Z route-due work; echo "route-due work exit $?"
check 'new lifecycle resolved its own occurrence 2' yes "$(grep -Fq 'resolved [key=captain-hold-work-2]' "$status" && echo yes || echo no)"
check 'each lifecycle reached its owner exactly once' 2 "$(prompts "$LAB")"
open=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$status")
check 'no parent decision left open for Dale' '' "$open"
echo "-- parent channel (secondmate -> parent status) at the end:"; cat "$status"
echo '-- owner transport log:'; cat "$LAB/owner.log"
echo "FAILS=${LAB_FAILS:-0}"
echo "LAB=$LAB"
