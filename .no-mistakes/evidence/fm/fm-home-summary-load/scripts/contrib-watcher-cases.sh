#!/usr/bin/env bash
# contrib-watcher-cases.sh <rounds> - run the two contribution watcher cases
# (5 s watcher waits in tests/fm-contributions.test.sh) alternately from the
# branch head and the original 433c7b85 tree, recording host load per run.
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK/lab-paths.env
E=/Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK
W=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5518WCKZCZZKKA1AW7FWEMK
rounds=${1:-2}
r=1
while [ "$r" -le "$rounds" ]; do
  for v in head base; do
    case $v in head) t=$W ;; *) t=$SCR/before ;; esac
    d="$SCR/contrib-watch-$v-$r"
    l0=$(sysctl -n vm.loadavg | awk '{print $2}')
    s=$SECONDS
    out=$("$E/scripts/run-one-contrib-test.sh" "$t" "$d" \
      test_watcher_keeps_diagnostics_separate_from_contribution_wakes \
      test_watcher_surfaces_new_contribution_once 2>&1)
    rc=$?
    printf 'round%s %s load1=%s rc=%s %ss\n' "$r" "$v" "$l0" "$rc" "$((SECONDS - s))"
    printf '%s\n' "$out" | grep -E '^(ok|not ok|FAILED)' | sed 's/^/    /'
  done
  r=$((r + 1))
done
