#!/usr/bin/env bash
# Hold one task meta lock with firstmate's own lock library until TERM, as a
# concurrent teardown would. Usage: hold-lock.sh <wt> <lockdir> <ready-file>
set -u
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-pr-lib.sh"
fm_lock_try_acquire "$2" || { echo "could not take $2" >&2; exit 1; }
trap 'fm_lock_release "$2"; exit 0' TERM
: > "$3"
sleep 600 &
wait
