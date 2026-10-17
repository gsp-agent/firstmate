#!/usr/bin/env bash
# drive-scenarios.sh <scenario> - live driver for the legacy task-data cutover
# and reused-id fixes. Each scenario mints its own lab home (lab-lib.sh) and
# prints a transcript; lab paths are listed in $EV/labs.txt for teardown.
# ROOT may point at another firstmate tree to replay the same scenario on it.
set -u
EV=${EV:-/Users/dalecarman/.no-mistakes/evidence/01M53SQGEGDY4VTCKTFHZEBF7T}
. "$EV/lab-lib.sh"
PR1=https://github.com/test/repo/pull/1
PR2=https://github.com/test/repo/pull/2
FAILS=0

check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then echo "CHECK PASS: $what"; else echo "CHECK FAIL: $what"; FAILS=$((FAILS + 1)); fi
}
present() { [ -e "$1" ] || [ -L "$1" ]; }
absent() { ! present "$1"; }
no_grep() { ! grep -Fq -- "$1" "$2"; }
step() { echo; echo "== $*"; }
run_logged() { # <label> <command...>: run, echo exit code and stderr/stdout
  local label=$1 rc
  shift
  "$@" > "$LAB/$label.out" 2> "$LAB/$label.err"
  rc=$?
  echo "\$ $label -> exit $rc"
  sed 's/^/  stdout| /' "$LAB/$label.out" | grep -v 'WATCHER\|━━\|beacon\|supervision\|watcher' | head -12
  sed 's/^/  stderr| /' "$LAB/$label.err" | grep -v 'WATCHER\|━━\|beacon\|supervision\|watcher\|^  stderr| ●  *$' | head -12
  return "$rc"
}

# The operator's cutover pass over retired folders with no task record:
# prepare from the completed backlog row, then stage only folders that
# prepare recorded; anything else is named and kept whole.
cutover_pass() {
  local dir id rec project pr
  for dir in "$LAB"/data/*/; do
    id=$(basename "$dir")
    [ -e "$LAB/state/$id.meta" ] && continue
    lab_helper "$LAB" prepare "$id"
    rec="$LAB/data/$id/record/data-cleanup.json"
    if [ ! -f "$rec" ]; then
      echo "cutover: $id kept whole (no recorded completed row)"
      continue
    fi
    jq -e '.expired == true' "$rec" >/dev/null 2>&1 && continue
    project=$(jq -r '.sources[-1].project' "$rec")
    pr=$(jq -r '.sources[-1].pr' "$rec")
    lab_helper "$LAB" stage "$id" "$project" "$pr"
  done
}

seed_backlog() { printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"; }

# Reused task-x1: the earlier PR 1 retirement came from the legacy archive
# row; the reused id runs again, closes at PR 2, and retires through the real
# fm-teardown.sh (meta prepare, record removal, backlog close, stage).
reuse_setup() {
  LAB=$(lab_new) || exit 1
  echo "$LAB" >> "$EV/labs.txt"
  echo "lab home: $LAB (code under test: $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo extracted))"
  T="$LAB/data/task-x1"
  mkdir -p "$T"
  seed_backlog
  printf '%s\n' "- [x] task-x1 - previous $PR1 (repo: demo) (done 2026-10-10)" \
    '  [historical row evidence](old-row.bin)' > "$LAB/history/completed.md"
  printf 'pull_request:\n  number: 1\n  state: merged\n  body: [old evidence](old-pr.bin)\n' > "$LAB/prs/1"
  printf 'pull_request:\n  number: 2\n  state: merged\n  merged: "2026-10-16T00:00:00Z"\n  body: [new evidence](new-pr.bin)\n' > "$LAB/prs/2"
  printf 'historical row evidence\n' > "$T/old-row.bin"
  printf 'historical PR evidence\n' > "$T/old-pr.bin"
  dd if=/dev/urandom of="$T/old-scratch.bin" bs=1048576 count=3 2>/dev/null
}

reuse_second_life() { # the reused id runs again and retires at PR 2 through real teardown
  step "task-x1 is reused: spawned again, works, and lands PR 2"
  # local-only teardown closes with a "local main" note, so the row carries
  # the repo and PR 2 that a PR-mode close would record.
  lab_run "$LAB" tasks-axi add task-x1 "reused" --kind ship --repo demo --pr "$PR2" --file "$LAB/data/backlog.md" >/dev/null \
    && lab_run "$LAB" tasks-axi start task-x1 --file "$LAB/data/backlog.md" >/dev/null \
    || echo "note: tasks-axi refused the reused row"
  dd if=/dev/urandom of="$T/new-scratch.bin" bs=1048576 count=4 2>/dev/null
  printf 'current PR evidence\n' > "$T/new-pr.bin"
  touch "$LAB/state/.last-watcher-beat"
  printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$LAB/missing-task-x1" \
    "project=$LAB/projects/demo" "kind=ship" "mode=local-only" "spawn_gen=task-x1-reuse" "pr=$PR2" \
    > "$LAB/state/task-x1.meta"
  echo "task-x1 before retirement: $(kib "$T") KiB"; show_tree "$T" | sed 's/^/  /'
  step "real fm-teardown.sh task-x1 (reused id, PR 2)"
  run_logged teardown-task-x1 lab_run "$LAB" "$ROOT/bin/fm-teardown.sh" task-x1
  check "reused task-x1 teardown exited 0" test "$?" = 0
  echo "backlog row now: $(grep -F 'task-x1' "$LAB/data/backlog.md" || true)"
  echo "record: $(record_view "$T")"
  echo "task-x1 after stage: $(kib "$T") KiB (staging moves, frees nothing)"; show_tree "$T" | sed 's/^/  /'
}

scenario_reuse_expired() {
  reuse_setup
  step "cutover pass on the retired legacy folder (no task record)"
  cutover_pass
  echo "record: $(record_view "$T")"
  check "legacy PR 1 scratch staged by the cutover" present "$T/.cleanup-hold/old-scratch.bin"
  step "next cycle: real fm-teardown.sh of a different task expires the PR 1 hold"
  run_logged teardown-c1 lab_teardown_other "$LAB" task-c1
  echo "record: $(record_view "$T")"
  check "PR 1 hold expired" jq -e '.expired == true' "$T/record/data-cleanup.json"
  check "PR 1 scratch deleted on expiry" absent "$T/.cleanup-hold"
  reuse_second_life
  check "reused retirement did not warn about a changed project or PR" no_grep 'changed project or PR' "$LAB/teardown-task-x1.err"
  check "new-scratch.bin staged into .cleanup-hold" present "$T/.cleanup-hold/new-scratch.bin"
  check "new-scratch.bin no longer in the task folder" absent "$T/new-scratch.bin"
  check "record complete, not expired" jq -e '.complete == true and .expired == false' "$T/record/data-cleanup.json"
  check "expired PR 1 legacy source marked closed" jq -e 'any(.sources[]; .pr == "'"$PR1"'" and .backlog.closed == true)' "$T/record/data-cleanup.json"
  check "PR 2 evidence kept in place at stage" grep -qx 'current PR evidence' "$T/new-pr.bin"
  step "next cycle: real fm-teardown.sh of a different task expires the PR 2 hold"
  before=$(kib "$T")
  run_logged teardown-c2 lab_teardown_other "$LAB" task-c2
  rc=$?
  after=$(kib "$T")
  echo "record: $(record_view "$T")"
  echo "task-x1 disk: $before KiB before expiry -> $after KiB after expiry"; show_tree "$T" | sed 's/^/  /'
  check "next teardown exited 0" test "$rc" = 0
  check "reused hold expired" absent "$T/.cleanup-hold"
  check "new-scratch.bin deleted" absent "$T/new-scratch.bin"
  check "PR 2 linked evidence kept" grep -qx 'current PR evidence' "$T/new-pr.bin"
  check "historical row evidence kept" present "$T/old-row.bin"
  check "historical PR evidence kept" present "$T/old-pr.bin"
  check "record expired" jq -e '.expired == true' "$T/record/data-cleanup.json"
  check "expiry reclaimed at least 4 MiB" test $((before - after)) -ge 4096
}

scenario_reuse_unexpired() {
  reuse_setup
  step "cutover pass stages legacy PR 1; no other task completes, so its hold stays open"
  cutover_pass
  echo "record: $(record_view "$T")"
  reuse_second_life
  check "teardown named the unexpired conflict" grep -Fq 'task data task-x1 retained whole for retry: completed row task-x1 changed project or PR' "$LAB/teardown-task-x1.err"
  check "new-scratch.bin not moved" present "$T/new-scratch.bin"
  check "PR 1 recovery still held" present "$T/.cleanup-hold/old-scratch.bin"
  check "PR 2 evidence untouched" grep -qx 'current PR evidence' "$T/new-pr.bin"
  step "next cycle: real fm-teardown.sh of a different task while the conflict stands"
  run_logged teardown-c1 lab_teardown_other "$LAB" task-c1
  rc=$?
  echo "record: $(record_view "$T")"
  check "next teardown still exits 0 (pass not failed)" test "$rc" = 0
  check "expiry named the unexpired conflict" grep -Fq 'completed row task-x1 changed project or PR' "$LAB/teardown-c1.err"
  check "expiry kept new-scratch.bin" present "$T/new-scratch.bin"
  check "expiry kept the PR 1 recovery" present "$T/.cleanup-hold/old-scratch.bin"
  check "expiry kept historical evidence" present "$T/old-row.bin"
}

# Chip's ordering case: an archived row dated 2026-10-10 for PR 4365 and a
# current undated checked row for PR 4364.
scenario_ordering() {
  LAB=$(lab_new) || exit 1
  echo "$LAB" >> "$EV/labs.txt"
  echo "lab home: $LAB"
  T="$LAB/data/task-o1"
  mkdir -p "$T" "$LAB/projects/obsolete"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n- [x] task-o1 - current https://github.com/groovejones/groove-sight-platform/pull/4364 (repo: demo)\n' > "$LAB/data/backlog.md"
  printf '%s\n' '- [x] task-o1 - old https://github.com/groovejones/groove-sight-platform/pull/4365 (repo: obsolete) (done 2026-10-10)' > "$LAB/history/completed.md"
  printf 'body: [current](current-pr-only.bin)\n' > "$LAB/prs/4364"
  printf 'body: no linked files\n' > "$LAB/prs/4365"
  printf 'current PR evidence\n' > "$T/current-pr-only.bin"
  dd if=/dev/urandom of="$T/discard.bin" bs=1048576 count=2 2>/dev/null
  step "cutover pass"
  cutover_pass
  echo "record: $(jq -c '[.sources[] | {project, pr}]' "$T/record/data-cleanup.json")"
  check "current backlog project chosen" jq -e '.sources[-1].project == "'"$LAB"'/projects/demo"' "$T/record/data-cleanup.json"
  check "current backlog PR 4364 chosen over the dated archive PR 4365" jq -e '.sources[-1].pr | endswith("/pull/4364")' "$T/record/data-cleanup.json"
  check "current-pr-only.bin survives stage" grep -qx 'current PR evidence' "$T/current-pr-only.bin"
  check "scratch staged" present "$T/.cleanup-hold/discard.bin"
  step "next cycle: real fm-teardown.sh of a different task"
  run_logged teardown-c1 lab_teardown_other "$LAB" task-c1
  check "hold expired" absent "$T/.cleanup-hold"
  check "current-pr-only.bin survives expiry" grep -qx 'current PR evidence' "$T/current-pr-only.bin"
  check "PR 4364 was read for references" grep -q 'pr view 4364' "$LAB/gh-axi.calls"
}

# Guard: undated rows naming different PRs in the same source cannot be
# ordered; the folder stays whole, is named, and is never staged - even by a
# later teardown cycle.
scenario_ambiguous() {
  LAB=$(lab_new) || exit 1
  echo "$LAB" >> "$EV/labs.txt"
  echo "lab home: $LAB"
  T="$LAB/data/task-a1"
  mkdir -p "$T"
  seed_backlog
  printf '%s\n' '- [x] task-a1 - first https://github.com/test/repo/pull/7 (repo: demo)' \
    '- [x] task-a1 - second https://github.com/test/repo/pull/8 (repo: demo)' > "$LAB/history/completed.md"
  printf 'body: none\n' > "$LAB/prs/7"; printf 'body: none\n' > "$LAB/prs/8"
  printf 'scratch\n' > "$T/discard.bin"
  step "cutover pass"
  run_logged cutover cutover_pass
  check "pass named task-a1 with the unproven-order reason" grep -Fq 'task data task-a1 retained whole for retry: completed backlog rows have different projects or PRs with unproven order' "$LAB/cutover.err"
  check "no cleanup record written" absent "$T/record/data-cleanup.json"
  check "nothing staged" absent "$T/.cleanup-hold"
  check "scratch untouched" present "$T/discard.bin"
  step "next cycle: real fm-teardown.sh of a different task"
  run_logged teardown-c1 lab_teardown_other "$LAB" task-c1
  check "teardown cycle left the ambiguous folder whole" present "$T/discard.bin"
  check "teardown cycle staged nothing" absent "$T/.cleanup-hold"
}

# An unreadable PR (the lab gh-axi has no fixture for #9, so it exits 2 like
# the old GSP failure) keeps the folder whole, is named, and never fails the
# cutover pass or the next teardown cycle.
scenario_unread_pr() {
  LAB=$(lab_new) || exit 1
  echo "$LAB" >> "$EV/labs.txt"
  echo "lab home: $LAB"
  T="$LAB/data/task-u1"
  mkdir -p "$T"
  seed_backlog
  printf '%s\n' '- [x] task-u1 - shipped https://github.com/test/repo/pull/9 (repo: demo) (done 2026-10-12)' > "$LAB/history/completed.md"
  dd if=/dev/urandom of="$T/scratch.bin" bs=1048576 count=1 2>/dev/null
  printf 'maybe linked from the PR\n' > "$T/capture.png"
  step "cutover pass"
  run_logged cutover cutover_pass
  rc=$?
  echo "record: $(record_view "$T")"
  check "cutover pass exited 0" test "$rc" = 0
  check "pass named the unread PR for task-u1" grep -Fq 'task data task-u1 retained whole for retry: unread PR https://github.com/test/repo/pull/9' "$LAB/cutover.err"
  check "record lists the unread PR" jq -e 'any(.sources[]; (.unread // []) | index("https://github.com/test/repo/pull/9"))' "$T/record/data-cleanup.json"
  check "nothing staged" absent "$T/.cleanup-hold"
  check "scratch and capture untouched" eval 'present "$T/scratch.bin" && present "$T/capture.png"'
  step "next cycle: real fm-teardown.sh of a different task retries the unread PR"
  run_logged teardown-c1 lab_teardown_other "$LAB" task-c1
  rc=$?
  check "teardown exited 0" test "$rc" = 0
  check "retry named the unread PR again" grep -Fq 'unread PR https://github.com/test/repo/pull/9' "$LAB/teardown-c1.err"
  check "folder still whole" eval 'present "$T/scratch.bin" && present "$T/capture.png" && absent "$T/.cleanup-hold"'
}

# A GitLab merge request named only in a continuation note under the row.
scenario_note_only_gitlab() {
  LAB=$(lab_new) || exit 1
  echo "$LAB" >> "$EV/labs.txt"
  echo "lab home: $LAB"
  T="$LAB/data/task-g1"
  mkdir -p "$T"
  seed_backlog
  printf '%s\n' '- [x] task-g1 - shipped (repo: demo) (done 2026-10-12)' \
    '  GitLab merge request https://gitlab.example.com/group/repo/-/merge_requests/7' > "$LAB/history/completed.md"
  cat > "$LAB/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'mr view') [ "$3" = 7 ] || exit 2; printf '{"iid":7,"state":"merged","description":"[capture](mr-only.png)"}\n' ;;
  'api --hostname') printf '[]\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$LAB/fakebin/glab"
  printf 'MR-only evidence\n' > "$T/mr-only.png"
  dd if=/dev/urandom of="$T/scratch.bin" bs=1048576 count=1 2>/dev/null
  step "cutover pass"
  run_logged cutover cutover_pass
  echo "record: $(record_view "$T")"
  check "PR identity taken from the continuation note" jq -e '.sources[-1].pr == "https://gitlab.example.com/group/repo/-/merge_requests/7"' "$T/record/data-cleanup.json"
  check "MR-linked evidence kept at stage" grep -qx 'MR-only evidence' "$T/mr-only.png"
  check "scratch staged" present "$T/.cleanup-hold/scratch.bin"
  step "next cycle: real fm-teardown.sh of a different task"
  run_logged teardown-c1 lab_teardown_other "$LAB" task-c1
  check "hold expired" absent "$T/.cleanup-hold"
  check "MR-linked evidence kept after expiry" grep -qx 'MR-only evidence' "$T/mr-only.png"
}

# Metadata-less reuse: after PR 1 expired, the reused id's completed row at
# PR 2 is in the current backlog but no task record exists, so the cutover
# pass prepares it from the row.
scenario_reuse_metadata_less() {
  reuse_setup
  step "cutover pass on legacy PR 1, then the next cycle expires it"
  cutover_pass
  run_logged teardown-c1 lab_teardown_other "$LAB" task-c1
  echo "record: $(record_view "$T")"
  step "reused id closed at PR 2 in the current backlog, no task record"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n%s\n' "- [x] task-x1 - reused $PR2 (repo: demo)" > "$LAB/data/backlog.md"
  dd if=/dev/urandom of="$T/new-scratch.bin" bs=1048576 count=4 2>/dev/null
  printf 'current PR evidence\n' > "$T/new-pr.bin"
  run_logged cutover2 cutover_pass
  echo "record: $(record_view "$T")"
  check "no changed-project-or-PR warning" no_grep 'changed project or PR' "$LAB/cutover2.err"
  check "new legacy source records PR 2 from the current row" jq -e '.sources[-1].pr == "'"$PR2"'" and .sources[-1].backlog.legacy == true and (.sources[-1].backlog.closed // false) == false' "$T/record/data-cleanup.json"
  check "closed PR 1 history kept in the record" jq -e '.sources[0].pr == "'"$PR1"'" and .sources[0].backlog.closed == true' "$T/record/data-cleanup.json"
  check "new-scratch.bin staged" present "$T/.cleanup-hold/new-scratch.bin"
  step "next cycle: real fm-teardown.sh of a different task"
  run_logged teardown-c2 lab_teardown_other "$LAB" task-c2
  check "hold expired" absent "$T/.cleanup-hold"
  check "PR 2 evidence kept" grep -qx 'current PR evidence' "$T/new-pr.bin"
  check "historical evidence kept" eval 'present "$T/old-row.bin" && present "$T/old-pr.bin"'
  check "record expired" jq -e '.expired == true' "$T/record/data-cleanup.json"
}

case "${1:-}" in
  reuse-expired) scenario_reuse_expired ;;
  reuse-unexpired) scenario_reuse_unexpired ;;
  ordering) scenario_ordering ;;
  ambiguous) scenario_ambiguous ;;
  unread-pr) scenario_unread_pr ;;
  reuse-metadata-less) scenario_reuse_metadata_less ;;
  note-only-gitlab) scenario_note_only_gitlab ;;
  *) echo "usage: $0 reuse-expired|reuse-unexpired|ordering|ambiguous" >&2; exit 2 ;;
esac
echo
echo "RESULT ${1}: $FAILS failed checks"
[ "$FAILS" = 0 ]
