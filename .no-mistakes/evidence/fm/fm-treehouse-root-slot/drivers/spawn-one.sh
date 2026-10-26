#!/usr/bin/env bash
# spawn-one.sh <fm-root> <task-id> <project> <transcript> <rc-file>
# Runs inside the lab's tmux "primary" pane, exactly where a firstmate primary
# runs fm-spawn.sh: $TMUX names the lab's private socket, FM_HOME the lab home.
# The worker is a plain long-running shell command (a raw launch command), so
# no agent login, trust store or token is involved.
set -u -o pipefail
root=$1 id=$2 proj=$3 out=$4 rcfile=$5
mkdir -p "$FM_HOME/user-home"
start=$(date +%s)
HOME="$FM_HOME/user-home" CODEX_HOME='' \
  "$root/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'while :; do sleep 60; done'" --mode local-only --yolo off 2>&1 \
  | no-mistakes redact 2>/dev/null > "$out"
rc=${PIPESTATUS[0]}
printf 'exit=%s elapsed=%ss\n' "$rc" "$(( $(date +%s) - start ))" > "$rcfile"
