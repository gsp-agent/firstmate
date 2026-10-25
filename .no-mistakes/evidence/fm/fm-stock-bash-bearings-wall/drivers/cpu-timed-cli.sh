#!/bin/bash
# Exercises bin/fm-timeout-lib.sh fm_run_cpu_timed under stock /bin/bash.
set -u
W=/Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5SW87YP0RGKBE86WKN1RSHF
. "$W/bin/fm-timeout-lib.sh"
printf 'bash %s, load %s\n' "$BASH_VERSION" "$(sysctl -n vm.loadavg)"
try() {  # <label> <expected-rc> <cmd...>
  local label=$1 want=$2 rc=0 s=$SECONDS out
  shift 2
  out=$("$@" 2>&1) || rc=$?
  printf '%-58s rc=%-3s want=%-3s %2ss  out=%s  %s\n' "$label" "$rc" "$want" "$((SECONDS - s))" \
    "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-60)" "$([ "$rc" = "$want" ] && echo PASS || echo FAIL)"
}
try 'wait: sleep 3 under 1s CPU bound finishes'            0   fm_run_cpu_timed 1 sleep 3
try 'burn: busy loop under 1s CPU bound reports 124'       124 fm_run_cpu_timed 1 /bin/bash -c 'while :; do :; done'
try 'burn ignoring SIGXCPU, probe wall 30s (124 = probe, not CPU bound, stopped it)' 124 fm_run_timed 30 /Users/dalecarman/.no-mistakes/evidence/01M5SW87YP0RGKBE86WKN1RSHF/drivers/xcpu-ignoring-burn.sh
try 'own exit status 7 and output preserved'               7   fm_run_cpu_timed 1 /bin/bash -c 'echo kept; exit 7'
try 'bound 0 refused, nothing runs'                        125 fm_run_cpu_timed 0 /bin/bash -c 'echo RAN'
try 'bound "1.5" refused'                                  125 fm_run_cpu_timed 1.5 /bin/bash -c 'echo RAN'
try 'bound "-1" refused'                                   125 fm_run_cpu_timed -1 /bin/bash -c 'echo RAN'
try 'missing command refused'                              125 fm_run_cpu_timed 1
try 'child burn passed up by the command (exit $?) reports 124'  124 fm_run_cpu_timed 1 /bin/bash -c '/bin/bash -c "while :; do :; done"; exit $?'
rc=0; fm_run_cpu_timed 1 /bin/bash -c 'while :; do :; done' || rc=$?
fm_timed_out "$rc" && echo "fm_timed_out recognises rc=$rc from the CPU bound: PASS" || echo "fm_timed_out rejects rc=$rc: FAIL"
