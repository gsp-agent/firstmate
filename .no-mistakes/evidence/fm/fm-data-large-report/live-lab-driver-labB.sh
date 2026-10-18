#!/usr/bin/env bash
# Live driver for the task-data cleanup change (branch fm/fm-data-large-report).
# Runs the real bin/fm-teardown.sh from the gate worktree against disposable,
# marked lab homes (bin/fm-lab-home.sh), a disposable user HOME that holds real
# br databases for .agent-config-*, gsp-* and project beads, a real markdown
# backlog through tasks-axi, real dcg for expiry, and a private tmux server
# (TMUX_TMPDIR from fm-lab-home.sh tmux-dir; TMUX unset). Nothing is stubbed.
# Lab B part of live-lab-driver.sh, run in parallel in lab labB2 to save wall-clock time.
# Usage: live-lab-driver-labB.sh <repo-worktree> <workspace-dir> <evidence-dir>
set -u
ROOT=$1 E=$3
W=$(cd -P "$2" && pwd -P) || exit 1
mkdir -p "$E/live"
LOG="$E/live/transcript-labB.txt"
: > "$LOG"
FAILS=0
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
check() { # <label> <command...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then say "PASS: $label"; else say "FAIL: $label"; FAILS=$((FAILS + 1)); fi
}
UH="$W/home"
PROJ="$W/proj"
DECOY="$W/decoy"
mkdir -p "$UH/.agent-config" "$UH/dev/gsp-beads" "$PROJ" "$DECOY"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid

ubr() { (cd "$1" && shift && env -u BEADS_DIR -u BEADS_DB -u BR_DB HOME="$UH" br "$@"); }
newbead() { # <dir> <title> <description> -> id
  ubr "$1" create "$2" --description "$3" --json | jq -r .id
}
# Bead databases were created by live-lab-driver.sh in the same workspace.

mklab() { # <name> -> sets LAB, TMUXDIR
  LAB="$W/$1"
  bash "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  TMUXDIR=$(bash "$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
  printf 'tmux\n' > "$LAB/config/backend"
  cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  touch "$LAB/state/.last-watcher-beat"
  env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux new-session -d -s firstmate -n keepalive 'sleep 7200'
}
labtmux() { env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux "$@"; }
task() { # <id>: backlog row in flight, live tmux window, task record
  local id=$1
  tasks-axi add "$id" "lab task $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  labtmux new-window -d -t firstmate -n "fm-$id" 'sleep 7200'
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$W/gone-$id" \
    "project=$PROJ" "kind=ship" "mode=local-only" "spawn_gen=lab-$id" > "$LAB/state/$id.meta"
  mkdir -p "$LAB/data/$id"
}
teardown() { # <id> [VAR=value...]: run the real teardown in the lab; sets RC
  local id=$1; shift
  local start=$SECONDS
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    HOME="$UH" FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" \
    FM_TEARDOWN_DATA_STAGE_TIMEOUT=120 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=60 \
    BEADS_DIR="$DECOY/.beads" BEADS_DB="$DECOY/.beads/beads.db" BR_DB="$DECOY/.beads/beads.db" \
    "$@" "$ROOT/bin/fm-teardown.sh" "$id" > "$E/live/$id.out" 2> "$E/live/$id.err"
  RC=$?
  say "--- teardown $id (lab $(basename "$LAB")) exit=$RC in $((SECONDS - start))s"
  sed 's/^/  stdout: /' "$E/live/$id.out" | tee -a "$LOG" >/dev/null
  sed 's/^/  stderr: /' "$E/live/$id.err" | tee -a "$LOG" >/dev/null
}
row_state() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
rec() { jq -c "$2" "$LAB/data/$1/record/data-cleanup.json"; }
snap() { # <id> <label>
  local id=$1
  {
    echo "  [$2] data/$id files:"
    (cd "$LAB/data/$id" 2>/dev/null && find . \( -type f -o -type l \) ! -path './clone/*' | sort | sed 's/^/    /'
     [ -d clone ] && echo "    ./clone/: $(find clone -type f | wc -l | tr -d ' ') files"
     [ -d .cleanup-hold/clone ] && echo "    ./.cleanup-hold/clone/: $(find .cleanup-hold/clone -type f | wc -l | tr -d ' ') files")
    echo "  [$2] record: $(jq -c '{complete, expired, expiry, retained, sources: [.sources[] | {beads, unread}]}' "$LAB/data/$id/record/data-cleanup.json" 2>/dev/null | cut -c1-600)"
    echo "  [$2] backlog row $id: $(row_state "$id"); pending close file: $([ -e "$LAB/state/$id.backlog-close" ] && echo present || echo absent); task record: $([ -e "$LAB/state/$id.meta" ] && echo present || echo absent); tmux window fm-$id: $(labtmux list-windows -t firstmate -F '#W' | grep -qx "fm-$id" && echo present || echo gone)"
  } | tee -a "$LOG" >/dev/null
}
retired_and_closed() { [ "$RC" = 0 ] && [ "$(row_state "$1")" = done ] && [ ! -e "$LAB/state/$1.backlog-close" ] && [ ! -e "$LAB/state/$1.meta" ]; }
staged() { [ -e "$LAB/data/$1/.cleanup-hold/discard.bin" ] && [ ! -e "$LAB/data/$1/discard.bin" ]; }
whole() { [ ! -e "$LAB/data/$1/.cleanup-hold" ] && [ -e "$LAB/data/$1/discard.bin" ]; }

say "=== Lab B: expiry after lock release, cut-off, full attempt, too-large, by-hand"
mklab labB2
N=${SLOW_BEADS:-50}
SLOW_BRIEF=''
for i in $(seq 1 "$N"); do
  SLOW_BRIEF="${SLOW_BRIEF}Bead $(newbead "$PROJ" "slow $i" "plain $i")"$'\n'
done
say "created $N project beads for the slow hold"
task lb-slow
printf '%s' "$SLOW_BRIEF" > "$LAB/data/lb-slow/brief.md"
printf 'scratch\n' > "$LAB/data/lb-slow/discard.bin"
teardown lb-slow FM_TEARDOWN_DATA_STAGE_TIMEOUT=600
snap lb-slow after-own-teardown
check "S9 setup: slow hold staged by its own teardown" staged lb-slow

say "## S9 a teardown expiring a slow hold releases its locks first: a concurrent fm-send finishes while expiry reads; budget cuts it off; reader dies with it"
labtmux new-window -d -t firstmate -n fm-lb-live 'cat'
printf '%s\n' "window=firstmate:fm-lb-live" "endpoint_task_id=lb-live" "kind=ship" "harness=claude" > "$LAB/state/lb-live.meta"
task lb-next1
printf 'scratch\n' > "$LAB/data/lb-next1/discard.bin"
started=$SECONDS
( teardown lb-next1 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=15 FM_SUPERVISION_ACTOR=main; exit "$RC" ) &
td_pid=$!
seen=0
for ((i = 0; i < 900; i++)); do
  if pgrep -f "backlog-references $LAB/data lb-slow" >/dev/null; then seen=1; break; fi
  kill -0 "$td_pid" 2>/dev/null || break
  sleep 0.1
done
say "expiry reader for lb-slow seen running: $seen (after $((SECONDS - started))s)"
lease_lock=absent; [ -e "$LAB/state/.fm-lease-command.lock" ] && lease_lock=present
meta_lock=absent; ls -d "$LAB/state/.meta-lb-next1.lock" >/dev/null 2>&1 && meta_lock=present
say "while expiry reads: home lease-command lock $lease_lock; lb-next1 meta lock $meta_lock; teardown stdout so far: $(tr '\n' ' ' < "$E/live/lb-next1.out")"
send_start=$(python3 -c 'import time; print(time.time())')
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX HOME="$UH" FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" \
  FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" lb-live "steer during expiry" \
  > "$E/live/fm-send.out" 2> "$E/live/fm-send.err"
send_rc=$?
send_secs=$(python3 -c "import time; print(round(time.time() - $send_start, 2))")
td_running=no; kill -0 "$td_pid" 2>/dev/null && td_running=yes
say "concurrent fm-send exit=$send_rc in ${send_secs}s; teardown still running when it finished: $td_running; inbox: $(ls "$LAB/state/lb-live.inbox" 2>/dev/null | tr '\n' ' ')"
wait "$td_pid"
RC=$?
total=$((SECONDS - started))
say "teardown lb-next1 returned exit=$RC after ${total}s overall (15s expiry budget)"
reader_gone=no
for ((i = 0; i < 20; i++)); do
  pgrep -f "backlog-references $LAB/data lb-slow" >/dev/null || { reader_gone=yes; break; }
  sleep 0.1
done
say "lb-slow expiry reader gone within 2s of teardown return: $reader_gone"
snap lb-slow after-cut-off
snap lb-next1 after-teardown
check "S9 expiry reader was observed running (expiry really was slow)" test "$seen" = 1
check "S9 home lease-command lock not held during expiry" test "$lease_lock" = absent
check "S9 concurrent fm-send exit 0 and finished while teardown was still expiring" test "$send_rc:$td_running" = "0:yes"
check "S9 fm-send recorded its steer in the live task's inbox" test -e "$LAB/state/lb-live.inbox/001.msg"
check "S9 teardown lb-next1 retired and closed its row" retired_and_closed lb-next1
check "S9 budget cut-off warning names lb-slow and promises one full attempt" grep -q 'task data lb-slow expiry stopped after .*one full 60s attempt' "$E/live/lb-next1.err"
check "S9 cut-off hold keeps its data and is marked cut-off" bash -c '[ -e "$1/.cleanup-hold/discard.bin" ] && jq -e ".expired != true and .expiry == \"cut-off\"" "$1/record/data-cleanup.json"' _ "$LAB/data/lb-slow"
check "S9 lb-slow's reference reader did not outlive the budget kill" test "$reader_gone" = yes

say "## S10 the one full attempt (FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=2) is cut off too: marked too-large, by-hand command advertised"
task lb-next2
printf 'scratch\n' > "$LAB/data/lb-next2/discard.bin"
teardown lb-next2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=2
snap lb-slow after-full-attempt
check "S10 teardown lb-next2 retired and closed" retired_and_closed lb-next2
check "S10 warning says too large and advertises the by-hand command" grep -q "lb-slow expiry stopped after its one full 2s attempt.*expire it by hand with bash .*fm-task-data-lib.sh expire $LAB/data $LAB/state lb-slow" "$E/live/lb-next2.err"
check "S10 hold kept and marked too-large" bash -c '[ -e "$1/.cleanup-hold/discard.bin" ] && jq -e ".expiry == \"too-large\"" "$1/record/data-cleanup.json"' _ "$LAB/data/lb-slow"

say "## S11 later teardowns skip a too-large hold and name it"
task lb-next3
printf 'scratch\n' > "$LAB/data/lb-next3/discard.bin"
teardown lb-next3
snap lb-slow after-skip
check "S11 teardown lb-next3 retired and closed" retired_and_closed lb-next3
check "S11 warning names lb-slow as too large and skipped" grep -q 'too large to expire automatically, skipped and kept for expiry by hand: lb-slow' "$E/live/lb-next3.err"
check "S11 hold untouched and still too-large" bash -c '[ -e "$1/.cleanup-hold/discard.bin" ] && jq -e ".expiry == \"too-large\"" "$1/record/data-cleanup.json"' _ "$LAB/data/lb-slow"

say "## S12 by-hand expiry: refuses while another process holds the task lock, then expires with no time limit"
holder() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-wake-lib.sh"
  local lock
  lock=$(fm_meta_lock_path "$LAB/state/lb-slow.meta") || exit 1
  fm_lock_try_acquire "$lock" || exit 1
  : > "$W/lock-held"
  sleep 8
  fm_lock_release "$lock"
}
( holder ) &
holder_pid=$!
for ((i = 0; i < 100; i++)); do [ -e "$W/lock-held" ] && break; sleep 0.1; done
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u TMUX HOME="$UH" FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" \
  bash "$ROOT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lb-slow > "$E/live/by-hand-locked.out" 2> "$E/live/by-hand-locked.err"
locked_rc=$?
say "by-hand while locked: exit=$locked_rc; stderr: $(cat "$E/live/by-hand-locked.err")"
check "S12 by-hand refuses a held task lock and expires nothing" bash -c '[ "$1" != 0 ] && grep -q "locked by another process" "$2" && [ -e "$3/.cleanup-hold/discard.bin" ]' _ "$locked_rc" "$E/live/by-hand-locked.err" "$LAB/data/lb-slow"
wait "$holder_pid"
bh_start=$SECONDS
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u TMUX HOME="$UH" FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" \
  bash "$ROOT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lb-slow > "$E/live/by-hand.out" 2> "$E/live/by-hand.err"
bh_rc=$?
say "by-hand expire: exit=$bh_rc in $((SECONDS - bh_start))s; stdout: $(cat "$E/live/by-hand.out"); stderr: $(cat "$E/live/by-hand.err")"
snap lb-slow after-by-hand
check "S12 by-hand expire exits 0 and expires the hold" bash -c '[ "$1" = 0 ] && [ ! -e "$2/.cleanup-hold" ] && jq -e ".expired == true" "$2/record/data-cleanup.json"' _ "$bh_rc" "$LAB/data/lb-slow"
check "S12 lock released after by-hand run" bash -c '! ls -d "$1"/.meta-lb-slow.lock* >/dev/null 2>&1' _ "$LAB/state"

labtmux kill-server 2>/dev/null || true
bash "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
say "=== live checks failed: $FAILS"
exit "$FAILS"
