#!/usr/bin/env bash
set -eu
export FM_HOME="$PWD/.nm-test-live/home"
export TMUX_TMPDIR=$(cat "$FM_HOME/state/.fm-lab-tmux-dir")
export TMUX=$(tmux -L fm-lab display-message -p -t primary:fm-live '#{socket_path},#{pid},0')
. bin/fm-backend.sh
fm_backend_source tmux
echo 'TARGET DISAPPEARS AFTER WINDOW INVENTORY'
echo 'The private tmux after-list-windows hook renames primary:fm-live to fm-other.'
roots=$(fm_backend_tmux_agent_root_pids primary:fm-live)
printf 'Returned roots: [%s]\n' "$roots"
test -z "$roots"
tmux -L fm-lab set-hook -gu after-list-windows
echo 'ACTUAL WINDOW IDENTITY AFTER RACE'
tmux -L fm-lab list-windows -t primary -F '#{session_name}:#{window_name} #{pane_tty} #{pane_current_command}'
echo 'RAW TMUX RESOLUTION OF NOW-ABSENT TARGET'
tmux -L fm-lab display-message -p -t primary:fm-live '#{session_name}:#{window_name} #{pane_tty}' || true
echo 'LIVE CLAUDE REMAINS AT THE SAME TRUST PROMPT'
tmux -L fm-lab capture-pane -p -t primary:fm-other
