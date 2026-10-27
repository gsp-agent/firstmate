#!/usr/bin/env bash
# Failing-first check: run only the tests this change adds (plus the existing
# never-returned guard) in the run worktree with bin/fm-spawn.sh taken from
# <spawn-rev>, one case per run since a failed assertion exits its file.
# bin/fm-spawn.sh is restored to HEAD and the one-case copies removed on exit.
# usage: failing-first.sh <worktree> <spawn-rev>
set -u
wt=$1 rev=$2
cd "$wt" || exit 1
restore() {
  git checkout --quiet HEAD -- bin/fm-spawn.sh
  rm -f tests/ff-one-*.test.sh
}
trap restore EXIT
git show "$rev:bin/fm-spawn.sh" > bin/fm-spawn.sh
echo "== bin/fm-spawn.sh from $(git rev-parse --short "$rev"); tests from HEAD =="
run_case() { # <test-file> <first-runner-line> <case...>
  local file=$1 first=$2 one
  shift 2
  one="tests/ff-one-$RANDOM.test.sh"
  sed "/^$first\$/,\$d" "tests/$file" > "$one"
  printf '%s\n' "$*" >> "$one"
  printf -- '-- %s: %s\n' "$file" "$*"
  bash "$one" 2>&1 | grep -E '^(ok|not ok) - ' | head -3
  rm -f "$one"
}
s=fm-spawn-worktree-settle.test.sh
sf=test_single_stale_first_read_is_not_accepted
run_case "$s" "$sf" test_allocator_claimed_clean_slot_lease_is_released success
run_case "$s" "$sf" test_allocator_claimed_clean_slot_lease_is_released abort
run_case "$s" "$sf" test_allocator_claimed_slot_is_never_returned success
run_case "$s" "$sf" test_allocator_claimed_slot_is_never_returned abort
d=fm-spawn-defer-slot.test.sh
df=test_clean_defer_returns_the_slot_and_the_retry_spawns
run_case "$d" "$df" test_adopted_slot_with_unpushed_commits_is_not_returned
