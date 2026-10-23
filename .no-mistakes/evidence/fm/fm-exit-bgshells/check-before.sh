#!/usr/bin/env bash
set -eu
export TMUX_TMPDIR=$(cat .nm-test-live/home/state/.fm-lab-tmux-dir)
export TMUX=$(tmux -L fm-lab display-message -p -t primary:fm-other '#{socket_path},#{pid},0')
. bin/fm-backend.sh
fm_backend_source tmux
. .nm-test-live/before-tmux.sh
echo 'PRE-FIX ROOT LOOKUP AGAINST THE SAME ABSENT TARGET'
roots=$(fm_backend_tmux_agent_root_pids primary:fm-live)
printf 'Pre-fix returned roots: [%s]\n' "$roots"
test -n "$roots"
for pid in $roots; do ps -p "$pid" -o pid=,pgid=,tpgid=,comm=; done
echo 'No signal or key was sent; this checks root discovery only.'
