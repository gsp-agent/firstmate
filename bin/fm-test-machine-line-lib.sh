#!/usr/bin/env bash
# Shared machine-line admission for fm-test-run.sh and fm-test-isolation-proof.sh.
# Source after setting RUN_STARTED_ISO and RUN_STARTED_MS; the caller supplies die.
# Call enter_machine_line <absolute-runner-path> [original-args...] only after
# inspection modes and pre-execution refusals have returned.
#
# An executing suite uses ~/.agent-state/machine-gate.sh when it is executable,
# or the exact FM_TEST_MACHINE_GATE value when that variable is set. A missing
# or non-executable gate, including an empty override, leaves execution unchanged.
# The gate's run command holds the machine line around a re-execution of the
# absolute runner for the whole suite, with a fixed 180-minute cap.
# A gate exit of 75 is retried only when the child never recorded admission;
# admitted suite failures propagate without retry. Retries wait 15 seconds by
# default; FM_TEST_MACHINE_LINE_RETRY_SECS accepts whole nonnegative seconds.
# MACHINE_LINE_NAME overrides the log label; otherwise it is the runner basename
# without .sh, with FM_TASK_ID appended when present.
#
# FM_TEST_MACHINE_LINE_HELD is an internal nonempty marker inherited by the
# admitted child and nested suites so they do not acquire the line again.
# FM_TEST_MACHINE_LINE_ADMITTED names the private marker written by the child.
# FM_TEST_MACHINE_LINE_STARTED_ISO and FM_TEST_MACHINE_LINE_STARTED_MS preserve
# the invocation's original start across re-execution, so timing and the runner's
# wall-clock budget include admission waits. They are consumed and unset here
# so a nested invocation measures its own start rather than the parent's wait.
# tests/fm-test-run.test.sh covers admission, release, cross-entry-point exclusion,
# relative launch paths, and invocation timing.

MACHINE_LINE_CAP_MINUTES=180
MACHINE_LINE_RETRY_SECS=15

RUN_STARTED_ISO=${FM_TEST_MACHINE_LINE_STARTED_ISO:-$RUN_STARTED_ISO}
RUN_STARTED_MS=${FM_TEST_MACHINE_LINE_STARTED_MS:-$RUN_STARTED_MS}
unset FM_TEST_MACHINE_LINE_STARTED_ISO FM_TEST_MACHINE_LINE_STARTED_MS

enter_machine_line() {
  local runner=$1
  shift

  if [ -n "${FM_TEST_MACHINE_LINE_HELD:-}" ]; then
    if [ -n "${FM_TEST_MACHINE_LINE_ADMITTED:-}" ]; then
      : >"$FM_TEST_MACHINE_LINE_ADMITTED" \
        || die "could not record machine-line admission"
    fi
    return 0
  fi

  local gate retry admitted rc line_name
  if [ "${FM_TEST_MACHINE_GATE+x}" = x ]; then
    gate=$FM_TEST_MACHINE_GATE
  else
    gate=${HOME}/.agent-state/machine-gate.sh
  fi
  if [ ! -x "$gate" ]; then
    return 0
  fi

  retry=${FM_TEST_MACHINE_LINE_RETRY_SECS:-$MACHINE_LINE_RETRY_SECS}
  case "$retry" in
    ''|*[!0-9]*) die "FM_TEST_MACHINE_LINE_RETRY_SECS must be whole seconds" ;;
  esac

  line_name=${MACHINE_LINE_NAME:-}
  if [ -z "$line_name" ]; then
    line_name=$(basename "$runner" .sh)
    if [ -n "${FM_TASK_ID:-}" ]; then
      line_name="${line_name}-${FM_TASK_ID}"
    fi
  fi

  admitted=$(mktemp "${TMPDIR:-/tmp}/fm-test-machine-line.XXXXXX") \
    || die "could not create machine-line admission marker"
  rm -f "$admitted"

  while :; do
    set +e
    FM_TEST_MACHINE_LINE_HELD=1 \
      FM_TEST_MACHINE_LINE_ADMITTED="$admitted" \
      FM_TEST_MACHINE_LINE_STARTED_ISO="$RUN_STARTED_ISO" \
      FM_TEST_MACHINE_LINE_STARTED_MS="$RUN_STARTED_MS" \
      MACHINE_LINE_NAME="$line_name" \
      bash "$gate" run --cap "$MACHINE_LINE_CAP_MINUTES" -- "$runner" "$@"
    rc=$?
    set -e
    if [ -e "$admitted" ]; then
      rm -f "$admitted"
      exit "$rc"
    fi
    if [ "$rc" -ne 75 ]; then
      rm -f "$admitted"
      exit "$rc"
    fi
    sleep "$retry"
  done
}
