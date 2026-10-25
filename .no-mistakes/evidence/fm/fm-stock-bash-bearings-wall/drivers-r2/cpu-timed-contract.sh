#!/bin/bash
# Round 2: drives fm_run_cpu_timed's public contract under stock /bin/bash.
# Each case runs under an outer 120s wall (fm_run_timed) so a hang shows as
# rc=124 from the guard with ~120s elapsed instead of stalling the probe.
set -u
LIB=/Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5SW87YP0RGKBE86WKN1RSHF/bin/fm-timeout-lib.sh
# shellcheck disable=SC1090
. "$LIB"
printf 'bash=%s load=%s\n' "$BASH_VERSION" "$(sysctl -n vm.loadavg)"
case_run() {  # <name> <command...>
  local name=$1 started rc=0 out
  shift
  started=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
  out=$("$@" 2>&1) || rc=$?
  printf '%-44s rc=%s wall=%ss out=%s\n' "$name" "$rc" \
    "$(perl -MTime::HiRes=time -e 'printf "%.1f", time - $ARGV[0]' "$started")" "$(printf '%s' "$out" | tr '\n' ' ')"
}
inner='. "$1"; shift; rc=0; fm_run_cpu_timed "$@" || rc=$?; echo "inner_rc=$rc"'
case_run 'wait 3s under 1s CPU bound' fm_run_timed 120 /bin/bash -c "$inner" x "$LIB" 1 sleep 3
case_run 'burn under 1s CPU bound' fm_run_timed 120 /bin/bash -c "$inner" x "$LIB" 1 /bin/bash -c 'while :; do :; done'
case_run 'burn, launcher ignores SIGXCPU' fm_run_timed 120 perl -e '$SIG{XCPU} = "IGNORE"; exec @ARGV' /bin/bash -c "$inner" x "$LIB" 1 /bin/bash -c 'while :; do :; done'
case_run 'child sees SIGXCPU disposition (ignored launcher)' fm_run_timed 120 perl -e '$SIG{XCPU} = "IGNORE"; exec @ARGV' /bin/bash -c "$inner" x "$LIB" 1 perl -e 'print defined $SIG{XCPU} ? $SIG{XCPU} : "DEFAULT"'
case_run 'real status 7 and output pass through' fm_run_timed 120 /bin/bash -c "$inner" x "$LIB" 1 /bin/bash -c 'echo kept; exit 7'
case_run 'bound 0 refused' fm_run_timed 120 /bin/bash -c "$inner" x "$LIB" 0 true
case_run 'bound abc refused' fm_run_timed 120 /bin/bash -c "$inner" x "$LIB" abc true
case_run 'missing command refused' fm_run_timed 120 /bin/bash -c "$inner" x "$LIB" 1
noperl=$(mktemp -d "${TMPDIR:-/tmp}/fm-r2-noperl.XXXXXX")
ln -s /bin/bash "$noperl/bash"
case_run 'no perl on PATH: runs nothing' fm_run_timed 120 env PATH="$noperl" /bin/bash -c "$inner" x "$LIB" 1 /bin/bash -c 'echo RAN'
rm -f "${noperl:?}/bash"; rmdir "${noperl:?}"
case_run 'fm_timed_out accepts 124' /bin/bash -c '. "$1"; fm_timed_out 124 && echo yes' x "$LIB"
