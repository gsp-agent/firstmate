#!/usr/bin/env bash
# Reproduce the report through the real runner: bin/fm-test-run.sh runs a script that
# goes red with a watcher still starting. Then watch the watcher for 60 s, as the bead did.
# usage: runner-red.sh <copy> <variant> [delays...]
set -u
copy=$1
variant=$2
shift 2
drivers=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PROBE_OUT=$(mktemp -d "$copy/.probe-out.XXXXXX")
export PROBE_OUT
export PROBE_VARIANT=$variant
cd "$copy" || exit 2
bin/fm-test-run.sh tests/zz-probe-held.test.sh </dev/null > "$PROBE_OUT/runner.log" 2>&1
rc=$?
printf 'runner exit: %s\n' "$rc"
cat "$PROBE_OUT/held-state" 2>/dev/null
printf -- '--- runner output lines from the suite (wrapper and tee alive through the cleanup):\n'
grep -E 'probe:|not ok|^ok ' "$PROBE_OUT/runner.log"
grep -E '^(FM_TEST_END|FM_TEST_SUMMARY|FAIL|PASS)' "$PROBE_OUT/runner.log" | sed 's#/.*/tests/#tests/#' | tail -3
printf -- '--- after the runner returned:\n'
bash "$drivers/check-survivors.sh" "$PROBE_OUT" "${@:-0 10 60}"
printf 'survivor check exit: %s\n' "$?"
