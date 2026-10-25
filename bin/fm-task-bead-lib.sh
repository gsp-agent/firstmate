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
# (fm-task-data-lib.sh's fm_task_data_bead_database keeps that map). An id no
# database owns, a database file this machine does not have, and a bead its
# owner reports not found all mean the task has no bead, and the caller keeps
# its old behavior.
# The read is the native `br --db <db> show <bead> --json`, run from / with
# BEADS_DIR, BEADS_DB and BR_DB cleared, bounded by FM_TASK_BEAD_TIMEOUT_SECS
# (default 10).
#
# fm_task_bead_read <task-id>
#   0  the task has a bead: FM_TASK_BEAD_ID and FM_TASK_BEAD_STATUS are set.
#   3  the task has no bead.
#   1  the owning database exists but did not answer; FM_TASK_BEAD_ERROR says
#      why. A caller deciding to close must refuse rather than guess.
# fm_task_bead_open <status>
#   0 for every status except closed and tombstone.
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

# shellcheck disable=SC2034 # FM_TASK_BEAD_* are results for sourcing callers.
fm_task_bead_read() {  # <task-id>
  local bead db out canonical status=0 secs=${FM_TASK_BEAD_TIMEOUT_SECS:-10} code
  FM_TASK_BEAD_ID=
  FM_TASK_BEAD_STATUS=
  FM_TASK_BEAD_ERROR=
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  bead=$(fm_task_bead_candidate "$1")
  if ! db=$(fm_task_data_bead_database "$bead") || [ -z "$db" ]; then
    case "$bead" in
      .*) return 3 ;;
    esac
    bead=".$bead"
    db=$(fm_task_data_bead_database "$bead") || return 3
    [ -n "$db" ] || return 3
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
  FM_TASK_BEAD_ID=$canonical
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
