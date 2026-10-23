#!/usr/bin/env bash
set -eu
export FM_HOME="$PWD/.nm-test-live/home"
export TMUX_TMPDIR=$(cat "$FM_HOME/state/.fm-lab-tmux-dir")
export TMUX=$(tmux -L fm-lab display-message -p -t primary:fm-live '#{socket_path},#{pid},0')
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$FM_HOME/data/live"
printf '# Disposable lifecycle validation\n' > "$FM_HOME/data/live/brief.md"
cat > "$FM_HOME/state/live.meta" <<EOF
window=primary:fm-live
endpoint_task_id=live
worktree=$PWD
project=$PWD
harness=claude
backend=tmux
kind=ship
mode=local-only
yolo=off
model=default
effort=default
EOF
echo 'REAL CLAUDE TERMINAL BEFORE EXIT'
tmux -L fm-lab capture-pane -p -t primary:fm-live
echo 'CHECKED ROOT DISCOVERY'
. bin/fm-backend.sh
fm_backend_source tmux
roots=$(fm_backend_tmux_agent_root_pids primary:fm-live)
test -n "$roots"
for pid in $roots; do ps -p "$pid" -o pid=,pgid=,tpgid=,comm=; done
echo 'MALFORMED AND ABSENT TARGETS'
for target in primary primary: :fm-live primary:fm-live:extra primary:nonexistent; do
  result=$(fm_backend_tmux_agent_root_pids "$target")
  test -z "$result"
  printf '%s -> no process roots\n' "$target"
done
echo 'EXIT AGAINST UNRECOGNIZED TRUST PROMPT'
set +e
FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=1 bin/fm-control.sh live exit
rc=$?
set -e
printf 'exit status=%s\n' "$rc"
test "$rc" -ne 0
for pid in $roots; do kill -0 "$pid"; done
echo 'ORIGINAL CLAUDE PROCESS REMAINS ALIVE'
echo 'REAL CLAUDE TERMINAL AFTER REFUSAL'
tmux -L fm-lab capture-pane -p -t primary:fm-live
