#!/usr/bin/env bash
# The new test's three cases, each in its own process so a red in one does not hide
# the next, on the copy named by $1, then the reused-pid test. Prints one line per case.
set -u
copy=$1
for v in under-arm reparented orphaned-arm; do
  t0=$(date +%s)
  msg=$(bash -c '. "$1/tests/fm-supervision-host.test.sh"; suite_exit_stops_held_watcher "$2"; echo PASSED' _ "$copy" "$v" 2>&1 </dev/null)
  rc=$?
  printf '%s: exit %s in %ss: %s\n' "$v" "$rc" "$(($(date +%s) - t0))" "$(printf '%s\n' "$msg" | tail -1)"
done
msg=$(bash -c '. "$1/tests/fm-supervision-host.test.sh"; test_suite_exit_leaves_a_pid_reused_since_its_listing' _ "$copy" 2>&1 </dev/null)
printf 'reused-pid: exit %s: %s\n' "$?" "$(printf '%s\n' "$msg" | tail -1)"
