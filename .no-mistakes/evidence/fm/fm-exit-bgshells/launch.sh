#!/usr/bin/env bash
set -eu
LAB="$PWD/.nm-test-live/home"
SOCKET_DIR=$(cat "$LAB/state/.fm-lab-tmux-dir")
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
 TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab new-session -d -s primary -n fm-live -x 140 -y 42 -c "$PWD" -e FM_HOME="$LAB" -e CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
 claude --setting-sources '' --settings '{"disableAllHooks":true}'
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab set-window-option -t primary:fm-live remain-on-exit on
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab display-message -p -t primary:fm-live '#{session_name}:#{window_name} #{pane_tty} #{pane_width}x#{pane_height}'
