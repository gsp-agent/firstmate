#!/usr/bin/env bash
# Append exactly one verified owning Bead: line to a GitHub PR before registration.
# Usage: fm-pr-bead.sh <task-id> <pr-url>
# Uses fm-task-bead-lib.sh's authoritative resolver, never PR or brief prose.
# A task without a bead is unchanged. A bead lookup the resolver cannot verify
# warns once and leaves the body without a line, so the Observer deploy guard
# still refuses deployment.
# Existing lines are read the way that guard reads them: the first word after a
# leading Bead or bead and spaces or colons, deduplicated. A body naming only the
# verified bead is unchanged; one naming any other bead, or a failed forge
# operation, refuses registration, including at merge time.
# The existing body remains a byte-for-byte prefix, preserving pipeline attestation.
# Repeating the command leaves a matching body unchanged.
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
  *)
    printf 'fm-pr-bead: warning: %s task %s: bead lookup returned %s (%s); no Bead: line added\n' \
      "$FM_PR_URL" "$1" "$RC" "$FM_TASK_BEAD_ERROR" >&2
    exit 0
    ;;
esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-bead.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
gh pr view "$FM_PR_URL" --json body > "$TMP/pr.json"
IDS=$(jq -r '
  .body | if type == "string" then . else error("unreadable PR body") end
  | [split("\n")[] | capture("^[Bb]ead[ :]+(?<id>[^[:space:]]+)") | .id] | unique | join(" ")
' "$TMP/pr.json")
case "$IDS" in
  '') ;;
  "$FM_TASK_BEAD_ID") exit 0 ;;
  *)
    printf 'fm-pr-bead: %s task %s: Bead lines name %s, not only verified bead %s\n' \
      "$FM_PR_URL" "$1" "$IDS" "$FM_TASK_BEAD_ID" >&2
    exit 1
    ;;
esac
jq -j --arg bead "$FM_TASK_BEAD_ID" '.body + (if .body == "" then "" else "\n\n" end) + "Bead: " + $bead' \
  "$TMP/pr.json" > "$TMP/body"
gh pr edit "$FM_PR_URL" --body-file "$TMP/body" >/dev/null
