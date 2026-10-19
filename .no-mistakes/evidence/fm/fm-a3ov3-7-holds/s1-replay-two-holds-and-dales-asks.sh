#!/usr/bin/env bash
# Scenarios 1-3: replay last night's two technical holds (update-branch, GSP
# capacity) next to Dale's real asks through the public hold CLI with the
# DEFAULT timeout, then let one real watcher cycle route the due ones.
set -u
. "$(dirname "$0")/lab-lib.sh"
cd "$WT" || exit 1
LAB=$(lab_new) || exit 1
echo "lab home: $LAB"
echo "router: $ROUTER (agent-config $(git -C "$HOME/.agent-config" rev-parse --short HEAD))"
echo "worktree head: $(git -C "$WT" rev-parse --short HEAD)"
echo "host: $(uptime | sed 's/.*load/load/')   timing allowance: ${LAB_ALLOWANCE:+widened read/row/check bounds}"

echo; echo '== hold CLI at 02:00:00Z, no --timeout-seconds (default), 2 technical + Dale asks'
while IFS='|' read -r id owner reason; do
  hold_cli "$LAB" 2026-10-14T02:00:00Z hold "$id" --title "$id replay" \
    --decision-owner "$owner" --reason "$reason" >/dev/null \
    || echo "FAIL  hold $id exited non-zero"
done <<HOLDS
branch|ep-firstmate|$UPDATE
capacity|ep-groove-sight-platform|$CAPACITY
money|ep-firstmate|Should I spend money to buy more seats?
credential|ep-firstmate|Could you provide the OAuth token?
person|ep-firstmate|Should I assign Ashton to the reviewer seat?
client|ep-firstmate|May I email the client that the rebase is complete?
production|ep-firstmate|Should I deploy this to production?
account|ep-firstmate|May I create a new account?
taste|ep-firstmate|Should the capacity indicator be blue or orange?
mixed|ep-firstmate|$UPDATE May I deploy to production too?
human|pm-dale-desk|$UPDATE
desk|human-desk-pane|$UPDATE
captain|captain|$UPDATE
HOLDS
echo '-- branch body fields written by hold:'
tasks "$LAB" show branch --full | sed -n 's/^  body: //p' | head -1
check 'branch default timeout is the 300s watcher interval' yes "$(body_has "$LAB" branch 'Hold timeout seconds: 300')"
check 'only the two technical holds are spooled for routing' 'branch.body capacity.body ' \
  "$(cd "$LAB/state/hold-domain/pending" 2>/dev/null && ls | LC_ALL=C sort | tr '\n' ' ')"
check 'supervision stays required while technical holds are pending' yes "$(supervision_needed "$LAB")"
check 'no owner prompt at creation' 0 "$(prompts "$LAB")"

echo; echo '== route-due sweep at 02:04:59Z (one second before the default timeout)'
hold_cli "$LAB" 2026-10-14T02:04:59Z route-due; echo "route-due exit $?"
check 'no owner prompt before timeout' 0 "$(prompts "$LAB")"
check 'branch still held before timeout' yes "$(field "$LAB" branch held)"
check 'capacity still held before timeout' yes "$(field "$LAB" capacity held)"

echo; echo '== real watcher cycle at 02:05:00Z (default timeout reached)'
t0=$(date +%s)
watch_once "$LAB" 2026-10-14T02:05:00Z > "$LAB/watch-due.out" 2>&1
echo "due watcher cycle wall time: $(( $(date +%s) - t0 ))s"
echo "watcher printed: $(tr '\n' ' ' < "$LAB/watch-due.out")"
for id in branch capacity; do
  check "$id released" no "$(field "$LAB" "$id" held)"
  check "$id work stays queued, not done" queued "$(field "$LAB" "$id" state)"
  check "$id carries agent-routed record" yes "$(body_has "$LAB" "$id" 'Resolution mode: agent-routed')"
  check "$id has no invented captain words" no "$(body_has "$LAB" "$id" 'Captain decision:')"
done
for id in money credential person client production account taste mixed human desk captain; do
  check "$id (Dale's ask) still held" yes "$(field "$LAB" "$id" held)"
  check "$id has no routing record" no "$(body_has "$LAB" "$id" 'Resolution mode:')"
done
check 'exactly two owner prompts' 2 "$(prompts "$LAB")"
echo '-- owner transport log (recording stand-in for herdr agent prompt):'
cat "$LAB/owner.log"
echo '-- routing receipts (state/hold-domain/routed.tsv):'
cat "$LAB/state/hold-domain/routed.tsv"
check 'pending bodies retired' '' "$(ls "$LAB/state/hold-domain/pending" 2>/dev/null)"
check 'supervision no longer required for routing' no "$(supervision_needed "$LAB")"
check 'no hold-domain routing failure wake' no \
  "$(grep -rqs 'hold-domain routing failed' "$LAB/watch-due.out" "$LAB/drained.out" "$LAB/state" && echo yes || echo no)"

echo; echo '== replay: route-due sweep at 02:06:00Z'
hold_cli "$LAB" 2026-10-14T02:06:00Z route-due; echo "route-due exit $?"
check 'replay adds no prompts' 2 "$(prompts "$LAB")"
echo; echo '== branch task after routing:'
tasks "$LAB" show branch --full | sed -n '/^  held:/p;/^  state:/p;/^  body:/p'
echo; echo '== money task (Dale ask) after routing:'
tasks "$LAB" show money --full | sed -n '/^  held:/p;/^  hold_kind:/p;/^  state:/p'
echo "FAILS=${LAB_FAILS:-0}"
echo "LAB=$LAB"
