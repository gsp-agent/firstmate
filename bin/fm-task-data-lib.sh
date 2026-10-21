#!/usr/bin/env bash
# Task-data staging runs only after teardown removes the task record, while its
# meta lock is still held. Expiring other tasks' holds runs after teardown
# releases every lock. fm-task-data.py owns retention and recovery rules.
# Callers source fm-wake-lib.sh for the same locks spawn uses to publish records.
# The sweep drains pending holds one at a time with no expiry budget, under a
# single-instance lock and each task's own meta lock; it holds no home-wide
# lease. Teardown starts it in the background after releasing its own locks,
# and FM_TASK_DATA_SWEEP=off suppresses that start.
# Usage: bash fm-task-data-lib.sh expire DATA STATE ID
#        bash fm-task-data-lib.sh sweep DATA STATE [REQUESTING_ID]
# A named sweep request atomically replaces STATE/.task-data-sweep.rerun with that completion's id.
# An active sweep takes another pass when that slot changes.
# An explicit sweep omits REQUESTING_ID and never replaces an existing slot.
# It creates an empty slot only when none exists.
# Each pass excludes the slot's snapshotted requester and the retiring id given to that pass.
# A new slot value never replaces that retiring id.
# Each locked expiry rechecks the latest requester before touching a hold.
# That recheck protects the requester's fresh recovery.
# A later, different completion may still expire an earlier hold.

fm_task_data_cleanup() { # <data> <state> <id> <project> <pr>
  local data=$1 state=$2 id=$3 project=$4 pr=$5 helper
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-data.py"
  fm_task_id_path_safe "$id" || return 1
  [ ! -e "$state/$id.meta" ] && [ ! -L "$state/$id.meta" ] || return 1
  command -v python3 >/dev/null 2>&1 || {
    echo "warning: task data retained: python3 is unavailable" >&2
    return 1
  }
  python3 "$helper" stage "$data" "$state" "$id" "$project" "$pr"
}

fm_task_data_sweep_request() {
  local state=$1 id=$2 request
  request=$(umask 077; mktemp "$state/.task-data-sweep.rerun.XXXXXX") || return 1
  if printf '%s\n' "$id" > "$request" && mv -f -- "$request" "$state/.task-data-sweep.rerun"; then
    return 0
  fi
  rm -f -- "$request"
  return 1
}

fm_task_data_expire_others() { # <data> <state> <id>
  local data=$1 state=$2 id=$3 requester helper lib listed other expiry lock budget full start remaining limit status rc=0 i
  local pending=() marks=() too_large=()
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-data.py"
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-data-lib.sh"
  command -v python3 >/dev/null 2>&1 || return 1
  budget=${FM_TEARDOWN_DATA_EXPIRE_TIMEOUT:-10}
  case "$budget" in ''|0*|*[!0-9]*) budget=10 ;; esac
  full=${FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT:-60}
  case "$full" in ''|0*|*[!0-9]*) full=60 ;; esac
  requester=$(cat "$state/.task-data-sweep.rerun") || return 1
  listed=$(python3 "$helper" pending "$data") || return 1
  while IFS=$'\t' read -r other expiry; do
    if [ -z "$other" ] || [ "$other" = "$id" ] || [ "$other" = "$requester" ] || ! fm_task_id_path_safe "$other"; then
      continue
    elif [ "$expiry" = too-large ]; then
      too_large+=("$other")
    else
      pending+=("$other")
      marks+=("$expiry")
    fi
  done <<< "$listed"
  if [ "${#too_large[@]}" -gt 0 ]; then
    echo "warning: task data holds too large to expire automatically, skipped and kept for expiry by hand: ${too_large[*]}" >&2
  fi
  start=$SECONDS
  # A concurrent teardown holds its own lock. Skip it instead of waiting on a
  # cycle of locks; only a later, different completed task expires a recovery.
  # Each attempt touches its record first, so ordering by record age keeps one
  # slow hold from taking every teardown's budget. A hold the budget cut off
  # gets one full attempt; if that is cut off too, it is marked too large.
  for ((i = 0; i < ${#pending[@]}; i++)); do
    remaining=$((budget - (SECONDS - start)))
    if [ "$remaining" -le 0 ]; then
      echo "warning: the ${budget}s task-data expiry budget ran out; holds left for a later teardown: ${pending[*]:i}" >&2
      break
    fi
    other=${pending[i]}
    lock=$(fm_meta_lock_path "$state/$other.meta") || continue
    fm_lock_try_acquire "$lock" || continue
    if ! requester=$(cat "$state/.task-data-sweep.rerun"); then
      fm_lock_release "$lock"
      rc=1
      continue
    fi
    if [ "$other" != "$id" ] && [ "$other" != "$requester" ] && [ ! -e "$state/$other.meta" ] && [ ! -L "$state/$other.meta" ]; then
      limit=$remaining
      [ "${marks[i]}" != cut-off ] || limit=$full
      touch -h -c "$data/$other/record/data-cleanup.json" 2>/dev/null || true
      status=0
      fm_run_timed "$limit" python3 "$helper" expire "$data" "$state" "$other" || status=$?
      if fm_timed_out "$status" && [ "${marks[i]}" = cut-off ]; then
        python3 "$helper" mark "$data" "$other" too-large || true
        echo "warning: task data $other expiry stopped after its one full ${limit}s attempt; deletions it made stay done and the rest stays held; it is too large to expire automatically, so later teardowns skip it and name it; expire it by hand with bash $lib expire $data $state $other" >&2
      elif fm_timed_out "$status"; then
        python3 "$helper" mark "$data" "$other" cut-off || true
        echo "warning: task data $other expiry stopped after ${limit}s; deletions it made stay done and the rest stays held; the next teardown that reaches it gives it one full ${full}s attempt" >&2
      fi
      [ "$status" = 0 ] || rc=1
    fi
    fm_lock_release "$lock"
  done
  return "$rc"
}

# Expire one hold with no time limit under the task meta lock teardown takes;
# a held lock or a live task refuses. A run that only staged a never-staged
# hold is followed by one more under the same lock, and a hold still not
# expired at the end is an error.
fm_task_data_expire_by_hand() { # <data> <state> <id> [request]
  local data=$1 state=$2 id=$3 request=${4:-} requester lock record helper status=0 unstaged=0 again=0
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-data.py"
  record="$data/$id/record/data-cleanup.json"
  fm_task_id_path_safe "$id" || { echo "error: unsafe task id: $id" >&2; return 1; }
  lock=$(fm_meta_lock_path "$state/$id.meta") || return 1
  if ! fm_lock_try_acquire "$lock"; then
    echo "error: task $id is locked by another process; nothing was expired, retry later" >&2
    return 1
  fi
  if [ -n "$request" ]; then
    if ! requester=$(cat "$request"); then
      fm_lock_release "$lock"
      return 1
    fi
    if [ "$id" = "$requester" ]; then
      fm_lock_release "$lock"
      return 0
    fi
  fi
  if [ -e "$state/$id.meta" ] || [ -L "$state/$id.meta" ]; then
    echo "error: task $id is live; nothing was expired" >&2
    status=1
  else
    if jq -e '.complete == false' "$record" >/dev/null 2>&1; then unstaged=1; fi
    python3 "$helper" expire "$data" "$state" "$id" || status=$?
    if [ "$status" = 0 ] && [ "$unstaged" = 1 ] \
        && jq -e '.complete == true and .expired != true' "$record" >/dev/null 2>&1; then
      again=1
      python3 "$helper" expire "$data" "$state" "$id" || status=$?
    fi
    if [ -e "$record" ] && ! jq -e '.expired == true' "$record" >/dev/null 2>&1; then
      echo "error: task data $id is not expired; what remains of it stays held" >&2
      [ "$status" != 0 ] || status=1
    elif [ "$again" = 1 ] && [ "$status" = 0 ]; then
      echo "task data $id expired; nothing of it stays held"
    fi
  fi
  fm_lock_release "$lock"
  return "$status"
}

# Drain every pending hold once, least recently tried first, with no expiry
# budget, including holds marked too large. A held meta lock or a live task
# refuses inside the by-hand expiry and stays held. Requester exclusions are
# owned by this file's header.
fm_task_data_sweep() { # <data> <state> [exclude-id]
  local data=$1 state=$2 keep=${3:-} exclude helper lock rerun snapshot listed other _expiry stage_timeout=${FM_TASK_DATA_SWEEP_STAGE_TIMEOUT:-3600}
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-data.py"
  case "$stage_timeout" in ''|0*|*[!0-9]*) stage_timeout=3600 ;; esac
  command -v python3 >/dev/null 2>&1 || return 1
  lock="$state/.task-data-sweep.lock"
  rerun="$state/.task-data-sweep.rerun"
  if ! fm_lock_try_acquire "$lock"; then
    echo "task-data sweep already running; requested another pass" >&2
    return 0
  fi
  snapshot=$(umask 077; mktemp "$state/.task-data-sweep.snapshot.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  export FM_TEARDOWN_DATA_STAGE_TIMEOUT=$stage_timeout
  while :; do
    if ! ln -f -- "$rerun" "$snapshot" || ! exclude=$(cat "$snapshot") \
        || ! listed=$(python3 "$helper" pending "$data"); then
      fm_lock_release "$lock"
      rm -f -- "$snapshot"
      return 1
    fi
    while IFS=$'\t' read -r other _expiry; do
      [ -n "$other" ] || continue
      [ -n "$keep" ] && [ "$other" = "$keep" ] && continue
      [ "$other" = "$exclude" ] && continue
      fm_task_id_path_safe "$other" || continue
      fm_task_data_expire_by_hand "$data" "$state" "$other" "$rerun" || true
    done <<< "$listed"
    fm_lock_release "$lock"
    [ "$rerun" -ef "$snapshot" ] && break
    fm_lock_try_acquire "$lock" || break
  done
  rm -f -- "$snapshot"
  return 0
}

# Start one sweep in the background. The id is excluded for this sweep's
# lifetime and is not written into the slot. A second start while one runs
# reports that the sweep is already running.
fm_task_data_sweep_start() { # <data> <state> [exclude-id]
  local lib exclude=${3:-}
  if [ ! -e "$2/.task-data-sweep.rerun" ]; then
    fm_task_data_sweep_request "$2" '' || return 1
  fi
  [ "${FM_TASK_DATA_SWEEP:-on}" = off ] && return 0
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-data-lib.sh"
  (
    trap '' HUP
    # shellcheck source=bin/fm-wake-lib.sh
    . "${lib%/*}/fm-wake-lib.sh" || exit 1
    # shellcheck source=bin/fm-pr-lib.sh
    . "${lib%/*}/fm-pr-lib.sh" || exit 1
    fm_task_data_sweep "$1" "$2" "$exclude"
  ) >/dev/null 2>&1 </dev/null &
}

fm_task_data_bead_reference() { # <data> <project> <bead>
  local data=$1 project=$2 bead=$3 owner out
  case "$bead" in
    .agent-config-*) owner="$HOME/.agent-config" ;;
    gsp-*) owner="$HOME/dev/gsp-beads" ;;
    *) owner=$project ;;
  esac
  if [ -n "$owner" ] && out=$(
    unset BEADS_DIR BEADS_DB BR_DB
    cd -- "$owner" 2>/dev/null || exit 1
    fm_run_timed 10 br show "$bead" --json
  ) && printf '%s\n' "$out" | jq -e --arg id "$bead" \
      'type == "array" and length == 1 and .[0].id == $id' >/dev/null; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$bead" in .agent-config-*|gsp-*) return 1 ;; esac
  fm_backlog_row_probe "$data" "$bead" || return 1
  fm_backlog_row_show "$data" "$bead" --full
}

fm_task_data_backlog_references() { # <data> <id> <required> <project> [bead...]
  local data=$1 id=$2 required=$3 project=$4 script_dir row out text='' task='' unread='[]'
  shift 4
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$script_dir/fm-tasks-axi-lib.sh" || return 1
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$script_dir/fm-backlog-transition-lib.sh" || return 1
  fm_backlog_tasks_axi_addressing "$data" || return 1
  if [ -n "$FM_BACKLOG_AXI_FILE" ] && [ ! -e "$FM_BACKLOG_AXI_FILE" ] && [ ! -L "$FM_BACKLOG_AXI_FILE" ] \
      && [ "$required" = 0 ] && [ "$#" -eq 0 ]; then
    printf '{"task":null,"text":"","unread":[]}\n'
    return 0
  fi
  unset TASKS_AXI_FILE
  [ "$required" != 1 ] || task=$id
  if fm_backlog_row_probe "$data" "$id"; then
    task=$id
    if out=$(fm_backlog_row_show "$data" "$id" --full) && [ -n "$out" ]; then
      text="$out"$'\n'
    else
      unread=$(jq -cn --arg id "$id" '[$id]')
    fi
  elif [ "$required" != 0 ] || [ -z "$FM_BACKLOG_AXI_FILE" ] \
      || [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
    unread=$(jq -cn --arg id "$id" '[$id]')
  fi
  for row in "$@"; do
    if out=$(fm_task_data_bead_reference "$data" "$project" "$row" 2>/dev/null) && [ -n "$out" ]; then
      text="$text$out"$'\n'
    else
      unread=$(printf '%s' "$unread" | jq -c --arg id "$row" '. + [$id]')
    fi
  done
  printf '%s' "$text" | jq -Rs --arg task "$task" --argjson unread "$unread" \
    '{task: (if $task == "" then null else $task end), text: ., unread: $unread}'
}

fm_task_data_pr_references() {
  local script_dir project_url encoded login endpoint page rows review review_ids review_page comments
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  if ! declare -F fm_pr_url_parse >/dev/null 2>&1; then
    # shellcheck source=bin/fm-pr-lib.sh
    . "$script_dir/fm-pr-lib.sh" || return 1
  fi
  fm_pr_url_parse "$1" || return 1
  case "$FM_PR_PROVIDER" in
    github)
      gh-axi pr view "$FM_PR_NUMBER" --repo "$FM_PR_PATH" --hostname "$FM_PR_HOST" --full --comments --reviews
      ;;
    gitlab)
      project_url="https://$FM_PR_HOST/$FM_PR_PATH"
      GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "$project_url" -F json \
        | jq -ce --argjson number "$FM_PR_NUMBER" 'if type == "object" and .iid == $number and (.state | type) == "string" and has("description") and (.description == null or (.description | type) == "string") then . else error("unreadable merge request") end' \
        || return 1
      encoded=$(printf '%s' "$FM_PR_PATH" | jq -sRr @uri) || return 1
      glab api --hostname "$FM_PR_HOST" --paginate \
        "projects/$encoded/merge_requests/$FM_PR_NUMBER/notes?per_page=100" \
        | jq -sce 'if length > 0 and all(.[]; type == "array" and all(.[]; (.body | type) == "string")) then . else error("unreadable merge request notes") end'
      ;;
    forgejo)
      login=$(fm_pr_forgejo_login "$FM_PR_HOST") || return 1
      tea api --login "$login" --repo "$FM_PR_PATH" "/repos/{owner}/{repo}/pulls/$FM_PR_NUMBER" \
        | jq -ce --argjson number "$FM_PR_NUMBER" 'if type == "object" and .number == $number and (.state | type) == "string" and (.body | type) == "string" then . else error("unreadable pull request") end' \
        || return 1
      for endpoint in "issues/$FM_PR_NUMBER/comments" "pulls/$FM_PR_NUMBER/reviews"; do
        page=1
        while :; do
          rows=$(tea api --login "$login" --repo "$FM_PR_PATH" \
            "/repos/{owner}/{repo}/$endpoint?limit=100&page=$page") || return 1
          printf '%s\n' "$rows" | jq -ce 'if type == "array" and all(.[]; (.body | type) == "string") then . else error("unreadable pull request discussion") end' || return 1
          if [ "$endpoint" = "pulls/$FM_PR_NUMBER/reviews" ]; then
            review_ids=$(printf '%s' "$rows" | jq -r '.[] | if (.id | type) == "number" and .id > 0 and .id == (.id | floor) then .id else error("invalid review identity") end') || return 1
            for review in $review_ids; do
              review_page=1
              while :; do
                comments=$(tea api --login "$login" --repo "$FM_PR_PATH" "/repos/{owner}/{repo}/pulls/$FM_PR_NUMBER/reviews/$review/comments?limit=100&page=$review_page") || return 1
                printf '%s\n' "$comments" | jq -ce 'if type == "array" and all(.[]; (.body | type) == "string") then . else error("unreadable review comments") end' || return 1
                [ "$(printf '%s' "$comments" | jq length)" -lt 100 ] && break
                review_page=$((review_page + 1))
              done
            done
          fi
          [ "$(printf '%s' "$rows" | jq length)" -lt 100 ] && break
          page=$((page + 1))
        done
      done
      ;;
    gerrit)
      fm_pr_gerrit_read_change "$FM_PR_HOST" "$FM_PR_NUMBER"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -o pipefail
  case "${1:-}" in
    backlog-location)
      [ "$#" -eq 2 ] || exit 1
      # shellcheck source=bin/fm-tasks-axi-lib.sh
      . "$(dirname "${BASH_SOURCE[0]}")/fm-tasks-axi-lib.sh" || exit 1
      # shellcheck source=bin/fm-backlog-transition-lib.sh
      . "$(dirname "${BASH_SOURCE[0]}")/fm-backlog-transition-lib.sh" || exit 1
      fm_backlog_tasks_axi_addressing "$2" || exit 1
      jq -cn --arg root "$FM_BACKLOG_AXI_ROOT" --arg file "$FM_BACKLOG_AXI_FILE" '{root: $root, file: $file}'
      ;;
    references)
      [ "$#" -eq 2 ] || exit 1
      fm_task_data_pr_references "$2"
      ;;
    backlog-references)
      [ "$#" -ge 5 ] || exit 1
      shift
      fm_task_data_backlog_references "$@"
      ;;
    expire)
      [ "$#" -eq 4 ] || exit 1
      # shellcheck source=bin/fm-wake-lib.sh
      . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh" || exit 1
      # shellcheck source=bin/fm-pr-lib.sh
      . "$(dirname "${BASH_SOURCE[0]}")/fm-pr-lib.sh" || exit 1
      fm_task_data_expire_by_hand "$2" "$3" "$4"
      ;;
    sweep)
      [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || exit 1
      # shellcheck source=bin/fm-wake-lib.sh
      . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh" || exit 1
      # shellcheck source=bin/fm-pr-lib.sh
      . "$(dirname "${BASH_SOURCE[0]}")/fm-pr-lib.sh" || exit 1
      if [ -n "${4:-}" ]; then
        fm_task_data_sweep_request "$3" "$4" || exit 1
      elif [ ! -e "$3/.task-data-sweep.rerun" ]; then
        fm_task_data_sweep_request "$3" '' || exit 1
      fi
      fm_task_data_sweep "$2" "$3"
      ;;
    *) exit 1 ;;
  esac
fi
