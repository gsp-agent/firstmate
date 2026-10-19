#!/usr/bin/env bash
set -u
EVIDENCE_ROOT=/Users/dalecarman/.no-mistakes/evidence/01M5999CSVGBG7SM5134TYA5NC
# Keep the normal toolchain temp root. The shell-quoting fixture embeds its
# own marker pathname inside a Git ref, so hidden workspace components make
# that synthetic ref invalid before the branch command is exercised.
bin/fm-test-run.sh tests/fm-task-delivery.test.sh --per-script-timeout-secs 1500 --json "$EVIDENCE_ROOT/delivery-recheck.json" > "$EVIDENCE_ROOT/delivery-recheck.log" 2>&1
rc=$?
cat "$EVIDENCE_ROOT/delivery-recheck.log"
exit "$rc"
