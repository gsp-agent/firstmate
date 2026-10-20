#!/usr/bin/env bash
set -eu
. "$1/bin/fm-secondmate-liveness-lib.sh"
fm_secondmate_liveness_lock sm1
fm_secondmate_liveness_probe "$FM_HOME/state/sm1.meta" sm1 poll
printf 'before: status=%s state=%s kill=%s
' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL"
[ "$FM_SM_LIVE_STATUS" = relaunchable ] && [ "$FM_SM_LIVE_KILL" = 1 ]
touch "$2/probed"
rc=0
fm_secondmate_liveness_relaunch "$FM_HOME/state/sm1.meta" sm1 "$3" || rc=$?
fm_secondmate_liveness_unlock sm1
printf 'after: rc=%s status=%s state=%s reason=%s
' "$rc" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_REASON"
touch "$2/finished"
