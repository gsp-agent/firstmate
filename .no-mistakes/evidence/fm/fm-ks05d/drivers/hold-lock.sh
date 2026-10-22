#!/usr/bin/env bash
set -u
. "$1/bin/fm-wake-lib.sh"
fm_lock_acquire_wait "$FM_HOME/state/.home-summary-refresh.lock"
: > "$FM_HOME/state/lock-ready"
sleep 60
