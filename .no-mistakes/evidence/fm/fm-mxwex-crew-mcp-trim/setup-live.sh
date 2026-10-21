#!/bin/bash
set -eu
ROOT=$PWD
BASE=$ROOT/.mcp-validation
LAB=$BASE/lab
export TMPDIR=$BASE/tmp
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$BASE/user" "$BASE/claude-config" "$BASE/project"
export HOME=$BASE/user CLAUDE_CONFIG_DIR=$BASE/claude-config
printf 'claude\n' > "$LAB/config/crew-harness"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'auto\n' > "$LAB/config/claude-permission-mode"
touch "$LAB/state/.last-watcher-beat"
git -C "$BASE/project" init -q -b main
printf 'lab project\n' > "$BASE/project/README.md"
printf 'root = "%s"\nmin_trees = 1\nmax_trees = 3\n' "$BASE/pool" > "$BASE/project/treehouse.toml"
git -C "$BASE/project" add README.md treehouse.toml
git -C "$BASE/project" -c user.name=Lab -c user.email=lab@example.invalid -c commit.gpgsign=false commit -qm 'Initialize disposable MCP validation project'
SOCKET_DIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
printf '%s\n' "$SOCKET_DIR" > "$BASE/socket-dir"
export TMUX_TMPDIR=$SOCKET_DIR
unset TMUX
# The helper owns the short private socket path. No default server is addressed.
tmux -L fm-lab -f /dev/null new-session -d -s primary -x 140 -y 45 -c "$ROOT" /bin/bash --noprofile --norc
tmux -L fm-lab set-option -g default-shell /bin/bash
tmux -L fm-lab set-option -g default-command '/bin/bash --noprofile --norc'
# Spawn commands inherit the socket from this disposable shell, never the operator's.
tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0' > "$BASE/tmux-env"
for id in trim-default trim-off trim-scout; do
  mkdir -p "$LAB/data/$id"
  printf '# Lab task\n## Captain\x27s intent\nValidate the launch. Do not modify files or use tools.\n## Firstmate spec\nReply with LAB_READY and stop.\n' > "$LAB/data/$id/brief.md"
done
