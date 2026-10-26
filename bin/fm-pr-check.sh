#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# Refuses when bin/fm-dod-lib.sh will not accept the named head as reachable
# outside the worker's disposable copy; in no-mistakes mode a forge-reported
# head is that named head and is already stored on the forge.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL, a GitLab merge request URL, and a Gerrit change URL
# are all accepted, including a merge request or change on a self-hosted
# instance.
# A GitHub pull request the forge reports as a draft is refused, naming the draft
# state and recording and arming nothing: a draft cannot be merged, so a poll armed on it
# would wait for an event that cannot occur while nobody is asked to act.
# Mark the pull request ready for review, then arm again; a lane that keeps a
# draft on purpose declares a wait instead of reporting done. An unreadable
# draft state does not refuse, matching how the head read below is optional.
# bin/fm-pr-merge.sh records through this script with FM_PR_CHECK_MERGE=1 and
# skips this refusal, because its own merge-time draft refusal is authoritative.
# The recorded pr= also frees the task's place in a declared project capacity
# (bin/fm-project-capacity-lib.sh), and the output then ends with
# bin/fm-dispatch-ready.sh's Dispatch lines saying what that place can start.
# A registered GitHub pull request is also stamped with the engines that wrote
# it through bin/fm-pr-made-with.sh, except on the merge-time re-record.
# Before registration, bin/fm-pr-bead.sh carries the verified owning bead into
# GitHub bodies, including at merge time after any pipeline body rewrite.
# Annotation failure refuses registration before its record, poll or callback.
# An optional home-owned config/pr-ready-callback executable receives
# <owner/repo> <positive-pr-number> <40hex-head> after the canonical record and
# static poll are published, before optional extras, except at merge time.
# The call is bounded to ten seconds. Only exit 0 and a final stdout JSON line
# with schema=pr-review-router.event.v1, exact repo/pr(integer)/head,
# accepted=true and disposition=handled|stale|closed|ignored acknowledge it.
# Failure is reported as pending without changing registration's status or
# records. Re-running this command retries delivery, never PR publication;
# the callback consumer must deduplicate the identity. An absent hook is inert.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A secondmate is a persistent worker, not a delivery lane: it never owns a
# pull request of its own. A URL reported on its routed status channel belongs
# to a task inside the mate's own home, which records and watches it there;
# arming a merge watch here would queue the mate itself for teardown as landed
# work once that pull request merges.
KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$KIND" = secondmate ]; then
  echo "error: $ID is a secondmate, not a delivery lane - $URL was reported on its status channel but belongs to a task in the mate's own home, which arms its own merge watch" >&2
  exit 1
fi

# Resume only identity-bound receipts under bin/fm-pr-lib.sh's retirement
# contract; fm_pr_poll_retirement_ready below decides whether replacement
# preserves repository discovery.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}
PR_RETIREMENT_RC=0
fm_pr_poll_retirement_ready "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" '' "$URL" \
  || PR_RETIREMENT_RC=$?
case "$PR_RETIREMENT_RC" in
  0) ;;
  2) echo "error: pending repository merge-queue sweep; preserving task state" >&2; exit 1 ;;
  *) echo "error: pending PR poll retirement could not be validated" >&2; exit 1 ;;
esac

# Refuse to arm a watch with no CLI on PATH to read it. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# change that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
# The Gerrit poll also needs jq, because Gerrit's status has to be read out of a
# structured record rather than off a rendered line: the tool's own table prints
# a change's subject before its status, and a subject is free text.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi
if [ "$PROVIDER" = gerrit ]; then
  if ! command -v gerrit-axi >/dev/null 2>&1; then
    echo "error: watching a Gerrit change requires gerrit-axi on PATH" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: watching a Gerrit change requires jq on PATH" >&2
    exit 1
  fi
fi

# Refuse to arm a Forgejo watch with no tea or jq on PATH, for the same reason
# as the GitLab and Gerrit cases above. tea also addresses a repo by slug only, resolving the
# host from a named "tea login" rather than from the URL the way gh and glab
# do, so a poll can only ever succeed when exactly one registered login
# matches this host; refuse now rather than watch something that can never
# resolve. This duplicates bin/fm-pr-poll.sh's own login match deliberately:
# that script is a static, standalone watcher body with no sourced
# dependency, so it re-derives the same match at every poll instead of
# trusting a name recorded here.
if [ "$PROVIDER" = forgejo ]; then
  if ! command -v tea >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "error: watching a Forgejo pull request requires tea and jq on PATH" >&2
    exit 1
  fi
  fm_pr_forgejo_login "$HOST" >/dev/null || {
    echo "error: watching a Forgejo pull request at $HOST requires exactly one 'tea login' registered for that host (see 'tea login list')" >&2
    exit 1
  }
fi

# The draft state is read before anything is recorded or armed. Only a positive
# draft reading refuses, because an unreadable one must not block arming.
if [ "$PROVIDER" = github ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  DRAFT_JSON=$(gh pr view "$URL" --json isDraft 2>/dev/null || true)
  if [ "$(fm_pr_json_draft_state "$DRAFT_JSON")" = true ]; then
    echo "error: $URL is a draft pull request; a draft cannot be merged, so merge monitoring would wait for an event that cannot occur - mark it ready for review and arm again, or declare a wait instead of done if the draft is deliberate" >&2
    exit 1
  fi
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, and
# tea's single-PR view ignores field selection entirely, so neither a GitLab
# nor a Forgejo task records a pr_head here, and neither does a Gerrit task: a
# Gerrit revision names one patch set, every amend or rebase is a new patch set,
# and bin/fm-review-diff.sh has no Gerrit path to resolve a current head with,
# so a recorded revision would silently become the reviewed content. Both
# consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh fetches a pull request head from the remote when none is
# recorded and otherwise diffs the local branch, which is the current content.
# bin/fm-pr-merge.sh reads a GitLab or Forgejo head live at merge time for the
# same reason, and treats a recorded value that disagrees as stale rather than
# authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
# The gate is asked about the ready report this task's worker was told to give;
# on a Gerrit change both publishing modes report the same published line.
case "$PROVIDER:$MODE" in
  gerrit:*) DONE_LINE="done: PR $URL published for review" ;;
  *:no-mistakes|*:) DONE_LINE="done: PR $URL checks green" ;;
  *) DONE_LINE="done: PR $URL" ;;
esac
if { [ -z "$PR_HEAD" ] || ! fm_dod_forge_head_is_named_head "$MODE"; } \
  && ! GATE_REASON=$(fm_dod_accept_ship_done "${KIND:-ship}" "$MODE" "$WT" "$PROJECT" "$DONE_LINE" "$STATE" "$ID" "$META"); then
  echo "error: $GATE_REASON" >&2
  exit 1
fi

if [ "$PROVIDER" = github ]; then
  "$SCRIPT_DIR/fm-pr-bead.sh" "$ID" "$URL" || exit 1
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_POLL_PUBLISH_LOCK=
PR_POLL_PUBLISH_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$PR_POLL_PUBLISH_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PR_POLL_PUBLISH_LOCK" || true
    PR_POLL_PUBLISH_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
fm_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK"
PR_POLL_PUBLISH_LOCK_HELD=1
if fm_pr_poll_publish_prepared; then
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
else
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
  echo "error: could not publish PR poll" >&2
  exit 1
fi
# Use the existing canonical record as recovery input, not a second publication
# queue. A callback cannot unwind the registration or cause another forge POST.
PR_READY_CALLBACK="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/pr-ready-callback"
if [ "$PROVIDER" = github ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ] \
  && [ -n "$PR_HEAD" ] && [ -e "$PR_READY_CALLBACK" ]; then
  PR_READY_ACK=0
  if [ -x "$PR_READY_CALLBACK" ] && command -v jq >/dev/null 2>&1; then
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    if PR_READY_RECEIPT=$(fm_run_timed 10 "$PR_READY_CALLBACK" "$PROJECT_PATH" "$NUMBER" "$PR_HEAD" </dev/null 2>/dev/null) \
      && printf '%s\n' "$PR_READY_RECEIPT" | tail -n 1 | jq -se --arg repo "$PROJECT_PATH" --argjson pr "$NUMBER" --arg head "$PR_HEAD" '
        length == 1 and (.[0] | .schema == "pr-review-router.event.v1" and .repo == $repo and .pr == $pr
        and .head == $head and .accepted == true
        and (.disposition | IN("handled", "stale", "closed", "ignored")))' >/dev/null 2>&1; then
      PR_READY_ACK=1
    fi
  fi
  if [ "$PR_READY_ACK" != 1 ]; then
    printf 'actionable: PR %s is registered; review callback pending for %s #%s at %s; rerun bin/fm-pr-check.sh %s %s\n' \
      "$URL" "$PROJECT_PATH" "$NUMBER" "$PR_HEAD" "$ID" "$URL" >&2
  fi
fi
# A GitHub pull request is stamped with the engines that wrote it
# (bin/fm-pr-made-with.sh), repeating the worker's own stamp because a later
# pipeline run rewrites the body. A failed stamp leaves the watch armed.
if [ "$PROVIDER" = github ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ]; then
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-pr-made-with.sh" "$ID" "$URL" >/dev/null \
    || printf 'actionable: PR %s is registered but its body may not name every engine that wrote it; rerun bin/fm-pr-made-with.sh %s %s\n' "$URL" "$ID" "$URL" >&2
fi
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
# The merge-time re-record is not a new review-ready PR, so it writes nothing.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || [ "${FM_PR_CHECK_MERGE:-}" = 1 ] \
  || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" pr_ready "$ID" "$URL" || true
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the static PR poll (bin/fm-pr-poll.sh).
# Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
# The recorded pr= freed the task's place when its project declares a limit,
# so the handoff itself says what that place can start
# (bin/fm-dispatch-ready.sh, silent for an unlimited project). The merge-time
# re-record frees nothing new.
PR_PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "${FM_PR_CHECK_MERGE:-}" != 1 ] && [ -n "$PR_PROJECT" ] && [ -d "$PR_PROJECT" ]; then
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-dispatch-ready.sh" --if-capped "$PR_PROJECT" || true
fi
