#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-resume-lib.sh: Codex session discovery and
# Herdr reporting, and the Grok crew resume record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-resume)
# shellcheck source=bin/fm-crew-resume-lib.sh
. "$ROOT/bin/fm-crew-resume-lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

test_codex_session_id_finds_only_the_new_matching_worktree_rollout() {
  local home=$TMP_ROOT/codex-home wt=$TMP_ROOT/wt other=$TMP_ROOT/other
  local day=$home/sessions/2026/10/28 id
  mkdir -p "$day" "$wt" "$other"
  printf '%s\n' '{"type":"session_meta","payload":{"id":"old-id","cwd":"'"$wt"'"}}' \
    > "$day/rollout-2026-10-28T00-00-00-old-id.jsonl"
  printf '%s\n' '{"type":"session_meta","payload":{"id":"other-id","cwd":"'"$other"'"}}' \
    > "$day/rollout-2026-10-28T01-00-00-other-id.jsonl"
  printf '%s\n' '{"type":"session_meta","payload":{"id":"new-id","cwd":"'"$wt"'"}}' \
    > "$day/rollout-2026-10-28T02-00-00-new-id.jsonl"
  touch -t 202610280000 "$day/rollout-2026-10-28T00-00-00-old-id.jsonl"
  touch -t 202610280100 "$day/rollout-2026-10-28T01-00-00-other-id.jsonl"
  touch -t 202610280200 "$day/rollout-2026-10-28T02-00-00-new-id.jsonl"
  id=$(fm_crew_codex_session_id "$home" "$wt" "$(date -j -f '%Y%m%d%H%M' 202610280130 +%s 2>/dev/null || date -d '2026-10-28 01:30' +%s)")
  [ "$id" = new-id ] || fail "codex discovery returned '$id', expected new-id"
  pass "codex session discovery finds only the new matching worktree rollout"
}

test_codex_report_sends_the_exact_herdr_report() {
  local fakebin=$TMP_ROOT/fakebin log=$TMP_ROOT/herdr.log
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CREW_HERDR_LOG"
SH
  chmod +x "$fakebin/herdr"
  FM_CREW_HERDR_LOG=$log PATH="$fakebin:$PATH" \
    fm_crew_report_codex_session fm-lab-test w1:p9 new-id || fail "codex herdr report failed"
  assert_contains "$(cat "$log")" \
    "pane report-agent-session w1:p9 --source herdr:codex --agent codex --agent-session-id new-id --session fm-lab-test" \
    "herdr did not receive the exact codex session report"
  pass "codex session report sends the exact herdr report-agent-session call"
}

test_grok_session_and_resume_record_round_trip() {
  local op=$TMP_ROOT/operator-grok wt=$TMP_ROOT/gwt worker=$TMP_ROOT/state/task-x.grok-home
  local enc sess got
  mkdir -p "$wt" "$worker"
  enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$wt")
  sess=$op/sessions/$enc/session-abc
  mkdir -p "$sess"
  printf '%s\n' '{"info":{"id":"session-abc","cwd":"'"$wt"'"},"grok_home":"'"$worker"'"}' > "$sess/summary.json"
  got=$(fm_crew_grok_session "$op/sessions" "$wt")
  [ "$got" = "session-abc	$worker" ] || fail "grok discovery returned '$got'"
  fm_crew_grok_resume_record_write "$op" session-abc "$worker" || fail "grok resume record write failed"
  got=$(fm_crew_grok_resume_record_read "$op" session-abc)
  [ "$got" = "$worker" ] || fail "grok resume record read returned '$got'"
  if fm_crew_grok_resume_record_write "$op" '../escape' "$worker" 2>/dev/null; then
    fail "grok resume record accepted a traversal session id"
  fi
  pass "grok session discovery and resume record round-trip, traversal refused"
}

test_codex_session_id_finds_only_the_new_matching_worktree_rollout
test_codex_report_sends_the_exact_herdr_report
test_grok_session_and_resume_record_round_trip
