#!/usr/bin/env bash
# Name every engine that wrote commits on a task's GitHub pull request on a
# `Made-with:` line in its body, so a reviewer that routes by author family can
# see which families wrote the work.
#
# Usage: fm-pr-made-with.sh <task-id> <pr-url>
#
# Firstmate strips AI co-author trailers and launches Claude workers with
# attribution off, so a fleet pull request otherwise names no engine at all.
# The engines are:
#   - the worker: the task record's harness= and model=, written
#     `Made-with: <harness> (<model>)`, with the model left out when it is
#     empty or `default`;
#   - each no-mistakes agent that wrote a `no-mistakes(<step>): ...` commit
#     the pull request carries, written
#     `Made-with: <agent> (<model>) via no-mistakes`, unless that agent is the
#     worker's harness. The commit's author time names the call: the latest
#     committing call (review-fix, test-fix, lint, lint-fix, document,
#     housekeeping, ci) of that step that exited ok at or before it, in a run
#     recorded for this pull request or for the task's branch in its project.
#     The source is no-mistakes' local state database, opened read-only as
#     bin/fm-pipeline-spend.sh opens it. A fixing call that committed nothing
#     names no one, and neither does the configured agent: only what the run
#     recorded.
# Only lines the body lacks are appended, after a blank line at its end. The
# existing body stays byte for byte as the prefix, so a rerun changes nothing.
# GitHub offers only a full-body write, so the edit follows the read at once.
# A later no-mistakes run rewrites the whole body and drops the lines, so a
# worker runs this as soon as its pull request is ready (bin/fm-dod-lib.sh) and
# bin/fm-pr-check.sh runs it again when it registers the pull request.
# A URL that is not a GitHub pull request needs nothing and exits 0.
# Exit status: 0 when the body names every engine found; 1 when the task
# record, the database, or the forge read or edit failed (an unreadable
# database still lets the worker line through first); 2 for bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
fail() {
  printf 'fm-pr-made-with: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -eq 2 ] || { usage >&2; exit 2; }
ID=$1
fm_pr_task_id_valid "$ID" || { echo "fm-pr-made-with: invalid task id" >&2; exit 2; }
fm_pr_url_parse "$2" || { echo "fm-pr-made-with: not a canonical pull request URL: $2" >&2; exit 2; }
if [ "$FM_PR_PROVIDER" != github ]; then
  echo "fm-pr-made-with: $FM_PR_URL is not a GitHub pull request; nothing to add"
  exit 0
fi
URL=$FM_PR_URL
META="$STATE/$ID.meta"
[ -f "$META" ] || fail "task record $META is unavailable"

meta_value() {  # <key>
  grep "^$1=" "$META" | tail -1 | cut -d= -f2-
}
engine_line() {  # <engine> <model> [suffix]
  case "$2" in
    ''|default) printf 'Made-with: %s%s\n' "$1" "${3:-}" ;;
    *) printf 'Made-with: %s (%s)%s\n' "$1" "$2" "${3:-}" ;;
  esac
}

HARNESS=$(meta_value harness)
[ -n "$HARNESS" ] || fail "task record $META names no harness"
PROJECT=$(meta_value project)
LINES=$(engine_line "$HARNESS" "$(meta_value model)")

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-made-with.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
gh pr view "$URL" --json body,commits > "$TMP/pr.json" || fail "could not read the body of $URL"

RC=0
DB=$(fm_nm_state_db "${PROJECT:-$STATE}")
if [ -f "$DB" ]; then
  FIXERS=$(fm_nm_bounded "$STATE" 30 python3 -I - "$DB" "$TMP/pr.json" "$URL" "$(meta_value branch)" "$PROJECT" <<'PY'
import json
import re
import sqlite3
import sys
from contextlib import closing
from datetime import datetime
from pathlib import Path

db, pr_json, url, branch, project = sys.argv[1:6]
with open(pr_json, encoding="utf-8") as f:
    commits = json.load(f).get("commits") or []
writes = []
for commit in commits:
    step = re.match(r"no-mistakes\(([a-z-]+)\):", commit.get("messageHeadline") or "")
    if step:
        when = datetime.fromisoformat(commit["authoredDate"].replace("Z", "+00:00"))
        writes.append((when.timestamp(), step[1]))
committing = ("review-fix", "test-fix", "lint", "lint-fix", "document", "housekeeping", "ci")
query = (
    "SELECT a.agent, COALESCE(a.model, '') FROM agent_invocations a"
    " JOIN runs r ON r.id = a.run_id JOIN repos p ON p.id = r.repo_id"
    " WHERE (r.pr_url = ? OR (r.branch = ? AND p.working_path = ?))"
    " AND a.exit_status = 'ok' AND a.step_name = ? AND a.started_at <= ?"
    " AND a.purpose IN (%s) ORDER BY a.started_at DESC LIMIT 1" % ", ".join("?" * len(committing))
)
named = []
with closing(sqlite3.connect(Path(db).as_uri() + "?mode=ro", uri=True, timeout=20)) as con:
    for when, step in sorted(writes):
        row = con.execute(query, (url, branch, project, step, when, *committing)).fetchone()
        if row and row[0] and row not in named:
            named.append(row)
for agent, model in named:
    if not any(c in agent + model for c in "\t\r\n"):
        print(f"{agent}\t{model}")
PY
  ) || { RC=1; echo "fm-pr-made-with: could not read no-mistakes fixing agents from $DB; naming the worker only" >&2; }
  while IFS="$(printf '\t')" read -r agent model; do
    [ -n "$agent" ] && [ "$agent" != "$HARNESS" ] || continue
    LINES="$LINES
$(engine_line "$agent" "$model" ' via no-mistakes')"
  done <<EOF
${FIXERS:-}
EOF
fi

jq --arg add "$LINES" '
  (.body // "") as $body
  | ($body | split("\n") | map(rtrimstr("\r"))) as $have
  | [$add | split("\n")[] as $line
      | select(any($have[]; . == $line) | not) | $line] as $missing
  | {missing: $missing,
     body: (if $body == "" then "" else $body + "\n\n" end) + ($missing | join("\n"))}
' "$TMP/pr.json" > "$TMP/plan.json" || fail "could not parse the body of $URL"
MISSING=$(jq -r '.missing[]' "$TMP/plan.json")
if [ -z "$MISSING" ]; then
  echo "fm-pr-made-with: $URL already names every engine found"
  exit "$RC"
fi
jq -j '.body' "$TMP/plan.json" > "$TMP/body"
gh pr edit "$URL" --body-file "$TMP/body" >/dev/null || fail "could not edit the body of $URL"
printf 'fm-pr-made-with: added to %s:\n%s\n' "$URL" "$MISSING"
exit "$RC"
