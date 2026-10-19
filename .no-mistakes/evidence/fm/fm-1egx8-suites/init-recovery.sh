#!/usr/bin/env bash
set -eu
. "$1/bin/fm-wake-lib.sh"
fm_recovery_marker_publish "$STATE/.watcher-down" downtime
fm_recovery_marker_read "$STATE/.watcher-down"
fm_recovery_marker_ack "$STATE/.watcher-down" "${FM_RECOVERY_MARKER_TOKEN##*:}"
