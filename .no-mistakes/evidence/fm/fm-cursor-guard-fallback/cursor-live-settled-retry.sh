#!/usr/bin/env bash
LAB=$1
EV=$2
exec > "$EV/live-settled-retry.log" 2>&1
export FM_HOME="$LAB" GROK_HOME="$LAB/grok" FM_CURSOR_USAGE_DIR="$LAB/usage"
export FM_CURSOR_CLI_CONFIG="$LAB/cursor/cli-config.json" FM_CURSOR_MODELS_RULE="$LAB/cursor/models.mdc"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
printf '{"cursor_fallback":{"models_pct":85,"max_age_h":26}}\n' > "$LAB/config/crew-dispatch.json"
printf 'cursor_models_pct=12\n' > "$LAB/usage/current-spending.txt"
FM_CURSOR_DAY=2026-10-15 bin/fm-control.sh lab-cap-normal relaunch --note 'Reply only LIVE_REPLAY_settled_retry. Do no tools or project work.'
printf 'Settled-composer retry exit=%s\n' "$?"
cat "$LAB/state/lab-cap-normal.control-relaunch"
if [ -f "$LAB/state/lab-cap-normal.cursor-limit" ]; then cat "$LAB/state/lab-cap-normal.cursor-limit"; else printf 'Expired reason retired after Cursor publication\n'; fi
printf done > "$EV/live-settled-retry.done"
