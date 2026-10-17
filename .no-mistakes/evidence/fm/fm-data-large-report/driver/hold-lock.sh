#!/usr/bin/env bash
# Hold one task's meta lock from a separate live process until <flag>.release exists.
# Usage: hold-lock.sh <state> <id> <flag>
ROOT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M55K1VPQMVY2S65757P9E9Q4
. "$ROOT/bin/fm-wake-lib.sh" || exit 1
lock=$(fm_meta_lock_path "$1/$2.meta") || exit 1
fm_lock_try_acquire "$lock" || exit 1
: > "$3.ready"
while [ ! -e "$3.release" ]; do sleep 0.2; done
fm_lock_release "$lock"
