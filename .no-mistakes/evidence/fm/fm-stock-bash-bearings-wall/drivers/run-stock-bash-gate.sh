#!/usr/bin/env bash
# Runs the real stock-macos-bash gate script from the run worktree, scrubbed.
set -o pipefail
cd /Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5SW87YP0RGKBE86WKN1RSHF || exit 2
EVID=/Users/dalecarman/.no-mistakes/evidence/01M5SW87YP0RGKBE86WKN1RSHF
{
  printf 'start: %s  load: %s\n' "$(date -u +%FT%TZ)" "$(sysctl -n vm.loadavg)"
  started=$(date +%s)
  bin/fm-stock-bash-check.sh 2>&1
  rc=$?
  printf '\nexit: %s  elapsed: %ss  end: %s  load: %s\n' "$rc" "$(( $(date +%s) - started ))" "$(date -u +%FT%TZ)" "$(sysctl -n vm.loadavg)"
  exit "$rc"
} | no-mistakes redact > "$EVID/stock-bash-gate.log"
