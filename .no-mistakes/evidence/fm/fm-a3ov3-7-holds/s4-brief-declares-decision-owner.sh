#!/usr/bin/env bash
# Scenario 7: Firstmate declares the decision owner at dispatch. The rebased
# fm-brief.sh usage keeps upstream-lean's ship options and this branch's
# --decision-owner; scaffolds name the owner, default to captain, and refuse a
# malformed endpoint before writing.
set -u
. "$(dirname "$0")/lab-lib.sh"
cd "$WT" || exit 1
LAB=$(lab_new) || exit 1
echo "lab home: $LAB"
brief() { lab_env "$LAB" '' "$WT/bin/fm-brief.sh" "$@"; }
echo '== fm-brief.sh --help usage lines'
brief --help 2>&1 | grep -E '^ *(Usage: )?fm-brief.sh ' | head -3
mkdir -p "$LAB/projects/sample"
echo; echo '== ship brief with --project and --decision-owner ep-firstmate'
brief ship-owned sample --mode no-mistakes --project "$LAB/projects/sample" --decision-owner ep-firstmate > "$LAB/ship.out" 2>&1; echo "exit $?"
grep -m1 '^Decision owner:' "$LAB/data/ship-owned/brief.md"
check 'ship brief names the owner' 'Decision owner: ep-firstmate' "$(grep -m1 '^Decision owner:' "$LAB/data/ship-owned/brief.md")"
echo; echo '== scout brief with no owner'
brief scout-legacy sample --scout > "$LAB/scout.out" 2>&1; echo "exit $?"
check 'scout brief defaults to captain' 'Decision owner: captain' "$(grep -m1 '^Decision owner:' "$LAB/data/scout-legacy/brief.md")"
echo; echo '== secondmate charter with --decision-owner=ep-groove-sight-platform'
brief mate-owned --secondmate --no-projects --decision-owner=ep-groove-sight-platform > "$LAB/mate.out" 2>&1; echo "exit $?"
check 'secondmate charter names the owner' 'Decision owner: ep-groove-sight-platform' "$(grep -m1 '^Decision owner:' "$LAB/data/mate-owned/brief.md")"
echo; echo '== malformed owner ../outside'
brief bad-owner sample --scout --decision-owner ../outside > "$LAB/bad.out" 2>&1; rc=$?
echo "exit $rc: $(cat "$LAB/bad.out")"
check 'malformed owner refused' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'no brief written for malformed owner' no "$([ -e "$LAB/data/bad-owner/brief.md" ] && echo yes || echo no)"
echo "FAILS=${LAB_FAILS:-0}"
echo "LAB=$LAB"
