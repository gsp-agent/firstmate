#!/usr/bin/env bash
# Task-data staging runs at the shared retirement boundary, while the task's
# protection and meta lock are still held. Expiring other tasks' holds runs after teardown
# releases every lock. fm-task-data.py owns retention and recovery rules.
# Callers source fm-wake-lib.sh for the same locks spawn uses to publish records.
# The sweep drains pending holds one at a time with no expiry budget, under a
# single-instance lock and each task's own meta lock; it holds no home-wide
# lease. Teardown starts it in the background after releasing its own locks,
# and FM_TASK_DATA_SWEEP=off suppresses that start.
# Usage: bash fm-task-data-lib.sh expire DATA STATE ID
#        bash fm-task-data-lib.sh sweep DATA STATE [REQUESTING_ID]
#        bash fm-task-data-lib.sh offload-plan DATA STATE [ID]
#        bash fm-task-data-lib.sh offload DATA STATE ID
# Each sweep ends with one offload pass over every eligible task, which does
# nothing in a home with no config/task-data-offload.json; offload also runs
# by hand for one task. fm-task-data.py --help owns eligibility and the
# backup-verifier and pointer contract.
# A named sweep request atomically replaces STATE/.task-data-sweep.rerun with that completion's id.
# An active sweep takes another pass when that slot changes.
# An explicit sweep omits REQUESTING_ID and never replaces an existing slot.
# It creates an empty slot only when none exists.
# Each pass excludes the slot's snapshotted requester.
# Each locked expiry rechecks the latest requester before touching a hold.
# That recheck protects the requester's fresh recovery.
# A later, different completion may still expire an earlier hold.
# The automatic launcher uses a fresh shell and process group so its drain
# survives the caller's group cleanup. A sweep releases its own lock and
# snapshot on exit; a killed owner's lock is reclaimed by the shared lock code.

fm_task_data_sweep_request() {
  local state=$1 id=$2 request
  request=$(umask 077; mktemp "$state/.task-data-sweep.rerun.XXXXXX") || return 1
  if printf '%s\n' "$id" > "$request"; then
    if [ -n "$id" ]; then
      mv -f -- "$request" "$state/.task-data-sweep.rerun" && return 0
    elif ln -- "$request" "$state/.task-data-sweep.rerun" 2>/dev/null || [ -e "$state/.task-data-sweep.rerun" ]; then
      rm -f -- "${request:?}"
      return 0
    fi
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
    echo "warning: task data holds exceed the foreground expiry budget, deferred to the background sweep when enabled: ${too_large[*]}" >&2
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
    if [ "$other" != "$id" ] && [ "$other" != "$requester" ] \
        && [ ! -e "$state/$other.meta" ] && [ ! -L "$state/$other.meta" ] \
        && [ ! -e "$state/$other.backlog-close" ] && [ ! -L "$state/$other.backlog-close" ]; then
      limit=$remaining
      [ "${marks[i]}" != cut-off ] || limit=$full
      touch -h -c "$data/$other/record/data-cleanup.json" 2>/dev/null || true
      status=0
      fm_run_timed "$limit" python3 "$helper" expire "$data" "$state" "$other" || status=$?
      if fm_timed_out "$status" && [ "${marks[i]}" = cut-off ]; then
        python3 "$helper" mark "$data" "$other" too-large || true
        echo "warning: task data $other expiry stopped after its one full ${limit}s attempt; deletions it made stay done and the rest stays held; later foreground passes skip it while the background sweep retries when enabled; alternatively expire it by hand with bash $lib expire $data $state $other" >&2
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
  if [ -e "$state/$id.meta" ] || [ -L "$state/$id.meta" ] \
      || [ -e "$state/$id.backlog-close" ] || [ -L "$state/$id.backlog-close" ]; then
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
fm_task_data_sweep() ( # <data> <state>; traps belong only to this sweep
  local data=$1 state=$2 exclude helper lock rerun snapshot listed other _expiry stage_timeout=${FM_TASK_DATA_SWEEP_STAGE_TIMEOUT:-3600}
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
  trap 'rm -f -- "${snapshot:?}"; fm_lock_release "$lock"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
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
      [ "$other" = "$exclude" ] && continue
      fm_task_id_path_safe "$other" || continue
      fm_task_data_expire_by_hand "$data" "$state" "$other" "$rerun" || true
    done <<< "$listed"
    fm_lock_release "$lock"
    [ "$rerun" -ef "$snapshot" ] && break
    fm_lock_try_acquire "$lock" || break
  done
  rm -f -- "$snapshot"
  fm_task_data_offload_pass "$data" "$state" || true
  return 0
)

# Offload one task under the spawn meta lock; a held lock refuses. The lock is
# released however the offload ends, including INT, TERM or HUP.
fm_task_data_offload_task() ( # <data> <state> <id>; traps belong only to this offload
  local lock
  fm_task_id_path_safe "$3" || return 1
  lock=$(fm_meta_lock_path "$2/$3.meta") || return 1
  fm_lock_try_acquire "$lock" || { echo "error: task is locked; nothing was offloaded" >&2; return 1; }
  trap 'fm_lock_release "$lock"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  python3 "$(dirname "${BASH_SOURCE[0]}")/fm-task-data.py" offload "$1" "$2" "$3"
)

# Offload every task offload-plan names, once each, in a home whose
# config/task-data-offload.json names a backup verifier; one pass at a time.
# A refusal keeps that task's originals for the next pass.
fm_task_data_offload_pass() { # <data> <state>
  local data=$1 state=$2 lock plan task rc=0
  [ -e "$(dirname "$data")/config/task-data-offload.json" ] || return 0
  lock="$state/.task-data-offload.lock"
  fm_lock_try_acquire "$lock" || return 0
  if ! plan=$(python3 "$(dirname "${BASH_SOURCE[0]}")/fm-task-data.py" offload-plan "$data" "$state"); then
    fm_lock_release "$lock"
    return 1
  fi
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    fm_task_data_offload_task "$data" "$state" "$task" || rc=1
  done < <(printf '%s\n' "$plan" | jq -r '[.moves[].task] | unique | .[]')
  fm_lock_release "$lock"
  return "$rc"
}

# Start one sweep in the background.
fm_task_data_sweep_start() { # <data> <state>
  local lib monitor_was_on=0
  if [ ! -e "$2/.task-data-sweep.rerun" ]; then
    fm_task_data_sweep_request "$2" '' || return 1
  fi
  [ "${FM_TASK_DATA_SWEEP:-on}" = off ] && return 0
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-data-lib.sh"
  # Teardown's caller can reap its process group after the command returns.
  # HUP immunity alone does not survive that TERM. Job control gives this
  # fresh shell its own group, without inheriting teardown's EXIT traps.
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  nohup bash "$lib" sweep "$1" "$2" >/dev/null 2>&1 </dev/null &
  [ "$monitor_was_on" -eq 1 ] || set +m
}

# The bead-prefix map: each home, under HOME, whose .beads/beads.db owns
# the prefix after it. The longest matching prefix wins.
fm_task_data_bead_locations() {
  cat <<'MAP'
.agent-config-beads .agent-config
dev/be-still bd
dev/carman-compound carmanco
dev/pfizer-clickless clickless
dev/dale dale
dev/gj-tool gj
dev/gj-gitlab-config gj-gitlab-config
dev/gj-magic-mirror gjmm
dev/groove-jones-ops gjops
dev/gsp-beads gsp
dev/heru-vr-vision-sim heru
dev/agent-observer obs
MAP
}

fm_task_data_bead_database() { # <bead>
  local bead=$1 prefix home best='' owner=''
  while read -r home prefix; do
    case "$bead" in
      "$prefix"-*) [ "${#prefix}" -le "${#best}" ] || { best=$prefix; owner=$home; } ;;
    esac
  done < <(fm_task_data_bead_locations)
  [ -n "$owner" ] && printf '%s\n' "$HOME/$owner/.beads/beads.db"
}

fm_task_data_bead_id_matches() { # <asked-id> <canonical-id> <database>
  local bead=$1 canonical=$2 db=$3
  [ "$canonical" != "$bead" ] || return 0
  # br expands unique short IDs while preserving prefix, suffix and owner; any
  # other answer is not this bead, even though br returned success.
  case "$canonical" in "${bead%-*}"-*-"${bead##*-}") ;; *) return 1 ;; esac
  [ "$(fm_task_data_bead_database "$canonical")" = "$db" ]
}

# A named bead has one owner: the database its prefix maps to, else this
# home's backlog for an id a task can carry. Prints the bead and returns 0,
# returns 3 when the owner answered that it does not exist or nothing can own
# it, returns 4 when a markdown backlog lacks the row so its archive decides,
# and fails when the owner cannot be read or the read times out.
# br runs from / so no database above the working directory can answer.
fm_task_data_bead_reference() { # <data> <bead>
  local data=$1 bead=$2 db out canonical status=0
  if db=$(fm_task_data_bead_database "$bead"); then
    out=$(
      unset BEADS_DIR BEADS_DB BR_DB
      cd / && fm_run_timed 10 br --db "$db" show "$bead" --json
    ) || status=$?
    if [ "$status" = 3 ] && printf '%s\n' "$out" | jq -e '.error.code == "ISSUE_NOT_FOUND"' >/dev/null; then
      return 3
    fi
    [ "$status" = 0 ] && canonical=$(printf '%s\n' "$out" | jq -er \
      'if type == "array" and length == 1 and (.[0].id | type) == "string" then .[0].id else error("ambiguous bead") end') || return 1
    fm_task_data_bead_id_matches "$bead" "$canonical" "$db" || return 1
    printf '%s\n' "$out"
    return 0
  fi
  fm_task_id_path_safe "$bead" || return 3
  if fm_backlog_row_probe "$data" "$bead"; then
    fm_backlog_row_show "$data" "$bead" --full || return 1
    return 0
  fi
  [ "$FM_BACKLOG_ROW_RESULT" = not_found ] || return 1
  [ -z "$FM_BACKLOG_AXI_FILE" ] || return 4
  return 3
}

fm_task_data_backlog_references() { # <data> <id> <required> [bead...]
  local data=$1 id=$2 required=$3 script_dir row out status text='' task='' unread='[]' archived='[]'
  shift 3
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$script_dir/fm-tasks-axi-lib.sh" || return 1
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$script_dir/fm-backlog-transition-lib.sh" || return 1
  fm_backlog_tasks_axi_addressing "$data" || return 1
  if [ -n "$FM_BACKLOG_AXI_FILE" ] && [ ! -e "$FM_BACKLOG_AXI_FILE" ] && [ ! -L "$FM_BACKLOG_AXI_FILE" ] \
      && [ "$required" = 0 ] && [ "$#" -eq 0 ]; then
    printf '{"task":null,"text":"","unread":[],"archived":[]}\n'
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
    status=0
    out=$(fm_task_data_bead_reference "$data" "$row" 2>/dev/null) || status=$?
    if [ "$status" = 0 ] && [ -n "$out" ]; then
      text="$text$out"$'\n'
    elif [ "$status" = 4 ]; then
      archived=$(printf '%s' "$archived" | jq -c --arg id "$row" '. + [$id]')
    elif [ "$status" != 3 ]; then
      unread=$(printf '%s' "$unread" | jq -c --arg id "$row" '. + [$id]')
    fi
  done
  printf '%s' "$text" | jq -Rs --arg task "$task" --argjson unread "$unread" --argjson archived "$archived" \
    '{task: (if $task == "" then null else $task end), text: ., unread: $unread, archived: $archived}'
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
    bead-locations)
      fm_task_data_bead_locations
      ;;
    offload-plan)
      [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || exit 1
      exec python3 "$(dirname "${BASH_SOURCE[0]}")/fm-task-data.py" "$@"
      ;;
    offload)
      [ "$#" -eq 4 ] || exit 1
      export FM_STATE_OVERRIDE=$3
      # shellcheck source=/dev/null
      . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh" || exit 1
      # shellcheck source=/dev/null
      . "$(dirname "${BASH_SOURCE[0]}")/fm-pr-lib.sh" || exit 1
      fm_task_data_offload_task "$2" "$3" "$4"
      ;;
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
      [ "$#" -ge 4 ] || exit 1
      shift
      fm_task_data_backlog_references "$@"
      ;;
    expire)
      [ "$#" -eq 4 ] || exit 1
      export FM_STATE_OVERRIDE=$3
      # shellcheck source=/dev/null
      . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh" || exit 1
      # shellcheck source=/dev/null
      . "$(dirname "${BASH_SOURCE[0]}")/fm-pr-lib.sh" || exit 1
      fm_task_data_expire_by_hand "$2" "$3" "$4"
      ;;
    sweep)
      [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || exit 1
      export FM_STATE_OVERRIDE=$3
      # shellcheck source=/dev/null
      . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh" || exit 1
      # shellcheck source=/dev/null
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
