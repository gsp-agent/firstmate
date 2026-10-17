#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-made-with.sh: which engines a task's pull
# request body names, and that only missing lines are ever appended.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-made-with.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-made-with-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 || fail "these tests run the script's jq programs with the real jq, which was not found"
command -v python3 >/dev/null 2>&1 || fail "these tests build a no-mistakes state database with python3, which was not found"
URL=https://github.com/o/r/pull/7
PROJECT=/work/project

# The fake gh serves one pull request body from FM_TEST_BODY and replaces it on
# edit, the way GitHub's full-body write does.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$1 $2 $3 $4 $5" in
  "pr view https://github.com/o/r/pull/7 --json body")
    jq -n --rawfile body "$FM_TEST_BODY" '{body: $body}'
    ;;
  "pr edit https://github.com/o/r/pull/7 --body-file "*)
    [ "${FM_TEST_EDIT_FAIL:-0}" = 0 ] || exit 1
    cp "$5" "$FM_TEST_BODY"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

# new_case <name> <harness> <model> <initial-body> builds a home whose task
# record names the worker, an empty no-mistakes home, and the PR body.
new_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home/state" "$CASE/nm"
  fm_write_meta "$CASE/home/state/task.meta" "harness=$2" "model=$3" \
    "project=$PROJECT" branch=fm/task
  printf '%s' "$4" > "$CASE/body"
  : > "$CASE/gh.log"
}

# add_calls <rows...> records no-mistakes agent calls, each row
# run|pr_url|branch|agent|model|purpose|exit_status, for the project repo.
add_calls() {
  python3 -I - "$CASE/nm/state.sqlite" "$PROJECT" "$@" <<'PY'
import sqlite3
import sys

db, project, rows = sys.argv[1], sys.argv[2], sys.argv[3:]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE IF NOT EXISTS repos (id TEXT PRIMARY KEY, working_path TEXT);
CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, pr_url TEXT);
CREATE TABLE IF NOT EXISTS agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, purpose TEXT,
  agent TEXT, model TEXT, exit_status TEXT, started_at INTEGER);
INSERT OR IGNORE INTO repos VALUES ('repo', '%s');
INSERT OR IGNORE INTO repos VALUES ('other', '/work/other');
""" % project)
for n, row in enumerate(rows):
    run, pr_url, branch, agent, model, purpose, status = row.split("|")
    repo, _, name = branch.rpartition(":")
    con.execute("INSERT OR IGNORE INTO runs VALUES (?, ?, ?, ?)",
                (run, repo or "repo", name, pr_url or None))
    con.execute("INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?, ?)",
                (f"call{n}", run, purpose, agent, model or None, status, n))
con.commit()
PY
}

run_stamp() {  # [url]
  FM_HOME="$CASE/home" NM_HOME="$CASE/nm" FM_TEST_BODY="$CASE/body" FM_TEST_GH_LOG="$CASE/gh.log" \
    PATH="$FAKEBIN:$PATH" "$SCRIPT" task "${1:-$URL}"
}

edits() {
  grep -c '^pr edit ' "$CASE/gh.log" || true
}

test_names_worker_and_a_different_fixing_agent() {
  local out
  new_case two-families claude claude-opus-5-5 $'## Why\nA reason.\n'
  add_calls "run1|$URL|fm/task|codex|gpt-6.1-sol|review-fix|ok" \
    "run1|$URL|fm/task|codex|gpt-6.1-sol|document|ok"
  out=$(run_stamp) || fail "a stamp with a readable database exited nonzero"
  assert_equals "$(cat "$CASE/body")" $'## Why\nA reason.\n\n\nMade-with: claude (claude-opus-5-5)\nMade-with: codex (gpt-6.1-sol) via no-mistakes' \
    "the body does not keep the old text as its prefix and end with both engine lines"
  assert_contains "$out" 'Made-with: codex (gpt-6.1-sol) via no-mistakes' "the output does not report the added lines"
  pass "the body names the worker and the different no-mistakes fixing agent"
}

test_rerun_changes_nothing() {
  local out
  out=$(run_stamp) || fail "a rerun exited nonzero"
  assert_equals "$(edits)" 1 "a rerun edited a body that already names every engine"
  assert_contains "$out" 'already names every engine found' "a rerun does not say the body is complete"
  pass "a rerun leaves a complete body alone"
}

test_only_ok_fixing_calls_of_another_agent_count() {
  new_case one-family claude claude-opus-5-5 'Body.'
  add_calls "run1|$URL|fm/task|claude|claude-opus-5-5|review-fix|ok" \
    "run1|$URL|fm/task|codex|gpt-6.1-sol|review-fix|error" \
    "run1|$URL|fm/task|codex|gpt-6.1-sol|review|ok" \
    "run1|$URL|fm/task|grok|grok-4.7|pr|ok" \
    "run2||other:fm/task|grok|grok-4.7|lint-fix|ok"
  run_stamp >/dev/null || fail "a stamp with only the worker's own family exited nonzero"
  assert_equals "$(cat "$CASE/body")" $'Body.\n\nMade-with: claude (claude-opus-5-5)' \
    "a failed call, a non-fixing call, another repository's run, or the worker's own agent was named"
  pass "only ok fixing calls by another agent on this task's runs are named"
}

test_branch_run_without_pr_counts() {
  new_case branch-run muse muse-wonder-1.0 'Body.'
  add_calls "run1||fm/task|claude|claude-opus-5-5|test-fix|ok"
  run_stamp >/dev/null || fail "a branch-matched run exited nonzero"
  assert_equals "$(cat "$CASE/body")" $'Body.\n\nMade-with: muse (muse-wonder-1.0)\nMade-with: claude (claude-opus-5-5) via no-mistakes' \
    "a fixing run on the task's branch that recorded no pull request was not named"
  pass "a fixing run on the task's branch counts before it records the pull request"
}

test_default_model_and_empty_body() {
  new_case default-model codex default ''
  run_stamp >/dev/null || fail "a stamp without a no-mistakes database exited nonzero"
  assert_equals "$(cat "$CASE/body")" 'Made-with: codex' \
    "an empty body did not become the worker line alone, without the default model"
  pass "an empty body gets the worker line, and a default model is left out"
}

test_crlf_body_already_naming_engines_is_left_alone() {
  new_case crlf grok grok-4.7 $'Text.\r\nMade-with: grok (grok-4.7)\r\n'
  run_stamp >/dev/null || fail "a CRLF body stamp exited nonzero"
  assert_equals "$(edits)" 0 "a CRLF body that already names the worker was edited"
  pass "a CRLF body that already names every engine is left alone"
}

test_unreadable_database_still_names_the_worker() {
  local status=0
  new_case bad-db claude claude-opus-5-5 'Body.'
  printf 'not a database' > "$CASE/nm/state.sqlite"
  run_stamp >/dev/null 2>&1 || status=$?
  assert_equals "$status" 1 "an unreadable database did not exit 1"
  assert_equals "$(cat "$CASE/body")" $'Body.\n\nMade-with: claude (claude-opus-5-5)' \
    "an unreadable database kept the worker line out"
  pass "an unreadable database exits 1 after naming the worker"
}

test_non_github_url_needs_nothing() {
  local out
  new_case gitlab claude claude-opus-5-5 'Body.'
  out=$(run_stamp https://gitlab.com/o/r/-/merge_requests/3) || fail "a GitLab merge request exited nonzero"
  assert_equals "$(cat "$CASE/gh.log")" '' "a GitLab merge request reached gh"
  assert_contains "$out" 'not a GitHub pull request' "a GitLab merge request was not reported as skipped"
  pass "a URL that is not a GitHub pull request needs nothing"
}

test_failures_exit_nonzero() {
  local status=0
  new_case edit-fails claude claude-opus-5-5 'Body.'
  FM_TEST_EDIT_FAIL=1 run_stamp >/dev/null 2>&1 || status=$?
  assert_equals "$status" 1 "a failed edit did not exit 1"
  status=0
  rm "$CASE/home/state/task.meta"
  run_stamp >/dev/null 2>&1 || status=$?
  assert_equals "$status" 1 "a missing task record did not exit 1"
  status=0
  run_stamp 'not a url' >/dev/null 2>&1 || status=$?
  assert_equals "$status" 2 "a bad URL was not a usage error"
  pass "a failed edit, a missing task record, and a bad URL exit nonzero"
}

test_names_worker_and_a_different_fixing_agent
test_rerun_changes_nothing
test_only_ok_fixing_calls_of_another_agent_count
test_branch_run_without_pr_counts
test_default_model_and_empty_body
test_crlf_body_already_naming_engines_is_left_alone
test_unreadable_database_still_names_the_worker
test_non_github_url_needs_nothing
test_failures_exit_nonzero
