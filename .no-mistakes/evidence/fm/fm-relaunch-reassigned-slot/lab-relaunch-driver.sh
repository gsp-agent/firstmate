#!/usr/bin/env bash
# Live lab driver for the reassigned-slot relaunch refusal (PR 176).
# Drives the real bin/fm-control.sh, bin/fm-spawn.sh and the merge-outcome
# writer against a disposable marked lab home and a real tmux server on a
# private socket directory. Never touches the operator's FM_HOME, pool, or
# default tmux server.
#
# Usage: lab-relaunch-driver.sh <repo-worktree> <lab-dir> <phase>
#   phase: setup | merge-line | refuse | own-claim | stop
set -u
REPO=$1
LAB=$2
PHASE=$3
cd "$REPO" || exit 1

TMUXD=$(bin/fm-lab-home.sh tmux-dir "$LAB" 2>/dev/null || true)
OTHER=gsp-p35kr-2-lab
URL=https://github.com/example/repo/pull/80

labtmux() { env TMUX_TMPDIR="$TMUXD" tmux "$@"; }

# Every product call runs with the lab home, the lab tmux, and an isolated
# HOME/CLAUDE_CONFIG_DIR so trust registration and harness state stay in $LAB.
labrun() {
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    FM_HOME="$LAB" TMUX_TMPDIR="$TMUXD" HOME="$LAB/user-home" \
    CLAUDE_CONFIG_DIR="$LAB/claude-config" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_LAUNCH_WAIT="${FM_CONTROL_LAUNCH_WAIT:-180}" "$@"
}

write_task() {  # <id> <slot-n>
  local id=$1 n=$2 wt="$LAB/pool/demo-$2/demo"
  mkdir -p "$LAB/data/$id"
  cat > "$LAB/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Lab fixture for relaunch slot-claim validation ($id).

## Firstmate spec
Do nothing; this worker exists only to prove relaunch behavior.
EOF
  {
    echo "window=fmlab:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$LAB/projects/demo"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "pr=$URL$n"
  } > "$LAB/state/$id.meta"
}

case "$PHASE" in
  setup)
    bin/fm-lab-home.sh create "$LAB" || exit 1
    TMUXD=$(bin/fm-lab-home.sh tmux-dir "$LAB") || exit 1
    mkdir -p "$LAB/user-home" "$LAB/claude-config" "$LAB/pool"
    git init -q -b main "$LAB/projects/demo"
    git -C "$LAB/projects/demo" -c user.name=lab -c user.email=lab@example.invalid \
      commit -q --allow-empty -m init
    for spec in nmlab-other:3 nmlab-own:4 nmlab-absent:5; do
      id=${spec%%:*}; n=${spec#*:}
      mkdir -p "$LAB/pool/demo-$n"
      git -C "$LAB/projects/demo" worktree add -q -b "fm/$id" "$LAB/pool/demo-$n/demo"
      write_task "$id" "$n"
    done
    # Slot 3 was handed to another task, whose spawn rewrote the claim.
    printf 'task=%s\nhome=%s\n' "$OTHER" "$LAB" > "$LAB/pool/demo-3/.fm-slot-owner"
    # Slot 4 still carries its own task's claim; slot 5 predates claims.
    printf 'task=%s\nhome=%s\n' nmlab-own "$LAB" > "$LAB/pool/demo-4/.fm-slot-owner"
    # Dead endpoints: each window holds a plain shell, no agent (worker exited).
    labtmux new-session -d -s fmlab -n fm-nmlab-other -c "$LAB/pool/demo-3/demo" \
      env HOME="$LAB/user-home" CLAUDE_CONFIG_DIR="$LAB/claude-config" /bin/bash --noprofile --norc
    for spec in nmlab-own:4 nmlab-absent:5; do
      id=${spec%%:*}; n=${spec#*:}
      labtmux new-window -d -t fmlab -n "fm-$id" -c "$LAB/pool/demo-$n/demo" \
        env HOME="$LAB/user-home" CLAUDE_CONFIG_DIR="$LAB/claude-config" /bin/bash --noprofile --norc
    done
    echo "lab home: marked=$([ -f "$LAB/.fm-lab-home" ] && echo yes || echo no)"
    echo "--- tmux windows (lab socket) ---"
    labtmux list-windows -t fmlab -F '#{window_name} cmd=#{pane_current_command}'
    echo "--- slot claims ---"
    for n in 3 4 5; do
      printf 'slot demo-%s: ' "$n"
      if [ -f "$LAB/pool/demo-$n/.fm-slot-owner" ]; then
        sed -n 's/^task=//p' "$LAB/pool/demo-$n/.fm-slot-owner"
      else
        echo '(no claim)'
      fi
    done
    ;;

  merge-line)
    for id in nmlab-other nmlab-own nmlab-absent; do
      n=$(sed -n 's#^worktree=.*/demo-\([0-9]*\)/demo$#\1#p' "$LAB/state/$id.meta")
      # A fresh live-PM registration owned by this driver process.
      printf 'bead=lab-acceptance\npid=%s\ntask=%s\n' "$$" "$id" > "$LAB/state/.pm-live-$id"
      printf 'done: PR ready for merge\n' > "$LAB/state/$id.status"
      rc=0
      labrun bash -c '
        . "$1/bin/fm-merge-outcome-lib.sh"
        fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" "$2" "$3" poll' \
        _ "$REPO" "$id" "$URL$n" || rc=$?
      echo "=== $id (slot demo-$n) merge-outcome rc=$rc; endpoint verdict from real tmux: $(labrun bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "fmlab:fm-$2"' _ "$REPO" "$id")"
      echo "status line: $(tail -n 1 "$LAB/state/$id.status")"
    done
    ;;

  refuse)
    id=nmlab-other
    cp -p "$LAB/data/$id/brief.md" "$LAB/brief-before"
    cp -p "$LAB/state/$id.meta" "$LAB/meta-before"
    echo "=== bin/fm-control.sh $id relaunch --note 'Merged; activation pending' (slot claimed by $OTHER)"
    rc=0; out=$(labrun bin/fm-control.sh "$id" relaunch --note 'Merged; activation pending' 2>&1) || rc=$?
    printf '%s\n' "$out"; echo "exit=$rc"
    cmp -s "$LAB/brief-before" "$LAB/data/$id/brief.md" && echo "brief: unchanged (no progress note appended)" || echo "brief: CHANGED"
    cmp -s "$LAB/meta-before" "$LAB/state/$id.meta" && echo "task record: unchanged" || echo "task record: CHANGED"
    [ -e "$LAB/state/$id.control-relaunch" ] && echo "relaunch journal: PRESENT" || echo "relaunch journal: absent"
    echo "endpoint now runs: $(labtmux display-message -p -t "fmlab:fm-$id" '#{pane_current_command}')"
    echo "--- pane fmlab:fm-$id after refusal (nothing typed) ---"
    labtmux capture-pane -p -t "fmlab:fm-$id" | sed '/^$/d'
    echo "--- end pane ---"
    echo
    echo "=== bin/fm-spawn.sh $id --relaunch (direct caller, slot claimed by $OTHER)"
    rc=0; out=$(labrun bin/fm-spawn.sh "$id" --relaunch 2>&1) || rc=$?
    printf '%s\n' "$out"; echo "exit=$rc"
    cmp -s "$LAB/meta-before" "$LAB/state/$id.meta" && echo "task record: unchanged" || echo "task record: CHANGED"
    echo "endpoint now runs: $(labtmux display-message -p -t "fmlab:fm-$id" '#{pane_current_command}')"
    labtmux capture-pane -p -t "fmlab:fm-$id" | sed '/^$/d' | head -5
    echo "--- end pane ---"
    ;;

  own-claim)
    id=${4:-nmlab-own}
    echo "=== bin/fm-control.sh $id relaunch --note 'Merged; activation pending' (slot claim: $(sed -n 's/^task=//p' "$(dirname "$(sed -n 's/^worktree=//p' "$LAB/state/$id.meta")")/.fm-slot-owner" 2>/dev/null || echo none))"
    rc=0; out=$(labrun bin/fm-control.sh "$id" relaunch --note 'Merged; activation pending' 2>&1) || rc=$?
    printf '%s\n' "$out"; echo "exit=$rc"
    echo "journal phase: $(sed -n 's/^phase=//p' "$LAB/state/$id.control-relaunch" 2>/dev/null | tail -1)"
    echo "endpoint now runs: $(labtmux display-message -p -t "fmlab:fm-$id" '#{pane_current_command}')"
    echo "brief tail: $(tail -n 3 "$LAB/data/$id/brief.md" | tr '\n' ' ')"
    ;;

  stop)
    labtmux kill-server 2>/dev/null || true
    bin/fm-lab-home.sh teardown "$LAB" || true
    echo "lab tmux server stopped"
    ;;
esac
