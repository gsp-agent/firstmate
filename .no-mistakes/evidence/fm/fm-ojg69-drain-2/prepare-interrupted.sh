#!/usr/bin/env bash
set -eu
root=$1 home=$2 mode=$3 absent=$4
. "$root/bin/fm-wake-lib.sh"
. "$root/bin/fm-tasks-axi-lib.sh"
. "$root/bin/fm-backlog-transition-lib.sh"
lock=$(fm_meta_lock_path "$home/state/replay-r1.meta")
fm_lock_acquire_wait "$lock"
trap 'fm_lock_release "$lock"' EXIT
flags=()
[ "$mode" = close ] || flags=(--retain)
fm_backlog_close_marker_write "$home/state" replay-r1 "$home/data" live-replay "${flags[@]+"${flags[@]}"}" --note 'local main'
python3 "$root/bin/fm-task-data.py" prepare "$home/data" "$home/state" replay-r1
