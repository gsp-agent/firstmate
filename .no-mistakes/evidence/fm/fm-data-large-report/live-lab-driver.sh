#!/usr/bin/env bash
# Live driver for the task-data cleanup change (branch fm/fm-data-large-report).
# Runs the real bin/fm-teardown.sh from the gate worktree against disposable,
# marked lab homes (bin/fm-lab-home.sh), a disposable user HOME that holds real
# br databases for .agent-config-*, gsp-* and project beads, a real markdown
# backlog through tasks-axi, real dcg for expiry, and a private tmux server
# (TMUX_TMPDIR from fm-lab-home.sh tmux-dir; TMUX unset). Nothing is stubbed.
# Usage: live-lab-driver.sh <repo-worktree> <workspace-dir> <evidence-dir>
set -u
ROOT=$1 E=$3
W=$(cd -P "$2" && pwd -P) || exit 1
mkdir -p "$E/live"
LOG="$E/live/transcript.txt"
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
for d in "$UH/.agent-config:.agent-config" "$UH/dev/gsp-beads:gsp" "$PROJ:proj" "$DECOY:decoy"; do
  git -C "${d%%:*}" init -q . && git -C "${d%%:*}" commit -q --allow-empty -m init
  ubr "${d%%:*}" init --prefix "${d##*:}" -q
done
AC_ID=$(newbead "$UH/.agent-config" "agent-config bead" '[capture](proof-ac.png)')
GSP_ID=$(newbead "$UH/dev/gsp-beads" "gsp bead" '[capture](proof-gsp.png)')
PROJ_ID=$(newbead "$PROJ" "project bead" '[capture](proof-proj.png)')
newbead "$DECOY" "decoy bead" 'decoy links nothing' >/dev/null
say "beads: agent-config=$AC_ID gsp=$GSP_ID project=$PROJ_ID (decoy db at $DECOY/.beads)"

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

say "=== Lab A: named-bead resolution, unread retry, kept evidence size, stage limit"
mklab labA
fixture() { # <id> <brief-text> <proof-name>
  task "$1"
  printf '%s\n' "$2" > "$LAB/data/$1/brief.md"
  printf 'linked evidence\n' > "$LAB/data/$1/$3"
  printf 'scratch\n' > "$LAB/data/$1/discard.bin"
}

say "## S1 dotted .agent-config bead resolves from HOME/.agent-config (inherited BEADS_DIR/BEADS_DB/BR_DB point at a decoy db)"
fixture la-ac "Bead $AC_ID" proof-ac.png
teardown la-ac
snap la-ac after-teardown
check "S1 teardown exits 0, task retired, backlog row done, no pending close" retired_and_closed la-ac
check "S1 scratch staged into .cleanup-hold" staged la-ac
check "S1 file linked only from the .agent-config bead stays in place" test -e "$LAB/data/la-ac/proof-ac.png"
check "S1 record names the bead with nothing unread" jq -e --arg b "$AC_ID" '.complete == true and .sources[0].beads == [$b] and .sources[0].unread == []' "$LAB/data/la-ac/record/data-cleanup.json"

say "## S2 gsp bead resolves from HOME/dev/gsp-beads"
fixture la-gsp "Bead $GSP_ID" proof-gsp.png
teardown la-gsp
snap la-gsp after-teardown
snap la-ac after-next-teardown
check "S2 teardown exits 0, task retired, backlog row done, no pending close" retired_and_closed la-gsp
check "S2 scratch staged into .cleanup-hold" staged la-gsp
check "S2 file linked only from the gsp bead stays in place" test -e "$LAB/data/la-gsp/proof-gsp.png"
check "S2 record has nothing unread" jq -e '.complete == true and .sources[0].unread == []' "$LAB/data/la-gsp/record/data-cleanup.json"
check "S2 next teardown expired la-ac's hold with real dcg and kept its linked file" bash -c '[ ! -e "$1/.cleanup-hold" ] && [ -e "$1/proof-ac.png" ] && jq -e ".expired == true" "$1/record/data-cleanup.json"' _ "$LAB/data/la-ac"

say "## S3 other bead resolves from the task's own project repo"
fixture la-proj "Bead $PROJ_ID" proof-proj.png
teardown la-proj
snap la-proj after-teardown
check "S3 teardown exits 0, retired, backlog row done" retired_and_closed la-proj
check "S3 scratch staged, project-bead-linked file kept" bash -c '[ -e "$1/.cleanup-hold/discard.bin" ] && [ -e "$1/proof-proj.png" ]' _ "$LAB/data/la-proj"
check "S3 record has nothing unread" jq -e '.complete == true and .sources[0].unread == []' "$LAB/data/la-proj/record/data-cleanup.json"

say "## S3b other bead absent from the project falls back to Firstmate's backlog row"
tasks-axi add lab-fallback-ref 'named evidence' --body '[capture](proof-fb.png)' --file "$LAB/data/backlog.md" >/dev/null
fixture la-fb "Bead lab-fallback-ref" proof-fb.png
teardown la-fb
snap la-fb after-teardown
check "S3b teardown exits 0, retired, backlog row done" retired_and_closed la-fb
check "S3b scratch staged, backlog-row-linked file kept" bash -c '[ -e "$1/.cleanup-hold/discard.bin" ] && [ -e "$1/proof-fb.png" ]' _ "$LAB/data/la-fb"
check "S3b record has nothing unread" jq -e '.complete == true and .sources[0].unread == []' "$LAB/data/la-fb/record/data-cleanup.json"

say "## S4 unresolvable generic bead keeps the folder whole, close completes, named; next teardown retries it"
fixture la-unread "Bead lab-ghost-ref" proof-ghost.png
teardown la-unread
snap la-unread after-teardown
check "S4 teardown exits 0, retired, backlog row done, no pending close" retired_and_closed la-unread
check "S4 folder kept whole (no .cleanup-hold, scratch in place)" whole la-unread
check "S4 unread id named in teardown output" grep -q 'lab-ghost-ref' "$E/live/la-unread.err"
check "S4 unread id named in the record" jq -e '.complete == false and .sources[0].unread == ["lab-ghost-ref"]' "$LAB/data/la-unread/record/data-cleanup.json"

say "## S4b unresolvable dotted .agent-config bead keeps the folder whole, close completes, named"
fixture la-unread-dot "Bead .agent-config-ghost9" proof-ghost.png
teardown la-unread-dot
snap la-unread-dot after-teardown
snap la-unread after-a-later-teardown-still-unresolvable
check "S4b teardown exits 0, retired, backlog row done, no pending close" retired_and_closed la-unread-dot
check "S4b folder kept whole" whole la-unread-dot
check "S4b dotted id named in teardown output and record" bash -c 'grep -q "\.agent-config-ghost9" "$1" && jq -e ".complete == false and .sources[0].unread == [\".agent-config-ghost9\"]" "$2"' _ "$E/live/la-unread-dot.err" "$LAB/data/la-unread-dot/record/data-cleanup.json"
check "S4 still kept whole after a later teardown while unresolvable" whole la-unread

say "## S6 kept report over 1 MiB (1.4 MB with a link at its end) prepares, closes, stages, keeps the link; S4 retry once its bead becomes readable"
tasks-axi add lab-ghost-ref 'now readable' --body '[capture](proof-ghost.png)' --file "$LAB/data/backlog.md" >/dev/null
task la-large
mkdir -p "$LAB/data/la-large/proof"
{ head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$LAB/data/la-large/report.md"
printf 'keep this image\n' > "$LAB/data/la-large/proof/capture.png"
printf 'scratch\n' > "$LAB/data/la-large/discard.bin"
teardown la-large
snap la-large after-teardown
snap la-unread after-retry
check "S6 teardown exits 0, retired, backlog row done, no pending close" retired_and_closed la-large
check "S6 scratch staged, file linked at the end of the 1.4 MB report kept" bash -c '[ -e "$1/.cleanup-hold/discard.bin" ] && [ -e "$1/proof/capture.png" ] && [ "$(wc -c < "$1/report.md" | tr -d " ")" -gt 1048576 ]' _ "$LAB/data/la-large"
check "S4 retry: the next teardown re-read lab-ghost-ref, staged scratch, kept its linked file, cleared unread" bash -c '[ -e "$1/.cleanup-hold/discard.bin" ] && [ -e "$1/proof-ghost.png" ] && jq -e ".complete == true and .sources[0].unread == []" "$1/record/data-cleanup.json"' _ "$LAB/data/la-unread"

say "## S7 kept report over 16 MiB keeps the folder whole and names the file; close completes"
task la-huge
head -c $((17 * 1024 * 1024)) /dev/zero | tr '\0' 'y' > "$LAB/data/la-huge/report.md"
printf 'scratch\n' > "$LAB/data/la-huge/discard.bin"
teardown la-huge
snap la-huge after-teardown
check "S7 teardown exits 0, retired, backlog row done, no pending close" retired_and_closed la-huge
check "S7 folder kept whole" whole la-huge
check "S7 report.md named in teardown output and record" bash -c 'grep -q "report.md" "$1" && jq -e ".complete == false and (.sources[0].unread | index(\"report.md\"))" "$2"' _ "$E/live/la-huge.err" "$LAB/data/la-huge/record/data-cleanup.json"

say "## S8 stage past FM_TEARDOWN_DATA_STAGE_TIMEOUT=1 (near-16 MiB report, 200 unmatched files) moves nothing; close completes"
task la-stage
head -c $((16 * 1024 * 1024 - 4096)) /dev/zero | tr '\0' 'z' > "$LAB/data/la-stage/report.md"
mkdir -p "$LAB/data/la-stage/clone"
for i in $(seq 1 200); do printf 'unmatched %s\n' "$i" > "$LAB/data/la-stage/clone/scratch-$i.bin"; done
printf 'scratch\n' > "$LAB/data/la-stage/discard.bin"
teardown la-stage FM_TEARDOWN_DATA_STAGE_TIMEOUT=1
snap la-stage after-teardown
check "S8 teardown exits 0, retired, backlog row done, no pending close" retired_and_closed la-stage
check "S8 nothing moved: no .cleanup-hold, all 200 files and scratch in place" bash -c '[ ! -e "$1/.cleanup-hold" ] && [ -e "$1/discard.bin" ] && [ "$(find "$1/clone" -type f | wc -l | tr -d " ")" = 200 ]' _ "$LAB/data/la-stage"
check "S8 warning names the task and the stage limit" grep -q 'la-stage.*stage limit' "$E/live/la-stage.err"
check "S8 record retained field names the limit" jq -e '.complete == false and (.retained | test("stage limit"))' "$LAB/data/la-stage/record/data-cleanup.json"

labtmux kill-server 2>/dev/null || true
bash "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true

say "=== Lab B: expiry after lock release, cut-off, full attempt, too-large, by-hand"
mklab labB
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
( teardown lb-next1 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=6 FM_SUPERVISION_ACTOR=main; exit "$RC" ) &
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
say "teardown lb-next1 returned exit=$RC after ${total}s overall (6s expiry budget)"
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
