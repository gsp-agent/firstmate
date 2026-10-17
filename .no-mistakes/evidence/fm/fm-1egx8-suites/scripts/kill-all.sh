#!/usr/bin/env bash
# Wait until the chain's short alone runs are done, then drive each stop mode.
set -u
EV=/Users/dalecarman/.no-mistakes/evidence/01M55Y5XKTJTJD73274HVHFNG1
until grep -q '^TMPDIR' "$EV/fm-host-mirror/summary.txt" 2>/dev/null; do sleep 2; done
echo "kill scenarios start $(date -u +%FT%TZ) (overlapping the fm-watch-triage alone run)"
for mode in KILL-runner KILL-runner-gated TERM-group INT-group; do
  bash "$EV/scripts/kill-real.sh" "$mode"
  echo "=========="
done
echo "kill scenarios end $(date -u +%FT%TZ)"
