#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-resume-lib.sh: Codex session discovery, the
# verified Herdr report, and the Codex resume record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-resume)
# shellcheck source=bin/fm-crew-resume-lib.sh
. "$ROOT/bin/fm-crew-resume-lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

FAKEBIN=$TMP_ROOT/fakebin
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
"pane report-agent-session")
  printf '%s\n' "$*" >> "$FM_CREW_HERDR_LOG"
  printf '%s\n' '{"result":{"ok":true}}'
  ;;
"agent get") printf '%s\n' "$FM_CREW_HERDR_AGENT_GET" ;;
*) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

agent_get_body() { # <agent> <session-id>
  printf '{"result":{"agent":{"agent":"%s","agent_session":{"agent":"%s","kind":"id","source":"herdr:%s","value":"%s"}}}}' \
    "$1" "$1" "$1" "$2"
}

test_codex_session_id_finds_only_the_new_matching_worktree_rollout() {
  local home=$TMP_ROOT/codex-home wt=$TMP_ROOT/wt other=$TMP_ROOT/other
  local day=$home/sessions/2026/10/28 id
  mkdir -p "$day" "$wt" "$other"
  printf '%s\n' '{"type":"session_meta","payload":{"id":"old-id","cwd":"'"$wt"'"}}' \
    > "$day/rollout-2026-10-28T00-00-00-old-id.jsonl"
  printf '%s\n' '{"type":"session_meta","payload":{"id":"other-id","cwd":"'"$other"'"}}' \
    > "$day/rollout-2026-10-28T03-00-00-other-id.jsonl"
  printf '%s\n' '{"type":"session_meta","payload":{"id":"new-id","cwd":"'"$wt"'"}}' \
    > "$day/rollout-2026-10-28T02-00-00-new-id.jsonl"
  touch -t 202610280000 "$day/rollout-2026-10-28T00-00-00-old-id.jsonl"
  touch -t 202610280300 "$day/rollout-2026-10-28T03-00-00-other-id.jsonl"
  touch -t 202610280200 "$day/rollout-2026-10-28T02-00-00-new-id.jsonl"
  id=$(fm_crew_codex_session_id "$home" "$wt" "$(date -j -f '%Y%m%d%H%M' 202610280130 +%s 2>/dev/null || date -d '2026-10-28 01:30' +%s)")
  [ "$id" = new-id ] || fail "codex discovery returned '$id', expected new-id"
  id=$(fm_crew_codex_session_id "$TMP_ROOT/no-such-home" "$wt" 0) || fail "codex discovery failed on a missing home"
  [ -z "$id" ] || fail "codex discovery invented '$id' from a missing home"
  pass "codex session discovery finds only the new matching worktree rollout and is quiet on a missing home"
}

test_codex_report_is_verified_by_reading_the_pane_back() {
  local log=$TMP_ROOT/herdr-applied.log out
  out=$(FM_CREW_HERDR_LOG=$log FM_CREW_HERDR_AGENT_GET=$(agent_get_body codex new-id) PATH="$FAKEBIN:$PATH" \
    fm_crew_report_codex_session fm-lab-test w1:p9 new-id) || fail "an applied codex herdr report was not accepted"
  assert_contains "$(cat "$log")" \
    "pane report-agent-session w1:p9 --source herdr:codex --agent codex --agent-session-id new-id --session fm-lab-test" \
    "herdr did not receive the exact codex session report"
  [ -z "$out" ] || fail "the codex report leaked herdr's reply to stdout: '$out'"
  pass "codex session report sends the exact herdr call, keeps its reply off stdout, and reads the session back"
}

test_codex_report_fails_when_herdr_keeps_another_session() {
  local log=$TMP_ROOT/herdr-ignored.log
  if FM_CREW_HERDR_LOG=$log FM_CREW_HERDR_AGENT_GET=$(agent_get_body codex old-id) PATH="$FAKEBIN:$PATH" \
    fm_crew_report_codex_session fm-lab-test w1:p9 new-id >/dev/null 2>&1; then
    fail "a codex report herdr accepted but never applied counted as success"
  fi
  if FM_CREW_HERDR_LOG=$log FM_CREW_HERDR_AGENT_GET='{"result":{"agent":null}}' PATH="$FAKEBIN:$PATH" \
    fm_crew_report_codex_session fm-lab-test w1:p9 new-id >/dev/null 2>&1; then
    fail "a codex report into a pane with no readable registration counted as success"
  fi
  pass "codex session report fails when the pane does not read back the reported session"
}

test_codex_resume_record_keeps_home_and_the_launch_line_args() {
  local record=$TMP_ROOT/state/task-x.codex-resume script=$TMP_ROOT/launch-words.sh launched
  mkdir -p "$TMP_ROOT/state"
  fm_crew_codex_args "'/s/task x.turn-ended'"
  printf 'printf "arg=%%s\\n" %s\n' "$(fm_crew_shell_words "${FM_CREW_CODEX_ARGS[@]}")" > "$script"
  launched=$(bash "$script") || fail "the rendered codex crew launch words do not parse as shell words"
  assert_equals "$(printf '%s\n' 'arg=--dangerously-bypass-approvals-and-sandbox' 'arg=--disable' 'arg=hooks' 'arg=-c' \
    'arg=notify=["bash","-c","touch '\''/s/task x.turn-ended'\''"]')" "$launched" \
    "the codex crew launch words do not carry the crew flags and turn-end notify"
  fm_crew_codex_resume_record_write "$record" new-id /codex/store "${FM_CREW_CODEX_ARGS[@]}" ||
    fail "codex resume record write failed"
  assert_equals "$(printf '%s\n' 'session_id=new-id' 'codex_home=/codex/store' "$launched")" "$(cat "$record")" \
    "codex resume record does not hold the session, its home, and the arguments the launch line carries"
  if fm_crew_codex_resume_record_write "$record" '../escape' /codex/store 2>/dev/null; then
    fail "codex resume record accepted a path-shaped session id"
  fi
  if fm_crew_codex_resume_record_write "$record" other-id relative/store 2>/dev/null; then
    fail "codex resume record accepted a relative CODEX_HOME"
  fi
  assert_contains "$(cat "$record")" "session_id=new-id" "a refused write replaced the existing codex resume record"
  pass "codex resume record keeps the session's CODEX_HOME and the args its launch line carries, refusing malformed input"
}

test_codex_session_id_finds_only_the_new_matching_worktree_rollout
test_codex_report_is_verified_by_reading_the_pane_back
test_codex_report_fails_when_herdr_keeps_another_session
test_codex_resume_record_keeps_home_and_the_launch_line_args
