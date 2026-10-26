#!/usr/bin/env bash
# Run named tests from the change head's copy of <test-file>, each in its own
# process, against <commit>'s bin/ extracted into <outdir>.
# Usage: run-tests-at.sh <worktree> <commit> <outdir> <test-file> <test>...
set -u
wt=$1 commit=$2 out=$3 file=$4
shift 4
cd "$wt" || exit 1
git archive --format=tar "$commit" bin tests | tar -x -C "$out"
git show "HEAD:tests/$file" > "$out/tests/full-$file"
for t in "$@"; do
  awk -v keep="$t" '
    /^test_[a-z0-9_]+$/ { if ($0 == keep) print; next }
    /^run_case test_[a-z0-9_]+$/ { if ($2 == keep) print; next }
    { print }
  ' "$out/tests/full-$file" > "$out/tests/only-$t.test.sh"
  printf '=== %s:%s @ %s\n' "$file" "$t" "$(git rev-parse --short "$commit")"
  bash "$out/tests/only-$t.test.sh" 2>&1
  printf '=== exit %s\n' "$?"
done
