#!/usr/bin/env bash
# Append exactly one verified owning Bead: line to a GitHub PR before registration.
# Usage: fm-pr-bead.sh <task-id> <pr-url>
# Uses fm-task-bead-lib.sh's authoritative resolver, never PR or brief prose.
# A task without a bead is unchanged. An unreadable owner, conflicting or duplicate
# owning line (any line the Observer deploy guard reads as one, such as bead: or
# Bead <id>), or failed forge operation refuses registration, including at merge time.
# The existing body remains a byte-for-byte prefix, preserving pipeline attestation.
# Repeating the command leaves a matching single line unchanged.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-task-data-lib.sh
. "$SCRIPT_DIR/fm-task-data-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-task-bead-lib.sh
. "$SCRIPT_DIR/fm-task-bead-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac
if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1" || ! fm_pr_url_parse "$2"; then
  echo 'fm-pr-bead: invalid task or PR URL' >&2
  exit 2
fi
[ "$FM_PR_PROVIDER" = github ] || exit 0
RC=0
fm_task_bead_read "$1" || RC=$?
case "$RC" in
  0) ;;
  3) exit 0 ;;
  *) printf 'fm-pr-bead: %s\n' "$FM_TASK_BEAD_ERROR" >&2; exit 1 ;;
esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-bead.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
gh pr view "$FM_PR_URL" --json body > "$TMP/pr.json"
jq -e --arg bead "$FM_TASK_BEAD_ID" '
  .body as $body
  | if ($body | type) != "string" then error("unreadable PR body") else . end
  | [$body | split("\n")[] | rtrimstr("\r") | select(test("^[Bb]ead[ :]"))] as $lines
  | if ($lines | length) == 0 then
      {changed: true, body: ($body + (if $body == "" then "" else "\n\n" end) + "Bead: " + $bead)}
    elif $lines == ["Bead: " + $bead] then {changed: false, body: $body}
    else error("conflicting or duplicate Bead: lines") end
' "$TMP/pr.json" > "$TMP/plan.json"
if [ "$(jq -r '.changed' "$TMP/plan.json")" = true ]; then
  jq -j '.body' "$TMP/plan.json" > "$TMP/body"
  gh pr edit "$FM_PR_URL" --body-file "$TMP/body" >/dev/null
fi
