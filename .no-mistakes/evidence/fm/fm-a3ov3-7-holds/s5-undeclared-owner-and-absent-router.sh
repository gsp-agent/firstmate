#!/usr/bin/env bash
# Scenario 8: no agent authority is inferred. A technical hold with no declared
# owner (no --decision-owner, no origin) stays with Dale; with the router
# absent, hold keeps ordinary captain-hold behavior and creates no routing state.
set -u
. "$(dirname "$0")/lab-lib.sh"
cd "$WT" || exit 1
LAB=$(lab_new) || exit 1
echo "lab home: $LAB"
echo; echo '== 02:00:00Z hold undeclared (technical reason, no owner, 60s), installed router'
hold_cli "$LAB" 2026-10-14T02:00:00Z hold undeclared --title 'undeclared owner' --timeout-seconds 60 \
  --reason "$UPDATE" > "$LAB/undeclared.out" 2>&1; echo "hold exit $? $(tr '\n' ' ' < "$LAB/undeclared.out")"
check 'owner defaults to captain' yes "$(body_has "$LAB" undeclared 'Decision owner: captain')"
hold_cli "$LAB" 2026-10-14T02:05:00Z route-due > "$LAB/sweep.out" 2>&1; echo "route-due exit $? $(tr '\n' ' ' < "$LAB/sweep.out")"
check 'undeclared technical hold still held for Dale' yes "$(field "$LAB" undeclared held)"
check 'no owner prompt' 0 "$(prompts "$LAB")"
check 'no pending routing body' no "$([ -e "$LAB/state/hold-domain/pending/undeclared.body" ] && echo yes || echo no)"
hold_cli "$LAB" '' open undeclared; check 'open reports an open captain call (exit 0)' 0 "$?"

echo; echo '== 02:00:00Z hold no-router (technical, owner ep-firstmate) with the router absent'
FM_HOLD_DOMAIN_ROUTER_SAVED=$ROUTER; ROUTER="$LAB/no-such-router.py"
hold_cli "$LAB" 2026-10-14T02:00:00Z hold no-router --title 'router absent' --decision-owner ep-firstmate \
  --timeout-seconds 60 --reason "$UPDATE" > "$LAB/norouter.out" 2>&1; echo "hold exit $? $(tr '\n' ' ' < "$LAB/norouter.out")"
hold_cli "$LAB" 2026-10-14T02:05:00Z route-due no-router; echo "route-due exit $?"
ROUTER=$FM_HOLD_DOMAIN_ROUTER_SAVED
check 'router-absent hold stays an ordinary captain hold' yes "$(field "$LAB" no-router held)"
check 'router-absent hold records no resolution' no "$(body_has "$LAB" no-router 'Resolution mode:')"
check 'router-absent hold created no routing state' no "$([ -e "$LAB/state/hold-domain/pending/no-router.body" ] && echo yes || echo no)"
check 'still no owner prompt' 0 "$(prompts "$LAB")"
echo "FAILS=${LAB_FAILS:-0}"
echo "LAB=$LAB"
