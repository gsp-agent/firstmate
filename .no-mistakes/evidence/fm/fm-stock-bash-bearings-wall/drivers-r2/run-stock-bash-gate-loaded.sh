#!/usr/bin/env bash
# Round 2: runs the real stock-macos-bash gate script from the run worktree at
# the machine's real load. The per-step wall is raised through the gate's own
# FM_STOCK_BASH_STEP_SECONDS knob (no code change) because symptom 1, the 900s
# wall at high load, is knowingly left for a follow-up; this run checks that
# the bearings suite reaches its full 62 count with no load-dependent
# activity-scan or registry failure. Output is scrubbed before it is written.
set -o pipefail
cd /Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5SW87YP0RGKBE86WKN1RSHF || exit 2
EVID=/Users/dalecarman/.no-mistakes/evidence/01M5SW87YP0RGKBE86WKN1RSHF
{
  printf 'commit: %s\n' "$(git rev-parse --short HEAD)"
  printf 'start: %s  load: %s\n' "$(date -u +%FT%TZ)" "$(sysctl -n vm.loadavg)"
  started=$(date +%s)
  FM_STOCK_BASH_STEP_SECONDS=5400 bin/fm-stock-bash-check.sh 2>&1
  rc=$?
  printf '\nexit: %s  elapsed: %ss  end: %s  load: %s\n' "$rc" "$(( $(date +%s) - started ))" "$(date -u +%FT%TZ)" "$(sysctl -n vm.loadavg)"
  exit "$rc"
} | no-mistakes redact > "$EVID/r2-stock-bash-gate-at-load.log"
