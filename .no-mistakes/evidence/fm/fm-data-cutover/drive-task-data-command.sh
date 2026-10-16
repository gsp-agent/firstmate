#!/usr/bin/env bash
# Execute the public cleanup interfaces with the same per-task lock as retirement.
set -euo pipefail
code_root=$1
data_root=$2
state_root=$3
task_id=$4
shift 4
. "$code_root/bin/fm-wake-lib.sh"
. "$code_root/bin/fm-pr-lib.sh"
task_lock=$(fm_meta_lock_path "$state_root/$task_id.meta")
fm_lock_try_acquire "$task_lock"
trap 'fm_lock_release "$task_lock"' EXIT
if [ "$1" = cycle ]; then
  shift
  . "$code_root/bin/fm-task-data-lib.sh"
  fm_task_data_cleanup "$data_root" "$state_root" "$task_id" "$1" "$2"
else
  helper=$1
  action=$2
  shift 2
  python3 "$helper" "$action" "$data_root" "$state_root" "$task_id" "$@"
fi
