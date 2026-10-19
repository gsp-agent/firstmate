#!/usr/bin/env bash
# Run only the recorded hold-routing regressions and the actual Herdr delivery check.
set -u
ROOT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M592GW4AWJHJT4FZVF69FVG7
EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M592GW4AWJHJT4FZVF69FVG7
cd "$ROOT" || exit 1
export TMPDIR="$ROOT/.test-hold-validation/tmp"
failed=0
printf 'START real Herdr owner delivery with installed router\n'
python3 "$EVIDENCE/live-unicode-herdr-driver.py" > "$EVIDENCE/live-unicode-herdr.log" 2>&1
rc=$?
printf 'END real Herdr owner delivery exit=%s\n' "$rc"
tail -8 "$EVIDENCE/live-unicode-herdr.log"
[ "$rc" -eq 0 ] || failed=1
for selector in stranded-release live-home timing fairness; do
  printf 'START selector=%s\n' "$selector"
  started=$(date +%s)
  FM_TEST_HOLD_ROUTING_REGRESSION="$selector" bash tests/fm-captain-hold-lifecycle.test.sh > "$EVIDENCE/targeted-$selector.log" 2>&1
  rc=$?
  printf 'END selector=%s exit=%s duration_seconds=%s\n' "$selector" "$rc" "$(( $(date +%s) - started ))"
  cat "$EVIDENCE/targeted-$selector.log"
  [ "$rc" -eq 0 ] || failed=1
done
printf 'START same reason-breaks regression against pre-fix 2eb4c129 executable\n'
FM_TEST_HOLD_ROUTING_REGRESSION=reason-breaks bash "$ROOT/.test-hold-validation/before/tests/fm-captain-hold-lifecycle.test.sh" > "$EVIDENCE/reason-breaks-before-2eb4c129.log" 2>&1
rc=$?
cat "$EVIDENCE/reason-breaks-before-2eb4c129.log"
printf 'END pre-fix regression exit=%s (expected nonzero)\n' "$rc"
[ "$rc" -ne 0 ] || failed=1
exit "$failed"
