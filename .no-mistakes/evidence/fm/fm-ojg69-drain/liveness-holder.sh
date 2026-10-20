#!/usr/bin/env bash
set -eu
. "$1/bin/fm-wake-lib.sh"
fm_lock_try_acquire "$STATE/.secondmate-relaunch.lock"
touch "$2"
IFS= read -r release
fm_lock_release "$STATE/.secondmate-relaunch.lock"
