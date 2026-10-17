#!/usr/bin/env bash
# Scenario 3+4: a home shaped like the real one (233 open rows, 11 captain
# holds, 62 state/*.meta files named by listed ids). Drives the real watcher's
# routing sweep and a keyed captain answer, and measures them against the
# 90-second sweep and 30-second row budgets. Every tasks-axi call is logged.
set -u
. "$(dirname "$0")/lab-lib.sh"
cd "$WT" || exit 1
now_s() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
LAB=$(lab_new) || exit 1
echo "lab home: $LAB   worktree head: $(git -C "$WT" rev-parse --short HEAD)"
echo "host: $(sysctl -n hw.ncpu) cores, $(uptime | sed 's/.*load/load/')"
for i in 1 2 3; do
  s=$(now_s); tasks-axi --version >/dev/null; e=$(now_s)
  echo "tasks-axi startup sample $i: $(echo "$e - $s" | bc)s"
done

# 222 ordinary open rows written straight into the markdown backlog.
{
  printf '## In flight\n\n## Queued\n'
  for i in $(seq -w 1 222); do
    printf -- '- [ ] row-%s - Ordinary row %s (repo: sample) (kind: ship) (since 2026-10-17)\n' "$i" "$i"
  done
  printf '\n## Done\n'
} > "$LAB/data/backlog.md"
# As in the real home, every meta is named by a listed task id.
for i in $(seq -w 1 222 | head -62); do
  printf 'decision_owner=ep-row-%s\nproject=/fixture/sample\n' "$i" > "$LAB/state/row-$i.meta"
done

echo; echo '== hold 11 captain calls through the CLI at 02:00:00Z (2 technical, 9 protected/human)'
while IFS='|' read -r id owner reason; do
  hold_cli "$LAB" 2026-10-14T02:00:00Z hold "$id" --title "$id call" \
    --decision-owner "$owner" --timeout-seconds 60 --reason "$reason" >/dev/null \
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
HOLDS
open=$(tasks "$LAB" list --fields hold_kind | grep -c '^  [a-z]')
captain=$(tasks "$LAB" list --fields hold_kind | grep -c ',captain$')
check 'open rows in the home' 233 "$open"
check 'captain-held rows' 11 "$captain"
check 'state/*.meta files' 62 "$(ls "$LAB"/state/*.meta | wc -l | tr -d ' ')"

# Log every tasks-axi call the product makes from here on.
cat > "$LAB/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/axi.log"
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$LAB/fakebin/tasks-axi"
: > "$LAB/axi.log"

echo; echo '== real watcher cycle at 02:01:00Z (both technical holds due)'
s=$(now_s)
LAB_WATCH_TIMEOUT=400 watch_once "$LAB" 2026-10-14T02:01:00Z > "$LAB/watch-due.out" 2>&1
e=$(now_s)
echo "watcher wake: $(tr '\n' ' ' < "$LAB/watch-due.out")"
echo "watcher cycle wall time: $(echo "$e - $s" | bc)s"
check 'branch routed and released' no "$(field "$LAB" branch held)"
check 'capacity routed and released' no "$(field "$LAB" capacity held)"
check 'exactly two owner prompts' 2 "$(prompts "$LAB")"
check 'watcher reported no routing failure' no \
  "$(grep -q 'hold-domain routing failed' "$LAB/watch-due.out" && echo yes || echo no)"
echo "tasks-axi calls during the cycle: $(wc -l < "$LAB/axi.log" | tr -d ' ')"
echo "  show calls on ordinary rows: $(grep -c '^show row-' "$LAB/axi.log")"
echo "  show calls on captain rows:  $(grep -Ec '^show (branch|capacity|money|credential|person|client|production|account|taste|mixed|human) ' "$LAB/axi.log")"
echo "  compatibility probes:        $(grep -Ec '^(--version|update --help|mv --help|hold --help)' "$LAB/axi.log")"

echo; echo '== steady-state sweep at 02:10:00Z (9 protected holds remain, nothing due)'
: > "$LAB/axi.log"
s=$(now_s)
hold_cli "$LAB" 2026-10-14T02:10:00Z route-due > "$LAB/steady.out" 2>&1; rc=$?
e=$(now_s)
cat "$LAB/steady.out"
echo "steady-state route-due exit $rc, wall time $(echo "$e - $s" | bc)s (watcher bound 90s, row bound 30s)"
check 'steady-state sweep reads no ordinary row' 0 "$(grep -c '^show row-' "$LAB/axi.log")"
check 'steady-state sweep adds no prompts' 2 "$(prompts "$LAB")"
echo "  tasks-axi calls: $(wc -l < "$LAB/axi.log" | tr -d ' ') (probes $(grep -Ec '^(--version|update --help|mv --help|hold --help)' "$LAB/axi.log"))"

echo; echo "== Dale's keyed answer to a held call without its own meta (answers intake)"
: > "$LAB/axi.log"
s=$(now_s)
printf 'money\tNo, do not buy seats.\tDale\n' \
  | hold_cli "$LAB" 2026-10-14T02:11:00Z answers --source 'lab keyed answer' > "$LAB/answer.out" 2>&1; rc=$?
e=$(now_s)
cat "$LAB/answer.out"
echo "answers exit $rc, wall time $(echo "$e - $s" | bc)s"
check 'answer closed the call' done "$(field "$LAB" money state)"
check 'answer read no listed meta id' 0 "$(grep -c '^show row-' "$LAB/axi.log")"
echo "  tasks-axi calls: $(wc -l < "$LAB/axi.log" | tr -d ' ')"
echo "host at end: $(uptime | sed "s/.*load/load/")"
echo "FAILS=${LAB_FAILS:-0}"
