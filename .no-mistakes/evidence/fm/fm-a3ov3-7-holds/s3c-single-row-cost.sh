#!/usr/bin/env bash
# s3c: time single routing rows in the s3b live-home-scale lab at production bounds.
set -u
. "$(dirname "$0")/lab-lib.sh"
LAB=$1
cd "$WT" || exit 1
now_s() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
echo "lab home: $LAB   host: $(uptime | sed 's/.*load/load/')"
for id in ${ROWS:-human taste mixed}; do
  : > "$LAB/axi.log"
  s=$(now_s); out=$(hold_cli "$LAB" 2026-10-14T02:20:00Z route-due "$id" 2>&1); rc=$?; e=$(now_s)
  echo "route-due $id: exit $rc, wall $(echo "$e - $s" | bc)s, tasks-axi calls $(wc -l < "$LAB/axi.log" | tr -d ' ') ${out:+output: $out}"
done
s=$(now_s); python3 "$ROUTER" --help >/dev/null 2>&1; e=$(now_s); echo "router startup: $(echo "$e - $s" | bc)s"
echo "host at end: $(uptime | sed 's/.*load/load/')"
