#!/usr/bin/env bash
# Live lab driver for the task-data cleanup change (fm/fm-data-large-report).
# Usage: lab-drive.sh <code-root> <scenario> <transcript>
# Each run mints a fresh marked lab home under /tmp (bin/fm-lab-home.sh), its own
# private tmux server (fm-lab-home.sh tmux-dir), a private HOME holding real br
# databases, and a real tasks-axi backlog, then drives the real bin/fm-teardown.sh
# and bin/fm-send.sh with plain FM_HOME=<lab> and no FM_*_OVERRIDE.
# Only dcg is stubbed (allow + log): the real dcg times out at 200 ms on this
# loaded machine and denies every rm, which would hide the behaviour under test.
# The lab path is printed on the last line; the caller removes it.
set -u
CODE=$1 SCENARIO=$2 OUT=$3
exec > >(tee "$OUT") 2>&1

LAB=$(mktemp -d /private/tmp/fm-lab.XXXXXX)  # real path: task-data refuses symlinked ancestors such as /tmp
"$CODE/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
TMUXDIR=$("$CODE/bin/fm-lab-home.sh" tmux-dir "$LAB") || { echo "tmux-dir failed"; exit 1; }
PROJ="$LAB/projects/proj"
mkdir -p "$LAB/fakebin" "$LAB/home/.agent-config" "$LAB/home/dev/gsp-beads" "$PROJ"
cat > "$LAB/fakebin/dcg" <<SH
#!/usr/bin/env bash
cat >> "$LAB/dcg.log"
echo >> "$LAB/dcg.log"
SH
chmod +x "$LAB/fakebin/dcg"
cp "$CODE/.tasks.toml" "$LAB/.tasks.toml"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
touch "$LAB/state/.last-watcher-beat"

labrun() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE -u BEADS_DIR -u BEADS_DB -u BR_DB \
    FM_HOME="$LAB" HOME="$LAB/home" TMUX_TMPDIR="$TMUXDIR" PATH="$LAB/fakebin:$PATH" \
    FM_SUPERVISION_ACTOR=main "$@"
}
now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }
since() { python3 -c "import time; print(f'{time.time() - $1:.1f}')"; }
step() { printf '\n=== %s (%s) ===\n' "$*" "$(date '+%H:%M:%S')"; }
check() { # <label> <command...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $label"; else echo "FAIL: $label"; fi
}
backlog_state() {
  labrun tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}
br_init() { # <dir> <prefix>
  (cd "$1" && git init -q . && labrun br init --prefix "$2" -q >/dev/null 2>&1)
}
br_new() { # <dir> <description> -> id
  (cd "$1" && labrun br create "lab evidence bead" -d "$2" --json 2>/dev/null | jq -r '.id')
}
new_task() { # <id>
  local id=$1
  labrun tasks-axi add "$id" "lab task $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  labrun tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/missing-$id" \
    "project=$PROJ" "kind=ship" "mode=local-only" "spawn_gen=lab-$id" > "$LAB/state/$id.meta"
  labrun tmux new-window -d -t firstmate -n "fm-$id" 'sleep 3600'
  mkdir -p "$LAB/data/$id"
}
teardown() { # <id> [env...]
  local id=$1 rc start; shift
  start=$(now)
  labrun "$@" "$CODE/bin/fm-teardown.sh" "$id" > "$LAB/$id.out" 2> "$LAB/$id.err"
  rc=$?
  TD_RC=$rc
  echo "fm-teardown.sh $id -> exit $rc in $(since "$start")s"
  echo "--- stdout"; cat "$LAB/$id.out"; echo "--- stderr"; cat "$LAB/$id.err"
  return "$rc"
}
show_tree() { (cd "$LAB/data/$1" && find . -path ./record -prune -o -type f -print | sort | sed 's/^/  /'); }
record() { jq -c '{complete, expired, expiry, unread: [.sources[]?.unread // empty], beads: [.sources[]?.beads // empty]}' \
  "$LAB/data/$1/record/data-cleanup.json" 2>/dev/null; }
hold_lock() { # <id> -> holds state/.meta-<id>.lock with a live pid
  sleep 600 & HOLDER=$!
  mkdir "$LAB/state/.meta-$1.lock" && printf '%s\n' "$HOLDER" > "$LAB/state/.meta-$1.lock/pid"
}
free_lock() { # <id>
  rm -f -- "$LAB/state/.meta-$1.lock/pid"; rmdir -- "$LAB/state/.meta-$1.lock"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
}
slow_hold() { # <id> <beads> : a finished task whose kept brief names <beads> readable project beads
  local id=$1 count=$2 i bead
  new_task "$id"
  for ((i = 0; i < count; i++)); do
    bead=$(br_new "$PROJ" "note $i")
    printf 'Bead %s\n' "$bead" >> "$LAB/data/$id/brief.md"
  done
  printf 'held scratch\n' > "$LAB/data/$id/scratch.bin"
}

# Lock timeline: log each change of the home-wide lease lock while teardown runs.
lock_sampler() { # <t0> <outfile>
  local last=x cur
  while :; do
    if [ -e "$LAB/state/.fm-lease-command.lock" ]; then cur=held; else cur=free; fi
    [ "$cur" = "$last" ] || { echo "+$(since "$1")s lease lock $cur" >> "$2"; last=$cur; }
    sleep 0.1
  done
}
send_live() { # <label> -> SEND_SECS, SEND_RC
  local s0; s0=$(now)
  labrun FM_SEND_SETTLE=0 "$CODE/bin/fm-send.sh" live-y "$1" > "$LAB/send.out" 2> "$LAB/send.err"
  SEND_RC=$?; SEND_SECS=$(since "$s0")
}
# Tear down lab-main in the background and fm-send live-y once <trigger> says
# another task's hold is being expired. Sets SEND_SECS, STILL, TRC.
drive_main() { # <trigger: touched|meta-gone> [env...]
  local trigger=$1 t0 tpid before sampler; shift
  send_live "baseline steer, no teardown running"
  echo "baseline fm-send live-y (no teardown running) -> exit $SEND_RC in ${SEND_SECS}s"
  BASE_SECS=$SEND_SECS
  before=$(stat -f %m "$LAB/data/lab-slow/record/data-cleanup.json")
  sleep 1.1
  t0=$(now)
  : > "$LAB/locks.log"
  lock_sampler "$t0" "$LAB/locks.log" & sampler=$!
  labrun "$@" "$CODE/bin/fm-teardown.sh" lab-main > "$LAB/lab-main.out" 2> "$LAB/lab-main.err" &
  tpid=$!
  if [ "$trigger" = touched ]; then
    while [ "$(stat -f %m "$LAB/data/lab-slow/record/data-cleanup.json")" = "$before" ] && kill -0 "$tpid" 2>/dev/null; do sleep 0.05; done
    echo "+$(since "$t0")s lab-slow's expiry attempt started (record touched); starting fm-send live-y"
  else
    while [ -e "$LAB/state/lab-main.meta" ] && kill -0 "$tpid" 2>/dev/null; do sleep 0.05; done
    sleep 0.5
    echo "+$(since "$t0")s lab-main's task record removed (base code expires other holds next, under its locks); starting fm-send live-y"
  fi
  echo "lease lock at fm-send start: $([ -e "$LAB/state/.fm-lease-command.lock" ] && echo held || echo free)"
  send_live "steer during expiry"
  if kill -0 "$tpid" 2>/dev/null; then STILL=yes; else STILL=no; fi
  echo "+$(since "$t0")s fm-send live-y -> exit $SEND_RC in ${SEND_SECS}s; teardown still running when fm-send returned: $STILL"
  echo "--- fm-send stderr"; cat "$LAB/send.err"
  wait "$tpid"; TRC=$?
  echo "+$(since "$t0")s fm-teardown.sh lab-main -> exit $TRC"
  kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
  echo "--- lease lock timeline"; cat "$LAB/locks.log"
  echo "--- stdout"; cat "$LAB/lab-main.out"; echo "--- stderr"; cat "$LAB/lab-main.err"
}

labrun tmux new-session -d -s firstmate -n keep 'sleep 86400'
(cd "$PROJ" && git init -q . && git -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m lab)
br_init "$PROJ" proj
echo "lab=$LAB code=$CODE tmux=$TMUXDIR scenario=$SCENARIO"

case "$SCENARIO" in
  beads)
    br_init "$LAB/home/.agent-config" .agent-config
    br_init "$LAB/home/dev/gsp-beads" gsp
    AC=$(br_new "$LAB/home/.agent-config" 'agent-config evidence [capture](proof/capture.png)')
    GSP=$(br_new "$LAB/home/dev/gsp-beads" 'gsp evidence [capture](proof/capture.png)')
    PB=$(br_new "$PROJ" 'project evidence [capture](proof/capture.png)')
    UNREAD=nope-zz9q
    echo "beads: agent-config=$AC gsp=$GSP project=$PB unresolvable=$UNREAD"
    for pair in "lab-ac:$AC" "lab-gsp:$GSP" "lab-proj:$PB" "lab-unread:$UNREAD"; do
      id=${pair%%:*} bead=${pair#*:}
      new_task "$id"
      mkdir -p "$LAB/data/$id/proof"
      printf 'Bead %s\n' "$bead" > "$LAB/data/$id/brief.md"
      printf 'linked only from the bead\n' > "$LAB/data/$id/proof/capture.png"
      printf 'scratch\n' > "$LAB/data/$id/scratch.bin"
      step "teardown $id naming bead $bead (BEADS_DIR/BEADS_DB/BR_DB point at a wrong database)"
      teardown "$id" BEADS_DIR="$LAB/wrong" BEADS_DB="$LAB/wrong/x.db" BR_DB="$LAB/wrong/x.db"
      check "$id teardown exits 0" [ "$TD_RC" = 0 ]
      check "$id backlog row is done" [ "$(backlog_state "$id")" = done ]
      check "$id has no pending backlog close" [ ! -e "$LAB/state/$id.backlog-close" ]
      check "$id task record retired" [ ! -e "$LAB/state/$id.meta" ]
      check "$id window killed on the lab tmux server" sh -c "! TMUX_TMPDIR='$TMUXDIR' tmux list-windows -t firstmate -F '#W' | grep -qx 'fm-$id'"
      check "$id bead-linked proof/capture.png kept in place" [ -f "$LAB/data/$id/proof/capture.png" ]
      echo "$id record: $(record "$id")"
      echo "$id files:"; show_tree "$id"
      if [ "$id" = lab-unread ]; then
        check "lab-unread scratch not moved" [ -f "$LAB/data/$id/scratch.bin" ]
        check "lab-unread nothing staged" [ ! -e "$LAB/data/$id/.cleanup-hold" ]
        check "lab-unread teardown output names $UNREAD" grep -q "$UNREAD" "$LAB/$id.err"
        check "lab-unread record incomplete and names $UNREAD as unread" \
          jq -e --arg b "$UNREAD" '.complete == false and (.sources[-1].unread | index($b) != null)' "$LAB/data/$id/record/data-cleanup.json"
      else
        check "$id unbound scratch staged into .cleanup-hold" [ -f "$LAB/data/$id/.cleanup-hold/scratch.bin" ]
        check "$id record lists bead $bead, nothing unread" \
          jq -e --arg b "$bead" '(.sources[-1].beads | index($b) != null) and (.sources[-1].unread == [])' "$LAB/data/$id/record/data-cleanup.json"
      fi
    done
    check "lab-ac hold expired by a later teardown, evidence kept" sh -c "[ ! -e '$LAB/data/lab-ac/.cleanup-hold' ] && [ -f '$LAB/data/lab-ac/proof/capture.png' ]"
    step "the unresolvable id becomes readable in Firstmate's backlog; next teardown retries it"
    labrun tasks-axi add "$UNREAD" 'late evidence' --body '[capture](proof/capture.png)' --file "$LAB/data/backlog.md" >/dev/null
    new_task lab-last
    teardown lab-last
    echo "lab-unread record: $(record lab-unread)"
    if [ "$(jq -r '.expiry // ""' "$LAB/data/lab-unread/record/data-cleanup.json")" = cut-off ]; then
      step "lab-last's budget cut the retry off; teardown lab-final gives it its one full attempt"
      new_task lab-final
      teardown lab-final
      echo "lab-unread record: $(record lab-unread)"
    fi
    echo "lab-unread files:"; show_tree lab-unread
    check "retry staged lab-unread scratch" [ -f "$LAB/data/lab-unread/.cleanup-hold/scratch.bin" ]
    check "retry cleared the unread id" jq -e '.sources[-1].unread == []' "$LAB/data/lab-unread/record/data-cleanup.json"
    check "retry kept the backlog-linked capture" [ -f "$LAB/data/lab-unread/proof/capture.png" ]
    ;;

  reports)
    new_task lab-big
    mkdir -p "$LAB/data/lab-big/proof"
    { head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$LAB/data/lab-big/report.md"
    printf 'keep this image\n' > "$LAB/data/lab-big/proof/capture.png"
    printf 'scratch\n' > "$LAB/data/lab-big/scratch.bin"
    ls -l "$LAB/data/lab-big/report.md"
    step "teardown lab-big with a 1.4 MB report.md"
    teardown lab-big
    check "lab-big backlog row is done" [ "$(backlog_state lab-big)" = done ]
    check "lab-big has no pending backlog close" [ ! -e "$LAB/state/lab-big.backlog-close" ]
    check "lab-big scratch staged" [ -f "$LAB/data/lab-big/.cleanup-hold/scratch.bin" ]
    check "link at the end of the large report kept proof/capture.png" [ -f "$LAB/data/lab-big/proof/capture.png" ]
    check "large report bytes unchanged" [ "$(wc -c < "$LAB/data/lab-big/report.md" | tr -d ' ')" = 1400041 ]
    echo "lab-big record: $(record lab-big)"

    new_task lab-huge
    mkdir -p "$LAB/data/lab-huge/record"
    dd if=/dev/zero of="$LAB/data/lab-huge/record/run.log" bs=1048576 count=16 2>/dev/null
    printf 'x' >> "$LAB/data/lab-huge/record/run.log"
    printf 'scratch\n' > "$LAB/data/lab-huge/scratch.bin"
    ls -l "$LAB/data/lab-huge/record/run.log"
    step "teardown lab-huge with a 16 MiB + 1 byte record/run.log"
    teardown lab-huge
    check "lab-huge backlog row is done" [ "$(backlog_state lab-huge)" = done ]
    check "lab-huge has no pending backlog close" [ ! -e "$LAB/state/lab-huge.backlog-close" ]
    check "lab-huge kept whole: scratch in place" [ "$(cat "$LAB/data/lab-huge/scratch.bin")" = scratch ]
    check "lab-huge kept whole: nothing staged" [ ! -e "$LAB/data/lab-huge/.cleanup-hold" ]
    check "teardown output names record/run.log" grep -q 'record/run.log' "$LAB/lab-huge.err"
    check "record names record/run.log unread" jq -e '.complete == false and (.sources[-1].unread | index("record/run.log") != null)' "$LAB/data/lab-huge/record/data-cleanup.json"
    echo "lab-huge record: $(record lab-huge)"
    check "lab-huge's teardown expired lab-big's hold" [ ! -e "$LAB/data/lab-big/.cleanup-hold" ]
    check "lab-big report and capture survive expiry" sh -c "[ -f '$LAB/data/lab-big/report.md' ] && [ -f '$LAB/data/lab-big/proof/capture.png' ]"
    echo "lab-big record: $(record lab-big)"

    step "shrink lab-huge's run.log, then teardown lab-next retries it"
    printf 'short log\n' > "$LAB/data/lab-huge/record/run.log"
    new_task lab-next
    teardown lab-next
    check "retry staged lab-huge scratch" [ -f "$LAB/data/lab-huge/.cleanup-hold/scratch.bin" ]
    check "retry cleared the unread file" jq -e '.sources[-1].unread == []' "$LAB/data/lab-huge/record/data-cleanup.json"
    echo "lab-huge record: $(record lab-huge)"
    ;;

  slow)
    step "set up: lab-slow hold naming ${BEADS:-80} real project beads, then a fast hold lab-fast"
    slow_hold lab-slow "${BEADS:-80}"
    teardown lab-slow >/dev/null; echo "lab-slow staged: $(record lab-slow)"
    new_task lab-fast
    printf 'scratch\n' > "$LAB/data/lab-fast/scratch.bin"
    hold_lock lab-slow   # keep lab-fast's teardown from touching the slow hold, so both stay unmarked
    teardown lab-fast >/dev/null; echo "lab-fast staged: $(record lab-fast)"
    free_lock lab-slow
    printf '%s\n' "window=firstmate:fm-live-y" "endpoint_task_id=live-y" "kind=ship" "harness=claude" \
      "worktree=$LAB/missing-live-y" "project=$PROJ" "mode=local-only" "spawn_gen=lab-live-y" > "$LAB/state/live-y.meta"
    labrun tmux new-window -d -t firstmate -n fm-live-y 'cat'
    echo "pending holds (least recently tried first):"; labrun python3 "$CODE/bin/fm-task-data.py" pending "$LAB/data" | sed 's/^/  /'
    new_task lab-main
    step "teardown lab-main with FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=${BUDGET:-10}; fm-send live-y while it expires lab-slow"
    drive_main touched FM_TEARDOWN_DATA_EXPIRE_TIMEOUT="${BUDGET:-10}"
    send_secs=$SEND_SECS still=$STILL trc=$TRC
    check "fm-send during expiry took no more than its no-teardown baseline + 3s" python3 -c "import sys; sys.exit(0 if $send_secs <= $BASE_SECS + 3 else 1)"
    check "lease lock was free when fm-send started" grep -q '^lease lock at fm-send start: free' "$OUT"
    check "fm-send recorded the steer in live-y's inbox" sh -c "ls '$LAB/state/live-y.inbox/' | grep -q msg"
    check "teardown was still expiring when fm-send returned" [ "$still" = yes ]
    check "teardown exit 0" [ "$trc" = 0 ]
    check "lab-main backlog row is done" [ "$(backlog_state lab-main)" = done ]
    check "slow hold kept its held scratch" [ -f "$LAB/data/lab-slow/.cleanup-hold/scratch.bin" ]
    check "slow hold marked cut-off" [ "$(jq -r .expiry "$LAB/data/lab-slow/record/data-cleanup.json")" = cut-off ]
    check "warning names the unvisited fast hold" grep -q 'holds left for a later teardown: lab-fast' "$LAB/lab-main.err"
    check "fast hold untouched past the budget" [ -f "$LAB/data/lab-fast/.cleanup-hold/scratch.bin" ]
    echo "pending holds now:"; labrun python3 "$CODE/bin/fm-task-data.py" pending "$LAB/data" | sed 's/^/  /'
    new_task lab-next
    step "teardown lab-next (default budget): fast hold first, then the slow hold's one full attempt"
    teardown lab-next
    check "lab-next expired the previously starved fast hold" [ ! -e "$LAB/data/lab-fast/.cleanup-hold" ]
    check "lab-next's full attempt expired the slow hold" [ ! -e "$LAB/data/lab-slow/.cleanup-hold" ]
    check "slow hold record expired with its mark cleared" jq -e '.expired == true and (has("expiry") | not)' "$LAB/data/lab-slow/record/data-cleanup.json"
    check "slow hold's kept brief survives" [ -f "$LAB/data/lab-slow/brief.md" ]
    ;;

  slow-base)
    # Counterfactual on the pre-change code: same set-up, same trigger.
    slow_hold lab-slow "${BEADS:-80}"
    teardown lab-slow >/dev/null; echo "lab-slow staged: $(record lab-slow)"
    new_task lab-fast
    printf 'scratch\n' > "$LAB/data/lab-fast/scratch.bin"
    hold_lock lab-slow
    teardown lab-fast >/dev/null; echo "lab-fast staged: $(record lab-fast)"
    free_lock lab-slow
    printf '%s\n' "window=firstmate:fm-live-y" "endpoint_task_id=live-y" "kind=ship" "harness=claude" \
      "worktree=$LAB/missing-live-y" "project=$PROJ" "mode=local-only" "spawn_gen=lab-live-y" > "$LAB/state/live-y.meta"
    labrun tmux new-window -d -t firstmate -n fm-live-y 'cat'
    new_task lab-main
    step "BASE CODE: teardown lab-main; fm-send live-y while it expires lab-slow"
    drive_main meta-gone
    ;;

  too-large)
    slow_hold lab-huge "${BEADS:-80}"
    step "set up: teardown lab-huge stages a hold naming ${BEADS:-80} real project beads"
    teardown lab-huge >/dev/null; echo "lab-huge staged: $(record lab-huge)"
    REC="$LAB/data/lab-huge/record/data-cleanup.json"
    for round in 1 2 3; do
      new_task "lab-r$round"
      before=$(stat -f %m "$REC")
      sleep 1.1
      step "teardown lab-r$round with FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=3"
      teardown "lab-r$round" FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=3
      after=$(stat -f %m "$REC")
      echo "lab-huge expiry mark: $(jq -r '.expiry // "none"' "$REC"); record tried this round: $([ "$after" != "$before" ] && echo yes || echo no)"
      case $round in
        1) check "round 1 cut off by the 2s budget and marked cut-off" [ "$(jq -r .expiry "$REC")" = cut-off ]
           check "round 1 promises one full 3s attempt" grep -q 'gives it one full 3s attempt' "$LAB/lab-r1.err" ;;
        2) check "round 2 full 3s attempt cut off, marked too-large" [ "$(jq -r .expiry "$REC")" = too-large ]
           check "round 2 warning names the by-hand command" grep -q 'expire it by hand with bash' "$LAB/lab-r2.err" ;;
        3) check "round 3 did not try the too-large hold" [ "$after" = "$before" ]
           check "round 3 names it as skipped" grep -q 'skipped and kept for expiry by hand: lab-huge' "$LAB/lab-r3.err" ;;
      esac
      check "held scratch still present after round $round" [ -f "$LAB/data/lab-huge/.cleanup-hold/scratch.bin" ]
    done
    advertised=$(sed -n 's/.*expire it by hand with //p' "$LAB/lab-r2.err")
    echo "advertised by-hand command: $advertised"
    read -r -a byhand <<< "$advertised"
    step "by-hand command while another live process holds lab-huge's task lock"
    hold_lock lab-huge
    labrun "${byhand[@]}"; echo "-> exit $?"
    check "refused hold still marked too-large and whole" sh -c "[ \"\$(jq -r .expiry '$REC')\" = too-large ] && [ -f '$LAB/data/lab-huge/.cleanup-hold/scratch.bin' ]"
    free_lock lab-huge
    step "by-hand command with the lock free (no time limit)"
    b0=$(now)
    labrun "${byhand[@]}"; brc=$?
    echo "-> exit $brc in $(since "$b0")s"
    check "by-hand expiry succeeded" [ "$brc" = 0 ]
    check "by-hand expiry removed the hold" [ ! -e "$LAB/data/lab-huge/.cleanup-hold" ]
    check "by-hand expiry released the task lock" [ ! -e "$LAB/state/.meta-lab-huge.lock" ]
    check "record expired and mark cleared" jq -e '.expired == true and (has("expiry") | not)' "$REC"
    check "kept brief survives" [ -f "$LAB/data/lab-huge/brief.md" ]
    ;;
esac

labrun tmux kill-server 2>/dev/null
"$CODE/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
echo "LAB=$LAB"
