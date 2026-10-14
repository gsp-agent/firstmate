#!/usr/bin/env bash

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
