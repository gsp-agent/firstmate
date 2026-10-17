#!/usr/bin/env bash
# Live: a kept report over 1 MiB no longer blocks preparation; kept evidence over
# 16 MiB is an unread reference that keeps the folder whole, lets the close go
# through, is named, and is retried once it shrinks.
. "$(dirname "$0")/lab-env.sh"
LAB=$(lab_new) || exit 1
lab_export "$LAB"
echo "lab home: $LAB"
lab_project "$LAB"
FAILS=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS: $what"; else echo "FAIL: $what"; FAILS=$((FAILS + 1)); fi
}
show() { # <task>
  echo "-- record"; cat "$LAB/data/$1/record/data-cleanup.json"; echo
  echo "-- data/$1"; (cd "$LAB/data/$1" && find . -type f -exec ls -l {} + | awk '{print $5, $9}' | sort -k2)
}
run() { # <task>
  lab_teardown "$LAB" "$1" > "$LAB/$1.out" 2> "$LAB/$1.err"
  RC=$?
  echo "exit=$RC"; echo "-- stdout"; cat "$LAB/$1.out"; echo "-- stderr"; cut -c1-400 "$LAB/$1.err"
}

lab_task "$LAB" t-large
mkdir -p "$LAB/data/t-large/proof"
{ head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$LAB/data/t-large/report.md"
printf 'keep this image\n' > "$LAB/data/t-large/proof/capture.png"
printf 'scratch\n' > "$LAB/data/t-large/scratch.bin"
echo; echo "== teardown t-large (report.md is $(wc -c < "$LAB/data/t-large/report.md" | tr -d ' ') bytes; its last line links proof/capture.png) =="
run t-large; show t-large
check "t-large teardown exits 0" [ "$RC" = 0 ]
check "t-large backlog row is done" [ "$(row_state "$LAB" t-large)" = done ]
check "t-large leaves no pending close" [ ! -e "$LAB/state/t-large.backlog-close" ]
check "t-large scratch is staged" [ -e "$LAB/data/t-large/.cleanup-hold/scratch.bin" ]
check "the link at the end of the 1.4 MB report kept proof/capture.png" [ -e "$LAB/data/t-large/proof/capture.png" ]
check "report.md bytes unchanged" [ "$(wc -c < "$LAB/data/t-large/report.md" | tr -d ' ')" = 1400041 ]

lab_task "$LAB" t-huge
mkdir -p "$LAB/data/t-huge/record"
dd if=/dev/zero of="$LAB/data/t-huge/record/run.log" bs=1048576 count=16 2>/dev/null
printf 'x' >> "$LAB/data/t-huge/record/run.log"
printf 'scratch\n' > "$LAB/data/t-huge/scratch.bin"
echo; echo "== teardown t-huge (record/run.log is $(wc -c < "$LAB/data/t-huge/record/run.log" | tr -d ' ') bytes, over 16 MiB) =="
run t-huge; show t-huge
check "t-huge teardown exits 0" [ "$RC" = 0 ]
check "t-huge backlog row is done (close went through)" [ "$(row_state "$LAB" t-huge)" = done ]
check "t-huge leaves no pending close" [ ! -e "$LAB/state/t-huge.backlog-close" ]
check "t-huge scratch stays in place (folder kept whole)" [ "$(cat "$LAB/data/t-huge/scratch.bin" 2>/dev/null)" = scratch ]
check "t-huge staged nothing" [ ! -e "$LAB/data/t-huge/.cleanup-hold" ]
check "t-huge teardown output names record/run.log" grep -qF record/run.log "$LAB/t-huge.err"
check "t-huge record lists record/run.log as unread" jq -e '.complete == false and (.sources[-1].unread | index("record/run.log") != null)' "$LAB/data/t-huge/record/data-cleanup.json"
echo "-- t-large after t-huge's expiry pass"; show t-large
check "t-huge's expiry pass expired t-large's hold" [ ! -e "$LAB/data/t-large/.cleanup-hold" ]
check "t-large report and linked capture survive expiry" [ -e "$LAB/data/t-large/report.md" ] && [ -e "$LAB/data/t-large/proof/capture.png" ]

printf 'short log\n' > "$LAB/data/t-huge/record/run.log"
lab_task "$LAB" t-next
echo; echo "== teardown t-next after t-huge's run.log shrank =="
run t-next; show t-huge
check "t-next teardown exits 0" [ "$RC" = 0 ]
check "the retry staged t-huge's scratch" [ -e "$LAB/data/t-huge/.cleanup-hold/scratch.bin" ]
check "the retry cleared the unread list" jq -e '.sources[-1].unread == []' "$LAB/data/t-huge/record/data-cleanup.json"

echo
echo "lab home to remove: $LAB"
echo "FAILS=$FAILS"
