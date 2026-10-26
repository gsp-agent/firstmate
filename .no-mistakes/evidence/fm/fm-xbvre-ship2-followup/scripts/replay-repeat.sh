#!/usr/bin/env bash
# Run the change head's three new replays (tests/fm-claude-wake.test.sh), each
# in its own process and <reps> times, against <commit>'s bin/ extracted into a
# throwaway dir. Under the round-1 sleep gate the two Stop-claim races must be
# red on the base every time (a second rewake, STOP_RC=2) and green on the
# head every time, never a STOP_DID_NOT_WAIT setup abort, whatever the load.
# Usage: replay-repeat.sh <worktree> <commit> <reps>
set -u
wt=$1 commit=$2 reps=$3
out=$(mktemp -d "${TMPDIR:-/tmp}/fm-replay-repeat.XXXXXX") || exit 1
cd "$wt" || exit 1
git archive --format=tar "$commit" bin tests | tar -x -C "$out"
git show 527b9c60:tests/fm-claude-wake.test.sh > "$out/tests/full.test.sh"
printf '# host load at start: %s\n' "$(uptime | sed 's/.*load averages*: //')"
for t in test_stop_claim_loses_to_waker_rewake_committed_after_pending_read \
         test_stop_claim_loses_to_inflight_waker_rewake \
         test_waker_banner_carries_away_line_on_host_home; do
  awk -v keep="$t" '
    /^test_[a-z0-9_]+$/ { if ($0 == keep) print; next }
    { print }
  ' "$out/tests/full.test.sh" > "$out/tests/only-$t.test.sh"
  r=1
  while [ "$r" -le "$reps" ]; do
    printf '=== %s @ %s run %s\n' "$t" "$(git rev-parse --short "$commit")" "$r"
    bash "$out/tests/only-$t.test.sh" 2>&1
    printf '=== exit %s\n' "$?"
    r=$((r + 1))
  done
done
printf '# host load at end: %s\n' "$(uptime | sed 's/.*load averages*: //')"
rm -rf "${out:?}"
