#!/usr/bin/env bash
# Native PR registration sends a bounded, exact-head completion callback.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-ready-callback)
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
URL=https://github.com/example/project/pull/7
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/forge-calls"
case "$*" in
  "pr view "*" --json isDraft") printf '{"isDraft":%s}\n' "${FM_TEST_DRAFT:-false}" ;;
  "pr view "*" --json headRefOid -q .headRefOid") printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  *) printf 'unexpected forge call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
cat > "$TMP_ROOT/callback" <<'SH'
#!/usr/bin/env bash
set -eu
# Read the actual published files before acknowledging the native call.
grep -qx 'pr=https://github.com/example/project/pull/7' "$FM_HOME/state/ship-one.meta"
grep -qx "pr_head=$3" "$FM_HOME/state/ship-one.meta"
cmp "$FM_HOME/state/ship-one.check.sh" "$FM_TEST_POLL"
printf '%s %s %s\n' "$1" "$2" "$3" >> "$FM_HOME/callbacks"
mode=${FM_TEST_CALLBACK_MODE:-ok}
receipt=$(jq -cn --arg repo "$1" --argjson pr "$2" --arg head "$3" \
  '{schema:"pr-review-router.event.v1",repo:$repo,pr:$pr,head:$head,accepted:true,disposition:"handled"}')
case "$mode" in
  empty) exit 0 ;;
  multiple) printf '{} %s\n' "$receipt"; exit 0 ;;
  wrong-repo) printf '%s\n' "$receipt" | jq -c '.repo="example/other"'; exit 0 ;;
  wrong-pr) printf '%s\n' "$receipt" | jq -c '.pr=8'; exit 0 ;;
  wrong-head) printf '%s\n' "$receipt" | jq -c '.head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'; exit 0 ;;
  wrong-schema) printf '%s\n' "$receipt" | jq -c '.schema="another.event.v1"'; exit 0 ;;
  string-pr) printf '%s\n' "$receipt" | jq -c '.pr="7"'; exit 0 ;;
  false-accepted) printf '%s\n' "$receipt" | jq -c '.accepted=false'; exit 0 ;;
  unknown-disposition) printf '%s\n' "$receipt" | jq -c '.disposition="sent"'; exit 0 ;;
  fail) printf '%s\n' "$receipt"; exit 75 ;;
  timeout)
    printf '%s\n' "$$" > "$FM_HOME/callback-pid"
    exec sleep 60 ;;
esac
# Model the receiver's identity deduplication independently of the producer.
# A lost reply or dead producer cannot undo this accepted consumer action.
if [ ! -e "$FM_HOME/accepted" ]; then
  printf '%s %s %s\n' "$1" "$2" "$3" > "$FM_HOME/accepted"
fi
case "$mode" in
  lost-ack) exit 75 ;;
  kill-after-accept) kill -KILL "${FM_TEST_OWNER_PID:?}"; exit 75 ;;
  prefix) printf 'transport diagnostic\n' ;;
esac
printf '%s\n' "$receipt"
SH
cat > "$TMP_ROOT/run.sh" <<'SH'
#!/usr/bin/env bash
export FM_TEST_OWNER_PID=$$
exec bash "$@"
SH
chmod +x "$TMP_ROOT/bin/gh" "$TMP_ROOT/callback"

make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/home/state" "$CASE_DIR/home/config" "$CASE_DIR/worktree"
  cat > "$CASE_DIR/home/state/ship-one.meta" <<EOF
kind=ship
mode=no-mistakes
worktree=$CASE_DIR/worktree
EOF
  chmod 600 "$CASE_DIR/home/state/ship-one.meta"
  cp "$TMP_ROOT/callback" "$CASE_DIR/home/config/pr-ready-callback"
}

run_check() {
  PATH="$TMP_ROOT/bin:$PATH" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CASE_DIR/home/state" \
    FM_TEST_POLL="$ROOT/bin/fm-pr-poll.sh" \
    bash "$TMP_ROOT/run.sh" "$ROOT/bin/fm-pr-check.sh" ship-one "$URL" > "$CASE_DIR/out" 2> "$CASE_DIR/err"
}

assert_registered() {
  grep -qx "pr=$URL" "$CASE_DIR/home/state/ship-one.meta" || fail "canonical PR was not recorded"
  grep -qx "pr_head=$HEAD" "$CASE_DIR/home/state/ship-one.meta" || fail "exact head was not recorded"
  cmp "$CASE_DIR/home/state/ship-one.check.sh" "$ROOT/bin/fm-pr-poll.sh" || fail "static poll was not published"
}

make_case success
run_check || fail "native registration failed: $(cat "$CASE_DIR/err")"
assert_registered
[ "$(cat "$CASE_DIR/home/callbacks")" = "example/project 7 $HEAD" ] || fail "callback identity was not exact"
if grep -q 'review callback pending' "$CASE_DIR/err"; then fail "exact receipt was not acknowledged"; fi
pass "native registration emits one exact event after its canonical record and static poll exist"

for mode in empty multiple wrong-repo wrong-pr wrong-head wrong-schema string-pr false-accepted unknown-disposition fail; do
  make_case "$mode"
  FM_TEST_CALLBACK_MODE=$mode run_check || fail "$mode changed successful registration's status"
  assert_registered
  grep -q 'review callback pending' "$CASE_DIR/err" || fail "$mode was falsely acknowledged"
  grep -qx 'armed: state/ship-one.check.sh' "$CASE_DIR/out" || fail "$mode lost registration output"
  pass "$mode leaves explicit pending delivery and preserves registration"
done

make_case prefix
FM_TEST_CALLBACK_MODE=prefix run_check || fail "prefixed receipt changed registration status"
if grep -q 'review callback pending' "$CASE_DIR/err"; then fail "valid final receipt was rejected"; fi
if grep -q 'transport diagnostic' "$CASE_DIR/out"; then fail "callback polluted registration stdout"; fi
pass "only the final receipt is read and callback output stays out of registration stdout"

make_case missing
mv "$CASE_DIR/home/config/pr-ready-callback" "$CASE_DIR/home/disabled-callback"
run_check || fail "missing optional hook changed registration status"
assert_registered
[ ! -e "$CASE_DIR/home/callbacks" ] || fail "missing hook ran a callback"
if grep -q 'review callback pending' "$CASE_DIR/err"; then fail "missing optional hook reported failure"; fi
pass "an absent callback is inert"

make_case merge
FM_PR_CHECK_MERGE=1 run_check || fail "merge-time registration failed"
assert_registered
[ ! -e "$CASE_DIR/home/callbacks" ] || fail "merge-time re-record sent a new ready event"
pass "merge-time re-record sends no publication callback"

make_case draft
if FM_TEST_DRAFT=true run_check; then fail "draft registration should have been refused"; fi
[ ! -e "$CASE_DIR/home/callbacks" ] || fail "refused draft sent a callback"
if grep -q '^pr=' "$CASE_DIR/home/state/ship-one.meta"; then fail "refused draft was registered"; fi
pass "refused publication sends no callback"

make_case timeout
FM_TEST_CALLBACK_MODE=timeout run_check || fail "callback timeout changed registration status"
assert_registered
grep -q 'review callback pending' "$CASE_DIR/err" || fail "timeout was falsely acknowledged"
callback_pid=$(cat "$CASE_DIR/home/callback-pid")
if kill -0 "$callback_pid" 2>/dev/null; then fail "bounded callback process was left running"; fi
pass "a hanging callback is stopped and leaves registration pending"

for mode in lost-ack kill-after-accept; do
  make_case "$mode"
  rc=0
  FM_TEST_CALLBACK_MODE=$mode run_check || rc=$?
  if [ "$mode" = lost-ack ]; then
    [ "$rc" = 0 ] || fail "lost acknowledgment changed registration status"
    grep -q 'review callback pending' "$CASE_DIR/err" || fail "lost acknowledgment was falsely accepted"
  else
    [ "$rc" = 137 ] || fail "producer was not killed after acceptance: $rc"
  fi
  assert_registered
  run_check || fail "restart replay failed"
  assert_registered
  [ "$(wc -l < "$CASE_DIR/home/callbacks" | tr -d ' ')" = 2 ] || fail "restart did not replay exact target once"
  [ "$(cat "$CASE_DIR/home/accepted")" = "example/project 7 $HEAD" ] || fail "consumer action was duplicated"
  if grep -Eq '^pr (create|review)' "$CASE_DIR/home/forge-calls"; then fail "replay republished to the forge"; fi
  pass "$mode preserves the native target and replay causes one consumer action with no publication"
done

# A recorded pr= frees the task's place in a project that declares a limit, so
# registration ends with bin/fm-dispatch-ready.sh's Dispatch line for it; an
# unlimited project and the merge-time re-record print none.
make_case dispatch-capped
fm_git_init_commit "$CASE_DIR/proj"
fm_git_add_origin "$CASE_DIR/proj" "$CASE_DIR/proj.origin.git"
printf 'project=%s\n' "$CASE_DIR/proj" >> "$CASE_DIR/home/state/ship-one.meta"
printf '%s\n' "proj 2" > "$CASE_DIR/home/config/project-capacity"
run_check || fail "capped registration failed: $(cat "$CASE_DIR/err")"
assert_registered
grep -q "^Dispatch: proj has 2 of 2 places free by bin/fm-spawn.sh's own count" "$CASE_DIR/out" \
  || fail "capped registration did not print the Dispatch line: $(cat "$CASE_DIR/out")"
pass "a PR handoff in a capped project prints the Dispatch line for the place it freed"

make_case dispatch-merge-rerecord
fm_git_init_commit "$CASE_DIR/proj"
fm_git_add_origin "$CASE_DIR/proj" "$CASE_DIR/proj.origin.git"
printf 'project=%s\n' "$CASE_DIR/proj" >> "$CASE_DIR/home/state/ship-one.meta"
printf '%s\n' "proj 2" > "$CASE_DIR/home/config/project-capacity"
FM_PR_CHECK_MERGE=1 run_check || fail "merge-time re-record failed: $(cat "$CASE_DIR/err")"
if grep -q '^Dispatch:' "$CASE_DIR/out"; then fail "merge-time re-record printed a Dispatch line"; fi
pass "the merge-time re-record frees nothing new and prints no Dispatch line"

make_case dispatch-uncapped
fm_git_init_commit "$CASE_DIR/proj"
fm_git_add_origin "$CASE_DIR/proj" "$CASE_DIR/proj.origin.git"
printf 'project=%s\n' "$CASE_DIR/proj" >> "$CASE_DIR/home/state/ship-one.meta"
run_check || fail "uncapped registration failed: $(cat "$CASE_DIR/err")"
if grep -q '^Dispatch:' "$CASE_DIR/out"; then fail "an unlimited project's PR handoff printed a Dispatch line"; fi
pass "a PR handoff in an unlimited project prints no Dispatch line"
