#!/usr/bin/env bash
# fm-task-bead-lib.sh - the bead a task answers to, and whether it is done.
#
# A merge or a measurement is a milestone. When a task has a bead, the bead's
# done is the authority on whether the task is done, so bin/fm-teardown.sh
# asks this file before it marks the task done, closes its backlog item, or
# removes its worker pane and local copy.
#
# A task has a bead when its id names one by the rule the PM send uses to name
# the task after its bead: an agent-config task `ac-<x>` answers to bead
# `.agent-config-<x>`, and any other task id is its bead id with a leading dot
# dropped, so `<id>` answers to bead `<id>`, or to `.<id>` when only a dotted
# prefix owns it. That bead is read from the one database its prefix owns
# (fm-task-data-lib.sh discovers that map from the bead homes on this machine).
# An id no database owns, a database file this machine does not have, and a
# bead its owner reports not found all mean the task has no bead, and the
# caller keeps its old behavior.
# The read is the native `br --db <db> show <bead> --json`, run from / with
# BEADS_DIR, BEADS_DB and BR_DB cleared, bounded by FM_TASK_BEAD_TIMEOUT_SECS
# (default 10). A unique short id that br expands to its canonical id is that
# bead when fm-task-data-lib.sh's fm_task_data_bead_id_matches accepts it.
#
# fm_task_bead_read <task-id> [<spawn-epoch>]
#   0  the task has a bead: FM_TASK_BEAD_ID (the id asked for, never the
#      expanded canonical id) and FM_TASK_BEAD_STATUS are set. Given the epoch
#      of the task's current spawn, an open bead's owner release also sets
#      FM_TASK_BEAD_RELEASE_AUTHOR and FM_TASK_BEAD_RELEASE_ID. The author is
#      empty when no release counts, and the id when br recorded none.
#   3  the task has no bead.
#   1  the owning database exists but did not answer, a bead home's record
#      could not be read, the bead's comments could not be read, or several
#      homes hold different beads under the id; FM_TASK_BEAD_ERROR says why.
#      A caller deciding to close must refuse rather than guess.
# fm_task_bead_open <status>
#   0 for every status except closed and tombstone.
# An owner's recorded release is the newest comment on an open bead that states
# the sentence "Firstmate may tear down this bead's tree", whose time is after
# the task's current spawn, and whose author is the bead's assignee, its owning
# EP, or its owning PM. The comment states the sentence when it opens with it,
# or with "owner's word for the worktree pool:" then the sentence, either form
# optionally signed first by its own author, and the sentence appears once.
# After it comes only a period, or a note starting "Checked" that has no quote
# mark and no condition, negation, or second mention of the release. Any other
# comment is not the owner's own statement, so it releases nothing. That
# sentence is the owner's record that the remaining step needs no tree. A
# restored task is a new spawn, so it needs a fresh release. The screen of the
# note cannot read every hedge: a mid-sentence "once" passes, because the live
# releases use it for later work, not for the release. The assignee is the
# issue's assignee field. The owning EP is
# "ep-" plus the directory name of any dev/*/.beads path that resolves to the
# owning database, links included. The owning PM is "pm-" plus the bead id or
# its prefix, each dot spelled as a dash. A PM under any other name releases
# only as the assignee or through the EP. A comment list that cannot be read is
# an unreadable bead, not an unreleased one.
# fm_task_merge_handoff_pending <status-file> <task-id>
#   0 when the task's last status line is the merge handoff that
#   bin/fm-merge-outcome-lib.sh writes for a live PM, which leaves activation
#   and live verification pending: the note handing them to the existing
#   owner, or the blocked line telling the PM no live owner is confirmed. Any
#   later status line from the task supersedes it.
#
# Callers source fm-task-data-lib.sh and fm-timeout-lib.sh first. Sourcing this
# file has no side effects.

fm_task_bead_candidate() {  # <task-id>
  case "$1" in
    ac-?*) printf '.agent-config-%s\n' "${1#ac-}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# The EP and PM names that may record a release for this bead, one per line.
fm_task_bead_release_authors() { # <bead-id> <database>
  local bead=$1 db=$2 prefix home best='' path base
  printf 'pm-%s\n' "${bead//./-}"
  while IFS=' ' read -r prefix home; do
    case "$bead" in
      "$prefix"-*)
        [ "${#prefix}" -le "${#best}" ] || best=$prefix
        ;;
    esac
  done <<EOF
$FM_TASK_DATA_BEAD_LOCATIONS
EOF
  printf 'pm-%s\n' "${best//./-}"
  for path in "$HOME"/dev/*/.beads/beads.db; do
    [ "$path" -ef "$db" ] || continue
    base=${path%/.beads/beads.db}
    printf 'ep-%s\n' "${base##*/}"
  done
}

# Prints "author<TAB>comment-id" for the newest recorded release in the br show
# JSON, or nothing when there is none. Returns 1 when the comment list cannot
# be read. This filter is the release rule.
fm_task_bead_release_from_json() { # <json> <authors> <spawn-epoch>
  jq -r --arg authors "$2" --arg sentence "Firstmate may tear down this bead's tree" \
    --arg lead_in "owner's word for the worktree pool" --argjson spawned "$3" '
    def created: try (.created_at | fromdateiso8601) catch 0;
    def withdrawn:
      test("[\"`]|\\b(?i:not|never|cannot|if|when|unless|until|while|after|before|except|but|however|still|hold|wait|stop|keep|withdraw\\w*|revoke\\w*|rescind\\w*|firstmate|tear|\\w+n[\\x27\\x{2019}]t)\\b|(?:[.!?;:]\\s+|\\n\\s*)(?i:no|only|once)\\b");
    def stated:
      .author as $author
      | (.text | ltrimstr($author)) as $text
      | ($text | test("\\A(?:(?:(?: \\([^()\\n]{1,40}\\))?, )?" + $lead_in + ":[ \\t]+)?" + $sentence
                      + "(?:\\.?\\s*\\z|(?:\\.\\s+|\\s*\\n\\s*)Checked\\b)"))
        and ($text | split($sentence) | length == 2 and (.[1] | withdrawn | not));
    def issue:
      if type == "array" and length == 1 and (.[0] | type) == "object" then .[0]
      else error("bead payload is not one issue") end;
    issue
    | .assignee as $assignee
    | (if (.comments | type) == "array" then .comments
       elif .comments == null then []
       else error("comments are not a list") end) as $comments
    | [
        $comments[]
        | select(type == "object")
        | select((.author | type) == "string" and (.author | test("^[A-Za-z0-9._+@-]+$")))
        | select(.author as $author | $author == $assignee or any($authors | split("\n")[]; . == $author))
        | select((.text | type) == "string" and stated)
        | select(created > $spawned)
      ]
    | sort_by(created, .id)
    | if length == 0 then ""
      else .[-1] | "\(.author)\t\(if (.id | type) == "number" then .id else "" end)" end
  ' 2>/dev/null <<FM_BEAD_RELEASE_JSON
$1
FM_BEAD_RELEASE_JSON
}

# shellcheck disable=SC2034 # FM_TASK_BEAD_* are results for sourcing callers.
fm_task_bead_read() {  # <task-id> [<spawn-epoch>]
  local bead db out canonical status=0 owned=0 secs=${FM_TASK_BEAD_TIMEOUT_SECS:-10} code
  local spawned=${2:-} release=''
  FM_TASK_BEAD_ID=
  FM_TASK_BEAD_STATUS=
  FM_TASK_BEAD_ERROR=
  FM_TASK_BEAD_RELEASE_AUTHOR=
  FM_TASK_BEAD_RELEASE_ID=
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  bead=$(fm_task_bead_candidate "$1")
  if ! fm_task_data_bead_locations; then
    FM_TASK_BEAD_ERROR="the bead homes on this machine could not be read"
    return 1
  fi
  db=$(fm_task_data_bead_database "$bead") || owned=$?
  if [ "$owned" = 1 ]; then
    case "$bead" in
      .*) return 3 ;;
    esac
    bead=".$bead"
    owned=0
    db=$(fm_task_data_bead_database "$bead") || owned=$?
    [ "$owned" != 1 ] || return 3
  fi
  if [ "$owned" != 0 ]; then
    FM_TASK_BEAD_ERROR="no one readable home owns bead $bead"
    return 1
  fi
  if [ ! -e "$db" ] && [ ! -L "$db" ]; then
    return 3
  fi
  if ! command -v jq >/dev/null 2>&1; then
    FM_TASK_BEAD_ERROR="jq is required to read bead $bead"
    return 1
  fi
  out=$(
    unset BEADS_DIR BEADS_DB BR_DB
    cd / && fm_run_timed "$secs" br --db "$db" show "$bead" --json 2>/dev/null
  ) || status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" = 3 ] && printf '%s\n' "$out" | jq -e '.error.code == "ISSUE_NOT_FOUND"' >/dev/null 2>&1; then
      return 3
    fi
    if [ "$status" = 124 ]; then
      FM_TASK_BEAD_ERROR="br show $bead did not answer within ${secs}s"
    else
      code=$(printf '%s\n' "$out" | jq -r '.error.code // empty' 2>/dev/null | head -n 1)
      FM_TASK_BEAD_ERROR="br show $bead against $db exited $status${code:+ ($code)}"
    fi
    return 1
  fi
  canonical=$(printf '%s\n' "$out" | jq -r '
    if type == "array" and length == 1 and (.[0].id | type) == "string"
    then .[0].id else empty end' 2>/dev/null)
  if [ -z "$canonical" ] || ! fm_task_data_bead_id_matches "$bead" "$canonical" "$db"; then
    FM_TASK_BEAD_ERROR="br show $bead returned no readable status"
    return 1
  fi
  FM_TASK_BEAD_STATUS=$(printf '%s\n' "$out" | jq -r --arg id "$canonical" '
    if type == "array" and length == 1 and .[0].id == $id
       and (.[0].status | type) == "string" and (.[0].status | length) > 0
    then .[0].status else empty end' 2>/dev/null)
  case "$FM_TASK_BEAD_STATUS" in
    ''|*[!A-Za-z0-9_-]*)
      FM_TASK_BEAD_STATUS=
      FM_TASK_BEAD_ERROR="br show $bead returned no readable status"
      return 1
      ;;
  esac
  FM_TASK_BEAD_ID=$bead
  if [ -n "$spawned" ] && fm_task_bead_open "$FM_TASK_BEAD_STATUS"; then
    if ! release=$(fm_task_bead_release_from_json "$out" "$(fm_task_bead_release_authors "$bead" "$db")" "$spawned"); then
      FM_TASK_BEAD_ID=
      FM_TASK_BEAD_STATUS=
      FM_TASK_BEAD_ERROR="bead $bead's comments could not be read"
      return 1
    fi
    IFS=$'\t' read -r FM_TASK_BEAD_RELEASE_AUTHOR FM_TASK_BEAD_RELEASE_ID <<EOF
$release
EOF
  fi
  return 0
}

fm_task_bead_open() {  # <status>
  case "$1" in
    closed|tombstone) return 1 ;;
    *) return 0 ;;
  esac
}

fm_task_merge_handoff_pending() {  # <status-file> <task-id>
  local file=$1 id=$2 last
  [ -f "$file" ] || return 1
  last=$(awk 'NF { line = $0 } END { print line }' "$file" 2>/dev/null) || return 1
  case "$last" in
    "note [key=merged-$id]"*": merged $id "*"; activation and live verification pending with the existing owner"*)
      return 0
      ;;
    "blocked [key=merged-owner-$id]"*": merged $id "*"; activation and live verification have no confirmed live owner"*)
      return 0
      ;;
  esac
  return 1
}
