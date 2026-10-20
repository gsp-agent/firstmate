#!/usr/bin/env bash
set -eu
. ./bin/fm-wake-lib.sh
. ./bin/fm-pr-lib.sh
action=$1
id=$2
shift 2
lock=$(fm_meta_lock_path "$FM_HOME/state/$id.meta")
fm_lock_try_acquire "$lock"
trap 'fm_lock_release "$lock"' EXIT
if [ "$action" = mark ]; then
  python3 ./bin/fm-task-data.py mark "$FM_HOME/data" "$id" "$@"
elif [ "${LIVE_WITHOUT_DCG:-0}" = 1 ]; then
  python=$(command -v python3)
  PATH="$FM_HOME/no-tools" "$python" ./bin/fm-task-data.py "$action" "$FM_HOME/data" "$FM_HOME/state" "$id" "$@"
else
  python3 ./bin/fm-task-data.py "$action" "$FM_HOME/data" "$FM_HOME/state" "$id" "$@"
fi
