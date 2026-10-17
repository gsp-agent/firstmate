#!/usr/bin/env bash
# refresh-timing.sh <rounds> <nm-delay-ms> <log> - alternate the old and new
# bin/fm-home-summary-refresh.sh (direct, no --best-effort, default 60 s bound,
# no FM_HOME_SUMMARY_TIMEOUT override) against the lab home, recording wall
# time, CPU, host load before/after, exit status and whether the ledger was
# republished with all 64 endpoints.
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK/lab-paths.env
E=/Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK
W=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5518WCKZCZZKKA1AW7FWEMK
rounds=$1 delay=$2 log=$3
ledger=$LAB/state/home-summary.json
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
unset FM_HOME_SUMMARY_TIMEOUT
r=1
while [ "$r" -le "$rounds" ]; do
  for ver in ${FM_LAB_VERS:-before after}; do
    case $ver in before) tree=$SCR/before ;; *) tree=$W ;; esac
    prev=$(jq -r '.generated_epoch // 0' "$ledger" 2>/dev/null || echo 0)
    l0=$(load1)
    start=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    FM_LAB_NM_DELAY_MS=$delay /usr/bin/time -p "$E/scripts/run-lab.sh" "$tree" fm-home-summary-refresh.sh \
      > "$SCR/refresh.out" 2> "$SCR/refresh.err"
    rc=$?
    end=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    l1=$(load1)
    cpu=$(awk '/^user/{u=$2} /^sys/{s=$2} END{printf "%.2f", u+s}' "$SCR/refresh.err")
    gen=$(jq -r '.generated_epoch // 0' "$ledger" 2>/dev/null || echo 0)
    eps=$(jq -r '.counts.endpoints // "none"' "$ledger" 2>/dev/null || echo none)
    if [ "$rc" -eq 0 ] && [ "$gen" != "$prev" ]; then pub=published; else pub=NOT-published; fi
    err=$(grep -v -E '^(real|user|sys) ' "$SCR/refresh.err" | tail -1 | cut -c1-160)
    printf 'round=%s ver=%-6s nm_delay_ms=%s wall=%6.2fs cpu=%6.2fs load1=%s->%s rc=%s %s endpoints=%s %s\n' \
      "$r" "$ver" "$delay" "$(echo "$end - $start" | bc)" "$cpu" "$l0" "$l1" "$rc" "$pub" "$eps" "${err:+err=\"$err\"}" | tee -a "$log"
  done
  r=$((r + 1))
done
