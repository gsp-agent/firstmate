#!/usr/bin/env bash
set -u
code=$1
action=$2
lab=$3
id=$4
shift 4
. "$code/bin/fm-wake-lib.sh"
lock=$(fm_meta_lock_path "$lab/state/$id.meta") || exit 1
fm_lock_try_acquire "$lock" || exit 1
trap 'fm_lock_release "$lock"' EXIT
helper=${TASK_DATA_HELPER:-$code/bin/fm-task-data.py}
if [ -n "${TASK_DATA_CHILD_PATH:-}" ]; then
  env "PATH=$TASK_DATA_CHILD_PATH" python3 "$helper" "$action" "$lab/data" "$lab/state" "$id" "$@"
else
  python3 "$helper" "$action" "$lab/data" "$lab/state" "$id" "$@"
fi
