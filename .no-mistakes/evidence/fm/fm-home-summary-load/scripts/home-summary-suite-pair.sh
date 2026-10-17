#!/usr/bin/env bash
# home-summary-suite-pair.sh <rounds> - run tests/fm-home-summary-refresh.test.sh
# from the original 433c7b85 tree and from the branch head back to back, so the
# pre-existing stale-lock check is judged on both under the same host load.
# Records load before each run, the exit status, and every not-ok line.
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK/lab-paths.env
W=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5518WCKZCZZKKA1AW7FWEMK
rounds=${1:-1}
r=1
while [ "$r" -le "$rounds" ]; do
  for v in base head; do
    case $v in head) t=$W ;; *) t=$SCR/before ;; esac
    l0=$(sysctl -n vm.loadavg | awk '{print $2}')
    s=$SECONDS
    out=$(bash "$t/tests/fm-home-summary-refresh.test.sh" 2>&1)
    rc=$?
    printf 'round%s %s load1=%s->%s rc=%s %ss ok=%s\n' "$r" "$v" "$l0" \
      "$(sysctl -n vm.loadavg | awk '{print $2}')" "$rc" "$((SECONDS - s))" \
      "$(printf '%s\n' "$out" | grep -c '^ok - ')"
    printf '%s\n' "$out" | grep -E '^not ok' | sed 's/^/    /'
  done
  r=$((r + 1))
done
