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

# The fake gh serves one pull request body from FM_TEST_BODY, its commits from
# FM_TEST_COMMITS and its head branch from FM_TEST_HEAD (default fm/task), and
# replaces the body on edit, the way GitHub's full-body write does.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$1 $2 $3 $4 $5" in
  "pr view https://github.com/o/r/pull/7 --json body,commits,headRefName")
    jq -n --rawfile body "$FM_TEST_BODY" --slurpfile commits "$FM_TEST_COMMITS" \
      --arg head "${FM_TEST_HEAD:-fm/task}" '{body: $body, commits: $commits, headRefName: $head}'
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
# record names the worker, an empty no-mistakes home, the PR body, and a pull
# request with no commits. REPO_PATH is the project path no-mistakes records.
new_case() {
  CASE="$TMP_ROOT/$1"
  REPO_PATH=$PROJECT
  mkdir -p "$CASE/home/state" "$CASE/nm"
  fm_write_meta "$CASE/home/state/task.meta" "harness=$2" "model=$3" \
    "project=$PROJECT" branch=fm/task
  printf '%s' "$4" > "$CASE/body"
  : > "$CASE/commits"
  : > "$CASE/gh.log"
}

# add_commits <headline|author-epoch...> puts commits on the pull request,
# each with an oid whose short form is c<epoch as six digits>.
add_commits() {
  local row
  for row in "$@"; do
    jq -n --arg head "${row%|*}" --argjson at "${row##*|}" --arg oid "$(printf 'c%06d%033d' "${row##*|}" 0)" \
      '{oid: $oid, messageHeadline: $head, authoredDate: ($at | todate)}' >> "$CASE/commits"
  done
}

# add_calls <rows...> records no-mistakes agent calls, each row
# run|pr_url|branch|agent|model|step|purpose|exit_status|started_at, for the
# project repo at REPO_PATH.
add_calls() {
  python3 -I - "$CASE/nm/state.sqlite" "$REPO_PATH" "$@" <<'PY'
import sqlite3
import sys

db, project, rows = sys.argv[1], sys.argv[2], sys.argv[3:]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE IF NOT EXISTS repos (id TEXT PRIMARY KEY, working_path TEXT);
CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, pr_url TEXT);
CREATE TABLE IF NOT EXISTS agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT,
  purpose TEXT, agent TEXT, model TEXT, exit_status TEXT, started_at INTEGER);
INSERT OR IGNORE INTO repos VALUES ('repo', '%s');
INSERT OR IGNORE INTO repos VALUES ('other', '/work/other');
""" % project)
for n, row in enumerate(rows):
    run, pr_url, branch, agent, model, step, purpose, status, started = row.split("|")
    repo, _, name = branch.rpartition(":")
    con.execute("INSERT OR IGNORE INTO runs VALUES (?, ?, ?, ?)",
                (run, repo or "repo", name, pr_url or None))
    con.execute("INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (f"call{n}", run, step, purpose, agent, model or None, status, int(started)))
con.commit()
PY
}

run_stamp() {  # [url]
  FM_HOME="$CASE/home" NM_HOME="$CASE/nm" FM_TEST_BODY="$CASE/body" FM_TEST_COMMITS="$CASE/commits" FM_TEST_GH_LOG="$CASE/gh.log" \
    PATH="$FAKEBIN:$PATH" "$SCRIPT" task "${1:-$URL}"
}

edits() {
  grep -c '^pr edit ' "$CASE/gh.log" || true
}

test_names_worker_and_each_committing_agent() {
  local out
  new_case two-families claude claude-opus-5-5 $'## Why\nA reason.\n'
  add_calls "run1|$URL|fm/task|codex|gpt-6.1-sol|review|review-fix|ok|100" \
    "run1|$URL|fm/task|grok|grok-4.7|document|housekeeping|ok|200" \
    "run1|$URL|fm/task|cursor|composer-2|ci|ci|ok|300"
  add_commits "feat: the worker's change|50" "no-mistakes(review): Fix a finding|150" \
    "no-mistakes(document): Update the docs|250"
  out=$(run_stamp) || fail "a stamp with a readable database exited nonzero"
  assert_equals "$(cat "$CASE/body")" $'## Why\nA reason.\n\n\nMade-with: claude (claude-opus-5-5)\nMade-with: codex (gpt-6.1-sol) via no-mistakes\nMade-with: grok (grok-4.7) via no-mistakes' \
    "the body does not keep the old text as its prefix and end with the worker and each committing agent"
  assert_contains "$out" 'Made-with: grok (grok-4.7) via no-mistakes' "the output does not report the added lines"
  pass "the body names the worker and each no-mistakes agent whose commit the pull request carries"
}

test_rerun_changes_nothing() {
  local out
  out=$(run_stamp) || fail "a rerun exited nonzero"
  assert_equals "$(edits)" 1 "a rerun edited a body that already names every engine"
  assert_contains "$out" 'already names every engine found' "a rerun does not say the body is complete"
  pass "a rerun leaves a complete body alone"
}

test_only_the_call_that_wrote_a_commit_counts() {
  local status=0 err
  new_case one-family claude claude-opus-5-5 'Body.'
  add_calls "run1|$URL|fm/task|codex|gpt-6.1-sol|review|review-fix|ok|10" \
    "run1|$URL|fm/task|claude|claude-opus-5-5|review|review-fix|ok|30" \
    "run1|$URL|fm/task|codex|gpt-6.1-sol|review|review-fix|error|35" \
    "run1|$URL|fm/task|grok|grok-4.7|review|review|ok|38" \
    "run1|$URL|fm/task|grok|grok-4.7|test|test-fix|ok|60" \
    "run2||other:fm/task|cursor|composer-2|lint|lint-fix|ok|5"
  add_commits "no-mistakes(review): Fix a finding|40" "no-mistakes(test): Fix a test|50" \
    "no-mistakes(lint): Fix lint|45"
  run_stamp >/dev/null 2>"$CASE/stderr" || status=$?
  err=$(cat "$CASE/stderr")
  assert_equals "$status" 1 "a no-mistakes commit that no recorded call wrote did not exit 1"
  assert_equals "$(cat "$CASE/body")" $'Body.\n\nMade-with: claude (claude-opus-5-5)' \
    "an earlier or failed fixer, a reviewer, a fixer that started after the commit, or another repository's run was named"
  assert_contains "$err" 'no recorded no-mistakes call wrote c000045 no-mistakes(lint): Fix lint' \
    "a commit only another repository's run could have written was not named on stderr"
  assert_contains "$err" 'no recorded no-mistakes call wrote c000050 no-mistakes(test): Fix a test' \
    "a commit only a later fixer could have written was not named on stderr"
  assert_not_contains "$err" 'c000040' "a commit the worker's own agent wrote was reported as unattributed"
  pass "only the latest ok committing call before each commit names its agent, the worker's own agent adds nothing, and an unattributed commit exits 1 naming it"
}

test_branch_run_without_pr_counts() {
  new_case branch-run muse muse-wonder-1.0 'Body.'
  add_calls "run1||fm/task|claude|claude-opus-5-5|test|test-fix|ok|10"
  add_commits "no-mistakes(test): Fix a test|20"
  run_stamp >/dev/null || fail "a branch-matched run exited nonzero"
  assert_equals "$(cat "$CASE/body")" $'Body.\n\nMade-with: muse (muse-wonder-1.0)\nMade-with: claude (claude-opus-5-5) via no-mistakes' \
    "a fixing run on the task's branch that recorded no pull request was not named"
  pass "a fixing run on the task's branch counts before it records the pull request"
}

test_symlinked_project_matches_its_resolved_path() {
  new_case symlink claude claude-opus-5-5 'Body.'
  mkdir -p "$CASE/agent-config"
  ln -s "$CASE/agent-config" "$CASE/dev-agent-config"
  printf 'project=%s\n' "$CASE/dev-agent-config" >> "$CASE/home/state/task.meta"
  REPO_PATH=$(cd "$CASE/agent-config" && pwd -P)
  add_calls "run1||fm/task|codex|gpt-6.1-sol|review|review-fix|ok|10"
  add_commits "no-mistakes(review): Fix a finding|20"
  run_stamp >/dev/null || fail "a run in the symlinked project's resolved path exited nonzero"
  assert_equals "$(cat "$CASE/body")" $'Body.\n\nMade-with: claude (claude-opus-5-5)\nMade-with: codex (gpt-6.1-sol) via no-mistakes' \
    "a run recorded under the resolved path of a symlinked project was not named"
  pass "a task record's symlinked project matches the resolved path no-mistakes records"
}

test_head_branch_run_counts() {
  new_case head-branch claude claude-opus-5-5 'Body.'
  add_calls "run1||fm/task-2c|codex|gpt-6.1-sol|review|review-fix|ok|10" \
    "run2||fm/other|grok|grok-4.7|review|review-fix|ok|15"
  add_commits "no-mistakes(review): Fix a finding|20"
  FM_TEST_HEAD=fm/task-2c run_stamp >/dev/null || fail "a run on the pull request's head branch exited nonzero"
  assert_equals "$(cat "$CASE/body")" $'Body.\n\nMade-with: claude (claude-opus-5-5)\nMade-with: codex (gpt-6.1-sol) via no-mistakes' \
    "a run on the pull request's renamed head branch was not named, or a run on an unrelated branch was"
  pass "a fixing run on the pull request's head branch counts when the task record names another branch"
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

test_absent_or_unreadable_database_still_names_the_worker() {
  local status=0
  new_case bad-db claude claude-opus-5-5 'Body.'
  printf 'not a database' > "$CASE/nm/state.sqlite"
  add_commits "no-mistakes(review): Fix a finding|20"
  run_stamp >/dev/null 2>"$CASE/stderr" || status=$?
  assert_equals "$status" 1 "an unreadable database did not exit 1"
  assert_equals "$(cat "$CASE/body")" $'Body.\n\nMade-with: claude (claude-opus-5-5)' \
    "an unreadable database kept the worker line out"
  assert_contains "$(cat "$CASE/stderr")" 'no recorded no-mistakes call wrote c000020 no-mistakes(review): Fix a finding' \
    "an unreadable database did not name the commit it could not attribute"
  status=0
  rm "$CASE/nm/state.sqlite"
  run_stamp >/dev/null 2>"$CASE/stderr" || status=$?
  assert_equals "$status" 1 "an absent database with a no-mistakes commit did not exit 1"
  assert_contains "$(cat "$CASE/stderr")" 'no recorded no-mistakes call wrote c000020 no-mistakes(review): Fix a finding' \
    "an absent database did not name the commit it could not attribute"
  pass "an absent or unreadable database exits 1 after naming the worker and each commit it could not attribute"
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

test_names_worker_and_each_committing_agent
test_rerun_changes_nothing
test_only_the_call_that_wrote_a_commit_counts
test_branch_run_without_pr_counts
test_symlinked_project_matches_its_resolved_path
test_head_branch_run_counts
test_default_model_and_empty_body
test_crlf_body_already_naming_engines_is_left_alone
test_absent_or_unreadable_database_still_names_the_worker
test_non_github_url_needs_nothing
test_failures_exit_nonzero
