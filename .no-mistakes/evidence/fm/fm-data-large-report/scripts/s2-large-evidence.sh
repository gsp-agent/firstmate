#!/usr/bin/env bash
# Live scenario 2: large kept evidence. A 1.4 MB report no longer blocks the
# close; a near-16 MiB report with many unmatched files hits the stage limit and
# keeps the folder whole; kept evidence over 16 MiB is an unread reference.
set -u
. "$(dirname "$0")/lab-lib.sh"
FAILS=0
lab_new || exit 1
echo "$LAB" >> "$(dirname "$0")/labs.txt"
now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }
timed_teardown() { # <id> <label> [VAR=value...]
  local id=$1 label=$2 t0 t1; shift 2
  t0=$(now)
  ( cd "$WT" && lab_env "$@" /usr/bin/time -l "$WT/bin/fm-teardown.sh" "$id" ) > "$LAB/$label.out" 2> "$LAB/$label.err"
  RC=$?
  t1=$(now)
  WALL=$(python3 -c "print(round($t1 - $t0, 1))")
  PEAK_MB=$(awk '/maximum resident set size/ {printf "%d", $1/1048576}' "$LAB/$label.err")
  sed 's/^/  out| /' "$LAB/$label.out"
  grep -v -e '^ *[0-9]\+ \+[a-z]' -e 'WATCHER\|watcher\|━\|^●' "$LAB/$label.err" | sed 's/^/  err| /'
  echo "  timing: teardown wall ${WALL}s, peak RSS of any process in the tree ${PEAK_MB} MiB, load $(uptime | sed 's/.*averages: //')"
}

echo "== L1: report.md of 1,400,041 bytes, link at the very end"
lab_task lab-big
T1="$LAB/data/lab-big"; mkdir -p "$T1/proof"
{ head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$T1/report.md"
printf 'keep this image\n' > "$T1/proof/capture.png"; printf 'scratch\n' > "$T1/scratch.bin"
timed_teardown lab-big l1
check "teardown exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "backlog row closed (state=$(row_state lab-big))" [ "$(row_state lab-big)" = done ]
check "no pending backlog close (cleanup_incomplete) left" [ ! -e "$LAB/state/lab-big.backlog-close" ]
check "scratch staged" [ -f "$T1/.cleanup-hold/scratch.bin" ]
check "image linked at the end of the large report kept" [ -f "$T1/proof/capture.png" ]
check "report bytes unchanged" [ "$(wc -c < "$T1/report.md" | tr -d ' ')" = 1400041 ]

echo "== L1-next: a small task's teardown (baseline timing) expires L1's hold"
lab_task lab-small1
timed_teardown lab-small1 l1n
BASE=$WALL
check "teardown exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "L1 hold expired" [ ! -e "$T1/.cleanup-hold" ]
check "L1 linked image survived expiry" [ -f "$T1/proof/capture.png" ] && [ -f "$T1/report.md" ]

echo "== L2: near-16 MiB report with one accented letter and 200 unmatched cloned files; stage limit 2s"
lab_task lab-huge
T2="$LAB/data/lab-huge"; mkdir -p "$T2/clone"
python3 - "$T2" <<'PY'
import os, sys
task = sys.argv[1]
line = "Ordinary review notes that name none of the cloned files.\n"
with open(os.path.join(task, "report.md"), "w", encoding="utf-8") as s:
    s.write(line * ((16 * 1024 * 1024 - 4096) // len(line)))
    s.write("Reviewed by José.\n")
for n in range(200):
    open(os.path.join(task, "clone", f"scratch-{n:03}.bin"), "w").write("scratch\n")
PY
timed_teardown lab-huge l2 FM_TEARDOWN_DATA_STAGE_TIMEOUT=2
check "teardown exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "backlog row closed (state=$(row_state lab-huge))" [ "$(row_state lab-huge)" = done ]
check "no pending backlog close left" [ ! -e "$LAB/state/lab-huge.backlog-close" ]
check "nothing staged" [ ! -e "$T2/.cleanup-hold" ]
check "all 200 cloned files still in place" [ "$(find "$T2/clone" -type f | wc -l | tr -d ' ')" = 200 ]
check "warning names the task and the limit" grep -qF "task data lab-huge retained whole for retry: reference matching passed its 2s stage limit" "$LAB/l2.err"
check "record's retained field names the limit" jq -e '.retained == "reference matching passed its 2s stage limit"' "$T2/record/data-cleanup.json"
check "peak RSS under 1 GiB on accented 16 MiB text (${PEAK_MB} MiB)" [ "${PEAK_MB:-99999}" -lt 1024 ]
echo "  extra wall time over the small-task baseline: $(python3 -c "print(round($WALL - $BASE, 1))")s (baseline ${BASE}s)"

echo "== L2-next: report shrinks; the next teardown of a different task stages L2 and clears the note"
printf 'short report\n' > "$T2/report.md"
lab_task lab-small2
timed_teardown lab-small2 l2n
check "teardown exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "L2 scratch staged on retry" [ -f "$T2/.cleanup-hold/clone/scratch-000.bin" ]
check "stage-limit note cleared" jq -e 'has("retained") | not' "$T2/record/data-cleanup.json"

echo "== L3: kept record/run.log of 16 MiB + 1 byte"
lab_task lab-over
T3="$LAB/data/lab-over"; mkdir -p "$T3/record"
dd if=/dev/zero of="$T3/record/run.log" bs=1048576 count=16 2>/dev/null; printf 'x' >> "$T3/record/run.log"
printf 'scratch\n' > "$T3/scratch.bin"
timed_teardown lab-over l3
check "teardown exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "backlog row closed (state=$(row_state lab-over))" [ "$(row_state lab-over)" = done ]
check "no pending backlog close left" [ ! -e "$LAB/state/lab-over.backlog-close" ]
check "scratch not moved, nothing staged" [ "$(cat "$T3/scratch.bin")" = scratch ] && [ ! -e "$T3/.cleanup-hold" ]
check "teardown output names record/run.log" grep -qF record/run.log "$LAB/l3.err"
check "record lists record/run.log as unread" jq -e '.complete == false and (.sources[-1].unread | index("record/run.log")) != null' "$T3/record/data-cleanup.json"
check "L2 hold expired by this teardown" [ ! -e "$T2/.cleanup-hold" ]

echo "== L3-next: log shrinks; next teardown retries and stages L3"
printf 'short log\n' > "$T3/record/run.log"
lab_task lab-small3
timed_teardown lab-small3 l3n
check "teardown exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "L3 scratch staged on retry" [ -f "$T3/.cleanup-hold/scratch.bin" ]
check "L3 unread list cleared" jq -e '.sources[-1].unread == []' "$T3/record/data-cleanup.json"
echo "== external calls the stubs absorbed:"; sort "$LAB/external-calls.log" 2>/dev/null | uniq -c | sed 's/^/  /' | head
lab_end
echo "FAILS=$FAILS"
