#!/usr/bin/env bash
# Live drive of the task-data cleanup change against disposable lab homes.
# Real: bin/fm-teardown.sh, bin/fm-task-data-lib.sh, bin/fm-task-data.py,
# bin/fm-send.sh, br (disposable beads databases under a disposable HOME),
# tasks-axi (lab backlog), dcg, jq, python3, tmux (private lab socket).
# Stubbed outward systems only: treehouse, no-mistakes, gh, gh-axi.
# Usage: live-drive.sh <worktree> <part: beads|stage|expire|receipts>
set -u
WT=$1
PART=$2
PASSES=0
FAILS=0
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then
    PASSES=$((PASSES + 1))
    echo "PASS: $what"
  else
    FAILS=$((FAILS + 1))
    echo "FAIL: $what"
  fi
}

make_lab() {
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  LAB=$(cd "$LAB" && pwd -P)
  "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/userhome/.agent-config" "$LAB/userhome/dev/gsp-beads" "$LAB/projects/proj"
  printf 'tmux\n' > "$LAB/config/backend"
  touch "$LAB/state/.last-watcher-beat"
  cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/fakebin/treehouse"
  cat > "$LAB/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$LAB/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$LAB/fakebin/"*
  git init -q "$LAB/projects/proj"
  (cd "$LAB/projects/proj" && HOME="$LAB/userhome" br init --prefix proof >/dev/null 2>&1)
  (cd "$LAB/userhome/.agent-config" && git init -q . && HOME="$LAB/userhome" br init --prefix .agent-config >/dev/null 2>&1)
  (cd "$LAB/userhome/dev/gsp-beads" && git init -q . && HOME="$LAB/userhome" br init --prefix gsp >/dev/null 2>&1)
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s firstmate -n keep 'sleep 3600'
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s sess -n fm-live-y 'cat'
  LAB_TMUX=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display -p -t firstmate '#{socket_path},#{pid},0')
  echo "lab home: $LAB"
}

drop_lab() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "${LAB:?}"
}

new_bead() { # <owner-dir> <title> <description>
  (cd "$1" && HOME="$LAB/userhome" br create "$2" --description "$3" --json 2>/dev/null) | jq -r '.id'
}

start_task() { # <id>
  local id=$1
  tasks-axi add "$id" "lab task $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -d -t firstmate -n "fm-$id" 'sleep 3600'
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/missing" \
    "project=$LAB/projects/proj" "kind=ship" "mode=local-only" "spawn_gen=$id" > "$LAB/state/$id.meta"
}

teardown() { # <id> [VAR=value...]; writes $LAB/<id>.out/.err, sets TD_RC and TD_SECONDS
  local id=$1 started
  shift
  started=$(python3 -c 'import time; print(time.time())')
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u FM_TEARDOWN_DATA_STAGE_TIMEOUT \
    -u FM_TEARDOWN_DATA_EXPIRE_TIMEOUT -u FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT \
    HOME="$LAB/userhome" FM_HOME="$LAB" TMUX="$LAB_TMUX" TMUX_TMPDIR="$LAB/tmux" \
    PATH="$LAB/fakebin:$PATH" "$@" "$WT/bin/fm-teardown.sh" "$id" > "$LAB/$id.out" 2> "$LAB/$id.err"
  TD_RC=$?
  TD_SECONDS=$(python3 -c "import time; print(round(time.time() - $started, 1))")
  echo "--- teardown $id rc=$TD_RC ${TD_SECONDS}s"
  sed 's/^/  out| /' "$LAB/$id.out"
  sed 's/^/  err| /' "$LAB/$id.err"
  return "$TD_RC"
}

row_state() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
present() { [ -e "$1" ] || [ -L "$1" ]; }
absent() { ! present "$1"; }
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
record() { jq -c "$1" "$LAB/data/$2/record/data-cleanup.json"; }
recq() { jq -e "$1" "$LAB/data/$2/record/data-cleanup.json" >/dev/null; }

part_beads() {
  make_lab
  local ac gsp
  ac=$(new_bead "$LAB/userhome/.agent-config" "agent-config evidence" '[capture](proof.png)')
  gsp=$(new_bead "$LAB/userhome/dev/gsp-beads" "gsp evidence" '[capture](proof.png)')
  echo "real beads: $ac (agent-config db), $gsp (gsp-beads db)"

  echo "=== Scenario: dotted .agent-config bead resolves in ~/.agent-config and the close completes"
  mkdir -p "$LAB/data/a1"
  printf 'Bead %s\n' "$ac" > "$LAB/data/a1/brief.md"
  printf 'linked evidence\n' > "$LAB/data/a1/proof.png"
  printf 'scratch\n' > "$LAB/data/a1/discard.bin"
  start_task a1
  teardown a1
  check "a1 teardown exits 0" [ "$TD_RC" = 0 ]
  check "a1 backlog row is done" [ "$(row_state a1)" = done ]
  check "a1 has no pending backlog close" absent "$LAB/state/a1.backlog-close"
  check "a1 bead-linked proof.png kept in place" present "$LAB/data/a1/proof.png"
  check "a1 scratch staged into .cleanup-hold" present "$LAB/data/a1/.cleanup-hold/discard.bin"
  check "a1 record: complete, bead listed, nothing unread" recq ".complete == true and (.sources[0].beads | index(\"$ac\")) != null and .sources[0].unread == []" a1
  echo "  record a1: $(record '{complete, beads: .sources[0].beads, unread: .sources[0].unread}' a1)"

  echo "=== Scenario: gsp-* bead resolves in ~/dev/gsp-beads; next teardown expires a1's hold"
  mkdir -p "$LAB/data/a2"
  printf 'Bead %s\n' "$gsp" > "$LAB/data/a2/brief.md"
  printf 'linked evidence\n' > "$LAB/data/a2/proof.png"
  printf 'scratch\n' > "$LAB/data/a2/discard.bin"
  start_task a2
  teardown a2
  check "a2 teardown exits 0" [ "$TD_RC" = 0 ]
  check "a2 backlog row is done" [ "$(row_state a2)" = done ]
  check "a2 has no pending backlog close" absent "$LAB/state/a2.backlog-close"
  check "a2 bead-linked proof.png kept" present "$LAB/data/a2/proof.png"
  check "a2 scratch staged" present "$LAB/data/a2/.cleanup-hold/discard.bin"
  check "a2 record: complete, nothing unread" recq '.complete == true and .sources[0].unread == []' a2
  check "a1 hold expired by a2's teardown" absent "$LAB/data/a1/.cleanup-hold"
  check "a1 linked proof.png still kept after expiry" present "$LAB/data/a1/proof.png"
  check "a1 record marked expired" recq '.expired == true' a1

  echo "=== Scenario (adversarial): unresolvable bead keeps data whole, close completes, id named, retried later"
  mkdir -p "$LAB/data/a3"
  printf 'Bead proof-nothere\n' > "$LAB/data/a3/brief.md"
  printf 'linked evidence\n' > "$LAB/data/a3/proof.png"
  printf 'scratch\n' > "$LAB/data/a3/discard.bin"
  start_task a3
  teardown a3
  check "a3 teardown exits 0" [ "$TD_RC" = 0 ]
  check "a3 backlog row is done" [ "$(row_state a3)" = done ]
  check "a3 has no pending backlog close" absent "$LAB/state/a3.backlog-close"
  check "a3 meta retired" absent "$LAB/state/a3.meta"
  check "a3 scratch NOT moved (data whole)" present "$LAB/data/a3/discard.bin"
  check "a3 nothing staged" absent "$LAB/data/a3/.cleanup-hold"
  check "a3 teardown output names proof-nothere" has "$LAB/a3.err" proof-nothere
  check "a3 record: incomplete, unread == [proof-nothere]" recq '.complete == false and .sources[0].unread == ["proof-nothere"]' a3
  echo "  record a3: $(record '{complete, unread: .sources[0].unread}' a3)"
  echo "  (making proof-nothere readable through Firstmate's backlog fallback)"
  tasks-axi add proof-nothere 'named evidence' --body '[capture](proof.png)' --file "$LAB/data/backlog.md" >/dev/null

  echo "=== Scenario: kept report over 1 MiB prepares, closes, stages; a3 retried by this teardown"
  mkdir -p "$LAB/data/a4/proof"
  { head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$LAB/data/a4/report.md"
  printf 'keep this image\n' > "$LAB/data/a4/proof/capture.png"
  printf 'scratch\n' > "$LAB/data/a4/scratch.bin"
  echo "  report.md bytes: $(wc -c < "$LAB/data/a4/report.md" | tr -d ' ')"
  start_task a4
  teardown a4
  check "a4 teardown exits 0" [ "$TD_RC" = 0 ]
  check "a4 backlog row is done" [ "$(row_state a4)" = done ]
  check "a4 has no pending backlog close" absent "$LAB/state/a4.backlog-close"
  check "a4 report.md intact" [ "$(wc -c < "$LAB/data/a4/report.md" | tr -d ' ')" -gt 1400000 ]
  check "a4 file linked at end of report kept" present "$LAB/data/a4/proof/capture.png"
  check "a4 scratch staged" present "$LAB/data/a4/.cleanup-hold/scratch.bin"
  check "a4 record complete with no cleanup error" recq '.complete == true' a4
  check "a3 retry: unread cleared" recq '.sources[0].unread == []' a3
  check "a3 retry: scratch now staged" present "$LAB/data/a3/.cleanup-hold/discard.bin"
  check "a3 retry: backlog-linked proof.png kept" present "$LAB/data/a3/proof.png"
  echo "  record a3 after retry: $(record '{complete, unread: .sources[0].unread}' a3)"

  echo "=== Scenario (boundary): kept report over 16 MiB is an unread reference; folder whole, close completes"
  mkdir -p "$LAB/data/a5"
  head -c $((17 * 1024 * 1024)) /dev/zero | tr '\0' 'y' > "$LAB/data/a5/report.md"
  printf 'scratch\n' > "$LAB/data/a5/scratch.bin"
  start_task a5
  teardown a5
  check "a5 teardown exits 0" [ "$TD_RC" = 0 ]
  check "a5 backlog row is done" [ "$(row_state a5)" = done ]
  check "a5 has no pending backlog close" absent "$LAB/state/a5.backlog-close"
  check "a5 scratch NOT moved" present "$LAB/data/a5/scratch.bin"
  check "a5 nothing staged" absent "$LAB/data/a5/.cleanup-hold"
  check "a5 teardown output names report.md" has "$LAB/a5.err" report.md
  check "a5 record unread lists report.md" recq '.sources[0].unread | index("report.md") != null' a5
  check "a4 hold expired on the next teardown" absent "$LAB/data/a4/.cleanup-hold"
  check "a4 linked capture.png and report kept after expiry" present "$LAB/data/a4/proof/capture.png"
  echo "  record a5: $(record '{complete, unread: .sources[0].unread}' a5)"
  drop_lab
}

part_stage() {
  make_lab
  local i
  echo "=== Scenario: a retiring task's stage stops at its limit under the locks; nothing moves, close completes"
  mkdir -p "$LAB/data/b1/clone"
  head -c $((16 * 1024 * 1024 - 4096)) /dev/zero | tr '\0' 'z' > "$LAB/data/b1/report.md"
  for ((i = 0; i < 200; i++)); do printf 'scratch %s\n' "$i" > "$LAB/data/b1/clone/unmatched-$i.bin"; done
  start_task b1
  teardown b1 FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_STAGE_TIMEOUT=2
  check "b1 teardown exits 0" [ "$TD_RC" = 0 ]
  check "b1 backlog row is done" [ "$(row_state b1)" = done ]
  check "b1 has no pending backlog close" absent "$LAB/state/b1.backlog-close"
  check "b1 all 200 unmatched files still in place" [ "$(find "$LAB/data/b1/clone" -name 'unmatched-*.bin' | wc -l | tr -d ' ')" = 200 ]
  check "b1 nothing staged" absent "$LAB/data/b1/.cleanup-hold"
  check "b1 warning names the task and the 2s limit" has "$LAB/b1.err" "task data b1 retained whole for retry: reference matching passed its 2s stage limit"
  check "b1 record retained names the limit" recq '.retained == "reference matching passed its 2s stage limit"' b1
  check "b1 lease and meta locks released at exit" absent "$LAB/state/.fm-lease-command.lock"
  echo "  record b1: $(record '{complete, retained}' b1)"

  echo "=== Scenario: accented kept text stays within the limit and bounded memory (product CLI under /usr/bin/time)"
  mkdir -p "$LAB/data/b2/clone"
  { printf 'Jos\xc3\xa9 caf\xc3\xa9\n'; head -c $((16 * 1024 * 1024 - 8192)) /dev/zero | tr '\0' 'w'; } > "$LAB/data/b2/report.md"
  for ((i = 0; i < 200; i++)); do printf 'scratch %s\n' "$i" > "$LAB/data/b2/clone/unmatched-$i.bin"; done
  env HOME="$LAB/userhome" PATH="$LAB/fakebin:$PATH" FM_TEARDOWN_DATA_STAGE_TIMEOUT=2 \
    /usr/bin/time -l python3 "$WT/bin/fm-task-data.py" stage "$LAB/data" "$LAB/state" b2 "$LAB/projects/proj" '' \
    > "$LAB/b2.out" 2> "$LAB/b2.err"
  echo "  stage rc=$?"
  grep -E 'retained|real|maximum resident' "$LAB/b2.err" | sed 's/^/  err| /'
  local rss real
  rss=$(awk '/maximum resident set size/ {print $1}' "$LAB/b2.err")
  real=$(awk '/ real / {print $1}' "$LAB/b2.err")
  check "b2 accented stage retained whole at its 2s limit" has "$LAB/b2.err" "task data b2 retained whole for retry: reference matching passed its 2s stage limit"
  check "b2 stage wall time within limit + 8s (${real}s)" python3 -c "import sys; sys.exit(0 if float('$real') <= 10 else 1)"
  check "b2 peak RSS under 700 MB (was ~1.4 GB before) ($((rss / 1048576)) MB)" [ "$rss" -lt $((700 * 1048576)) ]
  check "b2 nothing moved" [ "$(find "$LAB/data/b2/clone" -name 'unmatched-*.bin' | wc -l | tr -d ' ')" = 200 ]

  echo "=== Scenario: once the report shrinks, a later teardown of a different task stages b1 and clears the note"
  printf 'small report\n' > "$LAB/data/b1/report.md"
  rm -rf "${LAB:?}/data/b2"
  start_task b3
  teardown b3 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=30
  check "b3 teardown exits 0" [ "$TD_RC" = 0 ]
  check "b1 scratch now staged by the later teardown" present "$LAB/data/b1/.cleanup-hold/clone/unmatched-0.bin"
  check "b1 retained note cleared" recq 'has("retained") | not' b1
  echo "  record b1: $(record '{complete, retained}' b1)"
  drop_lab
}

write_hold() { # <id> <files-in-hold> <report-bytes> <mtime>
  local id=$1 count=$2 bytes=$3 when=$4 i
  mkdir -p "$LAB/data/$id/record" "$LAB/data/$id/.cleanup-hold"
  for ((i = 0; i < count; i++)); do printf 'held %s\n' "$i" > "$LAB/data/$id/.cleanup-hold/held-$i.bin"; done
  [ "$bytes" = 0 ] || head -c "$bytes" /dev/zero | tr '\0' 'q' > "$LAB/data/$id/report.md"
  jq -n --arg task "$id" --arg project "$LAB/projects/proj" --arg data "$LAB/data" \
    '{version: 1, task: $task, complete: true, expired: false,
      sources: [{project: $project, pr: "", beads: [], backlog: {data: $data, task: null}}]}' \
    > "$LAB/data/$id/record/data-cleanup.json"
  touch -t "$when" "$LAB/data/$id/record/data-cleanup.json"
}

part_expire() {
  make_lab
  local pid send_started send_seconds i lock_seen=unknown seen_complete=0 mtime_before
  # A real slow hold: a 15 MiB kept report and 150 held files, each an unmatched entry the expiry scans.
  write_hold old-done 150 $((15 * 1024 * 1024)) 202001010000
  write_hold young-done 1 0 202101010000
  printf '%s\n' "window=sess:fm-live-y" "kind=ship" "harness=claude" > "$LAB/state/live-y.meta"

  echo "=== Scenario: expiry of other holds runs after every lock is released; a concurrent fm-send is not blocked"
  start_task c1
  teardown c1 FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=4 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=6 &
  pid=$!
  for ((i = 0; i < 600; i++)); do
    if has "$LAB/c1.out" "teardown c1 complete" 2>/dev/null && pgrep -f "fm-task-data.py expire $LAB/data $LAB/state old-done" >/dev/null; then
      seen_complete=1
      break
    fi
    sleep 0.1
  done
  if [ "$seen_complete" = 1 ]; then
    if present "$LAB/state/.fm-lease-command.lock"; then lock_seen=held; else lock_seen=free; fi
    send_started=$(python3 -c 'import time; print(time.time())')
    env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      HOME="$LAB/userhome" FM_HOME="$LAB" TMUX="$LAB_TMUX" TMUX_TMPDIR="$LAB/tmux" PATH="$LAB/fakebin:$PATH" \
      FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 "$WT/bin/fm-send.sh" live-y "steer during expiry" \
      > "$LAB/send.out" 2> "$LAB/send.err"
    echo "  fm-send rc=$?"
    send_seconds=$(python3 -c "import time; print(round(time.time() - $send_started, 1))")
    still_expiring=no
    pgrep -f "fm-task-data.py expire $LAB/data $LAB/state old-done" >/dev/null && still_expiring=yes
  fi
  wait "$pid"
  local c1_rc=$?
  check "c1 teardown exits 0" [ "$c1_rc" = 0 ]
  check "c1 reached its expiry phase after printing complete" [ "$seen_complete" = 1 ]
  check "lease lock free while expiry runs (observed: $lock_seen)" [ "$lock_seen" = free ]
  check "concurrent fm-send finished in under 5s (${send_seconds:-?}s)" python3 -c "import sys; sys.exit(0 if float('${send_seconds:-999}') < 5 else 1)"
  check "expiry was still running when fm-send finished ($still_expiring)" [ "${still_expiring:-no}" = yes ]
  check "fm-send recorded the steer in live-y's inbox" present "$LAB/state/live-y.inbox/001.msg"
  sed 's/^/  send| /' "$LAB/send.out" "$LAB/send.err"
  echo "  lab pane live-y: $(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t sess:fm-live-y | grep -v '^$' | tail -2 | tr '\n' '|')"
  check "c1 backlog row is done" [ "$(row_state c1)" = done ]
  check "c1 warns old-done was cut off at 4s with one full 6s attempt next" has "$LAB/c1.err" "task data old-done expiry stopped after 4s; deletions it made stay done and the rest stays held; the next teardown that reaches it gives it one full 6s attempt"
  check "c1 names young-done as left for a later teardown" has "$LAB/c1.err" "holds left for a later teardown: young-done"
  check "old-done record marked cut-off" recq '.expiry == "cut-off"' old-done
  check "old-done held data kept" [ "$(find "$LAB/data/old-done/.cleanup-hold" -type f | wc -l | tr -d ' ')" = 150 ]

  echo "=== Scenario: next teardown expires the starved fast hold first, then gives old-done exactly one full attempt"
  start_task c2
  teardown c2 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=4 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=6
  check "c2 teardown exits 0" [ "$TD_RC" = 0 ]
  check "young-done expired (not starved by the slow hold)" absent "$LAB/data/young-done/.cleanup-hold"
  check "c2 warns old-done is too large after its one full 6s attempt and gives the by-hand command" has "$LAB/c2.err" "task data old-done expiry stopped after its one full 6s attempt; deletions it made stay done and the rest stays held; it is too large to expire automatically, so later teardowns skip it and name it; expire it by hand with bash $WT/bin/fm-task-data-lib.sh expire $LAB/data $LAB/state old-done"
  check "old-done record marked too-large" recq '.expiry == "too-large"' old-done
  check "old-done held data kept" present "$LAB/data/old-done/.cleanup-hold/held-149.bin"

  echo "=== Scenario: a too-large hold is skipped and named on later teardowns without spending budget"
  mtime_before=$(stat -f %m "$LAB/data/old-done/record/data-cleanup.json")
  start_task c3
  teardown c3 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=4 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=6
  check "c3 teardown exits 0" [ "$TD_RC" = 0 ]
  check "c3 names old-done as too large, skipped and kept" has "$LAB/c3.err" "warning: task data holds too large to expire automatically, skipped and kept for expiry by hand: old-done"
  check "c3 did not attempt old-done (record untouched)" [ "$(stat -f %m "$LAB/data/old-done/record/data-cleanup.json")" = "$mtime_before" ]
  check "old-done still marked too-large" recq '.expiry == "too-large"' old-done

  echo "=== Scenario (adversarial): the advertised by-hand command refuses while another process holds the task lock"
  local lockdir holder
  lockdir="$LAB/state/.meta-old-done.lock"
  sleep 300 &
  holder=$!
  mkdir "$lockdir" && printf '%s\n' "$holder" > "$lockdir/pid"
  env HOME="$LAB/userhome" FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" \
    bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" old-done > "$LAB/hand1.out" 2> "$LAB/hand1.err"
  local hand_rc=$?
  sed 's/^/  hand1| /' "$LAB/hand1.out" "$LAB/hand1.err"
  check "by-hand expire refused (rc=$hand_rc) under a held lock" [ "$hand_rc" != 0 ]
  check "refusal says the task is locked and nothing was expired" has "$LAB/hand1.err" "task old-done is locked by another process; nothing was expired"
  check "old-done hold untouched after refusal" present "$LAB/data/old-done/.cleanup-hold/held-149.bin"
  check "the other process's lock left in place" present "$lockdir/pid"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -rf "${lockdir:?}"

  echo "=== Scenario: the by-hand command expires the too-large hold with no time limit and releases the lock"
  local hs
  hs=$(python3 -c 'import time; print(time.time())')
  env HOME="$LAB/userhome" FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" \
    bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" old-done > "$LAB/hand2.out" 2> "$LAB/hand2.err"
  hand_rc=$?
  echo "  by-hand expire took $(python3 -c "import time; print(round(time.time() - $hs, 1))")s"
  sed 's/^/  hand2| /' "$LAB/hand2.out" "$LAB/hand2.err"
  check "by-hand expire exits 0" [ "$hand_rc" = 0 ]
  check "old-done hold removed" absent "$LAB/data/old-done/.cleanup-hold"
  check "old-done kept report.md stays" present "$LAB/data/old-done/report.md"
  check "old-done record expired with mark cleared" recq '.expired == true and (has("expiry") | not)' old-done
  check "task meta lock released after by-hand expire" absent "$lockdir"
  drop_lab
}

part_receipts() {
  make_lab
  local i
  echo "=== Scenario: thousands of expired records do not use up the expiry budget before a live hold"
  for ((i = 0; i < 3000; i++)); do
    mkdir -p "$LAB/data/exp-$i/record"
    printf '{"version":1,"task":"exp-%s","expired":true,"complete":true,"sources":[]}\n' "$i" > "$LAB/data/exp-$i/record/data-cleanup.json"
  done
  find "$LAB/data" -path '*/exp-*/record/data-cleanup.json' -exec touch -t 202001010000 {} +
  write_hold live-hold 1 0 202101010000
  start_task d1
  teardown d1
  check "d1 teardown exits 0" [ "$TD_RC" = 0 ]
  check "d1 backlog row is done" [ "$(row_state d1)" = done ]
  check "live hold expired despite 3000 older expired records" absent "$LAB/data/live-hold/.cleanup-hold"
  check "no budget-ran-out warning" lacks "$LAB/d1.err" "expiry budget ran out"
  local ls_start
  ls_start=$(python3 -c 'import time; print(time.time())')
  python3 "$WT/bin/fm-task-data.py" pending "$LAB/data" > "$LAB/pending.out"
  echo "  pending listing over 3001 records took $(python3 -c "import time; print(round(time.time() - $ls_start, 2))")s and printed $(wc -l < "$LAB/pending.out" | tr -d ' ') rows"
  drop_lab
}

part_debug() {
  make_lab
  start_task z1
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    HOME="$LAB/userhome" FM_HOME="$LAB" TMUX="$LAB_TMUX" TMUX_TMPDIR="$LAB/tmux" \
    PATH="$LAB/fakebin:$PATH" bash -x "$WT/bin/fm-teardown.sh" z1 > "$LAB/z1.out" 2> "$LAB/z1.trace"
  echo "rc=$?"
  grep -v '^++*' "$LAB/z1.trace" | tail -5
  tail -40 "$LAB/z1.trace"
  drop_lab
}

send_now() { # <label>; sets SEND_SECONDS and SEND_RC
  local started
  started=$(python3 -c 'import time; print(time.time())')
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    HOME="$LAB/userhome" FM_HOME="$LAB" TMUX="$LAB_TMUX" TMUX_TMPDIR="$LAB/tmux" PATH="$LAB/fakebin:$PATH" \
    FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 "$WT/bin/fm-send.sh" live-y "$1" > "$LAB/send-$1.out" 2> "$LAB/send-$1.err"
  SEND_RC=$?
  SEND_SECONDS=$(python3 -c "import time; print(round(time.time() - $started, 1))")
  echo "  fm-send '$1' rc=$SEND_RC took ${SEND_SECONDS}s"
}

part_send() {
  make_lab
  local pid i seen=0 samples=0 held=0 still=no c1_rc base1 base2 during
  write_hold old-done 150 $((15 * 1024 * 1024)) 202001010000
  printf '%s\n' "window=sess:fm-live-y" "kind=ship" "harness=claude" > "$LAB/state/live-y.meta"
  echo "=== Scenario: fm-send during another task's expiry costs no more than an idle fm-send (lease lock free throughout)"
  send_now baseline-1
  base1=$SEND_SECONDS
  start_task c1
  teardown c1 FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=25 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=30 &
  pid=$!
  for ((i = 0; i < 900; i++)); do
    if has "$LAB/c1.out" "teardown c1 complete" 2>/dev/null && pgrep -f "fm-task-data.py expire $LAB/data $LAB/state old-done" >/dev/null; then
      seen=1
      break
    fi
    sleep 0.1
  done
  if [ "$seen" = 1 ]; then
    send_now during-expiry
    during=$SEND_SECONDS
    pgrep -f "fm-task-data.py expire $LAB/data $LAB/state old-done" >/dev/null && still=yes
    while pgrep -f "fm-task-data.py expire $LAB/data $LAB/state old-done" >/dev/null; do
      samples=$((samples + 1))
      { present "$LAB/state/.fm-lease-command.lock" || present "$LAB/state/.meta-c1.lock"; } && held=$((held + 1))
      sleep 0.2
    done
  fi
  wait "$pid"
  c1_rc=$?
  send_now baseline-2
  base2=$SEND_SECONDS
  check "c1 teardown exits 0" [ "$c1_rc" = 0 ]
  check "c1 reached its expiry phase after printing complete" [ "$seen" = 1 ]
  check "expiry still running when the concurrent fm-send finished ($still)" [ "$still" = yes ]
  check "lease and c1 meta locks absent in all $samples samples taken during expiry (held in $held)" [ "$samples" -gt 0 ] && [ "$held" = 0 ]
  check "fm-send during expiry (${during}s) within 3s of the slower idle baseline (${base1}s, ${base2}s)" \
    python3 -c "import sys; sys.exit(0 if float('$during') <= max(float('$base1'), float('$base2')) + 3 else 1)"
  check "all three steers recorded in live-y's inbox" [ "$(find "$LAB/state/live-y.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 3 ]
  check "c1 backlog row is done" [ "$(row_state c1)" = done ]
  check "old-done held data kept by the cut-off attempt" present "$LAB/data/old-done/.cleanup-hold/held-149.bin"
  drop_lab
}

case "$PART" in
  send) part_send ;;
  debug) part_debug ;;
  beads) part_beads ;;
  stage) part_stage ;;
  expire) part_expire ;;
  receipts) part_receipts ;;
  *) echo "unknown part" >&2; exit 2 ;;
esac
echo "RESULT part=$PART passes=$PASSES fails=$FAILS"
[ "$FAILS" = 0 ]
