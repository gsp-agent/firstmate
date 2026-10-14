#!/usr/bin/env bash
LAB=$1
EV=$2
exec > "$EV/live-fresh-transcript.log" 2>&1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
export FM_HOME="$LAB" GROK_HOME="$LAB/grok" TREEHOUSE_ROOT="$LAB/treehouse" FM_CURSOR_USAGE_DIR="$LAB/usage"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
id=lab-implicit
mkdir -p "$LAB/data/$id"
printf 'cursor_models_pct=85\n' > "$LAB/usage/current-spending.txt"
tmux set-environment -g TREEHOUSE_ROOT "$LAB/treehouse"
bin/fm-spawn.sh "$id" "$LAB/project-lab-explicit-normal" --mode local-only --yolo off
printf 'Implicit spawn exit=%s\n' "$?"
cat "$LAB/state/$id.meta" "$LAB/state/$id.cursor-fallback"
printf done > "$EV/live-fresh.done"
