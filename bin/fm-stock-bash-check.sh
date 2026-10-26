#!/usr/bin/env bash
# fm-stock-bash-check.sh - the stock macOS Bash 3.2 compatibility check.
#
# Runs on a Mac before a Firstmate branch is pushed: the trusted
# .no-mistakes.yaml declares it as the `stock-macos-bash` gate after lint, so
# a red parks the run before any push or PR, and a maintainer runs it by hand
# with no arguments. It owns what the removed macos-stock-bash GitHub job ran;
# docs/configuration.md ("Gate defaults") owns why it runs locally.
#
# Under the host's own stock Bash (it must report 3.2.57), with a PATH that
# resolves `bash` to that interpreter before any newer one, it:
#   1. parses every canonical shell root (bin/fm-lint.sh --list-files with
#      CI=true, the full set) with `bash -n`;
#   2. runs each Bash 3.2 regression listed in fm_stock_bash_checks below and
#      requires its exact count of `ok - ` lines.
# It never runs ShellCheck. Each step runs under a wall-clock bound and a
# resident-memory cap on the step's whole process tree, both checked by a
# sampler twice a second; past either, the step is stopped and fails naming
# the cap. A hard wall at 6 times the idle bound (bin/fm-timeout-lib.sh's
# fm_exec_timed, which kills the step's process group) backs the sampler, so
# a step stops even if sampling stalls. macOS cannot enforce an address-space
# rlimit, so the memory cap is that sampler.
# Every step runs even after one fails, and the summary names each failure.
#
# Environment:
#   FM_STOCK_BASH_STEP_SECONDS  wall bound per step at idle load (default
#                               900). The effective wall for a step is this
#                               bound times the highest load factor (below)
#                               seen while the step runs, so a busy laptop
#                               stretches the wall instead of stopping a step
#                               that is only waiting for a core. A step that
#                               makes no progress at idle still stops at the
#                               idle bound.
#   FM_STOCK_BASH_RSS_KIB       process-tree RSS cap per step, in KiB
#                               (default 2097152 = 2 GiB)
#   FM_STOCK_BASH               interpreter under test (default /bin/bash)
#   FM_STOCK_BASH_LOAD_FACTOR   load factor override (positive integer,
#                               capped at 6); default: the 1-minute load
#                               average divided by the CPU count, rounded
#                               up, at least 1 and at most 6, re-read at
#                               each sample
#
# Exit status: 0 every step passed; 1 a step failed or hit a cap; 2 this host
# cannot run the check (no Bash 3.2.57 interpreter, or jq or tasks-axi
# missing), so the gate fails closed rather than passing unchecked.
#
# Usage:
#   fm-stock-bash-check.sh          run every step
#   fm-stock-bash-check.sh --help   print this usage
# shellcheck disable=SC2016 # each `bash -c` script expands its own variables
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-stock-bash-check.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

case "${1:-}" in
  -h | --help)
    sed -n '2,/--help   print this usage$/{s/^# \{0,1\}//;p;}' "$SELF"
    exit 0
    ;;
  '') ;;
  *)
    printf 'fm-stock-bash-check.sh: unknown argument: %s (see --help)\n' "$1" >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-timeout-lib.sh
. "$SELF_DIR/fm-timeout-lib.sh"

STOCK_BASH=${FM_STOCK_BASH:-/bin/bash}
STEP_SECONDS=${FM_STOCK_BASH_STEP_SECONDS:-900}
RSS_KIB=${FM_STOCK_BASH_RSS_KIB:-2097152}
GRACE_SECONDS=5
LOAD_FACTOR_MAX=6
for value in "$STEP_SECONDS" "$RSS_KIB"; do
  case "$value" in
    '' | 0* | *[!0-9]*)
      printf 'fm-stock-bash-check.sh: FM_STOCK_BASH_STEP_SECONDS and FM_STOCK_BASH_RSS_KIB must be positive integers\n' >&2
      exit 2
      ;;
  esac
done
case "${FM_STOCK_BASH_LOAD_FACTOR:-}" in
  '' | *[!0-9]* | 0*)
    [ -z "${FM_STOCK_BASH_LOAD_FACTOR:-}" ] || {
      printf 'fm-stock-bash-check.sh: FM_STOCK_BASH_LOAD_FACTOR must be a positive integer\n' >&2
      exit 2
    }
    ;;
esac

# Print the load factor: how many idle wall bounds one wall bound buys on
# this host right now. The 1-minute load average counts runnable work that
# is waiting for a core, which is the delay a wall bound must not mistake
# for a hang. Capped at LOAD_FACTOR_MAX so a wedged step still stops in
# bounded time on a busy host.
fm_stock_bash_load_factor() {
  local ncpu=1 load1=${FM_STOCK_BASH_LOAD_FACTOR:-}
  if [ -z "$load1" ]; then
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null) || ncpu=
    case "$ncpu" in '' | *[!0-9]* | 0) ncpu=1 ;; esac
    load1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1}') || load1=
  fi
  case "$load1" in '' | *[!0-9.]*)
    printf '1\n'
    return 0
    ;;
  esac
  awk -v load="$load1" -v ncpu="$ncpu" -v max="$LOAD_FACTOR_MAX" 'BEGIN {
    f = int(load / ncpu)
    if (load > f * ncpu) f++
    if (f < 1) f = 1
    if (f > max) f = max
    print f
  }'
}

fm_stock_bash_refuse() {
  printf 'fm-stock-bash-check.sh: cannot run here: %s\n' "$1" >&2
  exit 2
}

[ -x "$STOCK_BASH" ] || fm_stock_bash_refuse "$STOCK_BASH is not an executable Bash"
STOCK_VERSION=$("$STOCK_BASH" -c 'printf %s "$BASH_VERSION"' 2>/dev/null) || STOCK_VERSION=
case "$STOCK_VERSION" in
  3.2.57*) ;;
  *) fm_stock_bash_refuse "expected stock macOS Bash 3.2.57 at $STOCK_BASH, got '${STOCK_VERSION:-nothing}'" ;;
esac

# The tests resolve `bash`, jq, and tasks-axi through PATH, so the stock
# interpreter's directory leads and the tool directories follow every system
# directory: no newer bash can shadow the one under test.
fm_stock_bash_tool_dir() {  # <tool>
  local found
  found=$(command -v "$1" 2>/dev/null) || return 1
  case "$found" in
    /*) dirname "$found" ;;
    *) return 1 ;;
  esac
}
STOCK_PATH="$(dirname "$STOCK_BASH"):/bin:/usr/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
for tool in jq tasks-axi node; do
  tool_dir=$(fm_stock_bash_tool_dir "$tool") || {
    [ "$tool" = node ] && continue
    fm_stock_bash_refuse "$tool is required on PATH"
  }
  case ":$STOCK_PATH:" in
    *":$tool_dir:"*) ;;
    *) STOCK_PATH="$STOCK_PATH:$tool_dir" ;;
  esac
done
resolved_bash=$(PATH=$STOCK_PATH command -v bash) || resolved_bash=
[ "$resolved_bash" = "$STOCK_BASH" ] \
  || fm_stock_bash_refuse "PATH resolves bash to '${resolved_bash:-nothing}', not $STOCK_BASH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-stock-bash.XXXXXX") || fm_stock_bash_refuse "mktemp failed"
trap 'rm -rf "${WORK:?}"' EXIT

# Print the summed RSS in KiB of <pid> and every process descended from it.
# A failed process list is a failure: awk's status used to hide it, and a
# denied ps then looked like a tree of 0 KiB (.agent-config-nd9sk).
fm_stock_bash_tree_rss_kib() {  # <pid>
  local listing
  listing=$(ps -A -o pid= -o ppid= -o rss=) || return 1
  printf '%s\n' "$listing" | awk -v root="$1" '
    { parent[$1] = $2; rss[$1] = $3 }
    END {
      total = 0
      for (p in parent) {
        q = p
        for (depth = 0; depth < 64 && q != root && (q in parent); depth++) q = parent[q]
        if (q == root) total += rss[p]
      }
      print total + 0
    }'
}

FAILURES=
fm_stock_bash_fail() {  # <step> <reason>
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAILURES="$FAILURES$1: $2
"
}

# Run one step's command under the wall bound and the tree RSS cap, with its
# combined output in <log>. Each sample re-reads the load factor and grows
# STEP_LOAD_FACTOR, never shrinking it, so the wall is the idle bound times
# the highest factor seen. Sets STEP_STATUS, STEP_LOAD_FACTOR, and STEP_CAP
# (time, memory, unmeasured, or empty) and prints the step's duration, load
# factor, and peak tree RSS.
fm_stock_bash_run_bounded() {  # <step> <log> <command...>
  local step=$1 log=$2 pid rss peak=0 started factor
  shift 2
  STEP_CAP=
  STEP_LOAD_FACTOR=$(fm_stock_bash_load_factor)
  started=$(date +%s)
  (cd "$ROOT" && fm_exec_timed "$((STEP_SECONDS * LOAD_FACTOR_MAX))" "$GRACE_SECONDS" env PATH="$STOCK_PATH" "$@") >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ! rss=$(fm_stock_bash_tree_rss_kib "$pid"); then
      STEP_CAP='unmeasured'
      kill -TERM "$pid" 2>/dev/null
      break
    fi
    [ "$rss" -le "$peak" ] || peak=$rss
    if [ "$rss" -gt "$RSS_KIB" ]; then
      STEP_CAP='memory'
      kill -TERM "$pid" 2>/dev/null
      break
    fi
    factor=$(fm_stock_bash_load_factor)
    [ "$factor" -le "$STEP_LOAD_FACTOR" ] || STEP_LOAD_FACTOR=$factor
    if [ $(($(date +%s) - started)) -gt $((STEP_SECONDS * STEP_LOAD_FACTOR)) ]; then
      STEP_CAP='time'
      kill -TERM "$pid" 2>/dev/null
      break
    fi
    sleep 0.5
  done
  wait "$pid"
  STEP_STATUS=$?
  if [ -z "$STEP_CAP" ] && fm_timed_out "$STEP_STATUS"; then
    STEP_CAP='time'
    STEP_LOAD_FACTOR=$LOAD_FACTOR_MAX
  fi
  printf '%s: %ss, load factor %s, peak tree RSS %s KiB\n' \
    "$step" "$(($(date +%s) - started))" "$STEP_LOAD_FACTOR" "$peak"
}

fm_stock_bash_cap_reason() {
  case "$STEP_CAP" in
    time)
      printf 'stopped at the %ss wall bound (load factor %s times %ss at idle load)' \
        "$((STEP_SECONDS * STEP_LOAD_FACTOR))" "$STEP_LOAD_FACTOR" "$STEP_SECONDS"
      ;;
    memory) printf 'stopped at the %s KiB process-tree memory cap' "$RSS_KIB" ;;
    unmeasured) printf 'process list could not be read, so the %s KiB tree cap was not enforced' "$RSS_KIB" ;;
  esac
}

fm_stock_bash_parse_sweep() {
  local inventory="$WORK/shell-inventory" log="$WORK/parse.log" count
  (cd "$ROOT" && CI=true PATH="$STOCK_PATH" "$STOCK_BASH" bin/fm-lint.sh --list-files) >"$inventory" 2>"$WORK/list.err" || {
    cat "$WORK/list.err"
    fm_stock_bash_fail parse-sweep "bin/fm-lint.sh --list-files failed"
    return
  }
  count=$(grep -c . "$inventory")
  [ "$count" -gt 0 ] || {
    fm_stock_bash_fail parse-sweep "bin/fm-lint.sh --list-files printed no files"
    return
  }
  fm_stock_bash_run_bounded parse-sweep "$log" "$STOCK_BASH" -c '
    status=0
    while IFS= read -r f; do
      "$0" -n "$f" || { printf "stock Bash failed to parse %s\n" "$f"; status=1; }
    done < "$1"
    exit "$status"
  ' "$STOCK_BASH" "$inventory"
  cat "$log"
  if [ -n "$STEP_CAP" ]; then
    fm_stock_bash_fail parse-sweep "$(fm_stock_bash_cap_reason)"
  elif [ "$STEP_STATUS" -ne 0 ]; then
    fm_stock_bash_fail parse-sweep "stock Bash $STOCK_VERSION failed to parse a shell file (above)"
  else
    printf 'ok - parse-sweep: %s files parse under stock Bash %s\n' "$count" "$STOCK_VERSION"
  fi
}

# Run one regression script under stock Bash and require exactly <count>
# `ok - ` lines. Extra NAME=value arguments go into its environment.
fm_stock_bash_suite() {  # <step> <count> <tests/script> [NAME=value...]
  local step=$1 want=$2 script=$3 log got
  shift 3
  log="$WORK/$step.log"
  fm_stock_bash_run_bounded "$step" "$log" "$@" "$STOCK_BASH" "$script"
  cat "$log"
  got=$(grep -c '^ok - ' "$log")
  if [ -n "$STEP_CAP" ]; then
    fm_stock_bash_fail "$step" "$(fm_stock_bash_cap_reason)"
  elif [ "$STEP_STATUS" -ne 0 ] || [ "$got" -ne "$want" ]; then
    fm_stock_bash_fail "$step" "expected $want passing tests from $script, got $got (exit $STEP_STATUS)"
  fi
}

# The Bash 3.2 regressions and their exact passing counts. A suite that
# changes its count changes it here, and in tests/fm-stock-bash-check.test.sh's
# fixture, in the same commit.
fm_stock_bash_checks() {
  fm_stock_bash_suite snapshot-view 19 tests/fm-fleet-snapshot-view.test.sh
  fm_stock_bash_suite bearings 62 tests/fm-bearings-snapshot.test.sh
  # The full public-followup and watch-triage suites are not stock-Bash
  # snapshots; FM_TEST_ONLY runs only their Bash 3.2 empty-array regressions.
  fm_stock_bash_suite public-followup-empty-lock 1 tests/fm-public-followup.test.sh \
    FM_TEST_ONLY=test_first_register_succeeds_with_empty_lock_list_under_bash32
  fm_stock_bash_suite watch-churn-deferral 1 tests/fm-watch-triage.test.sh \
    FM_TEST_ONLY=test_turn_ended_churn_existing_marker_absorbed
  # Bash 3.2 has no printf %(...)T clock, so the helpers' date fallback runs.
  fm_stock_bash_suite fork-free-helpers 16 tests/fm-fork-free-helpers.test.sh
  fm_stock_bash_suite backend-adapter-file 2 tests/fm-backend.test.sh \
    FM_TEST_ONLY=test_backend_source_requires_adapter_file FM_TEST_BASH="$STOCK_BASH"
}

printf 'fm-stock-bash-check.sh: %s (Bash %s); per step: %ss wall at idle load, grown with load up to %s times, %s KiB tree RSS\n' \
  "$STOCK_BASH" "$STOCK_VERSION" "$STEP_SECONDS" "$LOAD_FACTOR_MAX" "$RSS_KIB"
fm_stock_bash_parse_sweep
fm_stock_bash_checks

if [ -n "$FAILURES" ]; then
  printf '\nfm-stock-bash-check.sh: stock Bash %s check FAILED:\n%s' "$STOCK_VERSION" "$FAILURES" >&2
  exit 1
fi
printf '\nfm-stock-bash-check.sh: every stock Bash %s check passed\n' "$STOCK_VERSION"
