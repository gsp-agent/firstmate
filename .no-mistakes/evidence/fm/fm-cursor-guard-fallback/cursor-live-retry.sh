#!/usr/bin/env bash
set -uo pipefail
LAB=$1
EV=$2
ROOT=$PWD
exec > "$EV/live-retry-transcript.log" 2>&1
export FM_HOME="$LAB" GROK_HOME="$LAB/grok"
export FM_CURSOR_USAGE_DIR="$LAB/usage" FM_CURSOR_CLI_CONFIG="$LAB/cursor/cli-config.json" FM_CURSOR_MODELS_RULE="$LAB/cursor/models.mdc"
export FM_CONTROL_LAUNCH_WAIT=45 FM_CONTROL_EXIT_WAIT=30
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
printf 'FM_HOME\nFM_CURSOR_USAGE_DIR\nFM_CURSOR_DAY\nFM_CURSOR_CLI_CONFIG\nFM_CURSOR_MODELS_RULE\n' > "$LAB/config/launch-env-allowlist"
tmux send-keys -t primary:fm-lab-cap-normal -l 'unsent-live-validation-text'
FM_CURSOR_DAY=2026-10-15 bin/fm-control.sh lab-cap-normal relaunch --note 'Emit LIVE_REPLAY_retry only. No tools or project work.'
printf 'Pending relaunch exit=%s; expected refusal\n' "$?"
cat "$LAB/state/lab-cap-normal.cursor-limit"
sed -n 's/^harness=/Recorded harness: /p' "$LAB/state/lab-cap-normal.meta"
tmux send-keys -t primary:fm-lab-cap-normal C-u
FM_CURSOR_DAY=2026-10-15 bin/fm-control.sh lab-cap-normal relaunch --note 'Emit LIVE_REPLAY_retry only. No tools or project work.'
printf 'Retry exit=%s\n' "$?"
cat "$LAB/state/lab-cap-normal.meta" "$LAB/state/lab-cap-normal.control-relaunch"
if [ -f "$LAB/state/lab-cap-normal.cursor-limit" ]; then cat "$LAB/state/lab-cap-normal.cursor-limit"; else printf 'Expired reason retired after Cursor publication\n'; fi
printf done > "$EV/live-retry.done"
