. "$1/bin/fm-wake-lib.sh"
fm_lock_acquire_wait "$FM_HOME/state/.home-summary-refresh.lock"
: > "$FM_HOME/state/lock-held"
exec sleep 120
