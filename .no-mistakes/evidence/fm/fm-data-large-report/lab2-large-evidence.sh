#!/usr/bin/env bash
# Lab 2: kept evidence over 1 MiB prepares and stages; kept evidence over
# 16 MiB keeps the folder whole while the close completes; a stage past its
# limit moves nothing; thousands of expired records do not starve a live hold;
# the next teardown retries the folders kept whole once they shrink.
. "$(dirname "$0")/lab-lib.sh"
new_lab
trap end_lab EXIT

say "S3: kept report.md of 1.4 MB with a link at its very end"
add_task big-report
T="$LAB/data/big-report"
mkdir -p "$T/proof"
{ head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$T/report.md"
printf 'keep this image\n' > "$T/proof/capture.png"
printf 'scratch\n' > "$T/scratch.bin"
lab_teardown big-report FM_TEARDOWN_DATA_STAGE_TIMEOUT=600; rc=$?
show "$LAB/big-report.out"; show "$LAB/big-report.err"
check "teardown exits 0" [ "$rc" = 0 ]
check "backlog row closed (done)" [ "$(row_state big-report)" = done ]
check "no pending backlog close (no cleanup_incomplete)" [ ! -e "$LAB/state/big-report.backlog-close" ]
check "scratch staged into .cleanup-hold" [ -f "$T/.cleanup-hold/scratch.bin" ]
check "file linked at the end of the large report stays" [ -f "$T/proof/capture.png" ]
check "report bytes unchanged (1400041)" [ "$(wc -c < "$T/report.md" | tr -d ' ')" = 1400041 ]
record big-report | jq -c '{complete, expired, unread: .sources[-1].unread}'

say "S4: kept record/run.log just over 16 MiB"
add_task huge-log
T4="$LAB/data/huge-log"
mkdir -p "$T4/record"
dd if=/dev/zero of="$T4/record/run.log" bs=1048576 count=16 2>/dev/null; printf 'x' >> "$T4/record/run.log"
printf 'scratch\n' > "$T4/scratch.bin"
lab_teardown huge-log FM_TEARDOWN_DATA_STAGE_TIMEOUT=600; rc=$?
show "$LAB/huge-log.out"; show "$LAB/huge-log.err"
check "teardown exits 0" [ "$rc" = 0 ]
check "backlog row closed (done)" [ "$(row_state huge-log)" = done ]
check "no pending backlog close" [ ! -e "$LAB/state/huge-log.backlog-close" ]
check "scratch not moved" [ "$(cat "$T4/scratch.bin")" = scratch ]
check "nothing staged" [ ! -e "$T4/.cleanup-hold" ]
check "teardown output names record/run.log" grep -q 'record/run.log' "$LAB/huge-log.err"
record huge-log | jq -c '{complete, expired, unread: .sources[-1].unread}'
check "record: complete=false, unread names record/run.log" \
  jq -e '.complete == false and (.sources[-1].unread | index("record/run.log") != null)' "$T4/record/data-cleanup.json"

say "S5: stage limit: near-16 MiB report with one accented letter and 200 unmatched files, limit 2s"
add_task stage-limit
T5="$LAB/data/stage-limit"
mkdir -p "$T5/clone"
python3 - "$T5" <<'PY'
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
s0=$(date +%s)
lab_teardown stage-limit FM_TEARDOWN_DATA_STAGE_TIMEOUT=2; rc=$?
echo "stage-limit teardown wall time: $(( $(date +%s) - s0 ))s"
show "$LAB/stage-limit.out"; show "$LAB/stage-limit.err"
check "teardown exits 0" [ "$rc" = 0 ]
check "backlog row closed (done)" [ "$(row_state stage-limit)" = done ]
check "no pending backlog close" [ ! -e "$LAB/state/stage-limit.backlog-close" ]
check "nothing staged" [ ! -e "$T5/.cleanup-hold" ]
check "all 200 scratch files still in place" [ "$(find "$T5/clone" -type f | wc -l | tr -d ' ')" = 200 ]
check "warning names the task and its 2s stage limit" \
  grep -q 'task data stage-limit retained whole for retry: reference matching passed its 2s stage limit' "$LAB/stage-limit.err"
record stage-limit | jq -c '{complete, expired, retained}'
check "record retained field names the limit" \
  jq -e '.retained == "reference matching passed its 2s stage limit"' "$T5/record/data-cleanup.json"

say "S9 + retries: 3000 expired records dated 2020, then the next teardown (default 10s budget)"
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
s0=$(date +%s.%N)
env -u NO_MISTAKES_GATE python3 "$ROOT/bin/fm-task-data.py" pending "$LAB/data" > "$LAB/pending.txt"
echo "pending listing over 3003 records took $(python3 -c "import time,sys; print(round(time.time()-float(sys.argv[1]),2))" "$s0")s and listed:"; cat "$LAB/pending.txt"
printf 'short log\n' > "$T4/record/run.log"
printf 'short report\n' > "$T5/report.md"
add_task task-next
s0=$(date +%s)
lab_teardown task-next; rc=$?
echo "next teardown wall time: $(( $(date +%s) - s0 ))s"
show "$LAB/task-next.out"; show "$LAB/task-next.err"
check "next teardown exits 0" [ "$rc" = 0 ]
check "live large-report hold expired despite 3000 older expired records" [ ! -e "$T/.cleanup-hold" ]
check "large report and its linked file survive expiry" [ -f "$T/report.md" ]
check "linked capture survives expiry" [ -f "$T/proof/capture.png" ]
check "large-report record expired" jq -e '.expired == true' "$T/record/data-cleanup.json"
check "huge-log folder retried once the log shrank: scratch staged" [ -f "$T4/.cleanup-hold/scratch.bin" ]
check "huge-log record no longer lists run.log unread" jq -e '.sources[-1].unread == []' "$T4/record/data-cleanup.json"
check "stage-limit folder retried: scratch staged" [ -f "$T5/.cleanup-hold/clone/scratch-000.bin" ]
check "stage-limit retained note cleared" jq -e 'has("retained") | not' "$T5/record/data-cleanup.json"
echo "lab2 failures: $FAILS"
