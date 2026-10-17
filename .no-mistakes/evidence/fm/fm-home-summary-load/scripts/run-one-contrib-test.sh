#!/usr/bin/env bash
# run-one-contrib-test.sh <worktree> <out-dir> <test-name>... - run only the named
# functions from tests/fm-contributions.test.sh (its own fixtures and asserts),
# without editing the suite: the suite is copied with its final loop removed.
set -u
W=$1 OUT=$2; shift 2
mkdir -p "$OUT"
sed -e "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$W/tests/lib.sh\"#" \
    -e '/^failures=0$/,$d' "$W/tests/fm-contributions.test.sh" > "$OUT/contrib-functions.sh"
grep -q "^\. \"$W/tests/lib.sh\"" "$OUT/contrib-functions.sh" || { echo "lib.sh rewrite failed" >&2; exit 2; }
for t in "$@"; do
  ( . "$OUT/contrib-functions.sh"; "$t" ) || { echo "FAILED $t"; exit 1; }
done
