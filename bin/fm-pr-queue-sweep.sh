#!/usr/bin/env bash
# Sweep open pull requests in watched GitHub repositories.
# A repository is watched when a private pr-poll sidecar names it (including
# one retained during retirement), or when FM_PR_SWEEP_REPOS names it from a
# snapshot taken before a terminal watch was retired.
# One pass reads all open pull requests in pages of 100, newest creation first.
# Each GitHub page is bounded by FM_PR_SWEEP_PAGE_TIMEOUT seconds (default 30).
# A failed or timed-out page fails the scan. Repositories whose pages completed
# may still print their removals.
# A completed repository prints `queue-empty <owner>/<repo>` only when no page
# saw an open pull request in the merge queue.
# A queued sighting prints no such line. The watcher then keeps that
# repository's sidecar and snapshot until a later successful scan sees none.
# The scan does not re-read an earlier page.
# Once the last watch has merged or closed, a pull request first queued after
# its page was read is outside the watched-repository guarantee, like one queued
# after retirement.
# tests/fm-pr-check-security.test.sh covers a queued sighting across two pages
# retaining discovery until the next scan reports the removal once.
# bin/fm-watch.sh owns publication and applies that line to retirement.
# There is no deadline around the complete scan.
# When FM_PR_SWEEP_BEAT names the watcher's liveness beacon, each completed
# page and repository attempt refreshes it so a progressing scan stays alive.
# It reports a pull request when its newest queue event is a removal, the pull
# request is open and not merged, and it is not back in the queue.
# A removal re-added before this pass is no longer the newest queue event, so a
# refresh that returns inside the watcher check interval does not wake.
# Each removal event is printed once, as
# `dequeued <url> reason=<escaped-text> event=<id>`.
# The reason is GitHub's text with JSON string escaping and no surrounding quotes.
# A removal whose reason is merged stays silent, and an unreadable event stays silent.
# An unreadable, malformed, or unsafe seen record fails the scan before querying
# GitHub; --contains returns 2 for validation or read errors.
# The watcher records an event id only after that wake is durable.
# This file owns the seen record: a mode-600 file state/merge-queue-sweep.seen
# whose first line is fm-merge-queue-sweep-v1 and whose later lines are event ids.
# Usage: fm-pr-queue-sweep.sh --scan <state>
#        fm-pr-queue-sweep.sh --repos <state>
#        fm-pr-queue-sweep.sh --contains <state> <event>
#        fm-pr-queue-sweep.sh --record <state> <event>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

SWEEP_SEEN_VERSION=fm-merge-queue-sweep-v1
# shellcheck disable=SC2016
SWEEP_QUERY='query($owner:String!,$repo:String!,$cursor:String){repository(owner:$owner,name:$repo){pullRequests(states:[OPEN],first:100,after:$cursor,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor}nodes{number state merged isInMergeQueue timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT,ADDED_TO_MERGE_QUEUE_EVENT]){nodes{__typename ... on RemovedFromMergeQueueEvent{id reason} ... on AddedToMergeQueueEvent{id}}}}}}}'
# shellcheck disable=SC2016
SWEEP_JQ='(.data.repository.pullRequests) as $p | if $p == null or ($p.pageInfo | type) != "object" then error("no page") else (($p.nodes // [])[] | . as $pr | (($pr.timelineItems.nodes // []) | last // {}) as $e | (["pr", ($pr.number | tostring), ($pr.state // ""), ($pr.merged | tostring), ($pr.isInMergeQueue | tostring), (if $e.__typename == "RemovedFromMergeQueueEvent" then "removed" elif $e.__typename == "AddedToMergeQueueEvent" then "added" else "" end), (if (($e.id // "") | test("^[A-Za-z0-9_+/=-]{0,256}$")) then ($e.id // "") else "" end)] | @tsv) + "\t" + (($e.reason // "") | tojson | .[1:-1])), (["page", (if $p.pageInfo.hasNextPage == true then "true" else "false" end), ($p.pageInfo.endCursor // "")] | @tsv) end'

sweep_event_id_ok() {
  local event=$1
  [ -n "$event" ] || return 1
  [ "${#event}" -le 256 ] || return 1
  case "$event" in
    *[!A-Za-z0-9_+/=-]*) return 1 ;;
  esac
}

sweep_state_ok() {
  [ -n "${1:-}" ] && [ -d "$1" ] && [ ! -L "$1" ]
}

sweep_seen_path() {
  printf '%s\n' "$1/merge-queue-sweep.seen"
}

# Load a private seen record into sweep_seen, wrapped in newlines.
# A missing file is not this function's job. An unsafe or malformed file returns 2.
sweep_seen_load() {
  local path=$1 state=$2 device version event
  sweep_seen=$'\n'
  device=$(fm_pr_file_device "$state") || return 2
  fm_pr_private_file_valid "$path" 600 "$device" || return 2
  exec 7< "$path" || return 2
  if ! IFS= read -r version <&7; then
    exec 7<&-
    return 2
  fi
  [ "$version" = "$SWEEP_SEEN_VERSION" ] || { exec 7<&-; return 2; }
  while IFS= read -r event <&7 || [ -n "$event" ]; do
    sweep_event_id_ok "$event" || { exec 7<&-; return 2; }
    case "$sweep_seen" in
      *$'\n'"$event"$'\n'*) ;;
      *) sweep_seen="${sweep_seen}${event}"$'\n' ;;
    esac
  done
  exec 7<&-
}

sweep_note_event() {
  local event=$1
  sweep_event_id_ok "$event" || return 0
  case "$sweep_seen" in
    *$'\n'"$event"$'\n'*) ;;
    *) sweep_seen="${sweep_seen}${event}"$'\n' ;;
  esac
}

# Armed-poll markers already published their event. Reading them keeps a sweep
# from waking that same event again. An unsafe marker is ignored.
sweep_note_markers() {
  local state=$1 marker version url event extra device
  device=$(fm_pr_file_device "$state") || return 0
  for marker in "$state"/*.pr-poll-queue-dropped; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    fm_pr_private_file_valid "$marker" 600 "$device" || continue
    exec 7< "$marker" || continue
    if ! IFS= read -r version <&7 || ! IFS= read -r url <&7 || ! IFS= read -r event <&7; then
      exec 7<&-
      continue
    fi
    if IFS= read -r extra <&7; then
      exec 7<&-
      continue
    fi
    exec 7<&-
    [ "$version" = fm-pr-poll-queue-dropped-v1 ] || continue
    [ -n "$url" ] || continue
    sweep_note_event "$event"
  done
}

sweep_contains() {
  local state=$1 event=$2 path
  sweep_event_id_ok "$event" || return 2
  sweep_state_ok "$state" || return 2
  path=$(sweep_seen_path "$state")
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 1
  fi
  sweep_seen_load "$path" "$state" || return 2
  case "$sweep_seen" in
    *$'\n'"$event"$'\n'*) return 0 ;;
  esac
  return 1
}

sweep_record() {
  local state=$1 event=$2 path device tmp ids
  sweep_event_id_ok "$event" || return 1
  sweep_state_ok "$state" || return 1
  path=$(sweep_seen_path "$state")
  if [ -e "$path" ] || [ -L "$path" ]; then
    sweep_seen_load "$path" "$state" || return 1
    case "$sweep_seen" in
      *$'\n'"$event"$'\n'*) return 0 ;;
    esac
  else
    sweep_seen=$'\n'
  fi
  device=$(fm_pr_file_device "$state") || return 1
  fm_pr_regular_destination_on_device_or_absent "$path" "$device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-merge-queue-sweep.XXXXXX") || return 1
  ids=${sweep_seen#$'\n'}
  if ! {
    printf '%s\n' "$SWEEP_SEEN_VERSION"
    [ -z "$ids" ] || printf '%s' "$ids"
    printf '%s\n' "$event"
  } > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$path" "$device" \
    || ! mv -f -- "$tmp" "$path" \
    || ! fm_pr_private_file_valid "$path" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
}

sweep_owner_repo_ok() {
  local owner=$1 repo=$2
  [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || return 1
  case "$owner" in
    *[!A-Za-z0-9-]*|-*|*-|*--*) return 1 ;;
  esac
  [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || return 1
  case "$repo" in
    .|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "$repo" = "${repo%%/*}" ]
}

sweep_note_repo() {
  local owner=$1 repo=$2 key
  sweep_owner_repo_ok "$owner" "$repo" || return 0
  key="${owner}/${repo}"
  case "$sweep_repos" in
    *$'\n'"$key"$'\n'*) ;;
    *) sweep_repos="${sweep_repos}${key}"$'\n' ;;
  esac
}

# FM_PR_SWEEP_REPOS is a newline-separated owner/repo list. Invalid lines are
# ignored. The caller initializes sweep_repos.
sweep_note_env_repos() {
  local line owner repo
  [ -n "${FM_PR_SWEEP_REPOS:-}" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      */*) ;;
      *) continue ;;
    esac
    owner=${line%%/*}
    repo=${line#*/}
    case "$repo" in
      */*) continue ;;
    esac
    sweep_note_repo "$owner" "$repo"
  done <<EOF
$FM_PR_SWEEP_REPOS
EOF
}

# Bound one GitHub page read. A page that does not answer is a failed read.
# timeout, then gtimeout, then the same alarm the watcher uses when neither exists.
sweep_page_gh() {
  local seconds=${FM_PR_SWEEP_PAGE_TIMEOUT:-30}
  case "$seconds" in
    ''|*[!0-9]*|0) seconds=30 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" gh "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" gh "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" 0 gh "$@"
  fi
}

sweep_note_sidecars() {
  local state=$1 sidecar provider url host path number extra owner repo
  for sidecar in "$state"/*.pr-poll; do
    [ -e "$sidecar" ] || [ -L "$sidecar" ] || continue
    [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || continue
    exec 7< "$sidecar" || continue
    if ! IFS= read -r provider <&7 || ! IFS= read -r url <&7 || ! IFS= read -r host <&7 \
      || ! IFS= read -r path <&7 || ! IFS= read -r number <&7; then
      exec 7<&-
      continue
    fi
    if IFS= read -r extra <&7; then
      exec 7<&-
      continue
    fi
    exec 7<&-
    [ "$provider" = github ] || continue
    [ "$host" = github.com ] || continue
    owner=${path%%/*}
    repo=${path#*/}
    [ "$path" = "$owner/$repo" ] || continue
    sweep_owner_repo_ok "$owner" "$repo" || continue
    case "$number" in
      ''|*[!0-9]*|0*) continue ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || continue
    sweep_note_repo "$owner" "$repo"
  done
}

# Buffer until pagination completes so a failed later page cannot publish a
# partial repository result; the header owns failed-read behavior.
sweep_one_repo() {
  local owner=$1 repo=$2 cursor='' fields line kind rest number state merged
  local queued event_kind event reason more page_cursor saw_page saw_queued collected url
  collected=
  saw_queued=0
  while :; do
    if [ -z "$cursor" ]; then
      fields=$(sweep_page_gh api graphql --hostname github.com \
        -f query="$SWEEP_QUERY" \
        -f owner="$owner" -f repo="$repo" -F cursor=null \
        --jq "$SWEEP_JQ" 2>/dev/null) || return 1
    else
      fields=$(sweep_page_gh api graphql --hostname github.com \
        -f query="$SWEEP_QUERY" \
        -f owner="$owner" -f repo="$repo" -f cursor="$cursor" \
        --jq "$SWEEP_JQ" 2>/dev/null) || return 1
    fi
    [ -n "$fields" ] || return 1
    saw_page=0
    more=false
    page_cursor=
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      kind=${line%%$'\t'*}
      case "$line" in
        *$'\t'*) rest=${line#*$'\t'} ;;
        *) rest= ;;
      esac
      case "$kind" in
        page)
          more=${rest%%$'\t'*}
          case "$rest" in
            *$'\t'*) page_cursor=${rest#*$'\t'} ;;
            *) page_cursor= ;;
          esac
          saw_page=1
          ;;
        pr)
          number=${rest%%$'\t'*}
          rest=${rest#*$'\t'}
          state=${rest%%$'\t'*}
          rest=${rest#*$'\t'}
          merged=${rest%%$'\t'*}
          rest=${rest#*$'\t'}
          queued=${rest%%$'\t'*}
          rest=${rest#*$'\t'}
          event_kind=${rest%%$'\t'*}
          rest=${rest#*$'\t'}
          event=${rest%%$'\t'*}
          case "$rest" in
            *$'\t'*) reason=${rest#*$'\t'} ;;
            *) reason= ;;
          esac
          case "$number" in
            ''|*[!0-9]*|0*) continue ;;
          esac
          [ "$queued" = true ] && saw_queued=1
          [ "$state" = OPEN ] || continue
          [ "$merged" = false ] || continue
          [ "$queued" = false ] || continue
          [ "$event_kind" = removed ] || continue
          [ "$reason" != merged ] || continue
          sweep_event_id_ok "$event" || continue
          case "$sweep_seen" in
            *$'\n'"$event"$'\n'*) continue ;;
          esac
          url="https://github.com/$owner/$repo/pull/$number"
          collected="${collected}dequeued ${url} reason=${reason} event=${event}"$'\n'
          sweep_note_event "$event"
          ;;
      esac
    done <<EOF
$fields
EOF
    [ "$saw_page" -eq 1 ] || return 1
    case "$more" in
      true|false) ;;
      *) return 1 ;;
    esac
    [ -z "${FM_PR_SWEEP_BEAT:-}" ] || touch "$FM_PR_SWEEP_BEAT"
    if [ "$more" = false ]; then
      if [ "$saw_queued" -eq 0 ]; then
        collected="${collected}queue-empty ${owner}/${repo}"$'\n'
      fi
      printf '%s' "$collected"
      return 0
    fi
    case "$page_cursor" in
      ''|*[!A-Za-z0-9_+/=-]*) return 1 ;;
    esac
    [ "${#page_cursor}" -le 512 ] || return 1
    [ "$page_cursor" != "$cursor" ] || return 1
    cursor=$page_cursor
  done
}

sweep_scan() {
  local state=$1 path key owner repo repo_out failed=0
  sweep_state_ok "$state" || return 1
  path=$(sweep_seen_path "$state")
  if [ -e "$path" ] || [ -L "$path" ]; then
    sweep_seen_load "$path" "$state" || return 1
  else
    sweep_seen=$'\n'
  fi
  sweep_note_markers "$state"
  sweep_repos=$'\n'
  sweep_note_env_repos
  sweep_note_sidecars "$state"
  while IFS= read -r key || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    owner=${key%%/*}
    repo=${key#*/}
    repo_out=$(sweep_one_repo "$owner" "$repo") || { repo_out=; failed=1; }
    [ -z "${FM_PR_SWEEP_BEAT:-}" ] || touch "$FM_PR_SWEEP_BEAT"
    [ -z "$repo_out" ] || printf '%s\n' "$repo_out"
  done <<EOF
$sweep_repos
EOF
  [ "$failed" -eq 0 ]
}

case "${1:-}" in
  --scan)
    [ "$#" -eq 2 ] || exit 1
    sweep_scan "$2"
    exit $?
    ;;
  --repos)
    [ "$#" -eq 2 ] || exit 0
    sweep_state_ok "$2" || exit 0
    sweep_repos=$'\n'
    sweep_note_sidecars "$2"
    printf '%s' "${sweep_repos#$'\n'}"
    exit 0
    ;;
  --contains)
    [ "$#" -eq 3 ] || exit 2
    sweep_contains "$2" "$3"
    exit $?
    ;;
  --record)
    [ "$#" -eq 3 ] || exit 1
    sweep_record "$2" "$3"
    exit $?
    ;;
esac
exit 0
