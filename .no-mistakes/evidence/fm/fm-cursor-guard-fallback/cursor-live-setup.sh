#!/usr/bin/env bash
set -euo pipefail
ROOT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4X1BTKBTAA2TSWVPH5VM2TK
EV=/Users/dalecarman/.no-mistakes/evidence/01M4X1BTKBTAA2TSWVPH5VM2TK
cd "$ROOT"
LAB=$(mktemp -d "$ROOT/.fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
SOCKET_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
printf '%s\n' "$LAB" > "$EV/lab-home.path"
printf '%s\n' "$SOCKET_DIR" > "$EV/lab-socket.path"
mkdir -p "$LAB/tmux" "$LAB/usage" "$LAB/grok" "$LAB/cursor"
printf 'cursor_models_pct=12\n' > "$LAB/usage/current-spending.txt"
printf 'tmux\n' > "$LAB/config/backend"
printf 'cursor\n' > "$LAB/config/crew-harness"
printf 'manual\n' > "$LAB/config/backlog-backend"
touch "$LAB/config/supervision-host-off"
cat > "$LAB/config/launch-env-allowlist" <<'LIST'
FM_CURSOR_USAGE_DIR
FM_CURSOR_DAY
FM_CURSOR_CLI_CONFIG
FM_CURSOR_MODELS_RULE
GROK_HOME
LIST
for k in "${!FM_@}"; do case "$k" in *_OVERRIDE) unset "$k";; esac; done
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$LAB" TMUX_TMPDIR="$SOCKET_DIR"
export FM_CURSOR_USAGE_DIR="$LAB/usage" FM_CURSOR_CLI_CONFIG="$LAB/cursor/cli-config.json" FM_CURSOR_MODELS_RULE="$LAB/cursor/models.mdc"
export GROK_HOME="$LAB/grok"
# The normal installed Cursor CLI is the lab primary. No mock binary or login.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab -f /dev/null new-session -d -s primary -x 120 -y 40 -c "$ROOT" -e FM_HOME="$LAB" cursor-agent
tmux -L fm-lab set-option -g default-shell /bin/bash
tmux -L fm-lab set-option -g remain-on-exit on
tmux -L fm-lab set-option -g automatic-rename off
for k in FM_CURSOR_USAGE_DIR FM_CURSOR_CLI_CONFIG FM_CURSOR_MODELS_RULE GROK_HOME; do
  tmux -L fm-lab set-environment -g "$k" "${!k}"
done
# A real shell in the same private server runs the real control interface.
tmux -L fm-lab new-window -d -t primary: -n driver -c "$ROOT" "/bin/bash '$EV/cursor-live-driver.sh' '$LAB' '$EV'"
printf 'Lab created: %s\nPrivate socket: %s\n' "$LAB" "$SOCKET_DIR"
