#!/bin/bash
# Runs bearings tests 25-62 (those the real gate's 900s wall cut off) under stock Bash, no wall.
set -o pipefail
W=/Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5SW87YP0RGKBE86WKN1RSHF
EVID=/Users/dalecarman/.no-mistakes/evidence/01M5SW87YP0RGKBE86WKN1RSHF
s=$(date +%s)
"$EVID/drivers/run-bearings-tests.sh" "$W" "$W/tests/fm-bearings-snapshot.test.sh" \
  $(awk '/^test_[A-Za-z0-9_]*$/' "$W/tests/fm-bearings-snapshot.test.sh" | sed -n '25,62p') 2>&1 \
  | no-mistakes redact 2>/dev/null > "$EVID/bearings-tests-25-62-stock-bash.log"
rc=$?
printf 'driver exit %s, %ss wall\n' "$rc" "$(( $(date +%s) - s ))" >> "$EVID/bearings-tests-25-62-stock-bash.log"
exit "$rc"
