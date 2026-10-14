#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, or Gerrit
# change poll sidecar.
# It emits exactly one merged line for a merged change. A GitHub pull request
# verified into the merge queue, by this poll or by bin/fm-pr-merge.sh, emits
# one `dequeued <url> reason=<token>` line once when it later leaves the queue
# unmerged. The token is GitHub's removal reason, or `unreadable` when that
# reason is not a short token. Every other reading, including every error,
# stays silent, so a failed lookup can never be read as a merge. The
# provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, gerrit-axi for Gerrit, and tea for Forgejo, so an upstream checkout
# needs no extra tooling to follow GitHub or GitLab. The Gerrit and Forgejo
# branches additionally need jq, which bin/fm-pr-check.sh refuses to arm those
# watches without.
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

# lines is 2 for the queue marker and 3 for the departure marker. The third
# line is the reason and may be empty. Format owner for both files is this
# script.
poll_marker_matches() {
  local path=$1 version=$2 expect_url=$3 lines=$4 got_version got_url _extra i
  poll_private "$path" || return 1
  exec 8< "$path" || return 1
  if ! IFS= read -r got_version <&8 || ! IFS= read -r got_url <&8; then
    exec 8<&-
    return 1
  fi
  i=2
  while [ "$i" -lt "$lines" ]; do
    if ! IFS= read -r _extra <&8; then
      exec 8<&-
      return 1
    fi
    i=$((i + 1))
  done
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$got_version" = "$version" ] && [ "$got_url" = "$expect_url" ]
}

poll_remove_regular() {
  local path=$1
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  rm -f -- "$path"
}

poll_write_lines() {
  local dest=$1 tmp
  shift
  poll_id_usable || return 1
  [ ! -L "$dest" ] || return 1
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    return 1
  fi
  tmp=$(mktemp "$poll_state/.fm-pr-poll-queue.XXXXXX") || return 1
  if printf '%s\n' "$@" > "$tmp" \
    && chmod 0600 "$tmp" \
    && poll_private "$tmp" \
    && [ ! -L "$dest" ] \
    && { [ ! -e "$dest" ] || [ -f "$dest" ]; } \
    && mv -f -- "$tmp" "$dest" \
    && poll_private "$dest"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

poll_record_queued() {
  local queue dropped
  poll_id_usable || return 0
  queue="$poll_state/$poll_id.pr-poll-queue"
  dropped="$poll_state/$poll_id.pr-poll-queue-dropped"
  poll_write_lines "$queue" fm-pr-poll-queue-v1 "$url" || return 0
  poll_remove_regular "$dropped" || true
}

poll_reason_token() {
  local raw=$1
  local LC_ALL=C
  if [ "${#raw}" -le 64 ]; then
    case "$raw" in
      *[!A-Za-z0-9_-]*) printf '%s' unreadable ;;
      *) printf '%s' "$raw" ;;
    esac
  else
    printf '%s' unreadable
  fi
}

poll_emit_dequeue() {
  local queue dropped token
  poll_id_usable || return 0
  queue="$poll_state/$poll_id.pr-poll-queue"
  dropped="$poll_state/$poll_id.pr-poll-queue-dropped"
  poll_marker_matches "$queue" fm-pr-poll-queue-v1 "$url" 2 || return 0
  if [ -e "$dropped" ] || [ -L "$dropped" ]; then
    if poll_marker_matches "$dropped" fm-pr-poll-queue-dropped-v1 "$url" 3; then
      return 0
    fi
    # A private marker for another departure can be replaced. Anything else
    # stays silent, so a bad file cannot wake on every poll.
    poll_private "$dropped" || return 0
  fi
  token=$(poll_reason_token "$GH_POLL_REASON")
  printf 'dequeued %s reason=%s\n' "$url" "$token"
  poll_write_lines "$dropped" fm-pr-poll-queue-dropped-v1 "$url" "$token" || true
}

github_read_poll() {
  local fields line total=0
  local state='' merged='' queued='' reason=''
  local saw_state=0 saw_merged=0 saw_queued=0 saw_reason=0
  # shellcheck disable=SC2016  # GraphQL and jq text are literal.
  fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{reason}}}}}}' \
    -F "owner=$owner" -F "repo=$repo" -F "number=$number" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "reason=" + (((.timelineItems.nodes // []) | map(select(.reason != null) | .reason) | last // "") | if test("^[A-Za-z0-9_-]{0,64}$") then . else "unreadable" end)' \
    2>/dev/null) || return 1
  [ -n "$fields" ] || return 1
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=}; saw_state=$((saw_state + 1)) ;;
      merged=*) merged=${line#merged=}; saw_merged=$((saw_merged + 1)) ;;
      queued=*) queued=${line#queued=}; saw_queued=$((saw_queued + 1)) ;;
      reason=*) reason=${line#reason=}; saw_reason=$((saw_reason + 1)) ;;
      *) return 1 ;;
    esac
  done <<EOF
$fields
EOF
  [ "$total" -eq 4 ] || return 1
  [ "$saw_state" -eq 1 ] && [ "$saw_merged" -eq 1 ] \
    && [ "$saw_queued" -eq 1 ] && [ "$saw_reason" -eq 1 ] || return 1
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
  case "$reason" in
    *[!A-Za-z0-9_-]*) reason=unreadable ;;
  esac
  [ "${#reason}" -le 64 ] || reason=unreadable
  GH_POLL_MERGED=$merged
  GH_POLL_QUEUED=$queued
  GH_POLL_REASON=$reason
}

github_poll() {
  poll_bind_identity
  github_read_poll || return 0
  if [ "$GH_POLL_MERGED" = true ]; then
    printf '%s\n' merged
    return 0
  fi
  if [ "$GH_POLL_QUEUED" = true ]; then
    poll_record_queued
    return 0
  fi
  poll_emit_dequeue
}

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
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
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
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
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
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 1 ] || exit 0
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
