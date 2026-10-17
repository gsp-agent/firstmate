#!/usr/bin/env bash
# locked-helper.sh <root> <lab> <action> <id> [args...]
# Runs bin/fm-task-data.py while holding STATE/.meta-ID.lock (the helper's
# documented caller contract, the same lock spawn and teardown use).
set -u
root=$1 lab=$2 action=$3 id=$4
shift 4
. "$root/bin/fm-wake-lib.sh"
lock=$(fm_meta_lock_path "$lab/state/$id.meta") || exit 1
fm_lock_acquire_wait "$lock" || exit 1
trap 'fm_lock_release "$lock"' EXIT
python3 "$root/bin/fm-task-data.py" "$action" "$lab/data" "$lab/state" "$id" "$@"
