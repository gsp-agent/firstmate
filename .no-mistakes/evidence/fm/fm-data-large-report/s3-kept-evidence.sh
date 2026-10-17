#!/usr/bin/env bash
# Live scenario: kept evidence over 1 MiB is read for references; kept evidence
# over 16 MiB is an unread reference that keeps the folder whole.
# Usage: s3-kept-evidence.sh <worktree> <lab>
set -uo pipefail
WT=${1:?} LAB=${2:?}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"

listing() { (cd "$LAB/data/$1" && find . -type f ! -path './record/data-cleanup.json' -exec ls -l {} + | awk '{print $5, $NF}' | sort -k2); }
row() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
record() { jq -c '{complete, expired, expiry, sources: [.sources[] | {beads, unread}]}' "$LAB/data/$1/record/data-cleanup.json"; }
pending_close() { if [ -e "$LAB/state/$1.backlog-close" ]; then echo "PENDING: $(tr '\n' ' ' < "$LAB/state/$1.backlog-close")"; else echo none; fi; }

bash "$E/lab-task.sh" "$LAB" t-bigreport
d="$LAB/data/t-bigreport"
mkdir -p "$d/proof"
{ head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$d/report.md"
printf 'image linked only from the last line of the report\n' > "$d/proof/capture.png"
printf 'scratch\n' > "$d/scratch.bin"
echo "=================== teardown t-bigreport (report.md is $(wc -c < "$d/report.md" | tr -d ' ') bytes; its last line links proof/capture.png)"
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-bigreport; echo "--- exit $?"
echo "--- data/t-bigreport (bytes path):"; listing t-bigreport
echo "--- backlog row: $(row t-bigreport)"
echo "--- pending close: $(pending_close t-bigreport)"
echo "--- record: $(record t-bigreport)"

echo
bash "$E/lab-task.sh" "$LAB" t-hugelog
d="$LAB/data/t-hugelog"
mkdir -p "$d/record"
dd if=/dev/zero of="$d/record/run.log" bs=1048576 count=16 2>/dev/null
printf 'x' >> "$d/record/run.log"
printf 'scratch\n' > "$d/scratch.bin"
echo "=================== teardown t-hugelog (record/run.log is $(wc -c < "$d/record/run.log" | tr -d ' ') bytes, one byte over 16 MiB)"
start=$SECONDS
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-hugelog; echo "--- exit $? after $((SECONDS - start))s"
echo "--- data/t-hugelog (bytes path):"; listing t-hugelog
echo "--- backlog row: $(row t-hugelog)"
echo "--- pending close: $(pending_close t-hugelog)"
echo "--- record: $(record t-hugelog)"

echo
echo "=================== shrink the log, then a different task's teardown retries t-hugelog and expires t-bigreport"
printf 'short log\n' > "$d/record/run.log"
bash "$E/lab-task.sh" "$LAB" t-after-big
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-after-big; echo "--- exit $?"
echo "--- data/t-hugelog:"; listing t-hugelog
echo "--- record: $(record t-hugelog)"
echo "--- data/t-bigreport:"; listing t-bigreport
echo "--- record: $(record t-bigreport)"
