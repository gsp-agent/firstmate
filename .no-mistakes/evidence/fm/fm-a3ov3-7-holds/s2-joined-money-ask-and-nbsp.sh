#!/usr/bin/env bash
# Scenarios 4-5 (adversarial, review F1): a technical update-branch reason with
# Dale's money question joined by a character the installed router's
# str.splitlines() treats as a line break must stay held for Dale; a technical
# reason with a leading or trailing NBSP must route once instead of failing.
# OLD_ROOT=<tree> runs the same scenario against the pre-fix code.
set -u
. "$(dirname "$0")/lab-lib.sh"
cd "$WT" || exit 1
LAB=$(lab_new) || exit 1
echo "lab home: $LAB"
echo "code under test: $ROOT ($(git -C "$WT" rev-parse --short HEAD) unless OLD_ROOT is set: ${OLD_ROOT:-current head})"
echo "router: $ROUTER (agent-config $(git -C "$HOME/.agent-config" rev-parse --short HEAD))"
MONEY='Also approve the 5000 dollar vendor invoice?'
prompts_for() { local c; c=$(grep -c "Hold $1 timed out" "$LAB/owner.log" 2>/dev/null); echo "${c:-0}"; }

echo; echo '== hold at 02:00:00Z: technical reason + money question joined by each separator'
seps='nel:\xc2\x85 ls:\xe2\x80\xa8 ps:\xe2\x80\xa9 fs:\x1c gs:\x1d rs:\x1e vt:\x0b ff:\x0c cr:\x0d'
for pair in $seps; do
  id=${pair%%:*}
  sep=$(printf "${pair#*:}")
  hold_cli "$LAB" 2026-10-14T02:00:00Z hold "$id" --title "joined $id" \
    --decision-owner ep-firstmate --timeout-seconds 60 --reason "$UPDATE$sep$MONEY" > "$LAB/hold-$id.out" 2>&1
  echo "hold $id exit $? $(tr '\n' ' ' < "$LAB/hold-$id.out")"
done
echo; echo '== hold at 02:00:00Z: technical reason with leading / trailing NBSP'
hold_cli "$LAB" 2026-10-14T02:00:00Z hold nbsp-lead --title 'nbsp lead' --decision-owner ep-firstmate \
  --timeout-seconds 60 --reason $'\xc2\xa0'"$UPDATE" > "$LAB/hold-nbsp-lead.out" 2>&1
echo "hold nbsp-lead exit $? $(tr '\n' ' ' < "$LAB/hold-nbsp-lead.out")"
hold_cli "$LAB" 2026-10-14T02:00:00Z hold nbsp-trail --title 'nbsp trail' --decision-owner ep-firstmate \
  --timeout-seconds 60 --reason "$UPDATE"$'\xc2\xa0' > "$LAB/hold-nbsp-trail.out" 2>&1
echo "hold nbsp-trail exit $? $(tr '\n' ' ' < "$LAB/hold-nbsp-trail.out")"
echo "pending routing bodies after hold: $(cd "$LAB/state/hold-domain/pending" 2>/dev/null && ls | LC_ALL=C sort | tr '\n' ' ')"

echo; echo '== route-due sweep at 02:01:00Z (timeout reached)'
hold_cli "$LAB" 2026-10-14T02:01:00Z route-due > "$LAB/sweep.out" 2>&1; echo "route-due exit $? $(tr '\n' ' ' < "$LAB/sweep.out")"
hold_cli "$LAB" 2026-10-14T02:02:00Z route-due > "$LAB/sweep2.out" 2>&1; echo "replay route-due exit $? $(tr '\n' ' ' < "$LAB/sweep2.out")"

echo
for pair in $seps; do
  id=${pair%%:*}
  check "$id: money ask still held for Dale" yes "$(field "$LAB" "$id" held)"
  check "$id: no routing record" no "$(body_has "$LAB" "$id" 'Resolution mode:')"
  check "$id: no pending body" no "$([ -e "$LAB/state/hold-domain/pending/$id.body" ] && echo yes || echo no)"
  check "$id: no owner prompt" 0 "$(prompts_for "$id")"
done
for id in nbsp-lead nbsp-trail; do
  check "$id: technical hold released" no "$(field "$LAB" "$id" held)"
  check "$id: agent-routed record" yes "$(body_has "$LAB" "$id" 'Resolution mode: agent-routed')"
  check "$id: owner prompted exactly once" 1 "$(prompts_for "$id")"
done
check 'no receipts for any joined money ask' '' "$(grep -v '^nbsp-' "$LAB/state/hold-domain/routed.tsv" 2>/dev/null)"
echo '-- owner transport log:'; cat "$LAB/owner.log" 2>/dev/null || echo '(none)'
echo '-- routing receipts:'; cat "$LAB/state/hold-domain/routed.tsv" 2>/dev/null || echo '(none)'
echo '-- stored Hold reason line for nel (shows the joined reason the router was given):'
tasks "$LAB" show nel --full | sed -n 's/^  body: //p' | head -1 | cut -c1-400
echo "FAILS=${LAB_FAILS:-0}"
echo "LAB=$LAB"
