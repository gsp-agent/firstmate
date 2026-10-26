#!/usr/bin/env bash
# Run the three new replays against a given commit's bin/ (base or head),
# using the head's test file. Usage: red-on-base.sh <worktree> <commit> <outdir>
set -u
wt=$1 commit=$2 out=$3
cd "$wt" || exit 1
git archive --format=tar "$commit" bin tests | tar -x -C "$out"
git show HEAD:tests/fm-claude-wake.test.sh > "$out/tests/fm-claude-wake.test.sh"
f="$out/tests/fm-claude-wake.test.sh"
# Keep the helpers/definitions; replace the trailing invocation list with the three replays.
awk '
  /^test_[a-z0-9_]+$/ { next }
  { print }
  END {
    print "test_stop_claim_loses_to_waker_rewake_committed_after_pending_read"
    print "test_stop_claim_loses_to_inflight_waker_rewake"
    print "test_waker_banner_carries_away_line_on_host_home"
  }
' "$f" > "$f.trim" && mv "$f.trim" "$f"
for t in test_stop_claim_loses_to_waker_rewake_committed_after_pending_read \
         test_stop_claim_loses_to_inflight_waker_rewake \
         test_waker_banner_carries_away_line_on_host_home; do
  awk -v keep="$t" '
    /^test_[a-z0-9_]+$/ { if ($0 == keep) print; next }
    { print }
  ' "$f" > "$out/tests/only-$t.test.sh"
  cp "$out/tests/only-$t.test.sh" "$out/tests/.only.sh"
  printf '=== %s @ %s\n' "$t" "$commit"
  bash "$out/tests/only-$t.test.sh" 2>&1
  printf '=== exit %s\n' "$?"
done
