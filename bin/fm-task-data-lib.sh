#!/usr/bin/env bash
# Task-data cleanup runs only after teardown removes the task record, while its
# meta lock is still held. fm-task-data.py owns retention and recovery rules.
# Callers source fm-wake-lib.sh for the same locks spawn uses to publish records.

fm_task_data_cleanup() { # <data> <state> <id> <project> <pr>
  local data=$1 state=$2 id=$3 project=$4 pr=$5 helper candidate other lock rc=0
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-data.py"
  fm_task_id_path_safe "$id" || return 1
  [ ! -e "$state/$id.meta" ] && [ ! -L "$state/$id.meta" ] || return 1
  command -v python3 >/dev/null 2>&1 || {
    echo "warning: task data retained: python3 is unavailable" >&2
    return 1
  }
  # A concurrent teardown holds its own lock. Skip it instead of waiting on a
  # cycle of locks; only a later, different completed task expires a recovery.
  for candidate in "$data"/*/record/data-cleanup.json; do
    [ -f "$candidate" ] || continue
    if jq -e 'type == "object" and .version == 1 and .expired == true' "$candidate" >/dev/null 2>&1; then
      continue
    fi
    other=${candidate%/record/data-cleanup.json}
    other=${other##*/}
    [ "$other" != "$id" ] || continue
    fm_task_id_path_safe "$other" || continue
    lock=$(fm_meta_lock_path "$state/$other.meta") || continue
    fm_lock_try_acquire "$lock" || continue
    if [ ! -e "$state/$other.meta" ] && [ ! -L "$state/$other.meta" ]; then
      python3 "$helper" expire "$data" "$state" "$other" || rc=1
    fi
    fm_lock_release "$lock"
  done
  python3 "$helper" stage "$data" "$state" "$id" "$project" "$pr" || rc=1
  return "$rc"
}
