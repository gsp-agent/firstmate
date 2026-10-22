#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, or Gerrit
# change poll sidecar.
# It emits exactly one merged line for a merged change.
# A closed unmerged GitHub pull request emits exactly one closed line.
# An open GitHub pull request outside the merge queue emits
# a `dequeued <url> reason=<escaped-text> event=<id>` line for its latest
# unreported removal. The reason is GitHub's text with JSON string escaping
# and no surrounding quotes. Every other reading, including every error,
# stays silent, so a failed lookup can never be read as a merge. The
# provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, gerrit-axi for Gerrit, and tea for Forgejo, so an upstream checkout
# needs no extra tooling to follow GitHub or GitLab. The Gerrit and Forgejo
# branches additionally need jq, which bin/fm-pr-check.sh refuses to arm those
# watches without.
# The watcher asks this file to read every authenticated GitHub poll in one
# sweep as one GraphQL query with one aliased pullRequest field per pull
# request. Each poll reports from that result. A failed sweep stays silent for
# the polls it covered. A poll the sweep did not cover reads itself.
set -u
LC_ALL=C
export LC_ALL

# A check.sh copy is that task. The watcher runs this file with --validated
# and passes the task it already authenticated, which wins over a stray value
# only when this file is not itself the check.
poll_bind_identity() {
  poll_id=
  poll_state=
  case "$0" in
    *.check.sh)
      poll_state=$(dirname -- "$0")
      poll_id=$(basename -- "$0" .check.sh)
      ;;
    *)
      poll_id=${FM_PR_POLL_ID-}
      poll_state=${FM_PR_POLL_STATE-}
      ;;
  esac
}

poll_id_usable() {
  local LC_ALL=C
  [ -n "${poll_id:-}" ] || return 1
  [ -n "${poll_state:-}" ] || return 1
  case "$poll_id" in
    .*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ -d "$poll_state" ] && [ ! -L "$poll_state" ]
}

poll_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

poll_device() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

poll_links() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

poll_private() {
  local path=$1 mode links device state_device
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode=$(poll_mode "$path") || return 1
  [ "$mode" = 600 ] || return 1
  links=$(poll_links "$path") || return 1
  [ "$links" = 1 ] || return 1
  device=$(poll_device "$path") || return 1
  state_device=$(poll_device "$poll_state") || return 1
  [ "$device" = "$state_device" ]
}

# Departure markers contain a version, URL, and removal event ID.
# Format owner for the marker is this
# script.
poll_marker_matches() {
  local path=$1 expect_url=$2 expect_event=$3 got_version got_url got_event _extra
  poll_private "$path" || return 1
  exec 8< "$path" || return 1
  if ! IFS= read -r got_version <&8 || ! IFS= read -r got_url <&8 \
    || ! IFS= read -r got_event <&8; then
    exec 8<&-
    return 1
  fi
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$got_version" = fm-pr-poll-queue-dropped-v1 ] && [ "$got_url" = "$expect_url" ] \
    && [ "$got_event" = "$expect_event" ]
}

poll_emit_dequeue() {
  local dropped
  poll_id_usable || return 0
  [ -n "$GH_POLL_EVENT" ] || return 0
  dropped="$poll_state/$poll_id.pr-poll-queue-dropped"
  if [ -e "$dropped" ] || [ -L "$dropped" ]; then
    if poll_marker_matches "$dropped" "$url" "$GH_POLL_EVENT"; then
      return 0
    fi
    # A private marker for another departure can be replaced. Anything else
    # stays silent, so a bad file cannot wake on every poll.
    poll_private "$dropped" || return 0
  fi
  printf 'dequeued %s reason=%s event=%s\n' "$url" "$GH_POLL_REASON" "$GH_POLL_EVENT"
}

github_identity_ok() {
  [ "$host" = github.com ] || return 1
  owner=${path%%/*}
  repo=${path#*/}
  [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || return 1
  case "$owner" in
    *[!A-Za-z0-9-]*|-*|*-|*--*) return 1 ;;
  esac
  [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || return 1
  case "$repo" in
    .|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "$url" = "https://github.com/$owner/$repo/pull/$number" ]
}

poll_accept_reading() {
  local state=$1 merged=$2 queued=$3 reason=$4 event=$5
  [ -n "$state" ] || return 1
  { [ "$merged" = true ] || [ "$merged" = false ]; } || return 1
  { [ "$queued" = true ] || [ "$queued" = false ]; } || return 1
  if [ "$merged" = true ] && [ "$state" != MERGED ]; then
    return 1
  fi
  if [ "$merged" = true ] && [ "$queued" = true ]; then
    return 1
  fi
  if [ "$state" = MERGED ] && [ "$merged" != true ]; then
    return 1
  fi
  case "$event" in
    *[!A-Za-z0-9_+/=-]*) return 1 ;;
  esac
  [ "${#event}" -le 256 ] || return 1
  GH_POLL_MERGED=$merged
  GH_POLL_QUEUED=$queued
  GH_POLL_REASON=$reason
  GH_POLL_EVENT=$event
  GH_POLL_STATE=$state
}

poll_cache_write_missing() {
  printf 'key=%s/%s#%s\nmissing=1\n.\n' "$1" "$2" "$3" >> "$FM_PR_POLL_BATCH_CACHE"
}

poll_cache_write_reading() {
  printf 'key=%s/%s#%s\nstate=%s\nmerged=%s\nqueued=%s\nreason=%s\nevent=%s\n.\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$FM_PR_POLL_BATCH_CACHE"
}

# 0: this sweep recorded an accepted reading. 1: this sweep covered the poll
# and the reading is missing or unusable, so the poll stays silent. 2: this
# sweep did not cover the poll, so the caller reads it itself.
poll_batch_lookup() {
  local cache=${FM_PR_POLL_BATCH_CACHE-}
  local key line phase=seek missing=0
  local state='' merged='' queued='' reason='' event=''
  [ -n "$cache" ] || return 2
  [ -f "$cache" ] && [ ! -L "$cache" ] || return 2
  key="key=$owner/$repo#$number"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$phase" in
      seek)
        [ "$line" = "$key" ] || continue
        phase='read'
        missing=0
        state=''
        merged=''
        queued=''
        reason=''
        event=''
        ;;
      read)
        case "$line" in
          .)
            if [ "$missing" -eq 1 ]; then
              return 1
            fi
            poll_accept_reading "$state" "$merged" "$queued" "$reason" "$event" && return 0
            return 1
            ;;
          missing=1) missing=1 ;;
          state=*) state=${line#state=} ;;
          merged=*) merged=${line#merged=} ;;
          queued=*) queued=${line#queued=} ;;
          reason=*) reason=${line#reason=} ;;
          event=*) event=${line#event=} ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done < "$cache"
  if [ "$phase" = read ]; then
    return 1
  fi
  return 2
}

poll_batch_commit_one() {
  local owner=$1 repo=$2 number=$3 missing=$4 bad=$5
  local state=$6 merged=$7 queued=$8 reason=$9 event=${10}
  if [ "$missing" -eq 1 ] || [ "$bad" -eq 1 ] \
    || ! poll_accept_reading "$state" "$merged" "$queued" "$reason" "$event"; then
    poll_cache_write_missing "$owner" "$repo" "$number"
  else
    poll_cache_write_reading "$owner" "$repo" "$number" \
      "$GH_POLL_STATE" "$GH_POLL_MERGED" "$GH_POLL_QUEUED" "$GH_POLL_REASON" "$GH_POLL_EVENT"
  fi
}

poll_batch_prefetch() {
  local state=$1
  local cache=${FM_PR_POLL_BATCH_CACHE-}
  local poll_root check id n i query vars='' body='' fields line batch_out batch_jq
  local cur=-1 missing=0 bad=0 alias_index
  local state_value='' merged_value='' queued_value='' reason_value='' event_value=''
  local -a batch_owner=() batch_repo=() batch_number=() batch_got=() gh_args=()
  [ -n "$cache" ] || return 0
  [ -f "$cache" ] && [ ! -L "$cache" ] || return 0
  [ -d "$state" ] && [ ! -L "$state" ] || return 0
  poll_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || return 0
  # shellcheck source=bin/fm-pr-lib.sh
  . "$poll_root/fm-pr-lib.sh"
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=$(basename -- "$check" .check.sh)
    fm_pr_poll_snapshot_capture "$state" "$id" "$0" || continue
    [ "$FM_PR_DATA_PROVIDER" = github ] || continue
    url=$FM_PR_DATA_URL
    host=$FM_PR_DATA_HOST
    path=$FM_PR_DATA_PATH
    number=$FM_PR_DATA_NUMBER
    github_identity_ok || continue
    batch_owner[${#batch_owner[@]}]=$owner
    batch_repo[${#batch_repo[@]}]=$repo
    batch_number[${#batch_number[@]}]=$number
  done
  n=${#batch_owner[@]}
  [ "$n" -gt 0 ] || return 0
  i=0
  while [ "$i" -lt "$n" ]; do
    poll_cache_write_missing "${batch_owner[$i]}" "${batch_repo[$i]}" "${batch_number[$i]}"
    batch_got[i]=0
    if [ "$i" -gt 0 ]; then
      vars="${vars},"
    fi
    vars="${vars}\$o${i}:String!,\$r${i}:String!,\$n${i}:Int!"
    body="${body}p${i}:repository(owner:\$o${i},name:\$r${i}){pullRequest(number:\$n${i}){state merged isInMergeQueue timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{id reason}}}}}"
    i=$((i + 1))
  done
  query="query FmPollBatch(${vars}){${body}}"
  gh_args=(--hostname github.com -f "query=${query}")
  i=0
  while [ "$i" -lt "$n" ]; do
    gh_args+=(-f "o${i}=${batch_owner[$i]}")
    gh_args+=(-f "r${i}=${batch_repo[$i]}")
    gh_args+=(-F "n${i}=${batch_number[$i]}")
    i=$((i + 1))
  done
  # shellcheck disable=SC2016  # GraphQL and jq text are literal.
  batch_jq='def reading: if . == null then "missing=1", "" else ((.timelineItems.nodes // []) | last // {}) as $event | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "reason=" + (($event.reason // "") | tojson | .[1:-1]), "event=" + (($event.id // "") | if test("^[A-Za-z0-9_+/=-]{0,256}$") then . else "" end), "" end; (.data // {}) | to_entries[] | select(.key | test("^p[0-9]+$")) | "alias=" + .key, ((.value.pullRequest // null) | reading)'
  if ! fields=$(gh api graphql "${gh_args[@]}" --jq "$batch_jq" 2>/dev/null) || [ -z "$fields" ]; then
    return 0
  fi
  batch_out=$(mktemp "${TMPDIR:-/tmp}/fm-pr-poll-batch.XXXXXX") || return 0
  if ! printf '%s\n' "$fields" > "$batch_out"; then
    rm -f -- "$batch_out"
    return 0
  fi
  if ! : > "$cache"; then
    rm -f -- "$batch_out"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      alias=p[0-9]*)
        if [ "$cur" -ge 0 ] && [ "${batch_got[$cur]}" -ne 1 ]; then
          poll_batch_commit_one "${batch_owner[$cur]}" "${batch_repo[$cur]}" \
            "${batch_number[$cur]}" "$missing" "$bad" "$state_value" \
            "$merged_value" "$queued_value" "$reason_value" "$event_value"
          batch_got[cur]=1
        fi
        cur=-1
        alias_index=${line#alias=p}
        case "$alias_index" in
          *[!0-9]*) ;;
          *)
            if [ "$alias_index" -lt "$n" ]; then
              cur=$alias_index
              missing=0
              bad=0
              state_value=''
              merged_value=''
              queued_value=''
              reason_value=''
              event_value=''
            fi
            ;;
        esac
        ;;
      '')
        if [ "$cur" -ge 0 ] && [ "${batch_got[$cur]}" -ne 1 ]; then
          poll_batch_commit_one "${batch_owner[$cur]}" "${batch_repo[$cur]}" \
            "${batch_number[$cur]}" "$missing" "$bad" "$state_value" \
            "$merged_value" "$queued_value" "$reason_value" "$event_value"
          batch_got[cur]=1
        fi
        cur=-1
        ;;
      missing=1)
        [ "$cur" -ge 0 ] || continue
        missing=1
        ;;
      state=*)
        [ "$cur" -ge 0 ] || continue
        state_value=${line#state=}
        ;;
      merged=*)
        [ "$cur" -ge 0 ] || continue
        merged_value=${line#merged=}
        ;;
      queued=*)
        [ "$cur" -ge 0 ] || continue
        queued_value=${line#queued=}
        ;;
      reason=*)
        [ "$cur" -ge 0 ] || continue
        reason_value=${line#reason=}
        ;;
      event=*)
        [ "$cur" -ge 0 ] || continue
        event_value=${line#event=}
        ;;
      *)
        [ "$cur" -ge 0 ] || continue
        bad=1
        ;;
    esac
  done < "$batch_out"
  rm -f -- "$batch_out"
  if [ "$cur" -ge 0 ] && [ "${batch_got[$cur]}" -ne 1 ]; then
    poll_batch_commit_one "${batch_owner[$cur]}" "${batch_repo[$cur]}" \
      "${batch_number[$cur]}" "$missing" "$bad" "$state_value" \
      "$merged_value" "$queued_value" "$reason_value" "$event_value"
    batch_got[cur]=1
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${batch_got[$i]}" -ne 1 ]; then
      poll_cache_write_missing "${batch_owner[$i]}" "${batch_repo[$i]}" "${batch_number[$i]}"
    fi
    i=$((i + 1))
  done
}

github_read_poll() {
  local fields line total=0 cache_rc=2
  local state='' merged='' queued='' reason='' event=''
  local saw_state=0 saw_merged=0 saw_queued=0 saw_reason=0 saw_event=0
  poll_batch_lookup
  cache_rc=$?
  if [ "$cache_rc" -eq 0 ]; then
    return 0
  fi
  if [ "$cache_rc" -eq 1 ]; then
    return 1
  fi
  # shellcheck disable=SC2016  # GraphQL and jq text are literal.
  fields=$(gh api graphql --hostname "$host" \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{id reason}}}}}}' \
    -f "owner=$owner" -f "repo=$repo" -F "number=$number" \
    --jq '.data.repository.pullRequest | ((.timelineItems.nodes // []) | last // {}) as $event | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "reason=" + (($event.reason // "") | tojson | .[1:-1]), "event=" + (($event.id // "") | if test("^[A-Za-z0-9_+/=-]{0,256}$") then . else "" end)' \
    2>/dev/null) || return 1
  [ -n "$fields" ] || return 1
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=}; saw_state=$((saw_state + 1)) ;;
      merged=*) merged=${line#merged=}; saw_merged=$((saw_merged + 1)) ;;
      queued=*) queued=${line#queued=}; saw_queued=$((saw_queued + 1)) ;;
      reason=*) reason=${line#reason=}; saw_reason=$((saw_reason + 1)) ;;
      event=*) event=${line#event=}; saw_event=$((saw_event + 1)) ;;
      *) return 1 ;;
    esac
  done <<EOF
$fields
EOF
  [ "$total" -eq 5 ] || return 1
  [ "$saw_state" -eq 1 ] && [ "$saw_merged" -eq 1 ] \
    && [ "$saw_queued" -eq 1 ] && [ "$saw_reason" -eq 1 ] && [ "$saw_event" -eq 1 ] || return 1
  poll_accept_reading "$state" "$merged" "$queued" "$reason" "$event"
}

github_poll() {
  poll_bind_identity
  github_read_poll || return 0
  if [ "$GH_POLL_MERGED" = true ]; then
    printf '%s\n' merged
    return 0
  fi
  if [ "$GH_POLL_STATE" = CLOSED ]; then
    printf '%s\n' closed
    return 0
  fi
  if [ "$GH_POLL_QUEUED" = true ]; then
    return 0
  fi
  poll_emit_dequeue
}

if [ "$#" -eq 2 ] && [ "$1" = --batch-prefetch ]; then
  poll_batch_prefetch "$2"
  exit 0
fi

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    github_identity_ok || exit 0
    github_poll
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    part_count=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      part_count=$((part_count + 1))
      [ "$part_count" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$part_count" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  gerrit)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A Gerrit project name is a path at no fixed depth that needs no enclosing
    # group, so one segment is canonical here where GitLab needs two, and Gerrit
    # reserves no route segment inside it.
    rest=$path
    part_count=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      part_count=$((part_count + 1))
      [ "$part_count" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$part_count" -ge 1 ] || exit 0
    [ "$url" = "https://$host/c/$path/+/$number" ] || exit 0
    # gerrit-axi resolves its server from the current directory's origin remote
    # first, and the watcher runs in no repository, so the host must be passed
    # explicitly from the validated record. Without it the tool has no host to
    # reach and fails before reading anything, and this poll is silent on every
    # failure, so the watch would wait forever on a change it never looked at.
    #
    # The status is read explicitly and is the only thing that can wake this
    # poll. Gerrit's submittability is a different question: a merged change
    # still reports its submit state as OK with nothing blocking it, so reading
    # submittability, a blocked_on list, or vote values would report a merge for
    # an open change that is merely ready to submit.
    #
    # jq selects the one record whose change number matches. A change number is
    # server-global and --host already pins the server, so the number alone
    # names the change. The record's own url field is deliberately not compared
    # against the stored URL: Gerrit composes that field from
    # gerrit.canonicalWebUrl and omits it when that setting is unset, so an
    # equality test would leave a correctly armed watch silent forever on such
    # a server, and this poll has no channel to report that it never matched.
    json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) || exit 0
    [ -n "$json" ] || exit 0
    status=$(printf '%s' "$json" | jq -r --argjson change "$number" '
      if type == "object" and .ok == true and (.changes | type) == "array" then
        [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
        | if ($match | length) == 1
             and ($match[0].status | type) == "string"
          then $match[0].status
          else error("no exact change record")
          end
      else
        error("invalid gerrit record")
      end' 2>/dev/null) || exit 0
    [ "$status" = MERGED ] && printf '%s\n' merged
    ;;
  forgejo)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    case "$path" in
      */*/*|/*|*/) exit 0 ;;
    esac
    owner=${path%%/*}
    repo=${path#*/}
    [ "$owner" != "$path" ] || exit 0
    for segment in "$owner" "$repo"; do
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || exit 0
      case "$segment" in
        .|..|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    command -v tea >/dev/null 2>&1 || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    # tea addresses a repo by slug only; the host comes from a named login
    # rather than a URL the way gh and glab take one, so the login registered
    # for this exact host is resolved fresh on every poll rather than trusted
    # from anywhere durable. Refuse to guess when zero or more than one
    # registered login matches, rather than picking one arbitrarily.
    # The list is parsed as JSON, never split on quotes per line, so a login
    # printed as one compact object still matches; this is the same filter
    # bin/fm-pr-lib.sh's fm_pr_forgejo_login applies.
    login=$(
      tea login list --output json 2>/dev/null | jq -er --arg h "$host" '
        if type == "array" then
          [ .[]
            | select(type == "object" and (.name | type) == "string" and (.name | length) > 0
                     and (.url | type) == "string")
            | select((.url
                      | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
                      | sub("[/?#].*$"; "")
                      | sub("^.*@"; "")
                      | sub(":[0-9]+$"; "")) == $h)
            | .name ]
          | if length == 1 then .[0] else error("not exactly one matching login") end
        else
          error("login list is not an array")
        end' 2>/dev/null
    ) || exit 0
    [ -n "$login" ] || exit 0
    # tea's single-PR view ignores field selection, so the one pull request
    # is read by number from the REST record through "tea api", which keeps
    # the credential inside tea. "tea api" exits 0 on an HTTP error with the
    # error body as output, so only a boolean merged field of true wakes this
    # poll and every other reading stays silent.
    merged=$(tea api --login "$login" --repo "$owner/$repo" \
      "/repos/{owner}/{repo}/pulls/$number" 2>/dev/null | jq -r '
        if type == "object" and (.merged | type) == "boolean"
        then .merged | tostring
        else error("invalid pull request record")
        end' 2>/dev/null) || exit 0
    [ "$merged" = true ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
