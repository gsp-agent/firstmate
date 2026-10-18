#!/usr/bin/env bash
# Drive the real bin/fm-teardown.sh, bin/fm-send.sh and the by-hand expiry
# command against disposable firstmate lab homes (bin/fm-lab-home.sh), one home
# per scenario. Usage: drive-lab.sh <repo-worktree> <parent-temp-dir> <scenario>...
# Only the services this change does not touch are shimmed so nothing reaches the
# operator's systems: no-mistakes, gh, gh-axi and treehouse. tmux is the real
# binary on each lab's private socket directory. dcg, python3, jq, br and
# tasks-axi are the real tools; scenario slow-expire alone swaps br for a slow
# one to inject a slow bead read.
set -u
REPO=$1 PARENT=$2
shift 2
FAILS=0

say() { printf '%s\n' "$*"; }
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then say "  PASS: $what"; else say "  FAIL: $what"; FAILS=$((FAILS + 1)); fi
}
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
present() { [ -e "$1" ]; }
contains() { grep -Fq -- "$2" "$1"; }

new_lab() { # <name> -> sets LAB, TMUXDIR
  LAB="$PARENT/$1"
  "$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  TMUXDIR=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
  mkdir -p "$LAB/shims"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/shims/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/shims/no-mistakes"
  cat > "$LAB/shims/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cp "$LAB/shims/gh-axi" "$LAB/shims/gh"
  chmod +x "$LAB/shims/"*
  git init -q --bare "$LAB/origin.git"
  git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$LAB/origin.git" "$LAB/seed" 2>/dev/null
  git -C "$LAB/seed" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m "lab baseline"
  git -C "$LAB/seed" push -q origin main
  git clone -q "$LAB/origin.git" "$LAB/project"
  git -C "$LAB/project" remote set-head origin main 2>/dev/null || true
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  touch "$LAB/state/.last-watcher-beat"
  say "lab home: $LAB (private tmux dir $TMUXDIR)"
}

end_lab() {
  TMUX_TMPDIR="$TMUXDIR" tmux kill-server 2>/dev/null || true
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" || say "  note: lab tmux dir teardown refused"
}

new_task() { # <id>
  local id=$1
  tasks-axi add "$id" "lab task $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/missing" \
    "project=$LAB/project" "kind=ship" "mode=local-only" "spawn_gen=$id" > "$LAB/state/$id.meta"
}

row_state() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }

# teardown <id> [VAR=value...]: run the real teardown with plain FM_HOME=<lab>.
teardown() {
  local id=$1 rc
  shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
    FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" PATH="$LAB/shims:$PATH" "$@" \
    "$REPO/bin/fm-teardown.sh" "$id" > "$LAB/$id.out" 2> "$LAB/$id.err"
  rc=$?
  say "  \$ FM_HOME=<lab> $* bin/fm-teardown.sh $id  -> exit $rc"
  sed 's/^/    | /' "$LAB/$id.out" "$LAB/$id.err" | grep -E 'task data|teardown .* complete|warning|error' | head -20
  return "$rc"
}

scenario_large_report() {
  say "== Scenario: kept report over 1 MiB prepares, closes, stages and expires"
  new_lab large-report
  local task="$LAB/data/big-report"
  mkdir -p "$task/proof"
  { head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$task/report.md"
  printf 'keep this image\n' > "$task/proof/capture.png"
  printf 'scratch\n' > "$task/scratch.bin"
  new_task big-report
  say "  report.md is $(wc -c < "$task/report.md" | tr -d ' ') bytes"
  teardown big-report; check "teardown exits 0" [ $? = 0 ]
  check "backlog row closed (state=$(row_state big-report))" [ "$(row_state big-report)" = done ]
  check "no pending backlog close left" absent "$LAB/state/big-report.backlog-close"
  check "scratch staged into .cleanup-hold" present "$task/.cleanup-hold/scratch.bin"
  check "file linked at the end of the large report kept in place" present "$task/proof/capture.png"
  check "report bytes unchanged" [ "$(wc -c < "$task/report.md" | tr -d ' ')" = 1400041 ]
  new_task next-one
  teardown next-one; check "next teardown exits 0" [ $? = 0 ]
  check "next completed task expired the hold" absent "$task/.cleanup-hold"
  check "report and linked capture survive expiry" present "$task/proof/capture.png"
  check "record says expired" jq -e '.expired == true' "$task/record/data-cleanup.json"
  end_lab
}

scenario_oversized() {
  say "== Scenario: kept evidence over 16 MiB keeps the folder whole, closes, names the file, retried later"
  new_lab oversized
  local task="$LAB/data/huge-log"
  mkdir -p "$task/record"
  dd if=/dev/zero of="$task/record/run.log" bs=1048576 count=16 2>/dev/null
  printf 'x' >> "$task/record/run.log"
  printf 'scratch\n' > "$task/scratch.bin"
  new_task huge-log
  teardown huge-log; check "teardown exits 0" [ $? = 0 ]
  check "backlog row closed (state=$(row_state huge-log))" [ "$(row_state huge-log)" = done ]
  check "no pending backlog close left" absent "$LAB/state/huge-log.backlog-close"
  check "scratch not moved" [ "$(cat "$task/scratch.bin")" = scratch ]
  check "nothing staged" absent "$task/.cleanup-hold"
  check "teardown output names record/run.log" contains "$LAB/huge-log.err" record/run.log
  check "record: complete=false and unread lists record/run.log" \
    jq -e '.complete == false and (.sources[-1].unread | index("record/run.log") != null)' "$task/record/data-cleanup.json"
  say "  record unread: $(jq -c '.sources[-1].unread' "$task/record/data-cleanup.json")"
  printf 'short log\n' > "$task/record/run.log"
  new_task next-two
  teardown next-two; check "next teardown exits 0" [ $? = 0 ]
  check "later teardown staged the folder once the log shrank" present "$task/.cleanup-hold/scratch.bin"
  check "record unread cleared" jq -e '.sources[-1].unread == []' "$task/record/data-cleanup.json"
  end_lab
}

scenario_stage_limit() {
  say "== Scenario: own stage stops at FM_TEARDOWN_DATA_STAGE_TIMEOUT under its locks, accented 16 MiB report"
  new_lab stage-limit
  local task="$LAB/data/slim" t0 t1 base_secs secs rss
  mkdir -p "$LAB/data/tiny" "$task/clone"
  printf 'tiny report\n' > "$LAB/data/tiny/report.md"
  new_task tiny
  t0=$(date +%s); teardown tiny; t1=$(date +%s); base_secs=$((t1 - t0))
  say "  baseline: a tiny task's teardown took ${base_secs}s"
  python3 - "$task" <<'PY'
import os, sys
task = sys.argv[1]
line = "Ordinary review notes that name none of the cloned files.\n"
with open(os.path.join(task, "report.md"), "w", encoding="utf-8") as stream:
    stream.write(line * ((16 * 1024 * 1024 - 4096) // len(line)))
    stream.write("Reviewed by José.\n")
for number in range(200):
    with open(os.path.join(task, "clone", f"scratch-{number:03}.bin"), "w") as stream:
        stream.write("scratch\n")
PY
  say "  report.md is $(wc -c < "$task/report.md" | tr -d ' ') bytes with one precomposed accent; clone/ has 200 unmatched files"
  new_task slim
  t0=$(date +%s)
  teardown slim /usr/bin/time -l -o "$LAB/slim.time" env FM_TEARDOWN_DATA_STAGE_TIMEOUT=2
  check "teardown exits 0" [ $? = 0 ]
  t1=$(date +%s); secs=$((t1 - t0))
  rss=$(awk '/maximum resident set size/ {print $1}' "$LAB/slim.time")
  say "  teardown with the 16 MiB report took ${secs}s (baseline ${base_secs}s); largest process peak RSS $((rss / 1024 / 1024)) MiB"
  check "backlog row closed (state=$(row_state slim))" [ "$(row_state slim)" = done ]
  check "nothing staged" absent "$task/.cleanup-hold"
  check "all 200 clone files still in place" [ "$(find "$task/clone" -type f | wc -l | tr -d ' ')" = 200 ]
  check "teardown warning names the task and its 2s stage limit" \
    contains "$LAB/slim.err" "task data slim retained whole for retry: reference matching passed its 2s stage limit"
  check "record retained names the limit" jq -e '.retained == "reference matching passed its 2s stage limit"' "$task/record/data-cleanup.json"
  check "teardown overran the tiny baseline by at most limit+8s" [ "$secs" -le $((base_secs + 10)) ]
  check "peak RSS of any teardown process at most 1 GiB" [ "$rss" -le $((1024 * 1024 * 1024)) ]
  printf 'short report\n' > "$task/report.md"
  new_task next-three
  teardown next-three; check "next teardown exits 0" [ $? = 0 ]
  check "later teardown staged the folder once the report shrank" present "$task/.cleanup-hold/clone/scratch-000.bin"
  check "record stage-limit note cleared" jq -e 'has("retained") | not' "$task/record/data-cleanup.json"
  end_lab
}

write_hold() { # <task> <beads-json> <touch-stamp>
  local task=$1 beads=$2 stamp=$3
  mkdir -p "$LAB/data/$task/record" "$LAB/data/$task/.cleanup-hold"
  printf 'held scratch\n' > "$LAB/data/$task/.cleanup-hold/scratch.bin"
  jq -n --arg task "$task" --arg project "$LAB/project" --arg data "$LAB/data" --argjson beads "$beads" \
    '{version: 1, task: $task, complete: true, expired: false,
      sources: [{project: $project, pr: "", beads: $beads, backlog: {data: $data, task: null}}]}' \
    > "$LAB/data/$task/record/data-cleanup.json"
  touch -t "$stamp" "$LAB/data/$task/record/data-cleanup.json"
}

scenario_slow_expire() {
  say "== Scenario: a slow expiry of another task's hold runs after locks are released; fm-send is not blocked"
  new_lab slow-expire
  local tpid spid i started send_secs lease_seen meta_seen td_alive td_secs rc
  write_hold old-hold '["tst-slow1", "tst-slow2", "tst-slow3"]' 202001010000
  write_hold young-hold '[]' 202101010000
  cat > "$LAB/shims/br" <<SH
#!/usr/bin/env bash
: > "$LAB/br-started"
exec sleep 12
SH
  chmod +x "$LAB/shims/br"
  printf '%s\n' "window=sess:fm-live-y" "kind=ship" "harness=claude" > "$LAB/state/live-y.meta"
  TMUX_TMPDIR="$TMUXDIR" tmux new-session -d -s sess -n fm-live-y 'sleep 900'
  new_task t-slow
  started=$SECONDS
  teardown t-slow FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=8 > "$LAB/t-slow.driver" &
  tpid=$!
  for ((i = 0; i < 600; i++)); do [ -e "$LAB/br-started" ] && break; sleep 0.1; done
  check "teardown reached the other hold's bead read" present "$LAB/br-started"
  local expiry_seen=$SECONDS
  lease_seen=no; [ -e "$LAB/state/.fm-lease-command.lock" ] && lease_seen=yes
  meta_seen=no; [ -e "$LAB/state/.meta-t-slow.lock" ] && meta_seen=yes
  say "  while expiry reads beads: home lease lock held=$lease_seen, t-slow meta lock held=$meta_seen"
  check "home-wide lease lock is free during expiry" [ "$lease_seen" = no ]
  check "the retiring task's meta lock is free during expiry" [ "$meta_seen" = no ]
  i=$SECONDS
  env -u TMUX -u TMUX_PANE FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" PATH="$LAB/shims:$PATH" \
    FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 "$REPO/bin/fm-send.sh" live-y "steer during expiry" \
    > "$LAB/send.out" 2> "$LAB/send.err" &
  spid=$!
  wait "$spid"; rc=$?
  send_secs=$((SECONDS - i))
  td_alive=no; kill -0 "$tpid" 2>/dev/null && td_alive=yes
  say "  concurrent fm-send (lease-guarded, FM_SUPERVISION_ACTOR=main) exit $rc in ${send_secs}s; teardown still expiring=$td_alive"
  sed 's/^/    | /' "$LAB/send.out" "$LAB/send.err" | head -6
  check "fm-send finished within 3s" [ "$send_secs" -le 3 ]
  check "fm-send overlapped the expiry (teardown still running)" [ "$td_alive" = yes ]
  check "fm-send recorded the steer" present "$LAB/state/live-y.inbox/001.msg"
  wait "$tpid"; rc=$?
  td_secs=$((SECONDS - started))
  cat "$LAB/t-slow.driver"
  check "teardown exits 0" [ "$rc" = 0 ]
  say "  teardown took ${td_secs}s in all; $((SECONDS - expiry_seen))s from the first bead read of the expiry to exit, with an 8s expiry budget"
  check "teardown exited within the 8s expiry budget plus 4s after expiry began" [ $((SECONDS - expiry_seen)) -le 12 ]
  check "backlog row closed" [ "$(row_state t-slow)" = done ]
  check "unfinished hold keeps its data" present "$LAB/data/old-hold/.cleanup-hold/scratch.bin"
  check "unreached hold keeps its data" present "$LAB/data/young-hold/.cleanup-hold/scratch.bin"
  check "warning names the hold the budget never reached" contains "$LAB/t-slow.err" "holds left for a later teardown: young-hold"
  check "slow hold marked cut-off" jq -e '.expiry == "cut-off"' "$LAB/data/old-hold/record/data-cleanup.json"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/shims/br"
  new_task next-four
  teardown next-four FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=5; check "next teardown exits 0" [ $? = 0 ]
  check "next teardown expired the hold the slow one starved" absent "$LAB/data/young-hold/.cleanup-hold"
  check "slow hold with unreadable beads still kept whole" present "$LAB/data/old-hold/.cleanup-hold/scratch.bin"
  end_lab
}

hold_count() { find "$LAB/data/giant/.cleanup-hold" -type f 2>/dev/null | wc -l | tr -d ' '; }

scenario_too_large() {
  say "== Scenario: a genuinely large hold: budget cut-off, one full attempt, too-large skip, expiry by hand under its lock"
  new_lab too-large
  local t0 secs sleeper advertised rc
  local by_hand=()
  mkdir -p "$LAB/data/giant/scratch"
  python3 - "$LAB/data/giant/scratch" <<'PY'
import os, sys
for d in range(40):
    os.makedirs(os.path.join(sys.argv[1], f"d{d:02}"))
    for f in range(1000):
        with open(os.path.join(sys.argv[1], f"d{d:02}", f"f{f:04}.bin"), "w") as s:
            s.write("x")
PY
  printf 'giant report\n' > "$LAB/data/giant/report.md"
  new_task giant
  teardown giant FM_TEARDOWN_DATA_STAGE_TIMEOUT=300; check "staging teardown exits 0" [ $? = 0 ]
  check "40,000 scratch files staged (hold has $(hold_count))" [ "$(hold_count)" = 40000 ]
  new_task t-a
  teardown t-a FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4; check "teardown A exits 0" [ $? = 0 ]
  say "  hold files after the 2s budget attempt: $(hold_count)"
  check "A: warning says one full 4s attempt comes next" contains "$LAB/t-a.err" "the next teardown that reaches it gives it one full 4s attempt"
  check "A: record marked cut-off" jq -e '.expiry == "cut-off"' "$LAB/data/giant/record/data-cleanup.json"
  check "A: hold still present" present "$LAB/data/giant/.cleanup-hold"
  new_task t-b
  t0=$SECONDS
  teardown t-b FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4; check "teardown B exits 0" [ $? = 0 ]
  say "  teardown B took $((SECONDS - t0))s; hold files after the full 4s attempt: $(hold_count)"
  check "B: warning names the one full 4s attempt" contains "$LAB/t-b.err" "task data giant expiry stopped after its one full 4s attempt"
  check "B: warning says later teardowns skip it" contains "$LAB/t-b.err" "too large to expire automatically, so later teardowns skip it"
  check "B: record marked too-large" jq -e '.expiry == "too-large"' "$LAB/data/giant/record/data-cleanup.json"
  local before
  before=$(hold_count)
  new_task t-c
  t0=$SECONDS
  teardown t-c FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4; check "teardown C exits 0" [ $? = 0 ]
  say "  teardown C took $((SECONDS - t0))s"
  check "C: warning names the skipped hold" contains "$LAB/t-c.err" \
    "holds too large to expire automatically, skipped and kept for expiry by hand: giant"
  check "C: hold untouched ($before -> $(hold_count) files)" [ "$(hold_count)" = "$before" ]
  check "C: still marked too-large" jq -e '.expiry == "too-large"' "$LAB/data/giant/record/data-cleanup.json"
  advertised=$(sed -n 's/.*expire it by hand with //p' "$LAB/t-b.err")
  say "  advertised by-hand command: $advertised"
  read -r -a by_hand <<< "$advertised"
  sleep 300 &
  sleeper=$!
  mkdir "$LAB/state/.meta-giant.lock" && printf '%s\n' "$sleeper" > "$LAB/state/.meta-giant.lock/pid"
  env PATH="$LAB/shims:$PATH" "${by_hand[@]}" > "$LAB/by-hand-1.out" 2> "$LAB/by-hand-1.err"; rc=$?
  say "  by hand while live pid $sleeper holds the task lock -> exit $rc: $(cat "$LAB/by-hand-1.err")"
  check "by hand refuses a held task lock" [ "$rc" != 0 ]
  check "nothing expired while locked ($before -> $(hold_count))" [ "$(hold_count)" = "$before" ]
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null
  rm -f -- "$LAB/state/.meta-giant.lock/pid"
  rmdir -- "$LAB/state/.meta-giant.lock"
  printf '%s\n' "window=x" > "$LAB/state/giant.meta"
  env PATH="$LAB/shims:$PATH" "${by_hand[@]}" > "$LAB/by-hand-2.out" 2> "$LAB/by-hand-2.err"; rc=$?
  say "  by hand while the task is live -> exit $rc: $(cat "$LAB/by-hand-2.err")"
  check "by hand refuses a live task" [ "$rc" != 0 ]
  rm -f -- "$LAB/state/giant.meta"
  t0=$SECONDS
  env PATH="$LAB/shims:$PATH" "${by_hand[@]}" > "$LAB/by-hand-3.out" 2> "$LAB/by-hand-3.err"; rc=$?
  say "  by hand, lock free -> exit $rc in $((SECONDS - t0))s"
  sed 's/^/    | /' "$LAB/by-hand-3.out" "$LAB/by-hand-3.err" | head -5
  check "by hand succeeds" [ "$rc" = 0 ]
  check "hold expired" absent "$LAB/data/giant/.cleanup-hold"
  check "record expired with no mark" jq -e '.expired == true and (has("expiry") | not)' "$LAB/data/giant/record/data-cleanup.json"
  check "task lock released" absent "$LAB/state/.meta-giant.lock"
  check "report kept" present "$LAB/data/giant/report.md"
  end_lab
}

scenario_expired_receipts() {
  say "== Scenario: 3,000 already-expired records never use up the expiry budget"
  new_lab expired-receipts
  local t0
  write_hold zz-live '[]' 202101010000
  python3 - "$LAB/data" <<'PY'
import json, os, sys
for number in range(3000):
    task = f"done-{number}"
    record = os.path.join(sys.argv[1], task, "record")
    os.makedirs(record)
    path = os.path.join(record, "data-cleanup.json")
    with open(path, "w") as stream:
        json.dump({"version": 1, "task": task, "complete": True, "expired": True,
                   "sources": [{"project": "", "pr": "", "beads": []}]}, stream)
    os.utime(path, (1577836800, 1577836800))
PY
  new_task t-e
  t0=$SECONDS
  teardown t-e FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=5; check "teardown exits 0" [ $? = 0 ]
  say "  teardown took $((SECONDS - t0))s"
  check "the one live hold expired" absent "$LAB/data/zz-live/.cleanup-hold"
  check "no budget-exhausted warning" bash -c '! grep -q "expiry budget ran out" "$1"' _ "$LAB/t-e.err"
  end_lab
}

scenario_named_beads() {
  say "== Scenario (intent): named beads resolve in the database that owns them; unresolvable id keeps data whole, close completes, retried"
  new_lab named-beads
  local home="$LAB/home" ac gsp variant bead task
  mkdir -p "$home/.agent-config" "$home/dev/gsp-beads"
  (cd "$home/.agent-config" && HOME="$home" br init --prefix .agent-config -q >/dev/null 2>&1)
  ac=$(cd "$home/.agent-config" && HOME="$home" br create "lab bead" -d '[capture](proof.png)' --json 2>/dev/null | jq -r '.id')
  (cd "$home/dev/gsp-beads" && HOME="$home" br init --prefix gsp -q >/dev/null 2>&1)
  gsp=$(cd "$home/dev/gsp-beads" && HOME="$home" br create "lab bead" -d '[capture](proof.png)' --json 2>/dev/null | jq -r '.id')
  say "  real br databases: $ac in <lab>/home/.agent-config, $gsp in <lab>/home/dev/gsp-beads"
  for variant in "ac:$ac" "gsp:$gsp" "unread:nope-zz9"; do
    bead=${variant#*:}
    task="$LAB/data/named-${variant%%:*}"
    mkdir -p "$task"
    printf 'Bead %s\n' "$bead" > "$task/brief.md"
    printf 'linked evidence\n' > "$task/proof.png"
    printf 'scratch\n' > "$task/discard.bin"
    new_task "named-${variant%%:*}"
    teardown "named-${variant%%:*}" HOME="$home" BEADS_DIR=/wrong BEADS_DB=/wrong BR_DB=/wrong
    check "$bead: teardown exits 0" [ $? = 0 ]
    check "$bead: backlog row closed" [ "$(row_state "named-${variant%%:*}")" = done ]
    check "$bead: no pending close" absent "$LAB/state/named-${variant%%:*}.backlog-close"
    check "$bead: bead-linked proof.png kept" [ "$(cat "$task/proof.png")" = 'linked evidence' ]
    if [ "${variant%%:*}" = unread ]; then
      check "$bead: scratch not moved" [ "$(cat "$task/discard.bin")" = scratch ]
      check "$bead: nothing staged" absent "$task/.cleanup-hold"
      check "$bead: named in teardown output" contains "$LAB/named-unread.err" "$bead"
      check "$bead: record unread names it" jq -e --arg b "$bead" '.complete == false and .sources[0].unread == [$b]' "$task/record/data-cleanup.json"
    else
      check "$bead: unlinked scratch staged" present "$task/.cleanup-hold/discard.bin"
    fi
  done
  tasks-axi add nope-zz9 'named evidence' --body '[capture](proof.png)' --file "$LAB/data/backlog.md" >/dev/null
  new_task named-next
  teardown named-next HOME="$home"; check "retry teardown exits 0" [ $? = 0 ]
  check "nope-zz9 now read from Firstmate's backlog: scratch staged" present "$LAB/data/named-unread/.cleanup-hold/discard.bin"
  check "nope-zz9: proof kept" present "$LAB/data/named-unread/proof.png"
  check "nope-zz9: unread cleared" jq -e '.sources[0].unread == []' "$LAB/data/named-unread/record/data-cleanup.json"
  end_lab
}

for scenario in "$@"; do
  "scenario_$scenario"
done
say "== failures: $FAILS"
[ "$FAILS" = 0 ]
