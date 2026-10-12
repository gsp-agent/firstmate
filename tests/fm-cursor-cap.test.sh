#!/usr/bin/env bash
# Behavior tests for bin/fm-cursor-cap.sh (daily cap on Cursor beads) and for the
# cursor pane command keeping the agent's exit status past the tee.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-cursor-cap.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-cap)
export FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
printf '{"cursor_daily_cap": 2}\n' > "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
STATEFILE="$FM_STATE_OVERRIDE/cursor-dispatch.json"

cap() { local day=$1; shift; FM_CURSOR_DAY=$day "$TOOL" "$@" 2> "$TMP_ROOT/err"; }

cap 2030-01-01 take a; expect_code 0 $? "first bead is counted"
cap 2030-01-01 take b; expect_code 0 $? "second bead is counted"
cap 2030-01-01 take c; expect_code 1 $? "a NEW bead is refused at the cap"
assert_contains "$(cat "$TMP_ROOT/err")" "refused c" "refusal is one stderr line naming the bead"
[ "$(wc -l < "$TMP_ROOT/err" | tr -d ' ')" = 1 ] || fail "refusal must be one line"
cap 2030-01-01 take a; expect_code 0 $? "a relaunch of a counted bead is allowed at the cap"
cap 2030-01-01 take a; expect_code 1 $? "the 3rd launch of one bead in a day is refused"
[ "$(jq -r '.beads | length' "$STATEFILE")" = 2 ] || fail "distinct beads are counted, not launches"
pass "cap counts distinct beads; relaunch allowed; 3rd launch refused"

cap 2030-01-01 give b; expect_code 0 $? "give returns a slot"
cap 2030-01-01 take c; expect_code 0 $? "the returned slot is usable by a new bead"
cap 2030-01-01 give a; cap 2030-01-01 take a
[ "$(jq -r '.beads.a' "$STATEFILE")" = 2 ] || fail "give of a relaunch drops one launch, not the bead"
pass "failed spawns give the slot back"

cap 2030-01-02 take d; expect_code 0 $? "a new day resets the count"
[ "$(jq -c '.' "$STATEFILE")" = '{"day":"2030-01-02","beads":{"d":1}}' ] || fail "day rollover did not reset state: $(cat "$STATEFILE")"
pass "day rollover resets the count"

rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
for i in 1 2 3 4 5 6; do cap 2030-01-03 take "x$i"; expect_code 0 $? "no cap configured: bead x$i"; done
pass "no cursor_daily_cap means no cap"

mkdir "$FM_STATE_OVERRIDE/cursor-dispatch.lock"
( sleep 1; rmdir "$FM_STATE_OVERRIDE/cursor-dispatch.lock" ) &
cap 2030-01-03 take y; expect_code 0 $? "waits for a held mkdir lock, then proceeds"
wait
pass "mkdir lock is honoured"

# The pane command keeps the agent's exit status past the tee, in bash and zsh.
tpl=$(grep -o '> >(tee __CURSORSTREAM__)' "$ROOT/bin/fm-spawn.sh" | head -1)
[ -n "$tpl" ] || fail "cursor template no longer tees through process substitution"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  "$sh" -c "(echo out; exit 7) ${tpl//__CURSORSTREAM__/\"$TMP_ROOT/stream.jsonl\"}"
  expect_code 7 $? "$sh: pane command exits with the agent's status, not tee's"
done
pass "cursor exit code survives the tee"

printf '# all fm-cursor-cap tests passed\n'
