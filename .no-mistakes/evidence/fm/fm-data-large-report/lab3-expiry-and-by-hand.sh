#!/usr/bin/env bash
# Lab 3: expiring other tasks' holds runs after teardown releases its locks
# (a concurrent fm-send is not blocked), the budget cuts an attempt off, a
# cut-off hold gets one full attempt of exactly its own limit, a hold cut off
# again is marked too-large, skipped and named, and the advertised by-hand
# command finishes a never-staged hold, refuses a locked or live task, and keeps
# scratch it re-held from an already-staged hold. Slowness is real: each hold
# names project beads that the real br reads one at a time.
. "$(dirname "$0")/lab-lib.sh"
new_lab
trap '[ -z "${HOLDER:-}" ] || kill "$HOLDER" 2>/dev/null; end_lab' EXIT
(cd "$PROJ" && HOME="$LAB/home" br init --prefix lab -q)
# 300 real beads, bulk-created; each hold names them all, so each expiry pass
# makes 300 real br reads (the live home has holds naming about 1,100).
for n in $(seq 1 300); do printf '## slow bead %s\n\nnotes %s\n\n' "$n" "$n"; done > "$LAB/beads.md"
(cd "$PROJ" && HOME="$LAB/home" br create -f "$LAB/beads.md" >/dev/null)
read -r -a BEADS <<< "$(cd "$PROJ" && HOME="$LAB/home" br list --json --limit 0 | jq -r '[.issues[].id] | join(" ")')"
echo "project beads: ${#BEADS[@]} (first ${BEADS[0]})"
s0=$(date +%s.%N); (cd "$PROJ" && br show "${BEADS[0]}" --json >/dev/null)
echo "one real br show took about $(python3 -c "import time,sys; print(round(time.time()-float(sys.argv[1]),2))" "$s0")s"
brief() { local b; for b in "${BEADS[@]}"; do printf 'Bead %s\n' "$b"; done; }

say "setup: aa-staged names 300 beads and is staged by its own teardown"
add_task aa-staged
A="$LAB/data/aa-staged"
brief > "$A/brief.md"; printf 'scratch a\n' > "$A/aa.bin"; printf 'scratch a2\n' > "$A/aa2.bin"
s0=$(date +%s)
lab_teardown aa-staged FM_TEARDOWN_DATA_STAGE_TIMEOUT=600; rc=$?
echo "aa-staged teardown (300 bead reads under its own lock, stage limit 600s) took $(( $(date +%s) - s0 ))s"
show "$LAB/aa-staged.err"
check "aa-staged teardown exits 0" [ "$rc" = 0 ]
check "aa-staged scratch staged" [ -f "$A/.cleanup-hold/aa.bin" ]
check "aa-staged record complete" jq -e '.complete == true and .expired == false' "$A/record/data-cleanup.json"

say "S6 + S5b: bb-unstaged's own stage passes its 2s limit; its expiry of aa-staged runs after its locks are released"
add_task live-y
printf 'harness=claude\n' >> "$LAB/state/live-y.meta"
add_task bb-unstaged
B="$LAB/data/bb-unstaged"
brief > "$B/brief.md"; printf 'scratch b\n' > "$B/bb.bin"
lab_teardown bb-unstaged FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_STAGE_TIMEOUT=2 \
  FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=8 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=3 &
TD=$!
for ((i = 0; i < 1800; i++)); do grep -q 'teardown bb-unstaged complete' "$LAB/bb-unstaged.out" 2>/dev/null && break; sleep 0.1; done
for ((i = 0; i < 100; i++)); do pgrep -f "fm-task-data.py expire $LAB/data $LAB/state aa-staged" >/dev/null && break; sleep 0.1; done
expiring=no; pgrep -f "fm-task-data.py expire $LAB/data $LAB/state aa-staged" >/dev/null && expiring=yes
echo "expiry of aa-staged running: $expiring"
echo "locks present in state/ while expiry runs:"; ls -a "$LAB/state" | grep -E '\.lock$' || echo "(none)"
check "expiry of another task's hold is running" [ "$expiring" = yes ]
check "home-wide lease lock released during expiry" [ ! -e "$LAB/state/.fm-lease-command.lock" ]
check "bb-unstaged meta lock released during expiry" [ ! -e "$LAB/state/.meta-bb-unstaged.lock" ]
check "bb-unstaged control lock released during expiry" [ ! -e "$LAB/state/.control-bb-unstaged.lock" ]
s0=$(date +%s.%N)
env -u NO_MISTAKES_GATE -u TMUX -u BEADS_PATH FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" PATH="$STUBS:$PATH" \
  FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" live-y "steer during expiry" \
  > "$LAB/send.out" 2> "$LAB/send.err"; src=$?
send_s=$(python3 -c "import time,sys; print(round(time.time()-float(sys.argv[1]),2))" "$s0")
td_alive=no; kill -0 "$TD" 2>/dev/null && td_alive=yes
echo "concurrent fm-send: rc=$src in ${send_s}s; teardown still running afterwards: $td_alive"
show "$LAB/send.out"; show "$LAB/send.err"
check "concurrent fm-send succeeded" [ "$src" = 0 ]
check "fm-send finished while the teardown was still expiring (not blocked behind it)" [ "$td_alive" = yes ]
check "fm-send recorded the steer in live-y's inbox" [ -n "$(ls "$LAB/state/live-y.inbox" 2>/dev/null | grep '\.msg$')" ]
wait "$TD"; rc=$?
show "$LAB/bb-unstaged.out"; show "$LAB/bb-unstaged.err"
check "bb-unstaged teardown exits 0" [ "$rc" = 0 ]
check "bb-unstaged backlog row closed (done)" [ "$(row_state bb-unstaged)" = done ]
check "bb-unstaged: no pending backlog close" [ ! -e "$LAB/state/bb-unstaged.backlog-close" ]
check "bb-unstaged kept whole by its stage limit" grep -q 'task data bb-unstaged retained whole for retry: reference matching passed its 2s stage limit' "$LAB/bb-unstaged.err"
check "bb-unstaged nothing staged" [ ! -e "$B/.cleanup-hold" ]
check "aa-staged cut off by the 8s budget and named" grep -q 'task data aa-staged expiry stopped after 8s' "$LAB/bb-unstaged.err"
check "aa-staged hold kept after the cut-off" [ -f "$A/.cleanup-hold/aa.bin" ]
check "aa-staged record marked cut-off" jq -e '.expiry == "cut-off"' "$A/record/data-cleanup.json"

say "S7: cut-off -> one full attempt -> too-large -> skipped and named (budget 2s, full attempt 3s)"
add_task task-c
lab_teardown task-c FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=3; rc=$?
show "$LAB/task-c.err"
check "task-c exits 0" [ "$rc" = 0 ]
check "least recently tried hold (bb-unstaged) went first and was cut off" grep -q 'task data bb-unstaged expiry stopped after 2s' "$LAB/task-c.err"
check "the hold the budget never reached is named" grep -q 'holds left for a later teardown: aa-staged' "$LAB/task-c.err"
add_task task-d
s0=$(date +%s)
lab_teardown task-d FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=3; rc=$?
show "$LAB/task-d.err"
check "task-d exits 0" [ "$rc" = 0 ]
check "aa-staged got its one full 3s attempt (not the 2s budget)" grep -q 'task data aa-staged expiry stopped after its one full 3s attempt' "$LAB/task-d.err"
check "warning advertises the by-hand command" grep -q 'expire it by hand with bash .*fm-task-data-lib.sh expire' "$LAB/task-d.err"
check "aa-staged marked too-large" jq -e '.expiry == "too-large"' "$A/record/data-cleanup.json"
check "aa-staged hold still kept" [ -f "$A/.cleanup-hold/aa.bin" ]
add_task task-e
lab_teardown task-e FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=3; rc=$?
show "$LAB/task-e.err"
check "task-e exits 0" [ "$rc" = 0 ]
check "task-e skips and names aa-staged" grep -q 'skipped and kept for expiry by hand: aa-staged' "$LAB/task-e.err"
check "bb-unstaged got its one full 3s attempt" grep -q 'task data bb-unstaged expiry stopped after its one full 3s attempt' "$LAB/task-e.err"
check "bb-unstaged marked too-large while still never staged" jq -e '.expiry == "too-large" and .complete == false' "$B/record/data-cleanup.json"
add_task task-f
s0=$(date +%s)
lab_teardown task-f FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=3; rc=$?
echo "task-f wall time $(( $(date +%s) - s0 ))s"
show "$LAB/task-f.err"
check "task-f exits 0" [ "$rc" = 0 ]
check "task-f names both too-large holds and tries neither" grep -q 'skipped and kept for expiry by hand: aa-staged bb-unstaged' "$LAB/task-f.err"
check "task-f made no new attempt" bash -c '! grep -q "expiry stopped" "$1"' _ "$LAB/task-f.err"
read -r -a CMD_A <<< "$(sed -n 's/.*expire it by hand with //p' "$LAB/task-d.err")"
read -r -a CMD_B <<< "$(sed -n 's/.*expire it by hand with //p' "$LAB/task-e.err")"
echo "advertised for aa-staged: ${CMD_A[*]}"
echo "advertised for bb-unstaged: ${CMD_B[*]}"
byhand() { # <out-prefix> <cmd...>
  local out=$1; shift
  env -u NO_MISTAKES_GATE -u TMUX -u BEADS_PATH PATH="$STUBS:$PATH" "$@" > "$out.out" 2> "$out.err"
}

say "S8a: the advertised command refuses while another live process holds the task lock"
sleep 600 & HOLDER=$!
mkdir "$LAB/state/.meta-bb-unstaged.lock"; printf '%s\n' "$HOLDER" > "$LAB/state/.meta-bb-unstaged.lock/pid"
cp "$B/record/data-cleanup.json" "$LAB/bb-before.json"
byhand "$LAB/bh-locked" "${CMD_B[@]}"; rc=$?
show "$LAB/bh-locked.out"; show "$LAB/bh-locked.err"
check "refuses with non-zero exit" [ "$rc" != 0 ]
check "says the task is locked and nothing was expired" grep -q 'is locked by another process; nothing was expired' "$LAB/bh-locked.err"
check "record untouched" cmp -s "$LAB/bb-before.json" "$B/record/data-cleanup.json"
check "scratch untouched" [ -f "$B/bb.bin" ]
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=

say "S8b: the advertised command refuses a live task"
mkdir -p "$LAB/aside"
printf 'kind=ship\nspawn_gen=aa-staged-again\n' > "$LAB/state/aa-staged.meta"
byhand "$LAB/bh-live" "${CMD_A[@]}"; rc=$?
show "$LAB/bh-live.err"
check "refuses with non-zero exit" [ "$rc" != 0 ]
check "says the task is live" grep -q 'task aa-staged is live; nothing was expired' "$LAB/bh-live.err"
check "hold untouched" [ -f "$A/.cleanup-hold/aa.bin" ]
mv "$LAB/state/aa-staged.meta" "$LAB/aside/aa-staged.meta"

say "S8c: by hand on the never-staged too-large hold (dead holder's stale lock left behind)"
s0=$(date +%s)
byhand "$LAB/bh-bb" "${CMD_B[@]}"; rc=$?
echo "by-hand bb-unstaged took $(( $(date +%s) - s0 ))s"
show "$LAB/bh-bb.out"; show "$LAB/bh-bb.err"
check "exits 0" [ "$rc" = 0 ]
check "last line states the final state" [ "$(tail -n 1 "$LAB/bh-bb.out")" = "task data bb-unstaged expired; nothing of it stays held" ]
check "never-staged scratch gone" [ ! -e "$B/bb.bin" ]
check "no hold left" [ ! -e "$B/.cleanup-hold" ]
check "record expired, too-large mark cleared" jq -e '.expired == true and (has("expiry") | not)' "$B/record/data-cleanup.json"
check "evidence kept (brief.md)" [ -f "$B/brief.md" ]
check "task lock released" [ ! -e "$LAB/state/.meta-bb-unstaged.lock" ]

say "S8d (adversarial): by hand on the already-staged too-large hold after the operator moved aa2.bin back"
mv "$A/.cleanup-hold/aa2.bin" "$A/aa2.bin"
byhand "$LAB/bh-aa" "${CMD_A[@]}"; rc=$?
show "$LAB/bh-aa.out"; show "$LAB/bh-aa.err"
check "exits non-zero" [ "$rc" != 0 ]
check "names the hold as not expired" grep -q 'task data aa-staged is not expired; what remains of it stays held' "$LAB/bh-aa.err"
check "the moved-back file is re-held, not deleted" [ -f "$A/.cleanup-hold/aa2.bin" ]
check "the old hold contents were expired" [ ! -e "$A/.cleanup-hold/aa.bin" ]
check "record complete, not expired, still too-large" jq -e '.complete == true and .expired == false and .expiry == "too-large"' "$A/record/data-cleanup.json"
check "no false 'expired' claim on stdout" bash -c '! grep -q "expired; nothing of it stays held" "$1"' _ "$LAB/bh-aa.out"
byhand "$LAB/bh-aa2" "${CMD_A[@]}"; rc=$?
show "$LAB/bh-aa2.out"; show "$LAB/bh-aa2.err"
check "a second by-hand run then expires it (exit 0)" [ "$rc" = 0 ]
check "hold gone after the second run" [ ! -e "$A/.cleanup-hold" ]
check "record expired, mark cleared" jq -e '.expired == true and (has("expiry") | not)' "$A/record/data-cleanup.json"
echo "lab3 failures: $FAILS"
