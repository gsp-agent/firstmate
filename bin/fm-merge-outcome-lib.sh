#!/usr/bin/env bash
# Shared durable, supervisor-facing outcome publication for a confirmed merge.
#
# Both a merge performed by this home and a merge detected by its existing poll
# use this operation, so neither outcome depends on an agent remembering it.
# This operation publishes the poll's local actionable row; the watcher
# immediately delivers that row as observation handling, not a second outcome
# path.
#
# The destination is the home's role, never the caller's choice:
#   - a secondmate home reports upward on its parent channel, resolved and
#     appended through bin/fm-parent-channel-lib.sh under its channel contract;
#   - a main home reports to the captain through the durable wake queue.
# A poll observed in a secondmate home also receives a local durable wake after
# the upward write, so the mate can handle its own poll observation.
# No new state file and no new transport are involved.
#
# Normal operation deduplicates the task's latest canonical PR identity through
# the merge-notification marker owned by bin/fm-pr-lib.sh. Main-home wake keys
# also include that PR identity so distinct PRs for a reused task remain
# distinct in queue presentation. The outcome is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave a merge silent.
# A live PM instead receives a non-completion event in the task status stream
# its waiter already watches, before the marker is committed. Replaying an old
# marker repairs a missing PM event. Publication is a handoff to the existing
# owner for activation and live verification, never proof those steps finished.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"

# shellcheck source=bin/fm-backend.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-backend.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# Called under the merge-notification lock. The task metadata lock protects
# the PR/incarnation read and status append from teardown or a replacement.
# Reuse the canonical PR and generation readers; neither an old PR nor an
# ambiguous task record may announce work against the current task.
# A handoff is never written into a task that no longer exists. When the task
# record is gone because teardown closed the task before this merge reached it,
# and the record teardown archived at <data>/<id>/record/closed-task.meta
# names this exact PR, the live PM gets a blocked line on the same status
# stream instead, naming the restore, and the outcome fails so the merge stays
# unacknowledged. A gone record with no matching archive stays refused with no
# event, because nothing binds the merge to this task.
fm_merge_outcome_pm_handoff() {  # <state> <task-id> <canonical-pr-url> [data-dir]
  local state=$1 id=$2 url=$3 data=${4-} meta lock generation line archive rc=0
  local backend target owner_state
  meta="$state/$id.meta"
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  if ! command -v fm_backlog_meta_spawn_gen_optional >/dev/null 2>&1; then
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-backlog-transition-lib.sh"
  fi
  archive=
  [ -z "$data" ] || archive="$data/$id/record/closed-task.meta"
  if [ ! -e "$meta" ] && [ ! -L "$meta" ] && [ -n "$archive" ] \
    && fm_pr_metadata_identity_parse "$archive" && [ "$FM_PR_META_URL" = "$url" ]; then
    line="blocked [key=merged-closed-$id]: merged $id $url, but task $id was closed before this merge reached it, so nobody owns its activation and live verification; bring it back with bin/fm-control.sh $id relaunch --restore --note <what remains> (record archived at $archive)"
    fm_parent_channel_append_once "$state/$id.status" "$(status_stamp_line "$line")" || true
    printf 'error: merge handoff for %s refused: the task was closed before its merge, so its live PM was told on %s\n' "$id" "$state/$id.status" >&2
    rc=1
  elif ! fm_pr_metadata_identity_parse "$meta" \
    || [ "$FM_PR_META_URL" != "$url" ] \
    || ! fm_backlog_meta_spawn_gen_optional "$meta" "$state"; then
    printf 'error: merge handoff for %s has missing, changed, or ambiguous task/PR identity\n' "$id" >&2
    rc=1
  else
    generation=${FM_BACKLOG_META_SPAWN_GEN:-legacy}
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta") || target=
    owner_state=unreadable
    if [ -n "$target" ]; then
      owner_state=$(fm_backend_agent_state "$backend" "$target") || owner_state=unreadable
    fi
    if [ "$owner_state" = alive ]; then
      line="note [key=merged-$id]: merged $id $url spawn_gen=$generation; activation and live verification pending with the existing owner"
    else
      # Relaunch takes the metadata lock itself and cannot bind an expected
      # generation. Keep the identity lock and let the live PM drive recovery.
      line="blocked [key=merged-owner-$id]: merged $id $url spawn_gen=$generation; worker liveness is $owner_state, so activation and live verification have no confirmed live owner; inspect the worker and recover with bin/fm-control.sh $id relaunch --note 'Merged $url; activation and live verification remain pending'"
      printf 'error: merge handoff for %s refused: worker liveness is %s; its live PM was told on %s\n' "$id" "$owner_state" "$state/$id.status" >&2
      rc=1
    fi
    fm_parent_channel_append_once "$state/$id.status" "$(status_stamp_line "$line")" || rc=1
  fi
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority]
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so the canonical outcome
#          also wakes this home after any upward hop needed by a secondmate.
# Optional <authority> is away, attended, or external (the retired yolo and
# away-grant values are still accepted for a persisted authority written before
# the words model landed). Away, external, and the retired tags are appended to
# the ledger line; attended remains untagged. The merge entrypoint supplies its
# authority after forge acceptance, while the poll supplies the persisted
# identity-bound value or external when no matching record proves that this
# home authorized the merge.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [authority]
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local self_rc=0 destination='' line lock status=0
  local provider host path number canonical_url pm_live=false
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  case "$authority" in
    away|external|yolo|away-grant) suffix=" $authority" ;;
    attended|'') ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  canonical_url=$FM_PR_URL
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  if destination=$(fm_parent_channel_destination "$home" "$state"); then
    line="done [key=merged-$id]: merged $id $canonical_url$suffix"
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
    destination=''
  fi

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_pm_live_task "$state" "$id"; then
    pm_live=true
    # This must also run for a matching marker written by an older version
    # that suppressed main without publishing anything the PM could observe.
    if ! fm_merge_outcome_pm_handoff "$state" "$id" "$canonical_url" "${FM_DATA_OVERRIDE:-$home/data}"; then
      fm_lock_release "$lock"
      return 1
    fi
  fi
  if fm_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" "$(status_stamp_line "$line")" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; } \
    && [ "$pm_live" = false ]; then
    fm_wake_append check "merged-$id-$canonical_url" \
      "check: merge landed: $id $canonical_url$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock" || status=1
  # Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
  [ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/fleet-ledger" ] || [ "$status" -ne 0 ] || FM_HOME=$home FM_STATE_OVERRIDE=$state "$_FM_MERGE_OUTCOME_LIB_DIR/fm-fleet-ledger.sh" merged "$id" pr "$canonical_url" || true
  return "$status"
}
