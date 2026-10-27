#!/usr/bin/env bash
# Live lab driver for fm/fm-relaunch-reassigned-slot at head 8d3f66b3.
#
# Disposable firstmate lab home (bin/fm-lab-home.sh), a real git project whose
# worktrees are laid out as Treehouse pool slots (<pool>/<n>/repo, claim at
# <pool>/<n>/.fm-slot-owner), and a real tmux server on the lab's private
# socket dir holding each task's endpoint. The worker harness is the machine's
# real `claude` CLI under a throwaway HOME, so a launched worker stops at the
# first-run theme picker and does no work. Drives the real entrypoints:
#   bin/fm-control.sh <id> relaunch, bin/fm-spawn.sh <id> --relaunch, and
#   fm_merge_outcome_report (what bin/fm-watch.sh calls on a merged poll).
#
# Usage: lab-driver.sh <run-worktree> <phase>
set -u
REPO=${1:?run worktree}
PHASE=${2:?phase}
cd "$REPO" || exit 1
LABROOT_FILE=${LABROOT_FILE:-/tmp/fm-relaunch-slot-lab-01M5YH3W.root}

say() { printf '\n=== %s\n' "$*"; }
check() {  # <ok?> <message>
  if [ "$1" = 0 ]; then echo "PASS: $2"; else echo "FAIL: $2"; fi
}

if [ "$PHASE" = setup ]; then
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
  ROOT=$(cd "$ROOT" && pwd -P)
  printf '%s\n' "$ROOT" > "$LABROOT_FILE"
fi
ROOT=$(cat "$LABROOT_FILE") || exit 1
LAB="$ROOT/home"
POOL="$ROOT/pool"
PROJ="$ROOT/groove-sight-platform"
UHOME="$ROOT/user-home"
SOCK=
[ "$PHASE" = setup ] || SOCK=$(bin/fm-lab-home.sh tmux-dir "$LAB") || exit 1

lab_env() {
  env -u TMUX -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u FM_GATE_REFUSE_BYPASS \
    -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    HOME="$UHOME" FM_HOME="$LAB" TMUX_TMPDIR="$SOCK" FM_SPAWN_NO_GUARD=1 "$@"
}
ltmux() { TMUX_TMPDIR="$SOCK" tmux "$@"; }
pane_cmd() { ltmux display-message -p -t "fmlab:fm-$1" '#{pane_current_command}' 2>/dev/null; }
claim_of() { tr '\n' ' ' < "$POOL/$1/.fm-slot-owner" 2>/dev/null || echo '(no claim file)'; }

new_window() {  # <id> <cwd>
  if ltmux has-session -t fmlab 2>/dev/null; then
    ltmux new-window -d -t fmlab -n "fm-$1" -c "$2"
  else
    env -u TMUX -u CLAUDE_CONFIG_DIR HOME="$UHOME" TMUX_TMPDIR="$SOCK" \
      tmux new-session -d -s fmlab -n "fm-$1" -x 200 -y 50 -c "$2"
  fi
}

add_task() {  # <id> <slot> <claim: other-id | self | absent>
  local id=$1 slot=$2 claim=$3 wt="$POOL/$2/repo"
  mkdir -p "$POOL/$slot"
  git -C "$PROJ" worktree add --quiet -b "fm/$id" "$wt" || exit 1
  mkdir -p "$LAB/data/$id"
  cat > "$LAB/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Lab probe for relaunch slot claims. Do nothing: make no tool calls and no file changes.

## Firstmate spec
Reply "lab probe idle" and stop.
EOF
  {
    echo "window=fmlab:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$PROJ"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$ROOT/tasktmp-$id"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=g1"
    echo "pr=https://github.com/example/groove-sight-platform/pull/$slot"
  } > "$LAB/state/$id.meta"
  printf 'done: PR ready for merge\n' > "$LAB/state/$id.status"
  case "$claim" in
    absent) ;;
    self) printf 'task=%s\nhome=%s\n' "$id" "$LAB" > "$POOL/$slot/.fm-slot-owner" ;;
    *) printf 'task=%s\nhome=%s\n' "$claim" "$LAB" > "$POOL/$slot/.fm-slot-owner" ;;
  esac
  new_window "$id" "$wt"
}

add_secondmate() {  # <id> <slot> <marker-id> <stale-claim-id>
  local id=$1 slot=$2 marker=$3 claim=$4 smh="$POOL/$2/repo"
  mkdir -p "$POOL/$slot"
  git -C "$PROJ" worktree add --quiet -b "sm/$id" "$smh" || exit 1
  mkdir -p "$smh/state" "$smh/data" "$smh/bin" "$LAB/data/$id"
  printf '# agents\n' > "$smh/AGENTS.md"
  printf '%s\n' "$marker" > "$smh/.fm-secondmate-home"
  printf '# secondmate brief\nLab probe. Do nothing.\n' > "$LAB/data/$id/brief.md"
  printf 'task=%s\nhome=%s\n' "$claim" "$LAB" > "$POOL/$slot/.fm-slot-owner"
  {
    echo "window=fmlab:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smh"
    echo "project=$smh"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smh"
    echo "projects="
  } > "$LAB/state/$id.meta"
  new_window "$id" "$smh"
}

snapshot() {  # <id> <tag>
  local id=$1 tag=$2
  cp -p "$LAB/state/$id.meta" "$ROOT/$id.meta.$tag"
  cp -p "$LAB/data/$id/brief.md" "$ROOT/$id.brief.$tag"
  ltmux capture-pane -p -t "fmlab:fm-$id" > "$ROOT/$id.pane.$tag"
  for f in control-relaunch control-relaunch.note; do
    [ ! -e "$LAB/state/$id.$f" ] || cp -p "$LAB/state/$id.$f" "$ROOT/$id.$f.$tag"
  done
}

unchanged() {  # <id> <tag>
  local id=$1 tag=$2
  cmp -s "$ROOT/$id.meta.$tag" "$LAB/state/$id.meta"; check $? "$id task record unchanged"
  cmp -s "$ROOT/$id.brief.$tag" "$LAB/data/$id/brief.md"; check $? "$id brief unchanged (no progress note appended)"
  for f in control-relaunch control-relaunch.note; do
    if [ -e "$ROOT/$id.$f.$tag" ]; then
      cmp -s "$ROOT/$id.$f.$tag" "$LAB/state/$id.$f"; check $? "$id's prior $f file (from an earlier completed relaunch) unchanged"
    else
      [ ! -e "$LAB/state/$id.$f" ]; check $? "$id has no $f file"
    fi
  done
  ltmux capture-pane -p -t "fmlab:fm-$id" > "$ROOT/$id.pane.after-$tag"
  cmp -s "$ROOT/$id.pane.$tag" "$ROOT/$id.pane.after-$tag"; check $? "nothing typed into $id's endpoint pane"
}

run_and_show() {  # <label> <cmd...>
  local label=$1 out rc; shift
  say "$label"
  out=$(lab_env "$@" 2>&1); rc=$?
  printf '%s\n' "$out"
  echo "exit code: $rc"
  LAST_OUT=$out LAST_RC=$rc
}

case "$PHASE" in
  setup)
    bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
    SOCK=$(bin/fm-lab-home.sh tmux-dir "$LAB") || exit 1
    mkdir -p "$UHOME"
    : > "$UHOME/.zshrc"; : > "$UHOME/.zshenv"
    printf 'claude\n' > "$LAB/config/secondmate-harness"
    git init --quiet -b main "$PROJ" || exit 1
    printf 'lab\n' > "$PROJ/README.md"
    git -C "$PROJ" add README.md
    git -C "$PROJ" -c user.name=lab -c user.email=lab@example.invalid commit --quiet -m init || exit 1
    # gsp-dc9j6: its slot 3 was handed to gsp-p35kr-2, whose spawn rewrote the claim.
    add_task gsp-dc9j6 3 gsp-p35kr-2
    printf 'gsp-p35kr-2 in-progress work\n' > "$POOL/3/repo/p35kr-work.txt"
    add_task own-1 4 self       # slot still claimed by its own task
    add_task pre-1 5 absent     # slot taken before claims existed
    add_task alias-1 6 gsp-other-6  # recorded via a symlinked path (adversarial)
    ln -s "$POOL/6" "$ROOT/slot6-alias"
    sed -i '' "s#^worktree=.*#worktree=$ROOT/slot6-alias/repo#" "$LAB/state/alias-1.meta"
    add_task near-1 7 near-1-2  # claimant id merely extends this task's id (adversarial)
    add_secondmate sm-own 8 sm-own fm-old-ship-8
    add_secondmate sm-bad 9 someone-else fm-old-ship-9
    add_secondmate sm-spawn 10 sm-spawn fm-old-ship-10
    sleep 2
    say "lab root: $ROOT"
    echo "lab home marker present: $([ -f "$LAB/.fm-lab-home" ] && echo yes || echo no)"
    say "slot claims"
    for s in 3 4 5 6 7 8 9 10; do printf 'slot %s claim: %s\n' "$s" "$(claim_of "$s")"; done
    echo "alias-1 recorded worktree: $(sed -n 's/^worktree=//p' "$LAB/state/alias-1.meta")"
    say "tmux endpoints (private lab socket, not the default server)"
    ltmux list-windows -t fmlab -F '#{session_name}:#{window_name} cmd=#{pane_current_command} cwd=#{pane_current_path}'
    ;;
  refuse-dead)
    id=gsp-dc9j6
    snapshot "$id" s1
    git -C "$POOL/3/repo" status --porcelain > "$ROOT/git-before"
    cp -p "$POOL/3/.fm-slot-owner" "$ROOT/claim-before"
    echo "endpoint before: $(pane_cmd "$id") (agent-free shell); slot 3 claim: $(claim_of 3)"
    run_and_show "S1 bin/fm-control.sh $id relaunch --note 'Merged; activation and live verification remain pending'" \
      bin/fm-control.sh "$id" relaunch --note 'Merged; activation and live verification remain pending'
    [ "$LAST_RC" = 1 ]; check $? "fm-control relaunch exits 1"
    case "$LAST_OUT" in *"claimed by task gsp-p35kr-2; refusing to relaunch into a reassigned slot"*) check 0 "refusal names the claimant gsp-p35kr-2 and the reason" ;; *) check 1 "refusal names the claimant gsp-p35kr-2 and the reason" ;; esac
    case "$LAST_OUT" in *"preserved at"*|*"was stopped"*) check 1 "no 'stopped'/'preserved at' rollback message pointing into the other task's copy" ;; *) check 0 "no 'stopped'/'preserved at' rollback message pointing into the other task's copy" ;; esac
    unchanged "$id" s1
    run_and_show "S2 bin/fm-spawn.sh $id --relaunch (direct launch-owner caller)" bin/fm-spawn.sh "$id" --relaunch
    [ "$LAST_RC" = 1 ]; check $? "fm-spawn --relaunch exits 1"
    case "$LAST_OUT" in *"claimed by task gsp-p35kr-2; refusing to relaunch into a reassigned slot"*) check 0 "fm-spawn refusal names claimant and reason" ;; *) check 1 "fm-spawn refusal names claimant and reason" ;; esac
    unchanged "$id" s1
    echo "endpoint after: $(pane_cmd "$id"); windows: $(ltmux list-windows -t fmlab -F '#{window_name}' | tr '\n' ' ')"
    cmp -s "$ROOT/claim-before" "$POOL/3/.fm-slot-owner"; check $? "slot 3 claim still names $(sed -n 's/^task=//p' "$POOL/3/.fm-slot-owner")"
    git -C "$POOL/3/repo" status --porcelain > "$ROOT/git-after"
    cmp -s "$ROOT/git-before" "$ROOT/git-after"; check $? "gsp-p35kr-2's copy untouched ($(tr '\n' ' ' < "$ROOT/git-after"))"
    [ ! -e "$POOL/3/repo/.claude" ]; check $? "no harness trust/config dropped into gsp-p35kr-2's copy"
    ;;
  adversarial)
    for id in alias-1 near-1; do
      snapshot "$id" adv
      wt=$(sed -n 's/^worktree=//p' "$LAB/state/$id.meta")
      echo "$id recorded worktree: $wt; claim beside its real slot: $(claim_of "$([ "$id" = alias-1 ] && echo 6 || echo 7)")"
      run_and_show "bin/fm-control.sh $id relaunch --note 'probe'" bin/fm-control.sh "$id" relaunch --note probe
      [ "$LAST_RC" = 1 ]; check $? "$id relaunch exits 1"
      case "$LAST_OUT" in *"refusing to relaunch into a reassigned slot"*) check 0 "$id refusal is the reassigned-slot refusal" ;; *) check 1 "$id refusal is the reassigned-slot refusal" ;; esac
      unchanged "$id" adv
    done
    ;;
  merge-tmux)
    for id in gsp-dc9j6 own-1 pre-1; do
      printf 'bead=lab-acceptance\npid=%s\ntask=%s\n' "$$" "$id" > "$LAB/state/.pm-live-$id"
      url=$(sed -n 's/^pr=//p' "$LAB/state/$id.meta")
      slot=$(basename "$(dirname "$(sed -n 's/^worktree=//p' "$LAB/state/$id.meta")")")
      say "merge outcome for $id ($url); endpoint $(pane_cmd "$id"); claim: $(claim_of "$slot")"
      (
        unset TMUX CLAUDE_CONFIG_DIR CODEX_HOME HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
        export HOME="$UHOME" FM_HOME="$LAB" TMUX_TMPDIR="$SOCK"
        # shellcheck source=/dev/null
        . bin/fm-merge-outcome-lib.sh
        fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" "$id" "$url" poll 2>&1
        echo "fm_merge_outcome_report exit: $?"
      )
      line=$(tail -n 1 "$LAB/state/$id.status")
      echo "PM status line:"; printf '%s\n' "$line"
      if [ "$id" = gsp-dc9j6 ]; then
        case "$line" in *"bin/fm-control.sh $id relaunch"*) check 1 "line does not recommend bin/fm-control.sh $id relaunch" ;; *) check 0 "line does not recommend bin/fm-control.sh $id relaunch" ;; esac
        case "$line" in *"claimed by task gsp-p35kr-2"*) check 0 "line names claimant gsp-p35kr-2" ;; *) check 1 "line names claimant gsp-p35kr-2" ;; esac
      else
        case "$line" in *"relaunch it with bin/fm-control.sh $id relaunch --note"*) check 0 "line still recommends relaunch for $id" ;; *) check 1 "line still recommends relaunch for $id" ;; esac
      fi
    done
    ;;
  merge-herdr)
    session=${3:?herdr lab session}
    for pair in gsp-dc9j6:other own-1:self pre-1:absent; do
      src=${pair%%:*}; id="h-$src"
      slot=$(basename "$(dirname "$(sed -n 's/^worktree=//p' "$LAB/state/$src.meta")")")
      # A record's pr= line must stay last (fm_pr_metadata_identity_parse), so
      # backend=herdr goes in before it.
      {
        sed -e "s#^window=.*#window=$session:w1-1#" -e "s#^endpoint_task_id=.*#endpoint_task_id=$id#" \
          -e '/^pr=/d' "$LAB/state/$src.meta"
        printf 'backend=herdr\n'
        printf 'pr=https://github.com/example/groove-sight-platform/pull/9%s\n' "$slot"
      } > "$LAB/state/$id.meta.tmp" && mv -f "$LAB/state/$id.meta.tmp" "$LAB/state/$id.meta"
      # Same slot, so the claim beside it is the one the tmux case read.
      [ "$src" != gsp-dc9j6 ] || true
      printf 'done: PR ready for merge\n' > "$LAB/state/$id.status"
      printf 'bead=lab-acceptance\npid=%s\ntask=%s\n' "$$" "$id" > "$LAB/state/.pm-live-$id"
      url=$(sed -n 's/^pr=//p' "$LAB/state/$id.meta")
      say "herdr merge outcome for $id (window $session:w1-1, server stopped); claim: $(claim_of "$slot")"
      if [ "$src" = own-1 ]; then
        # own-1's slot was reassigned in the alive-refusal scenario; restore its own claim for this case.
        printf 'task=%s\nhome=%s\n' "$id" "$LAB" > "$POOL/$slot/.fm-slot-owner"
        echo "slot $slot claim set to this record: $(claim_of "$slot")"
      fi
      (
        unset TMUX CLAUDE_CONFIG_DIR CODEX_HOME HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
        # Herdr finds its named lab session's socket under the normal HOME; no
        # harness launches in this phase, so nothing writes user config.
        export FM_HOME="$LAB" TMUX_TMPDIR="$SOCK"
        # shellcheck source=/dev/null
        . bin/fm-backend.sh
        echo "fm_backend_agent_state herdr $session:w1-1 -> $(fm_backend_agent_state herdr "$session:w1-1")"
        # shellcheck source=/dev/null
        . bin/fm-merge-outcome-lib.sh
        fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" "$id" "$url" poll 2>&1
        echo "fm_merge_outcome_report exit: $?"
      )
      line=$(tail -n 1 "$LAB/state/$id.status")
      echo "PM status line:"; printf '%s\n' "$line"
      if [ "$src" = gsp-dc9j6 ]; then
        case "$line" in *"bin/fm-control.sh $id relaunch"*) check 1 "line does not recommend relaunch for $id" ;; *) check 0 "line does not recommend relaunch for $id" ;; esac
        case "$line" in *"claimed by task gsp-p35kr-2"*) check 0 "line names claimant gsp-p35kr-2" ;; *) check 1 "line names claimant gsp-p35kr-2" ;; esac
      else
        case "$line" in *"relaunch it with bin/fm-control.sh $id relaunch --note"*) check 0 "line still recommends relaunch for $id" ;; *) check 1 "line still recommends relaunch for $id" ;; esac
      fi
    done
    ;;
  compat-own)
    id=own-1
    echo "endpoint before: $(pane_cmd "$id"); slot 4 claim: $(claim_of 4)"
    run_and_show "S4 bin/fm-control.sh $id relaunch --note 'own slot; resume'" \
      env FM_CONTROL_LAUNCH_WAIT=90 bin/fm-control.sh "$id" relaunch --note 'own slot; resume'
    [ "$LAST_RC" = 0 ]; check $? "own-claim relaunch exits 0"
    case "$LAST_OUT" in *"relaunched $id harness=claude"*) check 0 "own-claim relaunch reports relaunched" ;; *) check 1 "own-claim relaunch reports relaunched" ;; esac
    sleep 3
    echo "endpoint after: $(pane_cmd "$id")"
    echo "spawn_gen now: $(sed -n 's/^spawn_gen=//p' "$LAB/state/$id.meta")"
    echo "pane (last non-blank lines):"
    ltmux capture-pane -p -t "fmlab:fm-$id" | grep -v '^[[:space:]]*$' | tail -n 8 | cut -c1-120
    ;;
  compat-absent)
    id=pre-1
    echo "endpoint before: $(pane_cmd "$id"); slot 5 claim: $(claim_of 5)"
    run_and_show "S5 bin/fm-spawn.sh $id --relaunch (no claim file)" bin/fm-spawn.sh "$id" --relaunch
    [ "$LAST_RC" = 0 ]; check $? "absent-claim relaunch exits 0"
    case "$LAST_OUT" in *"spawned $id"*) check 0 "absent-claim relaunch reports spawned" ;; *) check 1 "absent-claim relaunch reports spawned" ;; esac
    sleep 3
    echo "endpoint after: $(pane_cmd "$id")"
    echo "pane (last non-blank lines):"
    ltmux capture-pane -p -t "fmlab:fm-$id" | grep -v '^[[:space:]]*$' | tail -n 8 | cut -c1-120
    ;;
  refuse-alive)
    id=own-1
    printf 'task=%s\nhome=%s\n' gsp-other-9 "$LAB" > "$POOL/4/.fm-slot-owner"
    snapshot "$id" alive2
    echo "endpoint before: $(pane_cmd "$id") (real Claude Code running); slot 4 claim now: $(claim_of 4)"
    run_and_show "S3 bin/fm-control.sh $id relaunch --note 'reassigned while alive'" \
      bin/fm-control.sh "$id" relaunch --note 'reassigned while alive'
    [ "$LAST_RC" = 1 ]; check $? "alive-endpoint relaunch into a reassigned slot exits 1"
    case "$LAST_OUT" in *"claimed by task gsp-other-9; refusing to relaunch into a reassigned slot"*) check 0 "refusal names claimant gsp-other-9" ;; *) check 1 "refusal names claimant gsp-other-9" ;; esac
    sleep 2
    unchanged "$id" alive2
    echo "endpoint after: $(pane_cmd "$id") (still the same running agent; no /exit was sent)"
    ;;
  secondmate)
    snapshot sm-own sm; snapshot sm-bad sm; snapshot sm-spawn sm
    echo "sm-own: marker=$(cat "$POOL/8/repo/.fm-secondmate-home") stale claim: $(claim_of 8)"
    run_and_show "S8 bin/fm-control.sh sm-own relaunch (own home marker, stale other-task claim)" \
      env FM_CONTROL_LAUNCH_WAIT=90 bin/fm-control.sh sm-own relaunch
    [ "$LAST_RC" = 0 ]; check $? "secondmate relaunch with stale claim exits 0"
    case "$LAST_OUT" in *"claimed by task"*) check 1 "no reassigned-slot refusal for a leased secondmate home" ;; *) check 0 "no reassigned-slot refusal for a leased secondmate home" ;; esac
    case "$LAST_OUT" in *"relaunched sm-own"*) check 0 "fm-control reports relaunched sm-own" ;; *) check 1 "fm-control reports relaunched sm-own" ;; esac
    echo "sm-bad: marker=$(cat "$POOL/9/repo/.fm-secondmate-home") stale claim: $(claim_of 9)"
    run_and_show "S9 bin/fm-control.sh sm-bad relaunch (home marked for someone-else)" \
      bin/fm-control.sh sm-bad relaunch
    [ "$LAST_RC" = 1 ]; check $? "wrong-marker secondmate relaunch exits 1"
    case "$LAST_OUT" in *"not marked as its own seeded secondmate home"*) check 0 "refusal names the home-marker mismatch" ;; *) check 1 "refusal names the home-marker mismatch" ;; esac
    unchanged sm-bad sm
    echo "sm-spawn: marker=$(cat "$POOL/10/repo/.fm-secondmate-home") stale claim: $(claim_of 10)"
    run_and_show "S10 bin/fm-spawn.sh sm-spawn --relaunch (direct, own marker, stale claim)" \
      bin/fm-spawn.sh sm-spawn --relaunch
    [ "$LAST_RC" = 0 ]; check $? "direct secondmate relaunch with stale claim exits 0"
    case "$LAST_OUT" in *"claimed by task"*) check 1 "no reassigned-slot refusal from fm-spawn for a secondmate" ;; *) check 0 "no reassigned-slot refusal from fm-spawn for a secondmate" ;; esac
    case "$LAST_OUT" in *"spawned sm-spawn"*) check 0 "fm-spawn reports spawned sm-spawn" ;; *) check 1 "fm-spawn reports spawned sm-spawn" ;; esac
    sleep 3
    for id in sm-own sm-bad sm-spawn; do echo "$id endpoint now: $(pane_cmd "$id")"; done
    ;;
  teardown-tmux)
    ltmux kill-server 2>/dev/null
    bin/fm-lab-home.sh teardown "$LAB"
    echo "lab tmux server stopped; lab root to remove: $ROOT"
    ;;
esac
