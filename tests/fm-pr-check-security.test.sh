#!/usr/bin/env bash
# Security and regression tests for canonical PR parsing, static merge polls,
# private atomic artifacts, authenticated custom checks, and teardown cleanup.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-security)
fm_git_identity fmtest fmtest@example.invalid
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_CP=$(command -v cp)
REAL_MV=$(command -v mv)
REAL_STAT=$(command -v stat)
REAL_CHMOD=$(command -v chmod)
# The merge path reads a merge request's JSON with the real jq, and BASE_PATH is
# deliberately restricted, so a case that needs jq exposes this one rather than
# depending on the host keeping jq in one of those four directories.
REAL_JQ=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"
export FM_TEST_REAL_JQ=$REAL_JQ

ack_watcher_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-wake-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

process_is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

LINK_KIND=
LINK_TARGET=
LINK_CONTENT=
LINK_MODE=
make_private_symlink() {
  local base=$1 destination=$2 kind=$3
  LINK_KIND=$kind
  LINK_TARGET="$base/target-$kind"
  LINK_CONTENT=
  LINK_MODE=
  case "$kind" in
    regular)
      LINK_CONTENT='external sentinel'
      printf '%s\n' "$LINK_CONTENT" > "$LINK_TARGET"
      chmod 0644 "$LINK_TARGET"
      LINK_MODE=644
      ;;
    dangling)
      rm -f "$LINK_TARGET"
      ;;
    directory)
      mkdir "$LINK_TARGET"
      printf 'outside\n' > "$LINK_TARGET/keep"
      chmod 0755 "$LINK_TARGET"
      LINK_MODE=755
      ;;
    *) fail "unknown symlink fixture kind" ;;
  esac
  ln -s "$LINK_TARGET" "$destination"
}

assert_private_symlink_unchanged() {
  local link=$1
  [ -L "$link" ] || fail "private destination symlink was replaced"
  case "$LINK_KIND" in
    regular)
      [ "$(cat "$LINK_TARGET")" = "$LINK_CONTENT" ] || fail "external regular target content changed"
      [ "$(file_mode "$LINK_TARGET")" = "$LINK_MODE" ] || fail "external regular target mode changed"
      ;;
    dangling)
      [ ! -e "$LINK_TARGET" ] || fail "dangling target was created"
      ;;
    directory)
      [ -f "$LINK_TARGET/keep" ] || fail "external directory target contents changed"
      [ "$(file_mode "$LINK_TARGET")" = "$LINK_MODE" ] || fail "external directory target mode changed"
      ;;
  esac
}

state_snapshot() {
  local state=$1 file
  (
    cd "$state" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r file; do
      if [ -L "$file" ]; then
        printf 'link %s %s\n' "$file" "$(readlink "$file")"
      else
        printf 'file %s %s ' "$file" "$(file_mode "$file")"
        shasum -a 256 "$file" | awk '{print $1}'
      fi
    done
  )
}

make_case() {
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$fakebin" "$fake_root/bin"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" update-ref refs/remotes/origin/main "$(git -C "$dir/wt" rev-parse HEAD)"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "$FM_TEST_GUARD_LOG"
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
test_api_string_field() {
  [ "$1" = -F ] || return 0
  case "$2" in
    true|false|null) return 1 ;;
  esac
  case "${2#-}" in
    ''|*[!0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}
test_beacon_fresh() {
  local modified
  case "$(uname -s)" in
    Darwin) modified=$(/usr/bin/stat -f %m "$1") || return 1 ;;
    *) modified=$(stat -c %Y "$1") || return 1 ;;
  esac
  [ "$(( $(date +%s) - modified ))" -lt 900 ]
}
case "${1:-} ${2:-}" in
  "api graphql")
    # The merge script's four-line outcome query stays on the branch below.
    # A poll query names the removal event, so this branch can dequeue a
    # pull request the outcome query has never described.
    case " $* " in
      *pullRequests*)
        [ "${FM_TEST_GH_SWEEP_FAIL:-0}" = 0 ] || exit 1
        request_host=github.com
        request_owner=
        request_repo=
        request_query=
        cursor=null
        jq_filter=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --jq) shift; jq_filter=${1-} ;;
            --hostname) shift; request_host=${1-} ;;
            -f|-F)
              field_mode=$1
              shift
              case "${1-}" in
                owner=*)
                  request_owner=${1#owner=}
                  test_api_string_field "$field_mode" "$request_owner" || exit 1
                  ;;
                repo=*)
                  request_repo=${1#repo=}
                  test_api_string_field "$field_mode" "$request_repo" || exit 1
                  ;;
                query=*) request_query=${1#query=} ;;
                cursor=*) cursor=${1#cursor=} ;;
              esac
              ;;
          esac
          shift
        done
        [ "$request_host" = github.com ] || exit 1
        [ -n "$jq_filter" ] || exit 1
        [ "$request_owner/$request_repo" != "${FM_TEST_GH_SWEEP_FAIL_REPO:-}" ] || exit 1
        if [ -n "${FM_TEST_GH_SWEEP_CORRUPT_SEEN:-}" ]; then
          printf 'malformed\n' > "$FM_TEST_GH_SWEEP_CORRUPT_SEEN" || exit 1
        fi
        if [ "${FM_TEST_GH_SWEEP_MUTATING:-0}" = 1 ]; then
          set -o pipefail
          "$FM_TEST_REAL_JQ" --arg query "$request_query" --arg cursor "$cursor" '
            ($query | capture("orderBy\\s*:\\s*\\{(?<body>[^}]+)\\}").body) as $order |
            ($order | capture("field\\s*:\\s*(?<field>[A-Z_]+)").field) as $field |
            ($order | capture("direction\\s*:\\s*(?<direction>ASC|DESC)").direction) as $direction |
            ($query | capture("first\\s*:\\s*(?<count>[0-9]+)").count | tonumber) as $count |
            ({CREATED_AT:"createdAt", UPDATED_AT:"updatedAt"}[$field] // error("unsupported order")) as $key |
            map(if $cursor != "null" and .number == 2 then
              .updatedAt = 1000 | .isInMergeQueue = false |
              .timelineItems.nodes = [{__typename:"RemovedFromMergeQueueEvent",id:"evt2",reason:"failed_checks"}]
            else . end) |
            sort_by(.[$key]) | (if $direction == "DESC" then reverse else . end) |
            . as $pulls |
            (if $cursor == "null" then 0 else
              (map(.number) | index($cursor | ltrimstr("cursor") | tonumber)) + 1
            end) as $start |
            .[$start:($start + $count)] as $page |
            {data:{repository:{pullRequests:{nodes:$page,pageInfo:{
              hasNextPage:($start + ($page | length) < ($pulls | length)),
              endCursor:(if ($page | length) > 0 then "cursor"+($page[-1].number | tostring) else null end)
            }}}}}
          ' "$FM_TEST_GH_SWEEP_DIR/pulls.json" | "$FM_TEST_REAL_JQ" -r "$jq_filter"
          exit $?
        fi
        if [ "${FM_TEST_GH_SWEEP_EXPIRE_BEAT:-0}" = 1 ]; then
          test_beacon_fresh "$FM_PR_SWEEP_BEAT" \
            || printf 'stale-beacon sweep\n' >> "$FM_TEST_GH_LOG"
          if [ "$cursor" != page6 ]; then
            touch -t 200001010000 "$FM_PR_SWEEP_BEAT" || exit 1
            printf 'expired-beacon sweep\n' >> "$FM_TEST_GH_LOG"
          fi
        fi
        if [ "$cursor" = page6 ] && [ -n "${FM_TEST_GH_SWEEP_REARM:-}" ]; then
          "$FM_TEST_GH_SWEEP_REARM" > "$FM_TEST_GH_SWEEP_DIR/rearm.out" \
            2> "$FM_TEST_GH_SWEEP_DIR/rearm.err" || exit 1
        fi
        [ "${FM_TEST_GH_SWEEP_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GH_SWEEP_SLEEP"
        if [ -z "${FM_TEST_GH_SWEEP_DIR:-}" ]; then
          printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' \
            | "$FM_TEST_REAL_JQ" -r "$jq_filter"
          exit $?
        fi
        page=$cursor
        [ "$page" != null ] && [ -n "$page" ] || page=page1
        [ -f "$FM_TEST_GH_SWEEP_DIR/$page.json" ] || exit 1
        "$FM_TEST_REAL_JQ" -r "$jq_filter" "$FM_TEST_GH_SWEEP_DIR/$page.json"
        exit $?
        ;;
      *REMOVED_FROM_MERGE_QUEUE_EVENT*)
        [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
        [ -z "${FM_TEST_GH_STATE_STARTED:-}" ] || : > "$FM_TEST_GH_STATE_STARTED"
        [ "${FM_TEST_GH_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GH_SLEEP"
        request_host=${GH_HOST:-github.com}
        poll_number=
        jq_filter=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --jq) shift; jq_filter=${1-} ;;
            --hostname) shift; request_host=${1-} ;;
            -f|-F)
              field_mode=$1
              shift
              case "${1-}" in
                owner=*|repo=*) test_api_string_field "$field_mode" "${1#*=}" || exit 1 ;;
                number=*) poll_number=${1#number=} ;;
              esac
              ;;
          esac
          shift
        done
        if [ "${FM_TEST_GH_POLL_EXPIRE_BEAT:-0}" = 1 ]; then
          test_beacon_fresh "$FM_PR_POLL_STATE/.last-watcher-beat" \
            || printf 'stale-beacon poll\n' >> "$FM_TEST_GH_LOG"
          if [ "$poll_number" != "${FM_TEST_GH_POLL_REARM_NUMBER:-}" ]; then
            touch -t 200001010000 "$FM_PR_POLL_STATE/.last-watcher-beat" || exit 1
            printf 'expired-beacon poll\n' >> "$FM_TEST_GH_LOG"
          fi
        fi
        if [ "$poll_number" = "${FM_TEST_GH_POLL_REARM_NUMBER:-}" ] \
          && [ -n "${FM_TEST_GH_POLL_REARM:-}" ]; then
          "$FM_TEST_GH_POLL_REARM" > "$FM_TEST_GH_LOG.rearm.out" \
            2> "$FM_TEST_GH_LOG.rearm.err" || exit 1
        fi
        if [ -n "${FM_TEST_GH_POLL_RESPONSES:-}" ]; then
          "$FM_TEST_REAL_JQ" --arg number "$poll_number" '.[$number]' "$FM_TEST_GH_POLL_RESPONSES" \
            | "$FM_TEST_REAL_JQ" -r "$jq_filter"
          exit $?
        fi
        state=${FM_TEST_GH_STATE-OPEN}
        if [ "$request_host" != github.com ]; then
          state=MERGED
          merged=true
        elif [ -n "${FM_TEST_GH_POLL_MERGED+x}" ]; then
          merged=$FM_TEST_GH_POLL_MERGED
        elif [ "$state" = MERGED ]; then
          merged=true
        else
          merged=false
        fi
        "$FM_TEST_REAL_JQ" -n --arg state "$state" --argjson merged "$merged" \
          --argjson queued "${FM_TEST_GH_POLL_QUEUED:-false}" \
          --arg reason "${FM_TEST_GH_POLL_REASON-}" \
          --arg event "${FM_TEST_GH_POLL_EVENT-}" \
          '{data:{repository:{pullRequest:{state:$state,merged:$merged,isInMergeQueue:$queued,timelineItems:{nodes:(if $event == "" then [] else [{id:$event,reason:$reason}] end)}}}}}' \
          | "$FM_TEST_REAL_JQ" -r "$jq_filter"
        exit $?
        ;;
    esac
    printf '%s\n' \
      "state=${FM_TEST_GH_GRAPHQL_STATE:-MERGED}" \
      "merged=${FM_TEST_GH_GRAPHQL_MERGED:-true}" \
      "queued=${FM_TEST_GH_GRAPHQL_QUEUED:-false}" \
      'base=main'
    exit 0
    ;;
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s\n' "{\"state\":\"OPEN\",\"isDraft\":false,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\",\"baseRefName\":\"main\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"name\":\"ci\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}"
        exit 0
        ;;
      *" --json isDraft "*)
        printf '%s\n' "{\"isDraft\":${FM_TEST_GH_DRAFT:-false}}"
        exit 0
        ;;
      *headRefOid,reviewDecision*)
        printf '%s\n' "{\"headRefOid\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\",\"reviewDecision\":\"APPROVED\"}"
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    [ -z "${FM_TEST_GH_MERGE_HOOK:-}" ] || "$FM_TEST_GH_MERGE_HOOK"
    exit 0
    ;;
esac
case " $* " in
  *" api repos/"*"/issues/"*"/comments?per_page=100 "*|*" api repos/"*"/pulls/"*"/reviews?per_page=100 "*|*" api repos/"*"/pulls/"*"/comments?per_page=100 "*)
    printf '%s\n' '[[]]'
    ;;
  *" api repos/"*"/commits/"*"/check-runs?filter=all&per_page=100 "*)
    printf '%s\n' '[{"check_runs":[]}]'
    ;;
  *" api repos/"*"/commits/"*"/statuses?per_page=100 "*)
    printf '%s\n' '[[]]'
    ;;
  *" api --paginate repos/"*"/rules/branches/"*merge_queue*)
    ;;
  *" api --paginate repos/"*"/rules/branches/"*)
    printf '%s\n' '[]'
    ;;
  *" api repos/"*"/branches/"*)
    printf '%s\n' '{"name":"main","protected":false}'
    ;;
  *" api repos/"*"/pulls/"*)
    printf '%s\n' "{\"state\":\"open\",\"user\":{\"login\":\"author\"},\"head\":{\"sha\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\"},\"draft\":false,\"mergeable\":true,\"merged_at\":null}"
    ;;
  *" api repos/"*)
    printf '%s\n' '{"permissions":{"push":false}}'
    ;;
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" state "*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    [ -z "${FM_TEST_GH_STATE_STARTED:-}" ] || : > "$FM_TEST_GH_STATE_STARTED"
    [ "${FM_TEST_GH_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GH_SLEEP"
    printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}"
    ;;
esac
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit "${FM_TEST_GH_AXI_RC:-0}"
SH
  # Plain glab, reproducing the real CLI's contract: its field output on stdout
  # and exit 0 on success, and a non-zero exit with no stdout on any failure.
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GLAB_LOG"
[ "${FM_TEST_GLAB_FAIL:-0}" = 0 ] || exit 1
[ "${FM_TEST_GLAB_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GLAB_SLEEP"
printf 'title:\tfixture merge request\nstate:\t%s\nauthor:\tsomeone\n' "${FM_TEST_GLAB_STATE:-opened}"
SH
  # gerrit-axi, reproducing the real CLI's contract: one JSON record on stdout
  # and exit 0 on success, and a non-zero exit with no stdout on any failure.
  # Its defaults are the real server's readings for an OPEN change, and the
  # submit fields are settable independently of the status so a case can build
  # the reading a merged change and a merely submittable change share.
  cat > "$fakebin/gerrit-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GERRIT_AXI_LOG"
[ "${FM_TEST_GERRIT_FAIL:-0}" = 0 ] || exit 1
if [ -n "${FM_TEST_GERRIT_RAW:-}" ]; then
  printf '%s\n' "$FM_TEST_GERRIT_RAW"
  exit 0
fi
change=${FM_TEST_GERRIT_CHANGE:-${2:-0}}
printf '{"ok":true,"op":"show","count":1,"missing":[],"changes":[{"change":%s,"subject":%s,"project":"p","status":"%s","wip":false,"submit":"%s","submittable":%s,"blocked_on":"%s","patch_set":1,"revision":"%s","url":"%s"}]}\n' \
  "$change" \
  "${FM_TEST_GERRIT_SUBJECT:-\"fixture change\"}" \
  "${FM_TEST_GERRIT_STATUS:-NEW}" \
  "${FM_TEST_GERRIT_SUBMIT:-NOT_READY}" \
  "${FM_TEST_GERRIT_SUBMITTABLE:-false}" \
  "${FM_TEST_GERRIT_BLOCKED_ON:-Code-Review}" \
  "${FM_TEST_GERRIT_REVISION:-5f07a68436929a527ddc7abadc8ef1abceae40ed}" \
  "${FM_TEST_GERRIT_URL:-https://gerrit.example/c/group/apps/console/+/4201}"
SH
  # no-mistakes, answering only `axi status` the way the real CLI does from a
  # worker copy: a run object, then its branch_sync block. By default the run's
  # result is the copy's own passed HEAD and custody is returned; a case
  # overrides the outcome, the pipeline head, the next action, or makes the read
  # fail.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_NM_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_NM_LOG"
[ "${1:-} ${2:-}" = "axi status" ] || exit 2
[ "${FM_TEST_NM_FAIL:-0}" = 0 ] || exit 1
head=$(git rev-parse HEAD 2>/dev/null) || exit 1
pipeline=${FM_TEST_NM_PIPELINE_HEAD:-$head}
printf 'run:\n  id: "RUNFIXTURE"\n  branch: fm/task\n  status: completed\n  head_sha: %s\noutcome: %s\n' \
  "$pipeline" "${FM_TEST_NM_OUTCOME-passed}"
printf 'branch_sync:\n  state: %s\n  local:\n    head: %s\n  pipeline:\n    current_head: %s\n' \
  "${FM_TEST_NM_SYNC_STATE:-synchronized}" "$head" "$pipeline"
if [ -n "${FM_TEST_NM_NEXT_ACTION:-}" ]; then
  printf '  next_action:\n    code: %s\n    command: no-mistakes axi status\n' "$FM_TEST_NM_NEXT_ACTION"
fi
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/glab" "$fakebin/gerrit-axi"
  chmod +x "$fakebin/no-mistakes"
  : > "$dir/gh.log"
  : > "$dir/gh-axi.log"
  : > "$dir/glab.log"
  : > "$dir/gerrit-axi.log"
  : > "$dir/guard.log"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

# Extra "field=value" arguments are written before pr=, because
# fm_pr_metadata_identity_parse rejects an unrecognised line after it.
write_poll_meta() {
  local state=$1 id=$2 url=$3 case_dir
  case_dir=$(cd "$state/../.." && pwd)
  shift 3
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" \
    "worktree=$case_dir/wt" \
    "$@" \
    "pr=$url"
}


run_check_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

run_merge_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_MERGE" "$@"
}

# shellcheck disable=SC2016 # Literal rejected URL bytes are parser test data.
INVALID_URLS=(
  'https://gitlab.com/single/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/0'
  'https://gitlab.com/g/p/-/merge_requests/01'
  'https://GitLab.com/g/p/-/merge_requests/1'
  'https://gitlab.com:443/g/p/-/merge_requests/1'
  'https://user@gitlab.com/g/p/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/1/'
  'https://gitlab.com/-/p/-/merge_requests/1'
  'https://gitlab.com/g/p.git/-/merge_requests/1'
  'https://gitlab.com/g/p.atom/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/1?x=1'
  'https://gitlab.com/g/p/-/merge_requests/1#note'
  'https://gitlab.com/g/p/-/issues/1'
  'https://gitlab.com//p/-/merge_requests/1'
  'https://.gitlab.com/g/p/-/merge_requests/1'
  'https://gitlab.com./g/p/-/merge_requests/1'
  'http://gitlab.com/g/p/-/merge_requests/1'
  'https://gerrit.example/c/proj/+/0'
  'https://gerrit.example/c/proj/+/01'
  'https://gerrit.example/c/proj/+/1/'
  'https://gerrit.example/c/proj/+/1/2'
  'https://gerrit.example/c/proj/+/1?x=1'
  'https://gerrit.example/c/proj/+/1#c'
  'https://gerrit.example/c/proj/+/1/+/2'
  'https://gerrit.example/c//+/1'
  'https://gerrit.example/c/proj//+/1'
  'https://gerrit.example/c/proj.git/+/1'
  'https://gerrit.example/c/-proj/+/1'
  'https://gerrit.example/c/a/-b/+/1'
  'https://gerrit.example/c/./+/1'
  'https://gerrit.example/c/a/../+/1'
  'https://gerrit.example/proj/+/1'
  'https://gerrit.example/c/proj/1'
  'https://gerrit.example/#/c/proj/+/1'
  'https://GERRIT.example/c/proj/+/1'
  'https://gerrit.example:8443/c/proj/+/1'
  'https://user@gerrit.example/c/proj/+/1'
  'https://.gerrit.example/c/proj/+/1'
  'https://gerrit.example./c/proj/+/1'
  'http://gerrit.example/c/proj/+/1'
  'https://github.com/c/proj/+/1'
  'https://gerrit.example/c/proj/+/1 '
  'https://github.com/o/r/pull/1/'
  ' https://github.com/o/r/pull/1'
  'https://github.com/o/r/pull/1 '
  'https://github.com/o /r/pull/1'
  $'https://github.com/o/r/pull/1\t'
  $'https://github.com/o/r/pull/1\r'
  $'https://github.com/o/r/pull/1\nnext'
  $'https://github.com/o/r/pull/1\r\nnext'
  $'https://github.com/o/r/pull/1\001'
  $'https://github.com/o/r/pull/1\033'
  $'https://github.com/o/r/pull/1\177'
  'https://user@github.com/o/r/pull/1'
  'https://user:pass@github.com/o/r/pull/1'
  'https://github.com:443/o/r/pull/1'
  'https://github.com/o%2Fr/pull/1'
  'https://github.com/o/r%2Fz/pull/1'
  'https://github.com/o/r/pull/1%3Fq'
  'https://github.com/o/r/pull/1%23f'
  'https://github.com/o/r/pull/1%24x'
  'https://github.com/o/r/pull/1%28x%29'
  'https://github.com/o/r/pull/1%60x'
  'https://github.com/o/r/pull/1%0D'
  'https://github.com/o/r/pull/1%0A'
  'https://github.com/o/r/pull/1%252Fz'
  'https://github.com//r/pull/1'
  'https://github.com/o//pull/1'
  'https://github.com/o/r//1'
  'https://github.com/o/r/1'
  'https://github.com/o/r/pull/'
  'https://github.com/-owner/r/pull/1'
  'https://github.com/owner-/r/pull/1'
  'https://github.com/owner--name/r/pull/1'
  'https://github.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/r/pull/1'
  'https://github.com/o/./pull/1'
  'https://github.com/o/../pull/1'
  'https://github.com/o/r+z/pull/1'
  'https://github.com/o/r/pull/+1'
  'https://github.com/o/r/pull/0'
  'https://github.com/o/r/pull/-1'
  'https://github.com/o/r/pull/01'
  'https://github.com/o/r/pull/0x1'
  'https://github.com/o/r/pull/1e2'
  'https://github.com/o/r/pull/1.0'
  'https://github.com/o/r/issues/1'
  'https://github.com/o/r/x/pull/1'
  'https://github.com/o/r/pull/1/files'
  'https://github.com/o/r/pull/1?q=x'
  'https://github.com/o/r/pull/1#f'
  'https://github.com.evil/o/r/pull/1'
  'https://evilgithub.com/o/r/pull/1'
  'https://gıthub.com/o/r/pull/1'
  'https://xn--gthub-3va.com/o/r/pull/1'
  'http://github.com/o/r/pull/1'
  'ssh://github.com/o/r/pull/1'
  'git://github.com/o/r/pull/1'
  'file://github.com/o/r/pull/1'
  '//github.com/o/r/pull/1'
  'HTTPS://github.com/o/r/pull/1'
  'https://GitHub.com/o/r/pull/1'
  'https://github.com/o$/r/pull/1'
  'https://github.com/o(/r/pull/1'
  'https://github.com/o)/r/pull/1'
  'https://github.com/o`/r/pull/1'
  'https://github.com/o/r`/pull/1'
  'https://github.com/o/r/pull/1`'
  "https://github.com/o/'r'/pull/1"
  'https://github.com/o/"r"/pull/1'
  'https://github.com/o/'\''"r"'\''/pull/1'
  "https://github.com/o/r/pull/1'"
  'https://github.com/o/r/pull/1"'
)

# shellcheck disable=SC2016 # Literal shell syntax is task-ID test data.
INVALID_IDS=(
  '../escape'
  'a/b'
  '.'
  '..'
  '.task'
  'task a'
  $'task\ta'
  $'task\na'
  'task*'
  "task'a"
  'task"a'
  'task;a'
  'task$a'
)

# shellcheck disable=SC2016 # Literal shell syntax is task-ID test data.
UNSAFE_LIFECYCLE_IDS=(
  '../escape'
  'a/b'
  '.'
  '..'
  '.task'
  'task a'
  $'task\ta'
  $'task\na'
  'task*'
  "task'a"
  'task"a'
  'task;a'
  'task$a'
)

test_parser_matrix() {
  local id row url owner repo number
  while IFS='|' read -r url owner repo number; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" || fail "parser rejected canonical URL"
    [ "$FM_PR_URL" = "$url" ] || fail "parser changed canonical URL"
    [ "$FM_PR_OWNER" = "$owner" ] || fail "parser returned wrong owner"
    [ "$FM_PR_REPO" = "$repo" ] || fail "parser returned wrong repository"
    [ "$FM_PR_NUMBER" = "$number" ] || fail "parser returned wrong PR number"
  done <<'EOF'
https://github.com/a/b/pull/1|a|b|1
https://github.com/my-org/repo/pull/42|my-org|repo|42
https://github.com/Owner/repo-name_with.parts/pull/123456|Owner|repo-name_with.parts|123456
EOF
  while IFS='|' read -r url host path number; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" || fail "parser rejected a canonical merge request URL"
    [ "$FM_PR_PROVIDER" = gitlab ] || fail "parser did not tag a merge request URL as gitlab"
    [ "$FM_PR_URL" = "$url" ] || fail "parser changed a canonical merge request URL"
    [ "$FM_PR_HOST" = "$host" ] || fail "parser returned wrong GitLab host"
    [ "$FM_PR_PATH" = "$path" ] || fail "parser returned wrong GitLab project path"
    [ "$FM_PR_NUMBER" = "$number" ] || fail "parser returned wrong merge request number"
    [ -z "$FM_PR_OWNER" ] && [ -z "$FM_PR_REPO" ] \
      || fail "parser set GitHub owner/repository for a merge request URL"
  done <<'EOF'
https://gitlab.com/group/project/-/merge_requests/1|gitlab.com|group/project|1
https://gitlab.com/group/sub/deep/project/-/merge_requests/42|gitlab.com|group/sub/deep/project|42
https://gitlab.example.co.uk/g/p/-/merge_requests/7|gitlab.example.co.uk|g/p|7
https://code.internal/team/tools/ci-runner/-/merge_requests/123456|code.internal|team/tools/ci-runner|123456
EOF
  # A Gerrit project is one nested name, so the whole path is the identity and
  # is never flattened into an owner/repository pair that cannot address it.
  while IFS='|' read -r url host path number; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" || fail "parser rejected a canonical Gerrit change URL"
    [ "$FM_PR_PROVIDER" = gerrit ] || fail "parser did not tag a Gerrit change URL as gerrit"
    [ "$FM_PR_URL" = "$url" ] || fail "parser changed a canonical Gerrit change URL"
    [ "$FM_PR_HOST" = "$host" ] || fail "parser returned wrong Gerrit host"
    [ "$FM_PR_PATH" = "$path" ] || fail "parser returned wrong Gerrit project path"
    [ "$FM_PR_NUMBER" = "$number" ] || fail "parser returned wrong Gerrit change number"
    [ -z "$FM_PR_OWNER" ] && [ -z "$FM_PR_REPO" ] \
      || fail "parser set GitHub owner/repository for a Gerrit change URL"
  done <<'EOF'
https://review.internal/c/group/apps/console/+/4201|review.internal|group/apps/console|4201
https://gerrit.example/c/proj/+/1|gerrit.example|proj|1
https://gerrit.example.co.uk/c/a/b/c/d/+/42|gerrit.example.co.uk|a/b/c/d|42
https://review.internal/c/All-Projects/+/123456|review.internal|All-Projects|123456
EOF
  while IFS='|' read -r url host owner repo number; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" || fail "parser rejected a canonical Forgejo pull request URL"
    [ "$FM_PR_PROVIDER" = forgejo ] || fail "parser did not tag a plural-pulls URL as forgejo"
    [ "$FM_PR_URL" = "$url" ] || fail "parser changed a canonical Forgejo pull request URL"
    [ "$FM_PR_HOST" = "$host" ] || fail "parser returned wrong Forgejo host"
    [ "$FM_PR_PATH" = "$owner/$repo" ] || fail "parser returned wrong Forgejo project path"
    [ "$FM_PR_OWNER" = "$owner" ] || fail "parser returned wrong Forgejo owner"
    [ "$FM_PR_REPO" = "$repo" ] || fail "parser returned wrong Forgejo repository"
    [ "$FM_PR_NUMBER" = "$number" ] || fail "parser returned wrong Forgejo pull request number"
  done <<'EOF'
https://git.example.com/fixture/fixture-repo/pulls/1|git.example.com|fixture|fixture-repo|1
https://code.internal/my-org/repo.name_with-parts/pulls/123456|code.internal|my-org|repo.name_with-parts|123456
EOF
  # A Forgejo-shaped URL on github.com is refused (anti-spoofing, mirroring
  # fm_pr_forge_host_valid's refusal of github.com), and neither GitHub's
  # singular "pull" nor GitLab's "/-/merge_requests/" is accepted as forgejo.
  for row in \
    'https://github.com/fixture/fixture-repo/pulls/1' \
    'https://git.example.com/fixture/fixture-repo/pull/1' \
    'https://git.example.com/group/sub/project/pulls/1'
  do
    ! fm_pr_url_parse "$row" || fail "parser accepted a URL that must not resolve as forgejo: $row"
  done
  fm_pr_url_parse https://github.com/a/b/pull/1 || fail "parser rejected canonical URL"
  [ "$FM_PR_PROVIDER" = github ] || fail "parser did not tag a pull request URL as github"
  [ "$FM_PR_HOST" = github.com ] || fail "parser returned wrong GitHub host"
  [ "$FM_PR_PATH" = a/b ] || fail "parser returned wrong GitHub project path"
  for row in "${INVALID_URLS[@]}"; do
    ! fm_pr_url_parse "$row" || fail "parser accepted a rejected raw-byte URL class"
  done
  for id in -task task- task--a Task-a task_a task.a; do
    fm_pr_task_id_valid "$id" || fail "task ID validator rejected a safe lifecycle-compatible slug"
  done
  fm_task_id_creation_valid _noncanonical \
    || fail "creation validator rejected a task ID after its reserved namespace moved"
  id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fm_pr_task_id_valid "$id" || fail "operational validator rejected a path-safe legacy task ID"
  ! fm_task_id_creation_valid "$id" || fail "creation validator accepted an overlong task ID"
  pass "raw-byte parser accepts canonical URLs and rejects the complete adversarial matrix"
}

test_invalid_entrypoints_have_zero_side_effects() {
  local dir before after value rc
  dir=$(make_case invalid-entrypoints)
  write_task_meta "$dir"
  printf 'existing-check\n' > "$dir/home/state/task-a.check.sh"
  printf 'existing-data\n' > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"

  for value in "${INVALID_URLS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_check_entry "$dir" task-a "$value" > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "direct entrypoint accepted invalid URL"
    [ "$(cat "$dir/stderr")" = 'error: invalid PR check request' ] || fail "direct invalid URL diagnostic was not fixed"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "direct invalid URL changed prior state"
  done

  for value in "${INVALID_IDS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_check_entry "$dir" "$value" https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "direct entrypoint accepted invalid task ID"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "invalid task ID changed state or traversed a path"
  done

  for value in "${INVALID_URLS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_merge_entry "$dir" task-a "$value" > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "merge entrypoint accepted invalid URL"
    [ "$(cat "$dir/stderr")" = 'error: invalid PR merge request' ] || fail "merge invalid URL diagnostic was not fixed"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "merge invalid URL changed prior state"
  done

  for value in "${INVALID_IDS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_merge_entry "$dir" "$value" https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "merge entrypoint accepted invalid task ID"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "merge invalid task ID changed state"
  done

  for value in "${UNSAFE_LIFECYCLE_IDS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_TEST_GUARD_LOG="$dir/guard.log" \
      "$TEARDOWN" "$value" --force > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "teardown accepted invalid task ID"
    [ "$(cat "$dir/stderr")" = 'error: invalid teardown request' ] \
      || fail "teardown invalid task ID diagnostic was not fixed"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "teardown invalid task ID changed state"
  done

  set +e
  run_check_entry "$dir" > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct entrypoint accepted zero arguments"
  set +e
  run_check_entry "$dir" task-a https://github.com/o/r/pull/1 extra > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct entrypoint accepted extra arguments"
  set +e
  run_merge_entry "$dir" > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge entrypoint accepted zero arguments"

  [ ! -s "$dir/gh.log" ] || fail "invalid direct or merge data called gh"
  [ ! -s "$dir/gh-axi.log" ] || fail "invalid direct or merge data called gh-axi"
  [ ! -s "$dir/guard.log" ] || fail "invalid direct or merge data called the guard"
  [ ! -e "$TMP_ROOT/escape.check.sh" ] || fail "task traversal wrote outside state"
  pass "PR and teardown entrypoints reject invalid arguments before every side effect"
}

# A draft cannot be merged, so arming a merge poll on one would wait for an event
# that cannot occur. Only a positive draft reading refuses, and it refuses before
# anything is recorded or armed; a ready or unreadable one arms as before.
test_draft_pull_request_is_not_armed() {
  local dir rc
  dir=$(make_case draft-refused)
  write_task_meta "$dir"
  cp "$dir/home/state/task-a.meta" "$dir/meta.before"
  set +e
  FM_TEST_GH_DRAFT=true run_check_entry "$dir" task-a https://github.com/o/r/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a draft pull request"
  grep -qi 'draft' "$dir/stderr" || fail "the refusal did not name the draft state"
  grep -qF 'https://github.com/o/r/pull/9' "$dir/stderr" || fail "the refusal did not name the pull request"
  cmp -s "$dir/meta.before" "$dir/home/state/task-a.meta" || fail "a refused draft changed the task metadata"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "a refused draft armed a poll"
  [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "a refused draft wrote a poll sidecar"
  [ ! -s "$dir/guard.log" ] || fail "a refused draft reached the guard"

  dir=$(make_case draft-cleared)
  write_task_meta "$dir"
  FM_TEST_GH_DRAFT=false run_check_entry "$dir" task-a https://github.com/o/r/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr" || fail "arming refused a pull request that is not a draft"
  grep -qxF 'pr=https://github.com/o/r/pull/9' "$dir/home/state/task-a.meta" \
    || fail "a non-draft pull request was not recorded"
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "a non-draft pull request was not armed"

  dir=$(make_case draft-unreadable)
  write_task_meta "$dir"
  FM_TEST_GH_DRAFT=null run_check_entry "$dir" task-a https://github.com/o/r/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr" || fail "an unreadable draft state blocked arming"
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "an unreadable draft state was not armed"
  pass "arming refuses a draft pull request, naming it, and arms a ready or unreadable one"
}

# A secondmate is a persistent worker, not a delivery lane: it never owns a
# pull request of its own. A URL relayed onto its status channel belongs to a
# task in the mate's own home, which arms its own watch, so arming one here is
# refused before anything is recorded - a poll on the mate would otherwise mark
# the merge notified and queue the mate itself for teardown as landed work.
test_secondmate_record_refuses_a_pr_watch() {
  local dir rc
  dir=$(make_case secondmate-refuses-watch)
  fm_write_meta "$dir/home/state/domain.meta" \
    'window=session:fm-domain' \
    "worktree=$dir/secondmate-home" \
    "project=$dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    'backend=tmux' \
    "home=$dir/secondmate-home"
  mkdir -p "$dir/secondmate-home"
  cp "$dir/home/state/domain.meta" "$dir/meta.before"
  set +e
  run_check_entry "$dir" domain https://github.com/o/r/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a merge watch was armed on a secondmate record"
  grep -qi 'secondmate' "$dir/stderr" || fail "the refusal did not name the record's kind"
  grep -qF 'https://github.com/o/r/pull/9' "$dir/stderr" \
    || fail "the refusal did not name the pull request it refused"
  cmp -s "$dir/meta.before" "$dir/home/state/domain.meta" \
    || fail "the refusal changed secondmate metadata"
  [ ! -e "$dir/home/state/domain.check.sh" ] || fail "the refusal armed a poll on a secondmate"
  [ ! -e "$dir/home/state/domain.pr-poll" ] || fail "the refusal wrote a poll sidecar on a secondmate"
  [ ! -s "$dir/gh.log" ] || fail "the refusal reached the forge"
  [ ! -s "$dir/guard.log" ] || fail "the refusal reached the guard"
  pass "fm-pr-check refuses to record a PR or arm a merge watch on a secondmate record"
}

# With no forge-reported head (gh cannot supply one), the named head is the
# worker copy's HEAD, and a HEAD that exists only there is refused.
test_unpushed_named_head_refuses_registration() {
  local dir sha
  dir=$(make_case unpushed-named-head)
  write_task_meta "$dir"
  git -C "$dir/wt" commit -q --allow-empty -m 'only in the copy'
  sha=$(git -C "$dir/wt" rev-parse HEAD)
  FM_TEST_GH_HEAD=unavailable run_check_entry "$dir" task-a https://github.com/o/r/pull/4 \
    > "$dir/stdout" 2> "$dir/stderr" && fail "unpushed PR head was registered"
  grep -Fq "named head $sha is unreachable outside the worker copy" "$dir/stderr" \
    || fail "refusal did not name the unreachable head: $(cat "$dir/stderr")"
  ! grep -q '^pr=' "$dir/home/state/task-a.meta" || fail "unpushed PR head still recorded pr="
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "unpushed PR head still armed a poll"
  pass "fm-pr-check refuses to register a PR whose named head is only in the worker copy"
}

# A direct-PR worker pushes from its own copy: the forge still reports the
# head pushed when the PR opened, but a later fix committed only in the copy
# is the named head, so registration is refused.
test_direct_pr_unpushed_commit_refuses_registration() {
  local dir pushed later
  dir=$(make_case direct-pr-unpushed)
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" "endpoint_task_id=task-a" "worktree=$dir/wt" \
    "project=$dir/project" "kind=ship" "mode=direct-PR"
  pushed=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" commit -q --allow-empty -m 'fix only in the copy'
  later=$(git -C "$dir/wt" rev-parse HEAD)
  FM_TEST_GH_HEAD=$pushed run_check_entry "$dir" task-a https://github.com/o/r/pull/4 \
    > "$dir/stdout" 2> "$dir/stderr" && fail "direct-PR head with an unpushed later commit was registered"
  grep -Fq "named head $later is unreachable outside the worker copy" "$dir/stderr" \
    || fail "direct-PR refusal did not name the unpushed commit: $(cat "$dir/stderr")"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "direct-PR unpushed commit still armed a poll"
  pass "fm-pr-check refuses a direct-PR registration while a later commit is only in the copy"
}

test_valid_recording_and_merge_derivation() {
  local dir expected sidecar count rc
  dir=$(make_case valid-recording)
  write_task_meta "$dir"
  expected=0123456789abcdef0123456789abcdef01234567
  FM_TEST_GH_HEAD=$expected run_check_entry "$dir" task-a https://github.com/my-org/repo_name.with-dots/pull/37 \
    > "$dir/stdout" 2> "$dir/stderr" || fail "valid direct check failed"

  grep -qxF 'pr=https://github.com/my-org/repo_name.with-dots/pull/37' "$dir/home/state/task-a.meta" \
    || fail "canonical pr metadata was not exact"
  grep -qxF "pr_head=$expected" "$dir/home/state/task-a.meta" || fail "PR head metadata was not exact"
  cmp -s "$POLL" "$dir/home/state/task-a.check.sh" || fail "published check was not byte-for-byte static"
  [ "$(file_mode "$dir/home/state/task-a.check.sh")" = 600 ] || fail "published check mode was not 0600"
  [ "$(file_mode "$dir/home/state/task-a.pr-poll")" = 600 ] || fail "published sidecar mode was not 0600"
  [ "$(file_mode "$dir/home/state/task-a.pr-poll-registration")" = 600 ] \
    || fail "published registration mode was not 0600"
  [ "$(fm_pr_file_link_count "$dir/home/state/task-a.check.sh")" = 1 ] \
    && [ "$(fm_pr_file_link_count "$dir/home/state/task-a.pr-poll")" = 1 ] \
    && [ "$(fm_pr_file_link_count "$dir/home/state/task-a.pr-poll-registration")" = 1 ] \
    || fail "published poll artifacts were not single-link files"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "published poll provenance or metadata binding was invalid"
  sidecar=$(cat "$dir/home/state/task-a.pr-poll")
  [ "$sidecar" = $'github\nhttps://github.com/my-org/repo_name.with-dots/pull/37\ngithub.com\nmy-org/repo_name.with-dots\n37' ] \
    || fail "published sidecar bytes were not exact"

  FM_TEST_GH_HEAD=$expected run_check_entry "$dir" task-a https://github.com/my-org/repo_name.with-dots/pull/37 \
    >/dev/null 2>/dev/null || fail "valid duplicate check failed"
  count=$(grep -c '^pr=' "$dir/home/state/task-a.meta")
  [ "$count" -eq 1 ] || fail "duplicate pr metadata was appended"
  count=$(grep -c '^pr_head=' "$dir/home/state/task-a.meta")
  [ "$count" -eq 1 ] || fail "duplicate pr_head metadata was appended"

  : > "$dir/gh.log"
  run_merge_entry "$dir" task-a https://github.com/my-org/repo_name.with-dots/pull/37 -- --merge \
    >/dev/null 2>/dev/null || fail "valid merge wrapper failed"
  grep -qxF "pr merge 37 --repo my-org/repo_name.with-dots --match-head-commit $expected --merge" "$dir/gh.log" \
    || fail "merge wrapper did not preserve repository derivation, live head, and method"
  # A merge this home performed leaves its own durable outcome, so the poll's
  # confirmation is no longer the first the captain hears of it. Acknowledge that
  # record before the watcher cycle below, which is what still retires the poll.
  assert_grep 'https://github.com/my-org/repo_name.with-dots/pull/37' "$dir/home/state/.wake-queue" \
    "a merge this home performed left no durable outcome"
  ack_watcher_cycle "$dir/home/state" || fail "merge outcome acknowledgement failed"
  # With the merge already reported, the poll's own detection is a duplicate the
  # watcher absorbs, so this cycle needs its own reason to end.
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/merged-watch.out" 2> "$dir/merged-watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "guarded merge poll retirement failed: $(cat "$dir/merged-watch.err")"
  assert_poll_absent "$dir/home/state" task-a
  assert_no_grep "merged-task-a" "$dir/home/state/.wake-queue" \
    "the drained self-merge outcome was republished by its poll"
  grep -qxF 'pr=https://github.com/my-org/repo_name.with-dots/pull/37' "$dir/home/state/task-a.meta" \
    || fail "guarded merge retirement removed pr metadata"
  grep -qxF "pr_head=$expected" "$dir/home/state/task-a.meta" \
    || fail "guarded merge retirement removed pr_head metadata"

  dir=$(make_case newline-head)
  write_task_meta "$dir"
  FM_TEST_GH_HEAD=$'0123456789abcdef0123456789abcdef01234567\nwindow=unexpected' \
    run_check_entry "$dir" task-a https://github.com/o/r/pull/2 >/dev/null 2>/dev/null \
    || fail "valid check with malformed remote head failed"
  assert_no_grep 'pr_head=' "$dir/home/state/task-a.meta" "multiline PR head reached metadata"
  assert_no_grep 'window=unexpected' "$dir/home/state/task-a.meta" "newline metadata key was injected"

  dir=$(make_case lifecycle-compatible-id)
  write_task_meta "$dir" Task_A.1
  run_merge_entry "$dir" Task_A.1 https://github.com/o/r/pull/3 \
    > "$dir/stdout" 2> "$dir/stderr" \
    || fail "safe lifecycle-compatible task ID could not use the PR merge flow"
  fm_pr_poll_artifacts_valid "$dir/home/state" Task_A.1 "$POLL" \
    || fail "safe lifecycle-compatible task ID did not publish an authenticated poll"
  ack_watcher_cycle "$dir/home/state" || fail "safe lifecycle-compatible merge acknowledgement failed"
  FM_TEST_GH_LOG="$dir/gh.log" run_merged_poll_cycle "$dir"
  assert_poll_absent "$dir/home/state" Task_A.1
  rm -rf "$dir/wt"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0700 "$dir/fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" Task_A.1 --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "safe lifecycle-compatible task ID could not be torn down: $(cat "$dir/teardown.err")"
  [ ! -e "$dir/home/state/Task_A.1.meta" ] \
    || fail "safe lifecycle-compatible task teardown retained metadata"

  for id in _noncanonical aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
    dir=$(make_case "legacy-teardown-${id:0:12}")
    fm_write_meta "$dir/home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "endpoint_task_id=$id" \
      "worktree=$dir/wt" \
      "project=$dir/project" \
      'kind=ship' \
      'mode=local-only'
    cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod 0700 "$dir/fakebin/tmux"
    touch "$dir/home/state/.last-watcher-beat"
    mkdir "$dir/home/state/$id.check.sh"
    set +e
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
      "$TEARDOWN" "$id" --force > "$dir/unsafe-teardown.out" 2> "$dir/unsafe-teardown.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "legacy task teardown accepted an unsafe direct artifact"
    [ -e "$dir/home/state/$id.meta" ] \
      || fail "legacy task teardown mutated lifecycle state before artifact refusal"
    [ -d "$dir/home/state/$id.check.sh" ] \
      || fail "legacy task teardown changed the unsafe direct artifact"
    rmdir "$dir/home/state/$id.check.sh"
    FM_HOME="$dir/home" "$ROOT/bin/fm-x-link.sh" "$id" req-legacy \
      --carry-count 0 --carry-ts 1700000000 --carry-platform x --carry-max 280 \
      > "$dir/x-link.out" 2> "$dir/x-link.err" \
      || fail "path-safe legacy task ID could not link an X request"
    run_merge_entry "$dir" "$id" https://github.com/o/r/pull/4 \
      > "$dir/merge.out" 2> "$dir/merge.err" \
      || fail "path-safe legacy task ID could not use the PR merge flow"
    fm_pr_poll_artifacts_valid "$dir/home/state" "$id" "$POLL" \
      || fail "path-safe legacy task ID did not publish an authenticated poll"
    ack_watcher_cycle "$dir/home/state" || fail "legacy path-safe merge acknowledgement failed"
    FM_TEST_GH_LOG="$dir/gh.log" run_merged_poll_cycle "$dir"
    assert_poll_absent "$dir/home/state" "$id"
    rm -rf "$dir/wt"
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
      "$TEARDOWN" "$id" --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
      || fail "legacy path-safe task ID could not be torn down: $(cat "$dir/teardown.err")"
    [ ! -e "$dir/home/state/$id.meta" ] || fail "legacy task teardown retained metadata"
  done
  pass "valid direct and merge flows record exact metadata and reject multiline head metadata"
}

# Runs one watcher under a hang guard that TERMs it and returns 124 once it has
# used sixty seconds of its own time. The guard pauses while the file named by
# FM_TEST_WATCH_BOUND_PAUSE exists, so a case that holds the watcher on work it
# injects, or makes it wait on concurrent work it started, charges that work's
# duration to itself instead of to the watcher.
# FM_TEST_CHECK_TIMEOUT sets the per-check timeout for a case that exercises it.
# Otherwise the product default applies: a tighter override silently kills a
# correct poll on a loaded machine, and the watcher then only retries it or
# exits on a later check's wake without the poll's result.
run_watcher_bounded() {
  local home=$1 fakebin=$2 check_interval=${FM_TEST_CHECK_INTERVAL:-0} watch_root=${FM_TEST_WATCH_ROOT:-$ROOT}
  local check_timeout_env=(-u FM_CHECK_TIMEOUT)
  [ -z "${FM_TEST_CHECK_TIMEOUT:-}" ] || check_timeout_env=("FM_CHECK_TIMEOUT=$FM_TEST_CHECK_TIMEOUT")
  shift 2
  perl -MPOSIX=WNOHANG -MTime::HiRes=time,sleep -e 'my $pause=shift; my $left=60; my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $last=time; while (waitpid($pid, WNOHANG) == 0) { my $now=time; $left -= $now - $last unless length $pause && -e $pause; $last=$now; if ($left <= 0) { kill "TERM", $pid; waitpid $pid, 0; exit 124 } sleep 0.02 } exit($? >> 8)' \
    "${FM_TEST_WATCH_BOUND_PAUSE:-}" env "${check_timeout_env[@]}" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$watch_root" FM_CHECK_INTERVAL="$check_interval" \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$fakebin:$BASE_PATH" "$WATCH" "$@"
}

test_rejected_metacharacter_bytes_are_inert() {
  local dir family rc before after
  dir=$(make_case rejected-metacharacters)
  write_task_meta "$dir"
  write_poll_meta "$dir/home/state" safe-check https://github.com/o/r/pull/99
  families=(
    'https://github.com/o$/r/pull/1'
    'https://github.com/o(/r/pull/1'
    'https://github.com/o)/r/pull/1'
    'https://github.com/o`/r/pull/1'
  )
  for family in "${families[@]}"; do
    rm -f "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
    set +e
    run_check_entry "$dir" task-a "$family" > /dev/null 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "rejected metacharacter byte was accepted"
    [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "rejected input left a runnable task check"
    [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "rejected input left a sidecar"
    fm_pr_poll_prepare "$dir/home/state" safe-check github https://github.com/o/r/pull/99 github.com o/r 99 "$POLL" \
      || fail "could not prepare bounded watcher poll"
    fm_pr_poll_publish_prepared || fail "could not publish bounded watcher poll"

    set +e
    FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "bounded watcher did not complete through the authenticated poll"
    rm -f "$dir/home/state/.last-check"
  done

  FM_TEST_GH_STATE=OPEN run_check_entry "$dir" task-a https://github.com/o/r/pull/1 >/dev/null 2>/dev/null \
    || fail "could not seed a prior valid static poll"
  before=$(state_snapshot "$dir/home/state")
  set +e
  run_check_entry "$dir" task-a "${families[0]}" >/dev/null 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "rejected replacement was accepted"
  after=$(state_snapshot "$dir/home/state")
  [ "$after" = "$before" ] || fail "rejected replacement changed a prior valid static poll"
  pass "rejected metacharacter bytes remain inert at generation and watcher time"
}

make_poll_fixture() {
  local dir=$1
  cp "$POLL" "$dir/home/state/task-a.check.sh"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    github https://github.com/o/r/pull/1 github.com o/r 1 > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
}

run_poll() {
  local dir=$1
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    bash "$dir/home/state/task-a.check.sh"
}

test_static_poll_contract() {
  local dir state out rc
  dir=$(make_case poll-contract)
  make_poll_fixture "$dir"

  for state in OPEN CLOSED EMPTY MALFORMED; do
    case "$state" in
      EMPTY) value= ;;
      MALFORMED) value='not-a-state' ;;
      *) value=$state ;;
    esac
    out=$(FM_TEST_GH_STATE="$value" run_poll "$dir")
    [ -z "$out" ] || fail "static poll emitted for non-merged state"
  done
  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ "$out" = merged ] || fail "static poll did not emit exactly one merged line"
  out=$(FM_TEST_GH_FAIL=1 run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted after gh failure"

  mv "$dir/home/state/task-a.pr-poll" "$dir/home/state/task-a.pr-poll.missing"
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with missing sidecar"
  mv "$dir/home/state/task-a.pr-poll.missing" "$dir/home/state/task-a.pr-poll"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' github https://github.com/o/r/pull/1 github.com o/r 1 extra > "$dir/home/state/task-a.pr-poll"
  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with multiline sidecar"
  printf '%s\n%s\n%s\n%s\n%s\n' github https://github.com/o/r/pull/1x github.com o/r 1x > "$dir/home/state/task-a.pr-poll"
  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with malformed numeric data"

  make_poll_fixture "$dir"
  set +e
  out=$(FM_STATE_OVERRIDE="$dir/home/state" FM_CHECK_TIMEOUT=1 FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_SLEEP=3 PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1"; run_check "$2"' bash "$WATCH" "$dir/home/state/task-a.check.sh")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher run_check timeout wrapper failed"
  [ -z "$out" ] || fail "timed-out static poll emitted output"

  write_poll_meta "$dir/home/state" task-a https://github.com/o/r/pull/1
  fm_pr_poll_prepare "$dir/home/state" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" \
    || fail "could not prepare authenticated watcher poll"
  fm_pr_poll_publish_prepared || fail "could not publish authenticated watcher poll"
  rm -f "$dir/home/state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher did not surface merged poll"
  [ "$(grep -c '^check: .*: merged$' "$dir/watch.out")" -eq 1 ] || fail "watcher did not convert merged output into exactly one wake"
  pass "static poll is silent except for one merged line and remains watcher-bounded"
}

test_atomic_interruption_leaves_no_partial_artifact() {
  local dir rc
  dir=$(make_case interrupted-write)
  write_task_meta "$dir"
  cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
'$REAL_CP' "\$@" || exit 1
kill -TERM "\$PPID"
exit 0
SH
  chmod +x "$dir/fakebin/cp"

  set +e
  run_check_entry "$dir" task-a https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "interrupted publication unexpectedly succeeded"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "interrupted publication left a runnable check"
  [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "interrupted publication left a sidecar"
  [ ! -e "$dir/home/state/task-a.pr-poll-registration" ] \
    || fail "interrupted publication left a registration"
  ! find "$dir/home/state" -name '.fm-pr-poll-*' -print | grep . >/dev/null \
    || fail "interrupted publication left temporary files"
  assert_no_grep 'pr=' "$dir/home/state/task-a.meta" "interrupted preparation changed metadata"
  pass "interrupted atomic preparation cleans private temporaries and publishes nothing"
}

test_concurrent_watcher_sees_only_complete_publication() {
  local n dir direct_pid direct_rc watch_pid rc i id
  # Arming also registers the contributions observer, and the watcher runs one
  # cycle's checks in name order. This task sorts first, so the watcher reaches
  # the poll under test, and stops on it, before that unrelated observer.
  id=a-task
  n=1
  while [ "$n" -le 3 ]; do
    dir=$(make_case "concurrent-$n")
    write_task_meta "$dir" "$id"
    cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
'$REAL_CP' "\$@" || exit 1
sleep 0.3
SH
    chmod +x "$dir/fakebin/cp"

    FM_TEST_GH_HEAD=0123456789abcdef0123456789abcdef01234567 \
      run_check_entry "$dir" "$id" https://github.com/o/r/pull/1 > "$dir/direct.out" 2> "$dir/direct.err" &
    direct_pid=$!
    i=0
    while [ "$i" -lt 100 ] && ! find "$dir/home/state" -name '.fm-pr-poll-check.*' -print | grep . >/dev/null; do
      sleep 0.01
      i=$((i + 1))
    done
    [ "$i" -lt 100 ] || fail "atomic publication did not reach staged check"

    # The watcher runs while publication is still in flight, and its hang
    # guard is not charged for the time it spends waiting on that publication.
    : > "$dir/direct-in-flight"
    FM_TEST_WATCH_BOUND_PAUSE="$dir/direct-in-flight" FM_TEST_GH_STATE=MERGED \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" &
    watch_pid=$!
    direct_rc=0
    wait "$direct_pid" || direct_rc=$?
    rm -f "$dir/direct-in-flight"
    rc=0
    wait "$watch_pid" || rc=$?
    [ "$direct_rc" -eq 0 ] || fail "concurrent direct arming failed"
    [ "$rc" -eq 0 ] || fail "concurrent watcher did not complete (rc=$rc): $(cat "$dir/watch.err")"
    grep -q '^check: .*: merged$' "$dir/watch.out" || fail "concurrent watcher never saw complete poll"
    [ ! -s "$dir/watch.err" ] || fail "concurrent watcher observed a partial artifact error"
    if [ -e "$dir/home/state/$id.check.sh" ]; then
      cmp -s "$POLL" "$dir/home/state/$id.check.sh" || fail "concurrent publication check bytes changed"
      [ "$(file_mode "$dir/home/state/$id.check.sh")" = 600 ] || fail "concurrent check mode was not private"
      [ "$(file_mode "$dir/home/state/$id.pr-poll")" = 600 ] || fail "concurrent sidecar mode was not private"
      [ "$(file_mode "$dir/home/state/$id.pr-poll-registration")" = 600 ] \
        || fail "concurrent registration mode was not private"
      fm_pr_poll_artifacts_valid "$dir/home/state" "$id" "$POLL" \
        || fail "concurrent publication did not leave canonical provenance"
    else
      assert_poll_absent "$dir/home/state" "$id"
    fi
    n=$((n + 1))
  done
  pass "concurrent watchers observe only complete private poll publications"
}

test_poll_publication_refuses_unsafe_destinations() {
  local artifact kind dir state destination
  for artifact in task-a.pr-poll task-a.pr-poll-registration task-a.check.sh; do
    for kind in regular dangling directory; do
      dir=$(make_case "poll-path-${artifact//./-}-$kind")
      state="$dir/home/state"
      fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" \
        || fail "could not stage poll symlink refusal fixture"
      destination="$state/$artifact"
      make_private_symlink "$dir" "$destination" "$kind"
      if fm_pr_poll_publish_prepared; then
        fail "poll publication accepted a private destination symlink"
      fi
      fm_pr_poll_cleanup
      assert_private_symlink_unchanged "$destination"
      [ ! -e "$state/task-a.pr-poll" ] || [ "$artifact" = task-a.pr-poll ] \
        || fail "check destination refusal published the sidecar"
    done

    dir=$(make_case "poll-path-${artifact//./-}-direct-directory")
    state="$dir/home/state"
    fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" \
      || fail "could not stage poll directory refusal fixture"
    destination="$state/$artifact"
    mkdir "$destination"
    if fm_pr_poll_publish_prepared; then
      fail "poll publication accepted a directory destination"
    fi
    fm_pr_poll_cleanup
    [ -d "$destination" ] || fail "poll publication replaced a directory destination"
    [ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print)" ] \
      || fail "poll publication wrote inside a directory destination"
  done
  pass "poll publication paths refuse symlinks and directories"
}

test_live_artifact_single_link_and_privacy_validation() {
  local artifact dir state alias rc
  for artifact in check.sh pr-poll pr-poll-registration; do
    dir=$(make_case "single-link-live-${artifact//./-}")
    state="$dir/home/state"
    write_task_meta "$dir"
    run_check_entry "$dir" task-a https://github.com/o/r/pull/10 >/dev/null 2>/dev/null \
      || fail "could not publish $artifact hard-link fixture"
    fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
      || fail "$artifact fixture was not initially authenticated"
    alias="$dir/$artifact.alias"
    ln "$state/task-a.$artifact" "$alias"
    if [ "$artifact" = pr-poll ]; then
      printf '%s\n%s\n%s\n%s\n' https://github.com/o/r/pull/11 o r 11 > "$alias"
    fi
    ! fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
      || fail "$artifact hard link remained authenticated"
    [ -e "$alias" ] || fail "$artifact hard-link refusal removed the external alias"
  done

  dir=$(make_case single-link-custom-check-registration)
  state="$dir/home/state"
  printf '#!/usr/bin/env bash\nprintf "custom-ready\\n"\n' > "$state/custom.check.sh"
  chmod 0700 "$state/custom.check.sh"
  alias="$dir/custom-check.alias"
  ln "$state/custom.check.sh" "$alias"
  set +e
  FM_HOME="$dir/home" "$REGISTER" custom > "$dir/register.out" 2> "$dir/register.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "custom check registration accepted a hard-linked source"
  [ ! -e "$state/custom.check-trust" ] || fail "rejected hard-linked custom check received a trust record"
  rm -f "$alias"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null \
    || fail "could not register the custom check single-link fixture"
  ln "$state/custom.check.sh" "$alias"
  ! fm_custom_check_registered "$state" custom \
    || fail "registered custom check remained authenticated after source hard-linking"
  ! fm_custom_check_snapshot_prepare "$state" custom \
    || fail "watcher snapshot accepted a hard-linked custom check source"
  fm_custom_check_snapshot_cleanup
  rm -f "$alias"
  alias="$dir/custom-trust.alias"
  ln "$state/custom.check-trust" "$alias"
  ! fm_custom_check_registered "$state" custom \
    || fail "hard-linked custom check trust remained authenticated"
  ! fm_custom_check_snapshot_prepare "$state" custom \
    || fail "watcher snapshot accepted a hard-linked custom check trust record"
  fm_custom_check_snapshot_cleanup
  [ -e "$alias" ] || fail "custom-check hard-link refusal removed the external alias"

  dir=$(make_case private-custom-check-source)
  state="$dir/home/state"
  printf '#!/usr/bin/env bash\nprintf "custom-ready\\n"\n' > "$state/custom.check.sh"
  chmod 0755 "$state/custom.check.sh"
  set +e
  FM_HOME="$dir/home" "$REGISTER" custom > "$dir/register.out" 2> "$dir/register.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "custom check registration accepted a non-private source"
  [ ! -e "$state/custom.check-trust" ] || fail "non-private custom check received a trust record"
  chmod 0700 "$state/custom.check.sh"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null \
    || fail "could not register private custom check fixture"
  chmod 0755 "$state/custom.check.sh"
  ! fm_custom_check_registered "$state" custom \
    || fail "registered custom check remained authenticated after becoming non-private"
  ! fm_custom_check_snapshot_prepare "$state" custom \
    || fail "watcher snapshot accepted a non-private custom check source"
  fm_custom_check_snapshot_cleanup
  pass "live poll and custom-check artifacts require private single-link files"
}

install_final_publication_fault() {
  local dir=$1
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
"${FM_TEST_REAL_MV:?}" "$@" || exit $?
[ "$last" = "${FM_TEST_FINAL_PATH:?}" ] || exit 0
case "${FM_TEST_FINAL_ACTION:?}" in
  type)
    rm -f -- "$last"
    ln -s "${FM_TEST_FAULT_LINK_TARGET:?}" "$last"
    ;;
  mode) "${FM_TEST_REAL_CHMOD:?}" 0644 "$last" ;;
  content) printf 'faulted final bytes\n' > "$last" ;;
  device) : > "${FM_TEST_FAULT_GATE:?}" ;;
  *) exit 2 ;;
esac
SH
  cat > "$dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_FINAL_PATH:-}" ] && [ -e "${FM_TEST_FAULT_GATE:-/nonexistent}" ]; then
  case " $* " in
    *" %d "*) printf '%s\n' 999999; exit 0 ;;
  esac
fi
exec "${FM_TEST_REAL_STAT:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv" "$dir/fakebin/stat"
}

assert_no_final_poll() {
  local state=$1
  [ ! -e "$state/task-a.check.sh" ] && [ ! -L "$state/task-a.check.sh" ] \
    || fail "failed publication left a runnable check name"
  [ ! -e "$state/task-a.pr-poll" ] && [ ! -L "$state/task-a.pr-poll" ] \
    || fail "failed publication left a sidecar name"
  [ ! -e "$state/task-a.pr-poll-registration" ] && [ ! -L "$state/task-a.pr-poll-registration" ] \
    || fail "failed publication left a registration name"
}

test_postrename_poll_validation_revokes_and_retries() {
  local artifact action dir state destination link_target gate
  for artifact in data registration check; do
    for action in type mode device content; do
      # The device fault is injected by a fake stat on PATH; on Darwin the
      # device helper now calls /usr/bin/stat directly, so the fake can never
      # fire there. Skip the device action on Darwin.
      if [ "$action" = device ] && [ "$(uname)" = Darwin ]; then
        continue
      fi
      dir=$(make_case "poll-final-$artifact-$action")
      state="$dir/home/state"
      write_poll_meta "$state" task-a https://github.com/o/r/pull/1
      fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" \
        || fail "could not prepare prior poll"
      fm_pr_poll_publish_prepared || fail "could not publish prior poll"
      write_poll_meta "$state" task-a https://github.com/o/r/pull/2
      fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/2 github.com o/r 2 "$POLL" \
        || fail "could not stage replacement poll"
      case "$artifact" in
        data) destination="$state/task-a.pr-poll" ;;
        registration) destination="$state/task-a.pr-poll-registration" ;;
        check) destination="$state/task-a.check.sh" ;;
      esac
      link_target="$dir/external-sentinel"
      gate="$dir/device-fault"
      printf 'external sentinel\n' > "$link_target"
      chmod 0644 "$link_target"
      install_final_publication_fault "$dir"
      if FM_TEST_FINAL_PATH="$destination" FM_TEST_FINAL_ACTION="$action" \
        FM_TEST_FAULT_LINK_TARGET="$link_target" FM_TEST_FAULT_GATE="$gate" \
        FM_TEST_REAL_MV="$REAL_MV" FM_TEST_REAL_STAT="$REAL_STAT" FM_TEST_REAL_CHMOD="$REAL_CHMOD" \
        PATH="$dir/fakebin:$BASE_PATH" fm_pr_poll_publish_prepared; then
        fail "post-rename $artifact $action fault was reported as success"
      fi
      fm_pr_poll_cleanup
      assert_no_final_poll "$state"
      [ "$(cat "$link_target")" = 'external sentinel' ] || fail "poll type fault changed an external target"
      [ "$(file_mode "$link_target")" = 644 ] || fail "poll type fault changed an external target mode"

      fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/2 github.com o/r 2 "$POLL" \
        || fail "could not prepare poll retry"
      PATH="$BASE_PATH" fm_pr_poll_publish_prepared || fail "poll retry did not recover after final validation fault"
      fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "poll retry did not publish a valid pair"
    done
  done
  pass "post-rename poll validation faults revoke both names and allow a clean retry"
}

test_bootstrap_leaves_unauthenticated_checks() {
  local dir state
  dir=$(make_case bootstrap-no-legacy-rewrite)
  state="$dir/home/state"
  fm_write_meta "$state/task-a.meta" \
    'window=fm-task-a' \
    'pr=https://github.com/o/r/pull/11'
  printf 'legacy bytes\n' > "$state/task-a.check.sh"
  chmod 0700 "$state/task-a.check.sh"

  mkdir -p "$dir/home/config"
  printf '%s\n' manual > "$dir/home/config/backlog-backend"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-bootstrap.sh" > "$dir/bootstrap.out" 2> "$dir/bootstrap.err" \
    || fail "bootstrap failed after migration retirement"
  [ "$(cat "$state/task-a.check.sh")" = 'legacy bytes' ] \
    || fail "bootstrap rewrote an unauthenticated check after migration retirement"
  assert_no_grep 'PR_CHECK_MIGRATION' "$dir/bootstrap.out" \
    "bootstrap still emitted a retired migration diagnostic on stdout"
  assert_no_grep 'PR_CHECK_MIGRATION' "$dir/bootstrap.err" \
    "bootstrap still emitted a retired migration diagnostic on stderr"
  pass "bootstrap does not rewrite unauthenticated checks or emit retired migration diagnostics"
}

test_custom_snapshot_cleanup_on_signal() {
  local dir state child_pid_file pid child_pid i rc
  dir=$(make_case custom-snapshot-signal)
  state="$dir/home/state"
  child_pid_file="$dir/custom-child.pid"
  # shellcheck disable=SC2016  # The generated child expands $$ when it runs.
  printf '%s\n' '#!/usr/bin/env bash' 'trap "" TERM' \
    'printf "%s\n" "$$" > "$FM_TEST_CUSTOM_CHILD_PID"' 'while :; do sleep 1; done' \
    > "$state/custom.check.sh"
  chmod 0700 "$state/custom.check.sh"
  cat > "$dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
"$@" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; exit 124' TERM
wait "$child"
SH
  chmod 0700 "$dir/fakebin/timeout"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null \
    || fail "could not register signal cleanup custom check"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=0 FM_CHECK_INTERVAL=0 \
    FM_SIGNAL_GRACE=0 FM_TEST_CUSTOM_CHILD_PID="$child_pid_file" \
    PATH="$dir/fakebin:$BASE_PATH" "$WATCH" \
    > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$child_pid_file" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$child_pid_file" ] || fail "watcher did not start the custom check child"
  find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
    || fail "watcher did not create the custom check snapshot"
  child_pid=$(cat "$child_pid_file")
  kill -TERM "$pid" 2>/dev/null || fail "could not signal watcher during custom check"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "signaled watcher did not exit promptly"
  fi
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "signaled watcher exited successfully"
  ! kill -0 "$child_pid" 2>/dev/null || fail "signaled watcher left the custom check child running"
  ! find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
    || fail "signaled watcher left a private custom check snapshot"
  ! find "$state" -maxdepth 1 -name '.fm-check-output.*' -print | grep . >/dev/null \
    || fail "signaled watcher left a private check output file"
  [ ! -e "$state/.watch.lock/pid" ] || fail "signaled watcher left its singleton lock"
  pass "watcher signals promptly stop custom checks and clean private state"
}

test_returned_custom_check_descendants_are_drained() {
  local backend dir state fakebin ready direct_done child_pid_file child_pid check rc force_fallback
  for backend in installed-timeout fallback-timeout; do
    dir=$(make_case "returned-custom-descendant-$backend")
    state="$dir/home/state"
    fakebin="$dir/fakebin"
    ready="$dir/descendant-ready"
    direct_done="$dir/direct-check-done"
    child_pid_file="$dir/descendant.pid"
    # The descendant ignores TERM and never exits on its own while this case's
    # directory exists, so its absence can only mean the watcher drained it.
    cat > "$state/custom.check.sh" <<'SH'
#!/usr/bin/env bash
perl -e '$SIG{TERM}="IGNORE"; open my $ready, ">", $ENV{FM_TEST_DESCENDANT_READY} or die $!; print {$ready} "ready\n"; close $ready; select undef, undef, undef, 0.2 while -d $ENV{FM_TEST_DESCENDANT_HOLD}' &
printf '%s\n' "$!" > "$FM_TEST_DESCENDANT_PID"
while [ ! -s "$FM_TEST_DESCENDANT_READY" ]; do sleep 0.01; done
: > "$FM_TEST_DIRECT_DONE"
SH
    # The watcher runs this check next in the same cycle, only after it has
    # finished with the returned one, so its wake both records whether the
    # descendant outlived that drain and stops the watcher.
    cat > "$state/z-drain-witness.check.sh" <<'SH'
#!/usr/bin/env bash
case "$(ps -o stat= -p "$(cat "$FM_TEST_DESCENDANT_PID")" 2>/dev/null)" in
  ''|Z*) printf 'descendant drained\n' ;;
  *) printf 'descendant alive\n' ;;
esac
SH
    for check in custom z-drain-witness; do
      chmod 0700 "$state/$check.check.sh"
      FM_HOME="$dir/home" "$REGISTER" "$check" >/dev/null \
        || fail "could not register $backend returned-descendant $check check"
    done
    if [ "$backend" = installed-timeout ]; then
      cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
      chmod 0700 "$fakebin/timeout"
      force_fallback=0
    else
      rm -f "$fakebin/timeout" "$fakebin/gtimeout"
      force_fallback=1
    fi

    rc=0
    FM_TEST_CHECK_TIMEOUT=10 FM_CHECK_FORCE_FALLBACK="$force_fallback" \
      FM_TEST_DESCENDANT_READY="$ready" FM_TEST_DESCENDANT_HOLD="$dir" \
      FM_TEST_DESCENDANT_PID="$child_pid_file" FM_TEST_DIRECT_DONE="$direct_done" \
      run_watcher_bounded "$dir/home" "$fakebin" > "$dir/watch.out" 2> "$dir/watch.err" || rc=$?
    child_pid=$(cat "$child_pid_file" 2>/dev/null || true)
    if [ -n "$child_pid" ] && process_is_live_non_zombie "$child_pid"; then
      kill -KILL "$child_pid" 2>/dev/null || true
      fail "$backend watcher left a returned check descendant alive"
    fi
    [ "$rc" -eq 0 ] \
      || fail "$backend watcher did not stop after the direct check returned (rc=$rc): $(cat "$dir/watch.err")"
    [ -s "$ready" ] && [ -n "$child_pid" ] && [ -e "$direct_done" ] \
      || fail "$backend watcher did not complete the direct custom check"
    grep -qxF "check: $state/z-drain-witness.check.sh: descendant drained" "$dir/watch.out" \
      || fail "$backend watcher moved past a returned check before draining its descendant: $(cat "$dir/watch.out")"
    ! find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
      || fail "$backend watcher left a private custom check snapshot"
    ! find "$state" -maxdepth 1 -name '.fm-check-output.*' -print | grep . >/dev/null \
      || fail "$backend watcher left a private check output file"
    [ ! -e "$state/.watch.lock/pid" ] || fail "$backend watcher left its singleton lock"
  done
  pass "returned custom check descendants are drained on installed and fallback timeout paths"
}

test_teardown_removes_poll_artifacts() {
  local dir fakebin artifact counterpart rc before
  dir=$(make_case teardown-cleanup)
  fakebin="$dir/fakebin"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only'
  printf 'check\n' > "$dir/home/state/task-a.check.sh"
  printf 'data\n' > "$dir/home/state/task-a.pr-poll"
  printf 'registration\n' > "$dir/home/state/task-a.pr-poll-registration"
  printf 'dropped\n' > "$dir/home/state/task-a.pr-poll-queue-dropped"
  printf 'trust\n' > "$dir/home/state/task-a.check-trust"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "teardown cleanup fixture failed"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "teardown left the runnable check"
  [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "teardown left the sidecar"
  [ ! -e "$dir/home/state/task-a.pr-poll-registration" ] || fail "teardown left the PR poll registration"
  [ ! -e "$dir/home/state/task-a.pr-poll-queue-dropped" ] || fail "teardown left the queue departure marker"
  [ ! -e "$dir/home/state/task-a.check-trust" ] || fail "teardown left the custom check registration"

  dir=$(make_case teardown-retirement-receipt)
  fakebin="$dir/fakebin"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only' \
    'pr=https://github.com/o/r/pull/18'
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/18
  fm_pr_poll_snapshot_capture "$dir/home/state" task-a "$POLL" \
    || fail "could not snapshot teardown receipt fixture"
  fm_pr_poll_retirement_publish "$dir/home/state" task-a "$POLL" merged \
    || fail "could not publish teardown receipt fixture"
  rm -f "$dir/home/state/task-a.check.sh"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"
  before=$(poll_artifact_snapshot "$dir/home/state" task-a)
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown bypassed a pending repository sweep"
  grep -F 'REFUSED: pending repository merge-queue sweep; preserving task state.' "$dir/teardown.err" >/dev/null \
    || fail "teardown refused for a reason other than its pending sweep: $(cat "$dir/teardown.err")"
  [ "$(poll_artifact_snapshot "$dir/home/state" task-a)" = "$before" ] \
    || fail "refused teardown changed the pending retirement artifacts"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  FM_TEST_GH_LOG="$dir/gh.log" run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "teardown receipt sweep failed: $(cat "$dir/watch.err")"
  assert_poll_absent "$dir/home/state" task-a
  ack_watcher_cycle "$dir/home/state" || fail "teardown receipt sweep acknowledgement failed"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "teardown failed after the repository sweep: $(cat "$dir/teardown.err")"
  [ ! -e "$dir/home/state/task-a.meta" ] || fail "receipt-aware teardown left task metadata"

  for artifact in check.sh pr-poll; do
    dir=$(make_case "teardown-final-directory-${artifact//./-}")
    fakebin="$dir/fakebin"
    fm_write_meta "$dir/home/state/task-a.meta" \
      'window=firstmate:fm-task-a' \
      'endpoint_task_id=task-a' \
      "worktree=$dir/missing-worktree" \
      "project=$dir/project" \
      'kind=ship' \
      'mode=local-only'
    if [ "$artifact" = check.sh ]; then
      counterpart=pr-poll
    else
      counterpart=check.sh
    fi
    mkdir "$dir/home/state/task-a.$artifact"
    printf 'directory sentinel\n' > "$dir/home/state/task-a.$artifact/sentinel"
    printf 'counterpart sentinel\n' > "$dir/home/state/task-a.$counterpart"
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
exit 0
SH
    chmod +x "$fakebin/tmux"
    touch "$dir/home/state/.last-watcher-beat"
    set +e
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_TMUX_LOG="$dir/tmux.log" \
      PATH="$fakebin:$BASE_PATH" "$TEARDOWN" task-a --force \
      > "$dir/teardown.out" 2> "$dir/teardown.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "teardown accepted a directory-shaped $artifact"
    [ -e "$dir/home/state/task-a.meta" ] || fail "teardown removed metadata before $artifact refusal"
    [ "$(cat "$dir/home/state/task-a.$artifact/sentinel")" = 'directory sentinel' ] \
      || fail "teardown changed the directory-shaped $artifact"
    [ "$(cat "$dir/home/state/task-a.$counterpart")" = 'counterpart sentinel' ] \
      || fail "teardown removed the counterpart before $artifact refusal"
    grep -F 'kill-window' "$dir/tmux.log" >/dev/null 2>&1 \
      && fail "teardown killed the endpoint before $artifact refusal"
  done

  pass "teardown removes safe poll artifacts and refuses directory-shaped check files without traversal"
}

# The Gerrit watch must follow a change exactly as the GitHub watch follows a
# pull request, on any server, and must never turn an unreadable or merely
# submittable change into a merge. Its evidence against a real change is in
# docs/gerrit-change-watch.md; this exercises the same paths hermetically.
test_gerrit_merge_watch() {
  local dir state out rc url value notool entry bindir name tool
  dir=$(make_case gerrit-merge-watch)
  state="$dir/home/state"
  url=https://gerrit.example/c/group/apps/console/+/4201
  # The Gerrit branch reads its status with the real jq, and BASE_PATH is
  # deliberately restricted, so this exposes jq explicitly rather than depending
  # on the host keeping it in one of those four directories.
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"

  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a gerrit "$url" gerrit.example group/apps/console 4201 "$POLL" \
    || fail "could not prepare a Gerrit poll"
  fm_pr_poll_publish_prepared || fail "could not publish a Gerrit poll"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "published Gerrit poll provenance or metadata binding was invalid"
  [ "$(cat "$state/task-a.pr-poll")" = "gerrit
$url
gerrit.example
group/apps/console
4201" ] || fail "published Gerrit sidecar bytes were not exact"

  # Only an exact MERGED status wakes firstmate. Every other reading, including
  # an abandoned change, a lowercase spelling, and a changed format, stays
  # silent rather than reporting a merge.
  for value in NEW ABANDONED merged Merged MERGED_LATER '' not-a-status; do
    out=$(FM_TEST_GERRIT_STATUS="$value" run_poll "$dir")
    [ -z "$out" ] || fail "Gerrit poll emitted for status '$value'"
  done

  # Readiness is not merge. A change that is fully submittable - nothing in its
  # blocked_on list, submit OK, submittable true - is exactly what an approved
  # but unsubmitted change looks like, and a merged change reports the same
  # three fields. Only the status separates them, so only the status is read.
  out=$(FM_TEST_GERRIT_STATUS=NEW FM_TEST_GERRIT_SUBMIT=OK \
    FM_TEST_GERRIT_SUBMITTABLE=true FM_TEST_GERRIT_BLOCKED_ON='' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll read a submittable open change as merged"

  out=$(FM_TEST_GERRIT_STATUS=MERGED FM_TEST_GERRIT_SUBMIT=OK \
    FM_TEST_GERRIT_SUBMITTABLE=true FM_TEST_GERRIT_BLOCKED_ON='' run_poll "$dir")
  [ "$out" = merged ] || fail "Gerrit poll did not emit exactly one merged line"

  out=$(FM_TEST_GERRIT_FAIL=1 FM_TEST_GERRIT_STATUS=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted after a gerrit-axi failure"
  out=$(FM_TEST_GERRIT_RAW='not json at all' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for unparseable output"
  out=$(FM_TEST_GERRIT_RAW='{"ok":false,"error":"unauthenticated"}' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a typed error record"
  out=$(FM_TEST_GERRIT_RAW='{"ok":true,"changes":[]}' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a record naming no change"

  # A record for some other change can never wake this task's poll, however the
  # server came to return it. The change number is what names the change, and
  # --host is what pins the server.
  out=$(FM_TEST_GERRIT_STATUS=MERGED FM_TEST_GERRIT_CHANGE=4202 run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for another change's record"
  out=$(FM_TEST_GERRIT_RAW='{"ok":true,"op":"show","changes":[{"change":4202,"status":"MERGED","url":null}]}' \
    run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for another change's url-less record"

  # Gerrit composes a change's url field from gerrit.canonicalWebUrl and omits
  # it when that setting is unset, so a merge must still be reported when the
  # server returns the field null or does not return it at all. Comparing it
  # against the stored URL is what would leave such a watch silent forever.
  out=$(FM_TEST_GERRIT_RAW='{"ok":true,"op":"show","changes":[{"change":4201,"status":"MERGED","url":null}]}' \
    run_poll "$dir")
  [ "$out" = merged ] || fail "Gerrit poll stayed silent for a merged change with a null url"
  out=$(FM_TEST_GERRIT_RAW='{"ok":true,"op":"show","changes":[{"change":4201,"status":"MERGED"}]}' \
    run_poll "$dir")
  [ "$out" = merged ] || fail "Gerrit poll stayed silent for a merged change with no url field"
  out=$(FM_TEST_GERRIT_STATUS=MERGED \
    FM_TEST_GERRIT_URL=https://alias.example/c/group/apps/console/+/4201 run_poll "$dir")
  [ "$out" = merged ] || fail "Gerrit poll stayed silent for a merged change behind an alias host"

  # A free-text subject carrying the merged spelling and the field separators
  # cannot forge a status, because the status is read from the structured
  # record rather than off a rendered line.
  out=$(FM_TEST_GERRIT_STATUS=NEW \
    FM_TEST_GERRIT_SUBJECT='"status: MERGED,MERGED,merged"' run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll read a merged spelling out of a change subject"

  # gerrit-axi resolves its server from the current directory's origin remote
  # first, and the watcher runs in no repository, so the host must be passed
  # explicitly or the tool answers as though the change did not exist.
  grep -qF -- "show 4201 --host gerrit.example --json" "$dir/gerrit-axi.log" \
    || fail "Gerrit poll did not address gerrit-axi by change number and explicit host"
  ! grep -qF -- "$url" "$dir/gerrit-axi.log" \
    || fail "Gerrit poll passed a change URL to gerrit-axi"

  # An absent CLI must produce no wake rather than a false merge, for either
  # tool the Gerrit branch needs. The whole search path is mirrored without it,
  # because a real one anywhere on PATH would make this prove nothing.
  for tool in gerrit-axi jq; do
    notool="$dir/no-$tool"
    rm -rf "$notool"
    mkdir -p "$notool"
    while IFS= read -r bindir; do
      [ -d "$bindir" ] || continue
      for entry in "$bindir"/*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")
        [ "$name" = "$tool" ] && continue
        [ -e "$notool/$name" ] || ln -s "$entry" "$notool/$name" 2>/dev/null
      done
    done <<EOF
$dir/fakebin
$(printf '%s\n' "$BASE_PATH" | tr ':' '\n')
EOF
    ! PATH="$notool" command -v "$tool" >/dev/null 2>&1 \
      || fail "the $tool-free search path still resolved $tool"
    out=$(FM_TEST_GERRIT_STATUS=MERGED FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" \
      PATH="$notool" bash "$state/task-a.check.sh")
    [ -z "$out" ] || fail "Gerrit poll emitted with $tool absent from PATH"

    # Arming is where a missing CLI can still be reported, so it refuses there.
    write_task_meta "$dir" "task-no-$tool"
    set +e
    out=$(FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
      FM_TEST_GUARD_LOG="$dir/guard.log" PATH="$notool" \
      "$PR_CHECK" "task-no-$tool" "$url" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "arming a Gerrit watch succeeded with $tool absent"
    case "$out" in
      *"requires $tool on PATH"*) ;;
      *) fail "arming a Gerrit watch with $tool absent did not report the missing CLI" ;;
    esac
    [ ! -e "$state/task-no-$tool.check.sh" ] || fail "refused Gerrit arming left a poll armed"
  done

  # A doctored sidecar cannot redirect the poll: the stored parts must rebuild
  # the stored URL exactly.
  printf '%s\n%s\n%s\n%s\n%s\n' gerrit "$url" elsewhere.example group/apps/console 4201 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GERRIT_STATUS=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a sidecar whose host was swapped"
  printf '%s\n%s\n%s\n%s\n%s\n' gerrit "$url" gerrit.example group/apps/other 4201 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GERRIT_STATUS=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a sidecar whose project was swapped"
  printf '%s\n%s\n%s\n%s\n%s\n' gerrit "$url" gerrit.example group/apps/console 4202 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GERRIT_STATUS=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Gerrit poll emitted for a sidecar whose change number was swapped"

  pass "the Gerrit watch wakes only on an explicit merged status and never on submittability"
}

# Arming a Gerrit watch records the canonical change identity and no pr_head.
# A Gerrit revision names one patch set, and bin/fm-review-diff.sh has no Gerrit
# path to resolve a current head with, so a recorded revision would quietly
# become the reviewed content after the next amend.
test_gerrit_arming_records_no_patch_set_revision() {
  local dir state rc out
  dir=$(make_case gerrit-arming)
  state="$dir/home/state"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"

  write_task_meta "$dir" task-rev
  FM_TEST_GERRIT_REVISION=$(git -C "$dir/wt" rev-parse HEAD) run_check_entry "$dir" task-rev \
    https://gerrit.example/c/group/apps/console/+/4201 >/dev/null \
    || fail "arming a Gerrit watch failed"
  grep -qxF 'pr=https://gerrit.example/c/group/apps/console/+/4201' "$state/task-rev.meta" \
    || fail "arming did not record the canonical Gerrit change URL"
  grep -q '^pr_head=' "$state/task-rev.meta" \
    && fail "arming recorded a Gerrit patch set revision as pr_head"
  [ -e "$state/task-rev.check.sh" ] || fail "arming a Gerrit watch left no poll armed"

  # Submitting a Gerrit change is refused outright, before anything is read or
  # recorded, rather than left as a silently absent provider branch.
  set +e
  out=$(run_merge_entry "$dir" task-rev \
    https://gerrit.example/c/group/apps/console/+/4201 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the merge path accepted a Gerrit change"
  case "$out" in
    *"does not submit a Gerrit change"*) ;;
    *) fail "the Gerrit merge refusal did not say firstmate does not submit" ;;
  esac
  [ ! -e "$state/task-rev.merge-authority" ] || fail "a refused Gerrit merge recorded merge authority"

  pass "Gerrit arming records no patch set revision and the merge path refuses to submit"
}

# A push to refs/for/ leaves no ref a fetch can see, so a remote-tracking ref
# that holds the worker's HEAD - the no-mistakes gate branch after a pipeline
# run - says nothing about what was published. Arming accepts the named head
# only when a live read shows the change's current patch set carrying that
# HEAD's tree - the squash is a new commit on the server's base, so the tree and
# not the commit names what was published - and refuses otherwise, before
# anything is recorded or armed. Once arming has recorded the change as pr=, a
# later done naming it is accepted from that record without a read, so a
# reviewer's rebase or new patch set on the server does not revoke it.
test_gerrit_ready_gate_reads_the_published_tree() {
  local dir state base published other out rc
  dir=$(make_case gerrit-ready-gate)
  state="$dir/home/state"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  base=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'one\n' > "$dir/wt/a"
  git -C "$dir/wt" add a
  git -C "$dir/wt" commit -q -m first
  printf 'two\n' > "$dir/wt/b"
  git -C "$dir/wt" add b
  git -C "$dir/wt" commit -q -m second
  git -C "$dir/wt" update-ref refs/remotes/no-mistakes/fm/task "$(git -C "$dir/wt" rev-parse HEAD)"
  published=$(git -C "$dir/wt" commit-tree "$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')" -p "$base" -m squashed)
  other=$(git -C "$dir/wt" rev-parse HEAD~1)
  [ "$(git -C "$dir/wt" rev-parse "$published^{tree}")" != "$(git -C "$dir/wt" rev-parse "$other^{tree}")" ] \
    || fail "the fixture's two revisions carry the same tree"

  write_task_meta "$dir" task-mismatch
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$other run_check_entry "$dir" task-mismatch \
    https://gerrit.example/c/group/apps/console/+/4201 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a change whose patch set is not this copy's HEAD tree"
  case "$out" in
    *"not the published content"*) ;;
    *) fail "the refusal did not say the change does not carry the named head: $out" ;;
  esac
  grep -q '^pr=' "$state/task-mismatch.meta" && fail "a refused Gerrit arming recorded pr="
  [ ! -e "$state/task-mismatch.check.sh" ] || fail "a refused Gerrit arming armed a poll"

  write_task_meta "$dir" task-unknown
  set +e
  FM_TEST_GERRIT_REVISION=0123456789abcdef0123456789abcdef01234567 run_check_entry "$dir" task-unknown \
    https://gerrit.example/c/group/apps/console/+/4201 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a patch set this copy has never held"

  write_task_meta "$dir" task-unread
  set +e
  FM_TEST_GERRIT_FAIL=1 run_check_entry "$dir" task-unread \
    https://gerrit.example/c/group/apps/console/+/4201 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a change it could not read"

  : > "$dir/gerrit-axi.log"
  write_task_meta "$dir" task-published
  FM_TEST_GERRIT_REVISION=$published run_check_entry "$dir" task-published \
    https://gerrit.example/c/group/apps/console/+/4201 >/dev/null \
    || fail "arming refused a change whose current patch set carries this copy's HEAD tree"
  grep -qF -- "show 4201 --host gerrit.example --json" "$dir/gerrit-axi.log" \
    || fail "the gate did not read the change from its own server"
  [ -e "$state/task-published.check.sh" ] || fail "an accepted Gerrit arming left no poll armed"
  grep -q '^pr_head=' "$state/task-published.meta" \
    && fail "the gate's live revision was recorded as pr_head"

  git -C "$dir/wt" update-ref -d refs/remotes/no-mistakes/fm/task
  : > "$dir/gerrit-axi.log"
  set +e
  out=$(FM_TEST_GERRIT_REVISION=0123456789abcdef0123456789abcdef01234567 \
    FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-dod-lib.sh"
      fm_dod_accept_ship_done ship no-mistakes "$2" "$3" "$4" "$5" task-published "$6"' \
    _ "$ROOT" "$dir/wt" "$dir/project" \
    "done: PR https://gerrit.example/c/group/apps/console/+/4201 published for review" \
    "$state" "$state/task-published.meta" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a server-side rebase after arming revoked the recorded change's done: $out"
  [ ! -s "$dir/gerrit-axi.log" ] || fail "a done naming the recorded change read the server again"
  pass "Gerrit arming accepts a published HEAD only by the change's current patch set tree"
}

# On a Gerrit project the pipeline's push is skipped, so a fix round's commits
# stay in its local gate until the worker recovers custody. A worker that
# publishes before recovering has an unfixed HEAD and an unfixed patch set that
# agree, so the published-tree check alone accepts it. A no-mistakes ready
# report on a Gerrit change must therefore also show the copy holds the run's
# result: refused while the run still holds the branch, when HEAD's tree is not
# the pipeline head's, or when the run cannot be read; accepted once recovered,
# even after the publish's Change-Id stamp rewrote the branch's messages.
test_gerrit_nm_ready_gate_requires_recovered_custody() {
  local dir state base unfixed fixed stamped squash elsewhere out rc url line
  dir=$(make_case gerrit-custody-gate)
  state="$dir/home/state"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  url=https://gerrit.example/c/group/apps/console/+/4201
  line="done: PR $url published for review"
  base=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'flawed\n' > "$dir/wt/doc"
  git -C "$dir/wt" add doc
  git -C "$dir/wt" commit -q -m "Document the value"
  unfixed=$(git -C "$dir/wt" rev-parse HEAD)
  # The pipeline's fix commit exists only in its gate: build it in another repo,
  # so this copy does not hold its object, exactly as before recovery.
  elsewhere="$dir/gate-only"
  git clone -q "$dir/wt" "$elsewhere"
  printf 'fixed\n' > "$elsewhere/doc"
  git -C "$elsewhere" commit -q -am "no-mistakes(review): Correct the documented value"
  fixed=$(git -C "$elsewhere" rev-parse HEAD)
  git -C "$dir/wt" cat-file -e "$fixed" 2>/dev/null && fail "the fixture copy already holds the pipeline's fix"

  # Case A from the live test: the server holds the unfixed patch set, which
  # matches the unrecovered HEAD, and the run reports custody unreturned.
  write_task_meta "$dir" task-unrecovered
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_PIPELINE_HEAD=$fixed \
    FM_TEST_NM_NEXT_ACTION=recover_custody run_check_entry "$dir" task-unrecovered "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish of the head before the pipeline's fixes were recovered"
  case "$out" in
    *"still holds this copy's branch"*) ;;
    *) fail "the refusal did not say the run still holds the branch: $out" ;;
  esac
  grep -q '^pr=' "$state/task-unrecovered.meta" && fail "a refused unrecovered publish recorded pr="
  [ ! -e "$state/task-unrecovered.check.sh" ] || fail "a refused unrecovered publish armed a poll"

  # The same state with no next action reported still refuses on the trees.
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_PIPELINE_HEAD=$fixed run_check_entry "$dir" task-unrecovered "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a copy whose HEAD is not the run's result"
  case "$out" in
    *"does not carry the no-mistakes run's result"*) ;;
    *) fail "the refusal did not say the copy lacks the run's result: $out" ;;
  esac

  set +e
  FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_NEXT_ACTION=continue_active_run \
    run_check_entry "$dir" task-unrecovered "$url" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish while the run is still active"

  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_FAIL=1 run_check_entry "$dir" task-unrecovered "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish whose no-mistakes run could not be read"
  case "$out" in
    *"could not be read"*) ;;
    *) fail "the refusal did not say the run could not be read: $out" ;;
  esac

  # A failed run whose own head was published has nothing to recover, so the
  # trees agree; its outcome alone refuses it, as does a missing outcome.
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_OUTCOME=failed run_check_entry "$dir" task-unrecovered "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish of a failed no-mistakes run"
  case "$out" in
    *"has outcome failed, not a pass"*) ;;
    *) fail "the refusal did not name the run's failed outcome: $out" ;;
  esac
  grep -q '^pr=' "$state/task-unrecovered.meta" && fail "a refused failed-run publish recorded pr="
  set +e
  FM_TEST_GERRIT_REVISION=$unfixed FM_TEST_NM_OUTCOME='' run_check_entry "$dir" task-unrecovered "$url" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming accepted a publish of a run with no outcome"

  # A published-for-review done whose URL is not a canonical Gerrit change is
  # refused, even though a gate push left HEAD on a remote-tracking ref.
  git -C "$dir/wt" update-ref refs/remotes/no-mistakes/fm/task "$unfixed"
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$unfixed PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-dod-lib.sh"
      fm_dod_accept_ship_done ship no-mistakes "$2" "$3" "$4"' \
    _ "$ROOT" "$dir/wt" "$dir/project" \
    "done: PR https://gerrit.example/r/c/group/apps/console/+/4201/1 published for review" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the done gate accepted a published-for-review report naming no Gerrit change"
  case "$out" in
    *"canonical https://<host>/c/<project>/+/<number> form"*) ;;
    *) fail "the refusal did not name the canonical Gerrit change form: $out" ;;
  esac
  git -C "$dir/wt" update-ref -d refs/remotes/no-mistakes/fm/task

  # Recovery fast-forwards the copy to the fix; the publish then stamps a
  # Change-Id, rewriting the message but not the tree, and pushes one squash.
  git -C "$dir/wt" fetch -q "$elsewhere" "$fixed"
  git -C "$dir/wt" merge -q --ff-only "$fixed"
  stamped=$(git -C "$dir/wt" commit-tree "$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')" -p "$unfixed" \
    -m "no-mistakes(review): Correct the documented value" -m "Change-Id: I0123456789abcdef0123456789abcdef01234567")
  git -C "$dir/wt" reset -q --hard "$stamped"
  squash=$(git -C "$dir/wt" commit-tree "$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')" -p "$base" -m squashed)
  [ "$stamped" != "$fixed" ] || fail "the fixture's stamped head did not diverge from the pipeline head"

  # The done gate itself, as crew-state and the secondmate ledger call it.
  set +e
  out=$(FM_TEST_GERRIT_REVISION=$squash FM_TEST_NM_PIPELINE_HEAD=$fixed \
    FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-dod-lib.sh"
      fm_dod_accept_ship_done ship no-mistakes "$2" "$3" "$4"' \
    _ "$ROOT" "$dir/wt" "$dir/project" "$line" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the done gate refused a recovered, published copy: $out"

  write_task_meta "$dir" task-recovered
  FM_TEST_GERRIT_REVISION=$squash FM_TEST_NM_PIPELINE_HEAD=$fixed run_check_entry "$dir" task-recovered "$url" >/dev/null \
    || fail "arming refused a recovered copy whose squash carries the pipeline's result"
  grep -qxF "pr=$url" "$state/task-recovered.meta" || fail "the recovered publish was not recorded"

  # A direct-PR task never runs the pipeline, so no run is asked about.
  : > "$dir/nm.log"
  write_task_meta "$dir" task-direct
  sed -i.bak 's/^mode=no-mistakes$/mode=direct-PR/' "$state/task-direct.meta" && rm -f "$state/task-direct.meta.bak"
  FM_TEST_GERRIT_REVISION=$squash FM_TEST_NM_FAIL=1 FM_TEST_NM_LOG="$dir/nm.log" \
    run_check_entry "$dir" task-direct "$url" >/dev/null \
    || fail "a direct-PR Gerrit publish was refused over a pipeline it never runs"
  [ ! -s "$dir/nm.log" ] || fail "a direct-PR Gerrit publish consulted no-mistakes"
  pass "a no-mistakes Gerrit ready report requires the pipeline's fixes recovered into the published copy"
}

# The GitLab watch must follow a merge request exactly as the GitHub watch
# follows a pull request, on any instance, and must never turn an unreadable
# merge request into a merge. Its evidence against the public fixture project
# https://gitlab.com/KarotKris/gitlab-merge-watch-fixture is in
# docs/gitlab-merge-watch.md; this exercises the same paths hermetically.
# A Forgejo pull request is followed by number through "tea api" on the one
# login registered for its host. Only a boolean merged field of true wakes the
# poll: tea api exits 0 on an HTTP error with the error body as output, so an
# error body, an unmerged record, a tea failure, and an ambiguous login all
# stay silent, and the read never depends on how many newer pull requests the
# repository has.
test_forgejo_merge_watch() {
  local dir state out url value
  dir=$(make_case forgejo-merge-watch)
  state="$dir/home/state"
  url=https://forgejo.example/o/r/pulls/7
  cat > "$dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TEA_LOG"
if [ "${1:-} ${2:-}" = "login list" ]; then
  printf '[\n'
  printf '  {\n    "name": "main",\n    "url": "https://forgejo.example"\n  }'
  if [ -n "${FM_TEST_TEA_SECOND_LOGIN:-}" ]; then
    printf ',\n  {\n    "name": "other",\n    "url": "https://forgejo.example"\n  }'
  fi
  printf '\n]\n'
  exit 0
fi
[ "${1:-}" = api ] || exit 0
[ -z "${FM_TEST_TEA_FAIL:-}" ] || exit 1
case "${FM_TEST_TEA_PULL:-open}" in
  merged) printf '{"state":"closed","merged":true,"head":{"sha":"abc"}}\n' ;;
  error) printf '{"message":"The target couldn'"'"'t be found.","url":"x"}\n' ;;
  *) printf '{"state":"open","merged":false,"head":{"sha":"abc"}}\n' ;;
esac
SH
  chmod +x "$dir/fakebin/tea"
  ln -sf "$(command -v jq)" "$dir/fakebin/jq"
  : > "$dir/tea.log"

  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a forgejo "$url" forgejo.example o/r 7 "$POLL" \
    || fail "could not prepare a Forgejo poll"
  fm_pr_poll_publish_prepared || fail "could not publish a Forgejo poll"

  for value in open error; do
    out=$(FM_TEST_TEA_LOG="$dir/tea.log" FM_TEST_TEA_PULL=$value run_poll "$dir")
    [ -z "$out" ] || fail "Forgejo poll emitted for a $value reading"
  done
  out=$(FM_TEST_TEA_LOG="$dir/tea.log" FM_TEST_TEA_PULL=merged FM_TEST_TEA_FAIL=1 run_poll "$dir")
  [ -z "$out" ] || fail "Forgejo poll emitted after a tea failure"
  out=$(FM_TEST_TEA_LOG="$dir/tea.log" FM_TEST_TEA_PULL=merged FM_TEST_TEA_SECOND_LOGIN=1 run_poll "$dir")
  [ -z "$out" ] || fail "Forgejo poll emitted with an ambiguous tea login"
  out=$(FM_TEST_TEA_LOG="$dir/tea.log" FM_TEST_TEA_PULL=merged run_poll "$dir")
  [ "$out" = merged ] || fail "Forgejo poll did not emit exactly one merged line"

  grep -qF -- "api --login main --repo o/r /repos/{owner}/{repo}/pulls/7" "$dir/tea.log" \
    || fail "the poll did not read the one pull request by number on the host's login"
  ! grep -qF -- "pulls list" "$dir/tea.log" \
    || fail "the poll scanned a pull request list instead of reading by number"
  pass "Forgejo poll reads one pull request by number through tea api and wakes only on merged true"
}

# The one tea login for a Forgejo host is found by parsing
# `tea login list --output json` as JSON, never by splitting each line on
# quotes. The pretty-printed fixture below is byte-for-byte what tea 0.14.0
# prints for two logins; the two compact fixtures are the same records with one
# object per line and as one line, the shapes a line-oriented split misread as
# a url equal to the login name, refusing every host. Both the sourced helper
# and the static watcher body, which keeps its own copy of the filter, must
# resolve every shape, strip scheme, port, and path from the url, and refuse
# an ambiguous host.
test_forgejo_login_list_shapes() {
  local dir state out shape url
  dir=$(make_case forgejo-login-shapes)
  state="$dir/home/state"
  cat > "$dir/tea-multiline.json" <<'JSON'
[
  {
    "name": "fixture-one",
    "url": "https://git.example.com",
    "ssh_host": "git.example.com",
    "user": "someone",
    "default": "true"
  },
  {
    "name": "fixture-two",
    "url": "http://code.internal:3000/",
    "ssh_host": "code.internal",
    "user": "other",
    "default": "false"
  }
]
JSON
  jq -c . "$dir/tea-multiline.json" > "$dir/tea-oneline.json"
  { printf '[\n'; jq -c '.[]' "$dir/tea-multiline.json" | sed '1!s/^/,/'; printf ']\n'; } \
    > "$dir/tea-perobject.json"
  [ "$(wc -l < "$dir/tea-oneline.json")" -eq 1 ] || fail "the one-line fixture is not one line"
  grep -q '^{"name":"fixture-one","url":"https://git.example.com"' "$dir/tea-perobject.json" \
    || fail "the per-object fixture does not put a whole login on one line"
  printf '[{"name":"a","url":"https://git.example.com"},{"name":"b","url":"https://git.example.com:3000/x"}]\n' \
    > "$dir/tea-ambiguous.json"
  cat > "$dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "login list" ]; then
  cat "$FM_TEST_TEA_LOGINS"
  exit 0
fi
[ "${1:-}" = api ] || exit 0
printf '%s\n' "$*" >> "$FM_TEST_TEA_LOG"
printf '{"state":"closed","merged":true,"head":{"sha":"abc"}}\n'
SH
  chmod +x "$dir/fakebin/tea"
  ln -sf "$(command -v jq)" "$dir/fakebin/jq"
  : > "$dir/tea.log"

  url=https://code.internal/o/r/pulls/7
  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a forgejo "$url" code.internal o/r 7 "$POLL" \
    || fail "could not prepare a Forgejo poll"
  fm_pr_poll_publish_prepared || fail "could not publish a Forgejo poll"

  for shape in multiline oneline perobject; do
    out=$(FM_TEST_TEA_LOGINS="$dir/tea-$shape.json" PATH="$dir/fakebin:$PATH" fm_pr_forgejo_login git.example.com) \
      || fail "$shape: the login helper refused a host with exactly one login"
    [ "$out" = fixture-one ] || fail "$shape: the login helper resolved '$out' for git.example.com"
    out=$(FM_TEST_TEA_LOGINS="$dir/tea-$shape.json" PATH="$dir/fakebin:$PATH" fm_pr_forgejo_login code.internal) \
      || fail "$shape: the login helper refused a url with a port and trailing slash"
    [ "$out" = fixture-two ] || fail "$shape: the login helper resolved '$out' for code.internal"
    ! FM_TEST_TEA_LOGINS="$dir/tea-$shape.json" PATH="$dir/fakebin:$PATH" fm_pr_forgejo_login elsewhere.example >/dev/null \
      || fail "$shape: the login helper resolved a host with no registered login"
    out=$(FM_TEST_TEA_LOGINS="$dir/tea-$shape.json" FM_TEST_TEA_LOG="$dir/tea.log" run_poll "$dir")
    [ "$out" = merged ] || fail "$shape: the static poll did not resolve the login and report the merge"
    grep -qF -- "api --login fixture-two --repo o/r" "$dir/tea.log" \
      || fail "$shape: the static poll did not read through the host's login"
    : > "$dir/tea.log"
  done
  ! FM_TEST_TEA_LOGINS="$dir/tea-ambiguous.json" PATH="$dir/fakebin:$PATH" fm_pr_forgejo_login git.example.com >/dev/null \
    || fail "the login helper picked one of two logins for the same host"
  out=$(FM_TEST_TEA_LOGINS="$dir/tea-ambiguous.json" FM_TEST_TEA_LOG="$dir/tea.log" run_poll "$dir")
  [ -z "$out" ] || fail "the static poll read through an ambiguous login"
  pass "Forgejo login match parses tea's JSON in every line shape, in the helper and the static poll"
}

test_gitlab_merge_watch() {
  local dir state out rc url value noglab entry bindir name
  dir=$(make_case gitlab-merge-watch)
  state="$dir/home/state"
  url=https://gitlab.example/group/subgroup/project/-/merge_requests/7

  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a gitlab "$url" gitlab.example group/subgroup/project 7 "$POLL" \
    || fail "could not prepare a GitLab poll"
  fm_pr_poll_publish_prepared || fail "could not publish a GitLab poll"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "published GitLab poll provenance or metadata binding was invalid"
  [ "$(cat "$state/task-a.pr-poll")" = "gitlab
$url
gitlab.example
group/subgroup/project
7" ] || fail "published GitLab sidecar bytes were not exact"

  # Only an exact merged state wakes firstmate. Every other reading, including
  # an unreadable merge request and a changed output format, stays silent.
  for value in opened closed locked '' not-a-state MERGED merged-but-not; do
    out=$(FM_TEST_GLAB_STATE="$value" run_poll "$dir")
    [ -z "$out" ] || fail "GitLab poll emitted for a non-merged state"
  done
  out=$(FM_TEST_GLAB_STATE=merged run_poll "$dir")
  [ "$out" = merged ] || fail "GitLab poll did not emit exactly one merged line"
  out=$(FM_TEST_GLAB_FAIL=1 run_poll "$dir")
  [ -z "$out" ] || fail "GitLab poll emitted after a glab failure"

  # glab is addressed by project URL and merge request number, never by the
  # merge request URL, which the real CLI resolves through the current git
  # repository the watcher does not have.
  grep -qF -- "mr view 7 -R https://gitlab.example/group/subgroup/project" "$dir/glab.log" \
    || fail "GitLab poll did not address glab by project URL and merge request number"
  ! grep -qF -- "$url" "$dir/glab.log" \
    || fail "GitLab poll passed a merge request URL to glab"

  # An absent CLI must produce no wake rather than a false merge. The whole
  # search path is mirrored without glab, because a real glab anywhere on
  # PATH would make this prove nothing.
  noglab="$dir/noglab"
  mkdir -p "$noglab"
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=$(basename "$entry")
      [ "$name" = glab ] && continue
      [ -e "$noglab/$name" ] || ln -s "$entry" "$noglab/$name" 2>/dev/null
    done
  done <<EOF
$dir/fakebin
$(printf '%s\n' "$BASE_PATH" | tr ':' '\n')
EOF
  ! PATH="$noglab" command -v glab >/dev/null 2>&1 \
    || fail "the glab-free search path still resolved glab"
  out=$(FM_TEST_GLAB_STATE=merged FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    PATH="$noglab" \
    bash "$state/task-a.check.sh")
  [ -z "$out" ] || fail "GitLab poll emitted with glab absent from PATH"

  # A doctored sidecar cannot redirect the poll: the stored parts must rebuild
  # the stored URL exactly.
  printf '%s\n%s\n%s\n%s\n%s\n' gitlab "$url" elsewhere.example group/subgroup/project 7 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GLAB_STATE=merged run_poll "$dir")
  [ -z "$out" ] || fail "GitLab poll emitted for a sidecar whose host was swapped"
  printf '%s\n%s\n%s\n%s\n%s\n' gitlab "$url" gitlab.example group/subgroup/other 7 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GLAB_STATE=merged run_poll "$dir")
  [ -z "$out" ] || fail "GitLab poll emitted for a sidecar whose project was swapped"

  # Arming is where a missing CLI can still be reported, so it refuses there.
  write_task_meta "$dir" task-b
  set +e
  out=$(FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" PATH="$noglab" \
    "$PR_CHECK" task-b "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming a GitLab watch succeeded with glab absent"
  case "$out" in
    *"requires glab on PATH"*) ;;
    *) fail "arming a GitLab watch with glab absent did not report the missing CLI" ;;
  esac
  [ ! -e "$state/task-b.check.sh" ] || fail "refused GitLab arming left a poll armed"

  # The merge path addresses the forge the URL names, and never the other one.
  # This fixture's glab answers with the field output the poll reads, so the
  # merge's JSON read cannot be parsed, which must refuse rather than merge on a
  # state it could not read.
  write_task_meta "$dir" task-c
  : > "$dir/glab.log"
  # The merge path needs jq before it reads anything, so this case supplies it
  # and the refusal below is the unreadable state rather than a missing tool.
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  set +e
  run_merge_entry "$dir" task-c "$url" >/dev/null 2> "$dir/merge-c.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge wrapper merged a GitLab merge request it could not read"
  grep -qF 'could not read the GitLab merge request state before merging' "$dir/merge-c.err" \
    || fail "merge wrapper refused for some reason other than the state it could not read"
  [ ! -s "$dir/gh-axi.log" ] || fail "merge wrapper reached the GitHub CLI for a GitLab URL"
  grep -qF "mr view 7 -R https://gitlab.example/group/subgroup/project" "$dir/glab.log" \
    || fail "merge wrapper did not read the merge request through glab at its own instance"
  ! grep -qF ' mr merge ' "$dir/glab.log" \
    || fail "merge wrapper merged despite an unreadable merge request state"

  pass "GitLab merge requests are followed on any instance and never wake falsely"
}

seed_canonical_poll() {
  local dir=$1 id=$2 url=$3 template=${4:-$POLL} state provider host path number
  state="$dir/home/state"
  fm_pr_url_parse "$url" || fail "retirement fixture URL was invalid"
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  fm_pr_poll_prepare "$state" "$id" "$provider" "$url" "$host" "$path" "$number" "$template" \
    || fail "could not prepare retirement fixture"
  fm_pr_poll_publish_prepared || fail "could not publish retirement fixture"
}

add_stop_custom_check() {
  local dir=$1 state
  state="$dir/home/state"
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$state/z-stop.check.sh"
  chmod 0700 "$state/z-stop.check.sh"
  FM_HOME="$dir/home" "$REGISTER" z-stop >/dev/null \
    || fail "could not register stop-cycle custom check"
}

assert_poll_absent() {
  local state=$1 id=$2 suffix
  for suffix in check.sh pr-poll pr-poll-registration pr-poll-retirement \
    pr-poll-queue-dropped; do
    [ ! -e "$state/$id.$suffix" ] && [ ! -L "$state/$id.$suffix" ] \
      || fail "retired poll left $id.$suffix"
  done
}

poll_artifact_snapshot() {
  local state=$1 id=$2 suffix path
  for suffix in check.sh pr-poll pr-poll-registration pr-poll-retirement \
    pr-poll-queue-dropped meta; do
    path="$state/$id.$suffix"
    [ -e "$path" ] || [ -L "$path" ] || continue
    if [ -L "$path" ]; then
      printf 'link %s %s\n' "$suffix" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      printf 'file %s %s ' "$suffix" "$(file_mode "$path")"
      shasum -a 256 "$path" | awk '{print $1}'
    else
      printf 'other %s\n' "$suffix"
    fi
  done
}

test_merged_poll_retires_once() {
  local dir state rc first second meta_before
  dir=$(make_case merged-retirement-once)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  meta_before=$(cat "$state/task-a.meta")
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged retirement watcher failed: $(cat "$dir/watch-1.err")"
  first=$(cat "$dir/watch-1.out")
  [ "$(grep -cxF "check: $state/task-a.check.sh: merged" "$dir/watch-1.out")" -eq 1 ] \
    || fail "first merged notification was not preserved: $first"
  [ "$(grep -cxF "check: $state/z-stop.check.sh: stop-cycle" "$dir/watch-1.out")" -eq 1 ] \
    || fail "merged retirement skipped the remaining checks"
  ack_watcher_cycle "$state" || fail "first merged notification handling acknowledgement failed"
  assert_poll_absent "$state" task-a
  [ "$(cat "$state/task-a.meta")" = "$meta_before" ] || fail "merged retirement changed canonical metadata"

  rm -f "$state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "second watcher cycle failed: $(cat "$dir/watch-2.err")"
  second=$(cat "$dir/watch-2.out")
  case "$second" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "second cycle did not reach the control check: $second" ;; esac
  ! grep -F 'task-a.check.sh: merged' "$dir/watch-2.out" >/dev/null \
    || fail "retired merged poll executed a second time"
  ! grep "$(printf '\tcheck\ttask-a.check.sh\t')" "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "handled merged notification remained queued after acknowledgement"
  pass "validated merged polls notify once and retire before the next watcher cycle"
}

# A poll's own retirement state is scoped to ONE registration, so it cannot by
# itself catch a poll re-registered for a task whose merge was already
# surfaced (e.g. bin/fm-pr-check.sh re-armed after the fact). The per-task
# merge-notified marker (bin/fm-pr-lib.sh) is what stops that re-registration
# from producing a second main-blocking wake for the identical merge, while a
# genuinely first notification (test_merged_poll_retires_once above) still
# reaches main.
test_merged_poll_reregistration_after_notification_is_absorbed() {
  local dir state rc first
  dir=$(make_case merged-reregistration-absorbed)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "first merged watcher cycle failed: $(cat "$dir/watch-1.err")"
  first=$(cat "$dir/watch-1.out")
  [ "$(grep -cxF "check: $state/task-a.check.sh: merged" "$dir/watch-1.out")" -eq 1 ] \
    || fail "first merge confirmation was not delivered: $first"
  ack_watcher_cycle "$state" || fail "first merge confirmation acknowledgement failed"
  assert_poll_absent "$state" task-a
  [ -f "$state/task-a.pr-poll-merge-notified" ] || fail "the merge-notified marker was not recorded"

  # Re-registration: fm-pr-check.sh re-armed for a task whose PR is already
  # merged (a fresh check.sh/pr-poll/pr-poll-registration, a distinct
  # retirement identity from the one just retired).
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  rm -f "$state/.last-check"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "second watcher cycle failed: $(cat "$dir/watch-2.err")"
  case "$(cat "$dir/watch-2.out")" in
    check:*z-stop.check.sh:*stop-cycle) ;;
    *) fail "the re-registered duplicate did not fall through to the next check: $(cat "$dir/watch-2.out")" ;;
  esac
  ! grep -F 'task-a.check.sh: merged' "$dir/watch-2.out" >/dev/null \
    || fail "a repeat identical merged poll opened a main-blocking row: $(cat "$dir/watch-2.out")"
  ! grep "$(printf '\tcheck\ttask-a.check.sh\t')" "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "the absorbed duplicate merge notice was queued as a main-blocking row"
  assert_poll_absent "$state" task-a
  pass "a repeat identical merged poll for an already-notified task is absorbed, never queued as a main-blocking row"
}

# The captain merging a PR himself on the forge is the same outcome as a merge
# this home performed: bin/fm-merge-outcome-lib.sh carries both to the parent on
# the one reply channel, so no second watch path exists for the captain's case.
# The poll's own durable row still lands here, because the mate that owns the
# task still has to act on it.
seed_secondmate_home() {  # <dir> [<route>]
  local dir=$1 route=${2:-remote}
  printf '%s\n' mate-x > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=%s\n' "$route" \
    > "$dir/home/.fm-secondmate-parent"
}

test_merged_poll_retries_a_failed_upward_report() {
  local dir state rc replies url
  url=https://github.com/o/r/pull/1
  dir=$(make_case merged-poll-upward-retry)
  state="$dir/home/state"
  replies="$state/parent-replies.status"
  printf '%s\n' mate-x > "$dir/home/.fm-secondmate-home"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merged-poll-upward-retry: failed report did not keep the watcher loud"
  [ -f "$state/task-a.check.sh" ] \
    || fail "merged-poll-upward-retry: failed report retired its retry poll"
  [ ! -e "$state/task-a.pr-poll-merge-notified" ] \
    || fail "merged-poll-upward-retry: failed report was marked notified"
  [ ! -e "$replies" ] \
    || fail "merged-poll-upward-retry: failed report wrote a parent reply"

  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' \
    > "$dir/home/.fm-secondmate-parent"
  rm -f "$state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged-poll-upward-retry: retry failed: $(cat "$dir/watch-2.err")"
  if [ ! -e "$replies" ]; then
    ack_watcher_cycle "$state" \
      || fail "merged-poll-upward-retry: recovery acknowledgement failed"
    rm -f "$state/.last-check"
    set +e
    FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
      > "$dir/watch-3.out" 2> "$dir/watch-3.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "merged-poll-upward-retry: post-recovery retry failed: $(cat "$dir/watch-3.err")"
  fi
  assert_grep "done [key=merged-task-a]: merged task-a $url" <(sed -E 's/ \[at=[0-9]+\]//' "$replies") \
    "merged-poll-upward-retry: repaired binding did not receive the retry"
  assert_poll_absent "$state" task-a
  pass "a failed upward merge report keeps its poll armed for repair and retry"
}

test_self_merge_and_poll_publish_one_outcome() {
  local dir state replies url rc
  url=https://github.com/o/r/pull/1

  # Interleaving one: self publication commits before the poll observes the
  # merge, so the poll absorbs the committed identity without reporting again.
  dir=$(make_case merge-outcome-committed)
  state="$dir/home/state"
  replies="$state/parent-replies.status"
  seed_secondmate_home "$dir"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2>"$dir/seed.err" \
    || fail "merge-outcome-committed: could not arm merge poll"
  run_merge_entry "$dir" task-a "$url" >"$dir/merge.out" 2>"$dir/merge.err" \
    || fail "merge-outcome-committed: merge entrypoint failed: $(cat "$dir/merge.err")"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    >"$dir/watch.out" 2>"$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "merge-outcome-committed: watcher failed: $(cat "$dir/watch.err")"
  [ "$(sed -E 's/ \[at=[0-9]+\]//' "$replies" | grep -c -F "done [key=merged-task-a]: merged task-a $url")" -eq 1 ] \
    || fail "merge-outcome-committed: self and poll reports produced duplicate merge outcomes"
  assert_no_grep "check: $state/task-a.check.sh: merged" "$state/.wake-queue" \
    "merge-outcome-committed: absorbed poll published a second outcome"
  assert_poll_absent "$state" task-a

  # Interleaving two: self publication lands but its marker commit fails. After
  # that outcome is drained, the still-armed poll must publish it again rather
  # than treating the interrupted attempt as complete and going silent.
  dir=$(make_case merge-outcome-uncommitted)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2>"$dir/seed.err" \
    || fail "merge-outcome-uncommitted: could not arm merge poll"
  cat >"$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *pr-poll-merge-notified*) exit 1 ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  set +e
  FM_TEST_REAL_MV="$REAL_MV" run_merge_entry "$dir" task-a "$url" \
    >"$dir/merge.out" 2>"$dir/merge.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "merge-outcome-uncommitted: landed merge was reported as failed"
  assert_grep "$url" "$state/.wake-queue" \
    "merge-outcome-uncommitted: interrupted publication emitted no outcome"
  [ ! -e "$state/task-a.pr-poll-merge-notified" ] \
    || fail "merge-outcome-uncommitted: failed marker commit was treated as complete"
  ack_watcher_cycle "$state" \
    || fail "merge-outcome-uncommitted: could not drain the first outcome"
  assert_no_grep "$url" "$state/.wake-queue" \
    "merge-outcome-uncommitted: first outcome remained queued after its drain"
  rm -f "$dir/fakebin/mv" "$state/.last-check"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    >"$dir/watch.out" 2>"$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "merge-outcome-uncommitted: poll retry failed: $(cat "$dir/watch.err")"
  [ "$(grep -cxF "check: $state/task-a.check.sh: merged" "$dir/watch.out")" -eq 1 ] \
    || fail "merge-outcome-uncommitted: poll retry did not re-emit the outcome"
  assert_grep "$url" "$state/.wake-queue" \
    "merge-outcome-uncommitted: drained outcome was not durably re-emitted"
  fm_pr_poll_merge_already_notified "$state" task-a github github.com o/r 1 \
    || fail "merge-outcome-uncommitted: successful retry did not commit the marker"
  assert_poll_absent "$state" task-a
  pass "staged self-merge and poll interleavings are never silent"
}

test_merged_poll_reports_upward_from_a_secondmate_home_once() {
  local dir state rc replies url
  url=https://github.com/o/r/pull/1
  dir=$(make_case merged-poll-upward)
  state="$dir/home/state"
  replies="$state/parent-replies.status"
  seed_secondmate_home "$dir"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged-poll-upward: watcher failed: $(cat "$dir/watch-1.err")"
  [ "$(grep -cxF "check: $state/task-a.check.sh: merged" "$dir/watch-1.out")" -eq 1 ] \
    || fail "merged-poll-upward: the poll's own row was lost: $(cat "$dir/watch-1.out")"
  assert_grep "done [key=merged-task-a]: merged task-a $url" <(sed -E 's/ \[at=[0-9]+\]//' "$replies") \
    "merged-poll-upward: a merge this home did not perform was never reported upward"
  [ "$(grep -c -F "$url" "$replies")" -eq 1 ] \
    || fail "merged-poll-upward: one detected merge produced more than one upward line"
  ack_watcher_cycle "$state" || fail "merged-poll-upward: acknowledgement failed"

  # Re-registered for the same, already-reported merge: the absorbed duplicate
  # must not tell the parent a second time either.
  seed_canonical_poll "$dir" task-a "$url"
  rm -f "$state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged-poll-upward: second watcher cycle failed: $(cat "$dir/watch-2.err")"
  [ "$(grep -c -F "$url" "$replies")" -eq 1 ] \
    || fail "merged-poll-upward: an absorbed duplicate detection reported the merge again"
  pass "a merge detected by the poll is reported upward from a secondmate home exactly once"
}

test_different_merged_pr_for_same_task_is_not_absorbed() {
  local dir state rc
  dir=$(make_case different-merged-pr-not-absorbed)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "first merged watcher cycle failed: $(cat "$dir/watch-1.err")"
  case "$(cat "$dir/watch-1.out")" in
    check:*task-a.check.sh:*merged) ;;
    *) fail "first PR merge confirmation was not delivered: $(cat "$dir/watch-1.out")" ;;
  esac
  ack_watcher_cycle "$state" || fail "first PR merge confirmation acknowledgement failed"
  assert_poll_absent "$state" task-a

  write_poll_meta "$state" task-a https://github.com/o/r/pull/2
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/2
  rm -f "$state/.last-check"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "different-PR watcher cycle failed: $(cat "$dir/watch-2.err")"
  case "$(cat "$dir/watch-2.out")" in
    check:*task-a.check.sh:*merged) ;;
    *) fail "a different PR merge was absorbed: $(cat "$dir/watch-2.out")" ;;
  esac
  grep -F "$(printf '\tcheck\tmerged-task-a-https://github.com/o/r/pull/2\t')" \
    "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "the different PR merge did not create a main-blocking wake row"
  fm_pr_poll_merge_already_notified "$state" task-a github github.com o/r 2 \
    || fail "the marker was not advanced to the different PR identity"
  ! fm_pr_poll_merge_already_notified "$state" task-a github github.com o/r 1 \
    || fail "the marker still matched the superseded PR identity"
  assert_poll_absent "$state" task-a
  pass "a different merged PR for the same task gets its own first notification"
}

# A secondmate is a persistent worker, never landed work: a merge poll armed
# on its record (bin/fm-pr-check.sh refuses new ones) is residue carrying a
# relayed child's pr=. When that residue reads merged the watcher retires the
# poll silently - no merge outcome, no notified marker, no wake that could put
# the mate itself up for teardown - and leaves every lifecycle artifact whole.
test_persistent_secondmate_retirement_is_poll_only() {
  local dir state meta_before status_before registry_before endpoint_before rc
  dir=$(make_case merged-retirement-secondmate)
  state="$dir/home/state"
  fm_write_meta "$state/domain.meta" \
    'window=session:fm-domain' \
    "worktree=$dir/secondmate-home" \
    "project=$dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    'backend=tmux' \
    "home=$dir/secondmate-home" \
    'pr=https://github.com/o/r/pull/2' \
    'pr_head=0123456789abcdef0123456789abcdef01234567'
  mkdir -p "$dir/secondmate-home"
  printf 'working: persistent endpoint remains healthy\n' > "$state/domain.status"
  printf -- '- domain | scope: test | home: %s\n' "$dir/secondmate-home" > "$dir/home/data/secondmates.md"
  printf 'endpoint-alive\n' > "$dir/endpoint-sentinel"
  meta_before=$(shasum -a 256 "$state/domain.meta")
  status_before=$(shasum -a 256 "$state/domain.status")
  registry_before=$(shasum -a 256 "$dir/home/data/secondmates.md")
  endpoint_before=$(shasum -a 256 "$dir/endpoint-sentinel")
  seed_canonical_poll "$dir" domain https://github.com/o/r/pull/2
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "persistent secondmate merged watcher failed: $(cat "$dir/watch.err")"
  case "$(cat "$dir/watch.out")" in
    check:*z-stop.check.sh:*stop-cycle) ;;
    *) fail "a secondmate's merged poll woke the watcher instead of retiring silently: $(cat "$dir/watch.out")" ;;
  esac
  assert_poll_absent "$state" domain
  [ ! -e "$state/domain.pr-poll-merge-notified" ] \
    || fail "a secondmate's retired poll recorded a merge notification"
  ! grep -F 'merged-domain-' "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "a secondmate's merged poll queued a landed-work wake"
  ! grep -F 'domain.check.sh' "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "a secondmate's merged poll queued a check wake"
  [ "$(shasum -a 256 "$state/domain.meta")" = "$meta_before" ] || fail "retirement changed secondmate metadata"
  [ "$(shasum -a 256 "$state/domain.status")" = "$status_before" ] || fail "retirement changed secondmate status"
  [ "$(shasum -a 256 "$dir/home/data/secondmates.md")" = "$registry_before" ] || fail "retirement changed secondmate registry"
  [ "$(shasum -a 256 "$dir/endpoint-sentinel")" = "$endpoint_before" ] || fail "retirement changed secondmate endpoint evidence"
  [ -d "$dir/secondmate-home" ] || fail "retirement removed the persistent secondmate home"
  pass "a merged poll on a persistent secondmate retires silently: no outcome, marker, or wake, and every lifecycle artifact preserved"
}

test_retirement_crash_recovery() {
  local dir state rc raw_count drain_count historical_poll

  dir=$(make_case retirement-after-queue)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/3
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/3
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/task-a.check.sh" "check: $state/task-a.check.sh: merged" \
    || fail "could not seed post-queue crash"
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/recovery.out" 2> "$dir/recovery.err" \
    || fail "post-queue crash recovery wake failed: $(cat "$dir/recovery.err")"
  grep -F 'check: rearm-resurface' "$dir/recovery.out" >/dev/null \
    || fail "post-queue crash did not surface its durable recovery first"
  ack_watcher_cycle "$state" || fail "post-queue crash recovery acknowledgement failed"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "post-queue retry watcher failed: $(cat "$dir/watch.err")"
  assert_poll_absent "$state" task-a
  raw_count=$(grep -cF "$(printf '\tcheck\tmerged-task-a-https://github.com/o/r/pull/3\t')" \
    "$state/.wake-queue" || true)
  [ "$raw_count" -eq 1 ] || fail "post-queue retry did not publish exactly one new terminal row"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2>/dev/null
  drain_count=$(grep -cF "$(printf '\tcheck\tmerged-task-a-https://github.com/o/r/pull/3\t')" \
    "$dir/drain.out" || true)
  [ "$drain_count" -eq 1 ] || fail "same-key crash retry rows did not deduplicate at drain"

  dir=$(make_case retirement-after-receipt)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/4
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/4
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot receipt crash fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish crash receipt"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "receipt recovery watcher failed: $(cat "$dir/restart.err")"
  assert_poll_absent "$state" task-a
  ! grep -F 'task-a.check.sh: merged' "$dir/restart.out" >/dev/null || fail "receipt recovery duplicated the terminal wake"

  dir=$(make_case retirement-after-check-removal)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/5
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/5
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot partial removal fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish partial removal receipt"
  rm -f "$state/task-a.check.sh"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "post-check-removal restart failed: $(cat "$dir/restart.err")"
  case "$(cat "$dir/restart.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "post-check-removal restart did not reach the control check" ;; esac
  assert_poll_absent "$state" task-a
  fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" || fail "completed retirement was not idempotent"

  dir=$(make_case retirement-after-registration-removal)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/5
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/5
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot sidecar-removal fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish sidecar-removal receipt"
  rm -f "$state/task-a.check.sh" "$state/task-a.pr-poll-registration"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "post-registration-removal restart failed: $(cat "$dir/restart.err")"
  case "$(cat "$dir/restart.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "post-registration-removal restart did not reach the control check" ;; esac
  assert_poll_absent "$state" task-a

  dir=$(make_case retirement-before-receipt-removal)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/5
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/5
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot receipt-only fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish receipt-only fixture"
  rm -f "$state/task-a.check.sh" "$state/task-a.pr-poll-registration" "$state/task-a.pr-poll"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "receipt-only restart failed: $(cat "$dir/restart.err")"
  case "$(cat "$dir/restart.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "receipt-only restart did not reach the control check" ;; esac
  assert_poll_absent "$state" task-a

  dir=$(make_case retirement-after-template-update)
  state="$dir/home/state"
  historical_poll="$dir/historical-fm-pr-poll.sh"
  cp "$POLL" "$historical_poll"
  printf '\n' >> "$historical_poll"
  chmod 0600 "$historical_poll"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/22
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/22 "$historical_poll"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/task-a.check.sh" "check: $state/task-a.check.sh: merged" \
    || fail "could not seed pre-update terminal wake"
  fm_pr_poll_snapshot_capture "$state" task-a "$historical_poll" \
    || fail "could not snapshot pre-update retirement fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$historical_poll" merged \
    || fail "could not publish pre-update retirement receipt"
  add_stop_custom_check "$dir"
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/template-recovery.out" 2> "$dir/template-recovery.err" \
    || fail "template-update recovery wake failed: $(cat "$dir/template-recovery.err")"
  grep -F 'check: rearm-resurface' "$dir/template-recovery.out" >/dev/null \
    || fail "template-update recovery did not surface its durable wake first"
  ack_watcher_cycle "$state" || fail "template-update recovery acknowledgement failed"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "template-update recovery watcher failed: $(cat "$dir/restart.err")"
  case "$(cat "$dir/restart.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "template-update recovery did not reach the control check" ;; esac
  ! grep -F 'pullRequest(number:' "$dir/gh.log" >/dev/null 2>&1 \
    || fail "template-update migration rebuilt and queried the retired poll"
  ! grep "$(printf '\tcheck\ttask-a.check.sh\t')" "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "template-update recovery left the handled terminal wake queued"
  assert_poll_absent "$state" task-a
  pass "queue, receipt, and every fixed-path removal crash point recover without loss or repeated execution"
}

test_external_merge_transition_retires_only_terminal_poll() {
  local dir state before rc label
  dir=$(make_case external-merge-transition)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/19
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/19
  add_stop_custom_check "$dir"
  before=$(poll_artifact_snapshot "$state" task-a)

  for label in open-green open-red closed-unmerged forge-error malformed; do
    rm -f "$state/.last-check"
    set +e
    case "$label" in
      open-green|open-red)
        FM_TEST_GH_STATE=OPEN run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
        ;;
      closed-unmerged)
        FM_TEST_GH_STATE=CLOSED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
        ;;
      forge-error)
        FM_TEST_GH_FAIL=1 run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
        ;;
      malformed)
        FM_TEST_GH_STATE=NOT_A_FORGE_STATE run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
        ;;
    esac
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "$label watcher cycle failed: $(cat "$dir/$label.err")"
    case "$(cat "$dir/$label.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "$label did not reach the control check" ;; esac
    [ "$(poll_artifact_snapshot "$state" task-a)" = "$before" ] || fail "$label changed the armed poll"
    ack_watcher_cycle "$state" || fail "$label control wake acknowledgement failed"
  done

  rm -f "$state/z-stop.check.sh" "$state/z-stop.check-trust" "$state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/merged.out" 2> "$dir/merged.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "external merged transition failed: $(cat "$dir/merged.err")"
  case "$(cat "$dir/merged.out")" in check:*task-a.check.sh:*merged) ;; *) fail "external merge did not preserve its notification" ;; esac
  assert_poll_absent "$state" task-a
  pass "open/red, closed-unmerged, malformed, and forge errors remain armed until an exact merged transition"
}

test_retirement_refuses_replacement_and_nonterminal_results() {
  local dir state before rc replacement_check replacement_data replacement_registration replacement_meta
  local historical_poll current_poll
  dir=$(make_case retirement-replacement)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/6
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/6
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot replacement fixture"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/7
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/7
  before=$(state_snapshot "$state")
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged \
    && fail "stale terminal snapshot retired a replacement poll"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "snapshot mismatch changed replacement artifacts"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "replacement poll was not left canonical"

  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot nonterminal fixture"
  for result in OPEN CLOSED ERROR 'merged extra'; do
    fm_pr_poll_retirement_publish "$state" task-a "$POLL" "$result" \
      && fail "nonterminal result '$result' received retirement authority"
  done
  [ "$(state_snapshot "$state")" = "$before" ] || fail "nonterminal result changed canonical artifacts"

  printf '# tamper\n' >> "$state/task-a.check.sh"
  before=$(state_snapshot "$state")
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged \
    && fail "tampered check received a retirement receipt"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "tampered retirement attempt changed state"

  dir=$(make_case retirement-rearm-race)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/20
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/20
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot rearm-race fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish rearm-race receipt"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/21
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/21
  replacement_check=$(shasum -a 256 "$state/task-a.check.sh")
  replacement_data=$(shasum -a 256 "$state/task-a.pr-poll")
  replacement_registration=$(shasum -a 256 "$state/task-a.pr-poll-registration")
  replacement_meta=$(shasum -a 256 "$state/task-a.meta")
  fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" || fail "stale receipt did not yield to a canonical replacement"
  [ ! -e "$state/task-a.pr-poll-retirement" ] || fail "stale receipt survived canonical replacement recovery"
  [ "$(shasum -a 256 "$state/task-a.check.sh")" = "$replacement_check" ] || fail "stale receipt changed replacement check"
  [ "$(shasum -a 256 "$state/task-a.pr-poll")" = "$replacement_data" ] || fail "stale receipt changed replacement data"
  [ "$(shasum -a 256 "$state/task-a.pr-poll-registration")" = "$replacement_registration" ] || fail "stale receipt changed replacement registration"
  [ "$(shasum -a 256 "$state/task-a.meta")" = "$replacement_meta" ] || fail "stale receipt changed replacement metadata"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "replacement poll lost canonical provenance"

  dir=$(make_case retirement-template-update-rearm-race)
  state="$dir/home/state"
  historical_poll="$dir/historical-fm-pr-poll.sh"
  current_poll="$dir/current-fm-pr-poll.sh"
  cp "$POLL" "$historical_poll"
  cp "$POLL" "$current_poll"
  printf '\n' >> "$current_poll"
  chmod 0600 "$historical_poll" "$current_poll"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/23
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/23 "$historical_poll"
  fm_pr_poll_snapshot_capture "$state" task-a "$historical_poll" \
    || fail "could not snapshot pre-update rearm fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$historical_poll" merged \
    || fail "could not publish pre-update rearm receipt"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/24
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/24 "$current_poll"
  replacement_check=$(shasum -a 256 "$state/task-a.check.sh")
  replacement_data=$(shasum -a 256 "$state/task-a.pr-poll")
  replacement_registration=$(shasum -a 256 "$state/task-a.pr-poll-registration")
  replacement_meta=$(shasum -a 256 "$state/task-a.meta")
  fm_pr_poll_retirement_recover_one "$state" task-a "$current_poll" \
    || fail "template update blocked stale receipt recovery"
  [ ! -e "$state/task-a.pr-poll-retirement" ] || fail "pre-update receipt survived canonical replacement recovery"
  [ "$(shasum -a 256 "$state/task-a.check.sh")" = "$replacement_check" ] || fail "pre-update receipt changed replacement check"
  [ "$(shasum -a 256 "$state/task-a.pr-poll")" = "$replacement_data" ] || fail "pre-update receipt changed replacement data"
  [ "$(shasum -a 256 "$state/task-a.pr-poll-registration")" = "$replacement_registration" ] || fail "pre-update receipt changed replacement registration"
  [ "$(shasum -a 256 "$state/task-a.meta")" = "$replacement_meta" ] || fail "pre-update receipt changed replacement metadata"
  fm_pr_poll_artifacts_valid "$state" task-a "$current_poll" || fail "updated replacement poll lost canonical provenance"

  dir=$(make_case custom-merged-not-retired)
  state="$dir/home/state"
  printf '#!/usr/bin/env bash\nprintf "merged\\n"\n' > "$state/custom.check.sh"
  chmod 0700 "$state/custom.check.sh"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null || fail "could not register merged custom check"
  set +e
  run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/custom.out" 2> "$dir/custom.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged custom watcher failed: $(cat "$dir/custom.err")"
  [ -f "$state/custom.check.sh" ] && [ -f "$state/custom.check-trust" ] \
    || fail "custom merged output was retired as a PR poll"
  [ ! -e "$state/custom.pr-poll-retirement" ] || fail "custom check received a PR receipt"
  pass "replacement, nonterminal, tampered, and custom results receive no deletion authority"
}

test_retirement_queue_failure_and_receipt_tampering() {
  local dir state before rc external
  dir=$(make_case retirement-queue-failure)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/8
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/8
  # Fail sequence publication without making the queue itself look non-empty:
  # a directory at .wake-queue would now (correctly) trigger re-arm recovery
  # before the poll runs, so it no longer exercises the terminal append path.
  mkdir "$state/.wake-queue.seq"
  before=$(poll_artifact_snapshot "$state" task-a)
  set +e
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "watcher retired despite queue publication failure"
  [ -s "$dir/gh.log" ] || fail "queue failure fixture did not reach the authenticated poll"
  [ "$(poll_artifact_snapshot "$state" task-a)" = "$before" ] || fail "queue failure changed poll artifacts"
  [ ! -e "$state/task-a.pr-poll-retirement" ] || fail "queue failure published a receipt"

  dir=$(make_case retirement-receipt-tamper)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/9
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/9
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot receipt tamper fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish receipt tamper fixture"
  printf 'extra\n' >> "$state/task-a.pr-poll-retirement"
  before=$(state_snapshot "$state")
  fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" \
    && fail "malformed receipt authorized poll deletion"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "malformed receipt changed poll state"
  set +e
  run_check_entry "$dir" task-a https://github.com/o/r/pull/10 > "$dir/rearm.out" 2> "$dir/rearm.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "rearm accepted an invalid pending retirement receipt"
  [ "$(cat "$dir/rearm.err")" = 'error: pending PR poll retirement could not be validated' ] \
    || fail "rearm did not report the invalid pending receipt"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "refused rearm changed poll state"

  rm -f "$state/task-a.pr-poll-retirement"
  external="$dir/external-receipt"
  printf 'external\n' > "$external"
  ln -s "$external" "$state/task-a.pr-poll-retirement"
  before=$(state_snapshot "$state")
  fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" \
    && fail "receipt symlink authorized poll deletion"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "receipt symlink changed poll state"
  [ "$(cat "$external")" = external ] || fail "receipt symlink target was changed"
  pass "queue failure and untrusted receipts preserve canonical poll evidence"
}

test_gitlab_merged_poll_retires() {
  local dir state url rc
  dir=$(make_case gitlab-merged-retirement)
  state="$dir/home/state"
  url=https://gitlab.example/group/subgroup/project/-/merge_requests/17
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  set +e
  FM_TEST_GLAB_STATE=merged run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "GitLab merged retirement watcher failed: $(cat "$dir/watch.err")"
  case "$(cat "$dir/watch.out")" in check:*task-a.check.sh:*merged) ;; *) fail "GitLab merged wake was missing" ;; esac
  assert_poll_absent "$state" task-a
  grep -qxF "pr=$url" "$state/task-a.meta" || fail "GitLab retirement removed canonical metadata"
  pass "GitHub and GitLab exact merged results share one retirement path"
}

# --- poll-path merge authority ----------------------------------------------

write_away_record() {  # <dir> [<fm-afk-contract.sh enter args>...]
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter "$@" >/dev/null \
    || fail "could not enter an away-posture record"
}

archive_away_record() {  # <dir>
  FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/home/state" \
    "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null \
    || fail "could not archive the away-posture record"
}

# The durable queue is TSV (epoch, sequence, kind, key, payload).
merged_ledger_row() {  # <state> <task-id>
  awk -F'\t' -v prefix="check: merge landed: $2 " \
    'index($5, prefix) == 1 { print $5 }' "$1/.wake-queue"
}

# Arming also registers the contributions observer, whose poll runs a full fleet
# snapshot on every watcher check cycle. No case here exercises it (its own
# suite does), so a case retires it before a bounded merged-poll run instead of
# charging that work to the run's hang guard. Only ever call this while no
# watcher runs, because a check removed mid-cycle is reported as rejected.
retire_contributions_observer() {  # <dir>
  FM_HOME="$1/home" "$ROOT/bin/fm-check-unregister.sh" contributions >/dev/null \
    || fail "could not retire the contributions observer"
}

run_merged_poll_cycle() {  # <dir>
  local dir=$1 rc=0
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged poll watcher failed: $(cat "$dir/watch.err")"
}

queue_merge() {  # <dir> <url>
  local dir=$1 url=$2 rc=0
  set +e
  FM_TEST_GH_GRAPHQL_STATE=OPEN FM_TEST_GH_GRAPHQL_MERGED=false \
    FM_TEST_GH_GRAPHQL_QUEUED=true \
    run_merge_entry "$dir" task-a "$url" > "$dir/merge.out" 2> "$dir/merge.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "queued merge failed: $(cat "$dir/merge.err")"
  assert_grep "is queued" "$dir/merge.out" "the forge did not queue the merge"
  [ -f "$dir/home/state/task-a.merge-authority" ] \
    || fail "the accepted queued merge did not persist its authority"
}

test_merged_poll_row_carries_the_merge_authority() {
  local dir state url expected posture
  url=https://github.com/o/r/pull/1

  # Both a yolo=on task and an ordinary one merge under the record's away
  # authority; the words model retired the per-task grant and the yolo tag.
  for posture in yolo words; do
    dir=$(make_case "queued-merge-authority-$posture")
    state="$dir/home/state"
    write_task_meta "$dir" task-a
    if [ "$posture" = yolo ]; then
      printf 'yolo=on\n' >> "$state/task-a.meta"
      write_away_record "$dir"
    else
      write_away_record "$dir" --words 'merge task-a when green'
    fi
    expected=away
    run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
      || fail "$posture: could not arm the merge poll"
    queue_merge "$dir" "$url"
    archive_away_record "$dir"
    run_merged_poll_cycle "$dir"
    [ "$(merged_ledger_row "$state" task-a)" = "check: merge landed: task-a $url $expected" ] \
      || fail "$posture: archived posture lost persisted authority: $(merged_ledger_row "$state" task-a)"
    [ ! -e "$state/task-a.merge-authority" ] \
      || fail "$posture: published merge left its authority record behind"
  done

  pass "queued merges retain their away authority after captain return"
}

test_merged_poll_row_names_no_authority_when_no_record_grants_one() {
  local dir state url
  url=https://github.com/o/r/pull/1

  dir=$(make_case queued-merge-authority-attended)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "attended: could not arm the merge poll"
  queue_merge "$dir" "$url"
  run_merged_poll_cycle "$dir"
  [ "$(merged_ledger_row "$state" task-a)" = "check: merge landed: task-a $url" ] \
    || fail "attended queued merge was tagged: $(merged_ledger_row "$state" task-a)"

  dir=$(make_case merged-poll-authority-external)
  state="$dir/home/state"
  write_poll_meta "$state" task-a "$url" yolo=on
  write_away_record "$dir"
  seed_canonical_poll "$dir" task-a "$url"
  run_merged_poll_cycle "$dir"
  [ "$(merged_ledger_row "$state" task-a)" = "check: merge landed: task-a $url external" ] \
    || fail "external merge was attributed from live away posture: $(merged_ledger_row "$state" task-a)"
  assert_poll_absent "$state" task-a

  pass "poll distinguishes attended authorization from external landing"
}

test_authority_persistence_refuses_rebound_metadata() {
  local dir state url_a url_b rc
  url_a=https://github.com/o/r/pull/1
  url_b=https://github.com/o/r/pull/2
  dir=$(make_case merge-authority-rebound-metadata)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url_a" >/dev/null 2> "$dir/seed.err" \
    || fail "rebind: could not arm the original poll"
  cat > "$dir/rebind.sh" <<SH
#!/usr/bin/env bash
"$PR_CHECK" task-a "$url_b" >/dev/null
SH
  chmod +x "$dir/rebind.sh"
  set +e
  FM_TEST_GH_MERGE_HOOK="$dir/rebind.sh" \
    FM_TEST_GH_GRAPHQL_STATE=OPEN FM_TEST_GH_GRAPHQL_MERGED=false \
    FM_TEST_GH_GRAPHQL_QUEUED=true \
    run_merge_entry "$dir" task-a "$url_a" > "$dir/merge.out" 2> "$dir/merge.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "rebind: accepted merge persisted against rebound metadata"
  grep -qxF "pr=$url_b" "$state/task-a.meta" \
    || fail "rebind: merge hook did not replace the canonical identity"
  [ ! -e "$state/task-a.merge-authority" ] \
    || fail "rebind: authority was published for the wrong canonical identity"
  pass "accepted merge authority refuses rebound task metadata"
}

test_authority_persists_before_control_unlock() {
  local dir state url
  url=https://github.com/o/r/pull/1
  dir=$(make_case merge-authority-control-lock)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "control lock: could not arm the merge poll"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *"task-a.merge-authority "*)
    [ -d "$FM_TEST_CONTROL_LOCK" ] || exit 91
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  FM_TEST_CONTROL_LOCK="$state/.control-task-a.lock" FM_TEST_REAL_MV="$REAL_MV" \
    queue_merge "$dir" "$url"
  pass "accepted merge authority persists under the lifecycle lock"
}

test_teardown_cannot_race_authority_consumption() {
  local dir state url watcher_pid rc i
  url=https://github.com/o/r/pull/1
  dir=$(make_case merge-authority-teardown-race)
  state="$dir/home/state"
  fm_write_meta "$state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only' \
    'yolo=on'
  write_away_record "$dir"
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "teardown race: could not arm the merge poll"
  queue_merge "$dir" "$url"
  archive_away_record "$dir"
  FM_TEST_GH_STATE_STARTED="$dir/poll-started" FM_TEST_GH_STATE=MERGED \
    FM_TEST_GH_SLEEP=0.5 FM_TEST_CHECK_TIMEOUT=3 \
    run_watcher_bounded "$dir/home" "$dir/fakebin" \
      > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher_pid=$!
  i=0
  while [ ! -e "$dir/poll-started" ]; do
    sleep 0.01
    i=$((i + 1))
    if [ "$i" -ge 500 ]; then
      kill "$watcher_pid" 2>/dev/null || true
      wait "$watcher_pid" 2>/dev/null || true
      fail "teardown race: watcher did not begin its validated poll"
    fi
  done
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown race: cleanup crossed the active poll transaction"
  [ -f "$state/task-a.merge-authority" ] \
    || fail "teardown race: refused cleanup removed persisted authority"
  rc=0
  wait "$watcher_pid" || rc=$?
  [ "$rc" -eq 0 ] || fail "teardown race: watcher failed with $rc: $(cat "$dir/watch.err")"
  [ "$(merged_ledger_row "$state" task-a)" = "check: merge landed: task-a $url away" ] \
    || fail "teardown race: concurrent cleanup downgraded the merge authority"
  pass "teardown cannot race merged-poll authority consumption"
}

test_authority_retirement_preserves_replacement() {
  local dir state url_a url_b rc merge_pid
  url_a=https://github.com/o/r/pull/1
  url_b=https://github.com/o/r/pull/2
  dir=$(make_case merge-authority-retirement-replacement)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url_a" >/dev/null 2> "$dir/seed.err" \
    || fail "replacement: could not arm the original poll"
  queue_merge "$dir" "$url_a"
  # The replacement runs inside the watcher, whose environment names the real
  # firstmate root, so restore the fixture root every other arming here uses.
  cat > "$dir/replace-authority.sh" <<SH
#!/usr/bin/env bash
export FM_ROOT_OVERRIDE="$dir/root" FM_TEST_GUARD_LOG="$dir/guard.log"
"$PR_CHECK" task-a "$url_b" >/dev/null
(
  FM_TEST_GH_GRAPHQL_STATE=OPEN FM_TEST_GH_GRAPHQL_MERGED=false \\
  FM_TEST_GH_GRAPHQL_QUEUED=true \\
  "$PR_MERGE" task-a "$url_b" > "$dir/replacement-merge.out" 2> "$dir/replacement-merge.err"
  printf '%s\n' \$? > "$dir/replacement-merge.rc"
) &
printf '%s\n' "\$!" > "$dir/replacement-merge.pid"
SH
  chmod +x "$dir/replace-authority.sh"
  # The watcher is held inside this mv while the replacement re-arms, so that
  # work pauses the watcher's hang guard.
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_REAL_MV" "$@" || exit $?
case " $* " in
  *"task-a.pr-poll-merge-notified "*)
    if [ ! -e "$FM_TEST_REPLACEMENT_RAN" ]; then
      : > "$FM_TEST_REPLACEMENT_RAN"
      : > "$FM_TEST_WATCH_BOUND_PAUSE"
      "$FM_TEST_REPLACEMENT_SCRIPT"
      rm -f "$FM_TEST_WATCH_BOUND_PAUSE"
    fi
    ;;
esac
SH
  chmod +x "$dir/fakebin/mv"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_REPLACEMENT_RAN="$dir/replacement-ran" \
    FM_TEST_REPLACEMENT_SCRIPT="$dir/replace-authority.sh" \
    FM_TEST_WATCH_BOUND_PAUSE="$dir/replacement-in-flight" \
    FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
      > "$dir/watch-a.out" 2> "$dir/watch-a.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "replacement: original poll failed: $(cat "$dir/watch-a.err")"
  # The replacement merge was started from inside the watcher, so it is not
  # this shell's child; wait on its recorded process like any merge run here.
  merge_pid=$(cat "$dir/replacement-merge.pid" 2>/dev/null) \
    || fail "replacement: serialized replacement merge was not started"
  while process_is_live_non_zombie "$merge_pid"; do
    sleep 0.01
  done
  [ -e "$dir/replacement-merge.rc" ] || fail "replacement: serialized replacement merge did not finish"
  [ "$(cat "$dir/replacement-merge.rc")" -eq 0 ] \
    || fail "replacement: serialized replacement merge failed: $(cat "$dir/replacement-merge.err")"
  [ -f "$state/task-a.merge-authority" ] \
    || fail "replacement: original poll retirement deleted the replacement authority"
  grep -qxF "pr=$url_b" "$state/task-a.meta" \
    || fail "replacement: replacement poll was not armed"
  ack_watcher_cycle "$state" || fail "replacement: could not acknowledge the original wake"
  rm -f "$dir/fakebin/mv" "$state/.last-check"
  run_merged_poll_cycle "$dir"
  awk -F'\t' -v expected="check: merge landed: task-a $url_b" \
    '$5 == expected { found=1 } END { exit !found }' "$state/.wake-queue" \
    || fail "replacement: replacement merge lost its attended authority"
  pass "poll retirement preserves a replacement authority record"
}

# A volume remount can renumber the state filesystem's st_dev while every inode
# and byte stays put, as APFS does across a reboot. This rewrites a published
# registration's recorded device the way that leaves it, changing no other
# byte. <which> is both, data, or check.
shift_registration_device() {  # <state> <id> [both|data|check]
  local state=$1 id=$2 which=${3:-both} registration device shifted tmp
  registration="$state/$id.pr-poll-registration"
  device=$(fm_pr_file_device "$state") || fail "could not read the state device"
  shifted=$((device + 1))
  tmp=$(mktemp "$state/.test-shifted-registration.XXXXXX") || fail "could not stage a shifted registration"
  awk -v live="$device" -v shifted="$shifted" -v which="$which" '
    (NR == 10 && which != "check") || (NR == 11 && which != "data") { sub("^" live ":", shifted ":") }
    { print }
  ' "$registration" > "$tmp" || fail "could not shift the registration device"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$registration"
  case "$which" in
    both|data) [ "$(sed -n 10p "$registration")" = "$shifted:$(fm_pr_file_inode "$state/$id.pr-poll")" ] \
      || fail "shifted fixture did not move only the recorded sidecar device" ;;
  esac
  case "$which" in
    both|check) [ "$(sed -n 11p "$registration")" = "$shifted:$(fm_pr_file_inode "$state/$id.check.sh")" ] \
      || fail "shifted fixture did not move only the recorded check device" ;;
  esac
}

test_device_renumbered_poll_stays_armed() {
  local dir state out rc original
  dir=$(make_case device-renumber-merged)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  shift_registration_device "$state" task-a
  # Assert the divergence so the case cannot pass vacuously: only the recorded
  # device differs, and that alone refuses the strict validation.
  cmp -s "$POLL" "$state/task-a.check.sh" || fail "renumber fixture changed the check bytes"
  [ "$(sed -n 8p "$state/task-a.pr-poll-registration")" = "$(fm_pr_sha256 "$state/task-a.pr-poll")" ] \
    || fail "renumber fixture changed the sidecar hash"
  ! fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "renumber fixture still authenticated before any watcher cycle"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "renumbered poll watcher failed: $(cat "$dir/watch.err")"
  out=$(cat "$dir/watch.out")
  case "$out" in
    *'rejected unauthenticated state checks'*) fail "watcher refused a poll whose only change was a renumbered volume: $out" ;;
  esac
  [ "$(grep -c '^check: .*task-a\.check\.sh: merged$' "$dir/watch.out")" -eq 1 ] \
    || fail "renumbered poll did not surface its merge exactly once: $out"

  dir=$(make_case device-renumber-rerecord)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  original="$dir/registration.original"
  cp "$state/task-a.pr-poll-registration" "$original"
  shift_registration_device "$state" task-a
  add_stop_custom_check "$dir"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *"task-a.pr-poll-registration "*)
    [ -d "$FM_TEST_CONTROL_LOCK" ] || exit 91
    [ -d "$FM_TEST_POLL_PUBLISH_LOCK" ] || exit 92
    : > "$FM_TEST_REGISTRATION_RENAMED"
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  set +e
  FM_TEST_CONTROL_LOCK="$state/.control-task-a.lock" \
    FM_TEST_POLL_PUBLISH_LOCK="$state/.pr-poll-publish-task-a.lock" FM_TEST_REAL_MV="$REAL_MV" \
    FM_TEST_REGISTRATION_RENAMED="$dir/registration-renamed" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "re-record watcher failed: $(cat "$dir/watch.err")"
  [ -e "$dir/registration-renamed" ] || fail "re-record never replaced the registration under its locks"
  cmp -s "$original" "$state/task-a.pr-poll-registration" \
    || fail "re-recorded registration differs from the one published on the live device"
  [ "$(file_mode "$state/task-a.pr-poll-registration")" = 600 ] || fail "re-recorded registration is not private"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "re-recorded poll is not strictly authenticated"
  grep -F 'pullRequest(number:' "$dir/gh.log" >/dev/null \
    || fail "re-recorded poll did not run its validated check in the same cycle"
  grep -F 're-recorded PR poll identity for task-a' "$state/.watch-triage.log" >/dev/null \
    || fail "re-record left no triage evidence"
  ! ls "$state"/.fm-pr-poll-registration.* >/dev/null 2>&1 || fail "re-record left a staged registration behind"
  pass "a poll armed before a volume renumber is re-recorded under the control lock and keeps detecting merges"
}

test_device_rerecord_refuses_tampered_artifacts() {
  local mutation dir state out rc registration_sha shifted_device replacement exercised=
  for mutation in swapped-check altered-check swapped-sidecar altered-sidecar altered-template-hash \
    wrong-mode hardlinked-check split-device foreign-device; do
    # A regular file cannot sit on another device than its own directory without
    # a file mount, which Darwin does not offer, and Darwin's device helper reads
    # /usr/bin/stat directly, so no PATH fake can stand in there.
    if [ "$mutation" = foreign-device ] && [ "$(uname)" = Darwin ]; then
      exercised="$exercised (foreign-device not exercisable on Darwin)"
      continue
    fi
    exercised="$exercised $mutation"
    dir=$(make_case "device-rerecord-refuses-$mutation")
    state="$dir/home/state"
    write_poll_meta "$state" task-a https://github.com/o/r/pull/1
    seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
    if [ "$mutation" = split-device ]; then
      shift_registration_device "$state" task-a data
    else
      shift_registration_device "$state" task-a
    fi
    shifted_device=$(( $(fm_pr_file_device "$state") + 1 ))
    case "$mutation" in
      swapped-check)
        cp "$POLL" "$state/.swap"
        chmod 0600 "$state/.swap"
        mv -f -- "$state/.swap" "$state/task-a.check.sh"
        ;;
      altered-check) printf '# tampered\n' >> "$state/task-a.check.sh" ;;
      swapped-sidecar)
        cp "$state/task-a.pr-poll" "$state/.swap"
        chmod 0600 "$state/.swap"
        mv -f -- "$state/.swap" "$state/task-a.pr-poll"
        ;;
      altered-sidecar)
        printf '%s\n%s\n%s\n%s\n%s\n' github https://github.com/o/r/pull/2 github.com o/r 2 \
          > "$state/task-a.pr-poll"
        ;;
      altered-template-hash)
        replacement=$(printf 'another template\n' | shasum -a 256 | awk '{print $1}')
        awk -v hash="$replacement" 'NR == 9 { $0 = hash } { print }' \
          "$state/task-a.pr-poll-registration" > "$state/.swap"
        chmod 0600 "$state/.swap"
        mv -f -- "$state/.swap" "$state/task-a.pr-poll-registration"
        ;;
      wrong-mode) chmod 0640 "$state/task-a.check.sh" ;;
      hardlinked-check) ln "$state/task-a.check.sh" "$dir/check.alias" ;;
      split-device) ;;
      foreign-device)
        cat > "$dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TEST_FOREIGN_PATH" ]; then
  case " $* " in
    *" %d "*) printf '%s\n' "$FM_TEST_FOREIGN_DEVICE"; exit 0 ;;
  esac
fi
exec "$FM_TEST_REAL_STAT" "$@"
SH
        chmod +x "$dir/fakebin/stat"
        ;;
    esac
    ! fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
      || fail "$mutation fixture was authenticated before any watcher cycle"
    registration_sha=$(fm_pr_sha256 "$state/task-a.pr-poll-registration")
    set +e
    FM_TEST_FOREIGN_PATH="$state/task-a.check.sh" FM_TEST_FOREIGN_DEVICE="$shifted_device" \
      FM_TEST_REAL_STAT="$REAL_STAT" FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "$mutation watcher failed: $(cat "$dir/watch.err")"
    out=$(cat "$dir/watch.out")
    case "$out" in
      "check: rejected unauthenticated state checks:"*"task-a.check.sh"*) ;;
      *) fail "$mutation on a renumbered registration was not refused: $out" ;;
    esac
    [ "$(fm_pr_sha256 "$state/task-a.pr-poll-registration")" = "$registration_sha" ] \
      || fail "$mutation let the watcher re-record the registration"
    ! grep -F 'pullRequest(number:' "$dir/gh.log" >/dev/null 2>&1 \
      || fail "$mutation ran the refused poll"
    ! ls "$state"/.fm-pr-poll-registration.* >/dev/null 2>&1 \
      || fail "$mutation left a staged registration behind"
  done

  dir=$(make_case device-rerecord-pending-retirement)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  shift_registration_device "$state" task-a
  fm_pr_poll_registration_device_shifted "$state" task-a "$POLL" \
    || fail "pending-retirement fixture was not a device shift before its receipt"
  : > "$state/task-a.pr-poll-retirement"
  chmod 0600 "$state/task-a.pr-poll-retirement"
  ! fm_pr_poll_registration_device_shifted "$state" task-a "$POLL" \
    || fail "a pending retirement receipt did not keep its artifacts from being re-recorded"
  ! fm_pr_poll_registration_rerecord_device "$state" task-a "$POLL" \
    || fail "a pending retirement receipt was re-recorded around"
  pass "a renumbered registration is never re-recorded around a tampered artifact:$exercised, or a pending retirement"
}

start_poll_publish_holder() {  # <dir> <state> <id>
  local dir=$1 state=$2 id=$3 i
  PR_POLL_HOLDER_ACQUIRED="$dir/poll-publish-holder-acquired"
  PR_POLL_HOLDER_RELEASE="$dir/poll-publish-holder-release"
  PR_POLL_HOLDER_LOCK="$state/.pr-poll-publish-$id.lock"
  cat > "$dir/poll-publish-holder.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
trap 'fm_lock_release "$FM_TEST_LOCK" || true' EXIT
fm_lock_acquire_wait "$FM_TEST_LOCK"
: > "$FM_TEST_ACQUIRED"
while [ ! -e "$FM_TEST_RELEASE" ]; do sleep 0.01; done
SH
  chmod +x "$dir/poll-publish-holder.sh"
  FM_TEST_ROOT="$ROOT" FM_TEST_LOCK="$PR_POLL_HOLDER_LOCK" \
    FM_TEST_ACQUIRED="$PR_POLL_HOLDER_ACQUIRED" FM_TEST_RELEASE="$PR_POLL_HOLDER_RELEASE" \
    "$dir/poll-publish-holder.sh" &
  PR_POLL_HOLDER_PID=$!
  for i in $(seq 1 100); do
    [ -e "$PR_POLL_HOLDER_ACQUIRED" ] && return 0
    sleep 0.02
  done
  kill "$PR_POLL_HOLDER_PID" 2>/dev/null || true
  wait "$PR_POLL_HOLDER_PID" 2>/dev/null || true
  fail "poll publication holder did not acquire its lock"
}

release_poll_publish_holder() {
  : > "$PR_POLL_HOLDER_RELEASE"
  wait "$PR_POLL_HOLDER_PID" || fail "poll publication holder did not release its lock"
}

test_device_rerecord_serializes_direct_rearm() {
  local dir state url_a url_b i rearm_pid
  url_a=https://github.com/o/r/pull/1
  url_b=https://github.com/o/r/pull/2
  dir=$(make_case device-rerecord-serialized-direct-rearm)
  state="$dir/home/state"
  write_poll_meta "$state" task-a "$url_a"
  seed_canonical_poll "$dir" task-a "$url_a"
  cp "$state/task-a.pr-poll" "$dir/published.pr-poll"
  cp "$state/task-a.pr-poll-registration" "$dir/published.registration"
  cp "$state/task-a.check.sh" "$dir/published.check.sh"
  start_poll_publish_holder "$dir" "$state" task-a
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_TEST_GUARD_LOG="$dir/guard.log" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a "$url_b" > "$dir/rearm.out" 2> "$dir/rearm.err" &
  rearm_pid=$!
  for i in $(seq 1 100); do
    if fm_pr_metadata_identity_parse "$state/task-a.meta" && [ "$FM_PR_META_URL" = "$url_b" ]; then
      break
    fi
    sleep 0.02
  done
  [ "$FM_PR_META_URL" = "$url_b" ] || fail "direct re-arm did not rewrite metadata before publication"
  sleep 1
  process_is_live_non_zombie "$rearm_pid" || fail "direct re-arm did not wait for poll publication"
  cmp -s "$dir/published.pr-poll" "$state/task-a.pr-poll" \
    || fail "blocked direct re-arm replaced the published sidecar"
  cmp -s "$dir/published.registration" "$state/task-a.pr-poll-registration" \
    || fail "blocked direct re-arm replaced the published registration"
  cmp -s "$dir/published.check.sh" "$state/task-a.check.sh" \
    || fail "blocked direct re-arm replaced the published check"
  release_poll_publish_holder
  wait "$rearm_pid" || fail "direct re-arm failed after poll publication release: $(cat "$dir/rearm.err")"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "released direct re-arm did not publish a strict poll"
  [ "$(sed -n 4p "$state/task-a.pr-poll-registration")" = "$url_b" ] \
    || fail "released direct re-arm registration does not name its PR"
  pass "direct re-arm publication waits without replacing an armed poll"
}

test_device_rerecord_serializes_rerecord() {
  local dir state original rc watcher_pid i
  dir=$(make_case device-rerecord-serialized-rerecord)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  cp "$state/task-a.pr-poll-registration" "$dir/registration.original"
  shift_registration_device "$state" task-a
  original=$(fm_pr_sha256 "$state/task-a.pr-poll-registration")
  add_stop_custom_check "$dir"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *"task-a.pr-poll-registration "*)
    [ -d "$FM_TEST_CONTROL_LOCK" ] || exit 91
    [ -d "$FM_TEST_POLL_PUBLISH_LOCK" ] || exit 92
    : > "$FM_TEST_REGISTRATION_RENAMED"
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  start_poll_publish_holder "$dir" "$state" task-a
  FM_TEST_CONTROL_LOCK="$state/.control-task-a.lock" \
    FM_TEST_POLL_PUBLISH_LOCK="$state/.pr-poll-publish-task-a.lock" \
    FM_TEST_REGISTRATION_RENAMED="$dir/registration-renamed" FM_TEST_REAL_MV="$REAL_MV" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher_pid=$!
  for i in $(seq 1 100); do
    [ -d "$state/.control-task-a.lock" ] && break
    sleep 0.02
  done
  [ -d "$state/.control-task-a.lock" ] || fail "watcher did not reach its device re-record"
  sleep 1
  process_is_live_non_zombie "$watcher_pid" || fail "watcher did not wait for poll publication"
  [ "$(fm_pr_sha256 "$state/task-a.pr-poll-registration")" = "$original" ] \
    || fail "blocked watcher rewrote a device-shifted registration"
  [ ! -e "$dir/registration-renamed" ] || fail "blocked watcher renamed the registration"
  release_poll_publish_holder
  rc=0
  wait "$watcher_pid" || rc=$?
  [ "$rc" -eq 0 ] || fail "released watcher re-record failed: $(cat "$dir/watch.err")"
  [ -e "$dir/registration-renamed" ] || fail "released watcher did not replace the registration"
  cmp -s "$dir/registration.original" "$state/task-a.pr-poll-registration" \
    || fail "released watcher did not restore the live-device registration"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "released watcher did not strictly authenticate the poll"
  pass "device re-record publication waits without rewriting its registration"
}

# An unmerged pull request outside the queue with a new removal event must
# wake once with GitHub's removal reason. A merge still wakes as merged
# alone. An unreadable read, or a poll with no removal event, stays silent.
# A follow-up cycle has to acknowledge the previous wake first. Otherwise the
# watcher re-announces that wake and never reaches the poll, and a missing
# dequeue line would pass without the poll having run.
expect_stop_cycle() {  # <output> <why>
  [ "$(wc -l < "$1" | tr -d '[:space:]')" -eq 1 ] || fail "$2: $(cat "$1")"
  case "$(cat "$1")" in
    check:*z-stop.check.sh:*stop-cycle) ;;
    *) fail "$2: $(cat "$1")" ;;
  esac
}

test_github_poll_uses_the_pr_host() {
  local dir state url out
  dir=$(make_case github-poll-host)
  state="$dir/home/state"
  url=https://github.com/o/r/pull/1
  make_poll_fixture "$dir"
  out=$(GH_HOST=ghe.example FM_TEST_GH_STATE=OPEN run_poll "$dir")
  [ -z "$out" ] || fail "enterprise host falsely reported a merge for the GitHub PR: $out"
  out=$(GH_HOST=ghe.example FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ "$out" = merged ] || fail "explicit GitHub host did not report its real merged state: $out"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  add_stop_custom_check "$dir"
  GH_HOST=ghe.example FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_REASON=failed_checks \
    FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50MQ== \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "GitHub host watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/watch.out")" -eq 1 ] \
    || fail "GitHub host watcher did not report its removal: $(cat "$dir/watch.out")"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "enterprise host retired the GitHub PR watch"
  pass "a GitHub PR stays bound to github.com despite an enterprise GH_HOST"
}

test_github_identity_fields_stay_strings() {
  local dir state path url out number
  for path in acme/123 123/r acme/true true/r acme/false false/r acme/null null/r; do
    dir=$(make_case "github-identity-${path%/*}-${path#*/}")
    state="$dir/home/state"
    url="https://github.com/$path/pull/7"
    write_poll_meta "$state" task-a "$url"
    seed_canonical_poll "$dir" task-a "$url"
    out=$(FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
      FM_TEST_GH_POLL_EVENT=evt7 FM_TEST_GH_POLL_REASON=failed_checks run_poll "$dir")
    [ "$out" = "dequeued $url reason=failed_checks event=evt7" ] \
      || fail "$path lost its armed queue removal: $out"
    out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
    [ "$out" = merged ] || fail "$path lost its merge confirmation: $out"
    write_slow_sweep_page "$dir" page1 8 true page2
    write_slow_sweep_page "$dir" page2 9 false ""
    FM_TEST_GH_LOG="$dir/sweep-gh.log" FM_TEST_GH_SWEEP_DIR="$dir/sweep" PATH="$dir/fakebin:$BASE_PATH" \
      "$ROOT/bin/fm-pr-queue-sweep.sh" --scan "$state" > "$dir/sweep.out" 2> "$dir/sweep.err" \
      || fail "$path failed pagination: $(cat "$dir/sweep.err")"
    for number in 8 9; do
      [ "$(grep -Fxc "dequeued https://github.com/$path/pull/$number reason=failed_checks event=evt$number" "$dir/sweep.out")" -eq 1 ] \
        || fail "$path lost its page removal for pull $number: $(cat "$dir/sweep.out")"
    done
    if [ "$path" = acme/123 ]; then
      retire_contributions_observer "$dir"
      add_stop_custom_check "$dir"
      FM_TEST_GH_LOG="$dir/watch-gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
        FM_TEST_GH_POLL_EVENT=evt7 FM_TEST_GH_POLL_REASON=failed_checks FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
        run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
        || fail "numeric repository watcher failed: $(cat "$dir/watch.err")"
      FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
        > "$dir/drain.out" 2> "$dir/drain.err" || fail "numeric repository wake drain failed"
      for number in 7 8 9; do
        [ "$(grep -Fc "dequeued https://github.com/$path/pull/$number reason=failed_checks" "$dir/drain.out")" -eq 1 ] \
          || fail "numeric repository wake lost pull $number: $(cat "$dir/drain.out")"
      done
    fi
  done
  pass "numeric and JSON-literal identities preserve merge reads and queue-removal wakes on every page"
}

test_dequeue_sweep_reaches_later_checks() {
  local dir state round id
  dir=$(make_case dequeue-sweep)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  write_poll_meta "$state" task-b https://github.com/o/r/pull/2
  seed_canonical_poll "$dir" task-b https://github.com/o/r/pull/2
  cat > "$state/mail.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'visited\n' >> "$FM_HOME/state/mail.log"
printf 'poll did not finish within 1s budget\n'
SH
  chmod 0700 "$state/mail.check.sh"
  FM_HOME="$dir/home" "$REGISTER" mail >/dev/null \
    || fail "could not register the recurring mail timeout check"
  cat > "$state/task-a0.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'visited\n' >> "$FM_HOME/state/midpoint.log"
if [ -e "$FM_HOME/state/.last-check" ]; then
  printf 'premature timestamp\n'
fi
printf 'midpoint\n'
SH
  chmod 0700 "$state/task-a0.check.sh"
  FM_HOME="$dir/home" "$REGISTER" task-a0 >/dev/null \
    || fail "could not register the check between PR polls"
  add_stop_custom_check "$dir"
  for round in 1 2; do
    rm -f "${state:?}/.last-check"
    # shellcheck disable=SC2016 # $event and $reason are jq variables.
    "$REAL_JQ" -n --arg event "drop-a-$round" '
      def pull($event; $reason):
        {data:{repository:{pullRequest:{state:"OPEN",merged:false,isInMergeQueue:false,
          timelineItems:{nodes:[{id:$event,reason:$reason}]}}}}};
      {"1":pull($event; "failed_checks"), "2":pull("drop-b-1"; "ci_failure")}
    ' > "$dir/poll-responses.json"
    LC_ALL=C FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_POLL_RESPONSES="$dir/poll-responses.json" \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-$round.out" 2> "$dir/watch-$round.err" \
      || fail "dequeue sweep $round failed: $(cat "$dir/watch-$round.err")"
    [ "$(grep -cxF "check: $state/mail.check.sh: poll did not finish within 1s budget" "$dir/watch-$round.out")" -eq 1 ] \
      || fail "dequeue sweep $round lost the earlier mail timeout"
    [ "$(wc -l < "$state/mail.log" | tr -d '[:space:]')" -eq "$round" ] \
      || fail "dequeue sweep $round skipped or repeated the mail check"
    [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/watch-$round.out")" -eq 1 ] \
      || fail "dequeue sweep $round missed the new first-PR removal: $(cat "$dir/watch-$round.out")"
    if [ "$round" -eq 1 ]; then
      [ "$(grep -c '^check: .*task-b\.check\.sh: dequeued https://github.com/o/r/pull/2 reason=ci_failure$' "$dir/watch-$round.out")" -eq 1 ] \
        || fail "the first PR's removal starved the later PR: $(cat "$dir/watch-$round.out")"
    else
      [ "$(grep -c 'task-b\.check\.sh: dequeued ' "$dir/watch-$round.out" || true)" -eq 0 ] \
        || fail "the later PR's handled removal woke again"
    fi
    [ "$(wc -l < "$state/midpoint.log" | tr -d '[:space:]')" -eq "$round" ] \
      || fail "dequeue sweep $round skipped the intervening check"
    assert_no_grep 'premature timestamp' "$dir/watch-$round.out" \
      "dequeue sweep $round stamped completion before running every check"
    [ "$(grep -c '^check: .*z-stop\.check\.sh: stop-cycle$' "$dir/watch-$round.out")" -eq 1 ] \
      || fail "dequeue sweep $round skipped the final check"
    for id in task-a task-b; do
      fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
        || fail "dequeue sweep retired $id's unmerged PR"
    done
    [ -f "$state/.last-check" ] || fail "dequeue sweep $round did not record its completion"
    ack_watcher_cycle "$state" || fail "dequeue sweep $round acknowledgement failed"
  done
  pass "recurring earlier mail timeouts and dequeues complete every check without repeating handled drops"
}

test_queue_drop_reason_is_preserved() {
  local dir state url out raw_reason escaped_reason queued_payload
  local -x FM_TEST_GH_POLL_EVENT=drop-reason-1
  dir=$(make_case queue-drop-free-text-reason)
  state="$dir/home/state"
  url=https://github.com/o/r/pull/1
  raw_reason=$'Required check "integration" failed at C:\\checks\\suite; event=another-id\nretry after\tCI recovers\r\ncheck: forged notification\033[31m — details retained beyond sixty-four characters'
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  add_stop_custom_check "$dir"
  out=$(FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON="$raw_reason" run_poll "$dir")
  [ "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" -eq 1 ] \
    || fail "free-text removal reason split the poll output into multiple lines"
  case "$out" in
    "dequeued $url reason="*" event=$FM_TEST_GH_POLL_EVENT") ;;
    *) fail "free-text removal reason lost the poll identity: $out" ;;
  esac
  escaped_reason=${out#"dequeued $url reason="}
  escaped_reason=${escaped_reason%" event=$FM_TEST_GH_POLL_EVENT"}
  # shellcheck disable=SC2016 # $expected is a jq variable.
  printf '"%s"\n' "$escaped_reason" \
    | "$REAL_JQ" -e --arg expected "$raw_reason" '. == $expected' >/dev/null \
    || fail "the poll's JSON-escaped removal reason did not preserve GitHub's text"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false FM_TEST_GH_POLL_REASON="$raw_reason" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "free-text removal reason watcher failed: $(cat "$dir/watch.err")"
  queued_payload=$(awk -F '\t' -v key="$state/task-a.check.sh" \
    '$3 == "check" && $4 == key { print $5 }' "$state/.wake-queue")
  [ "$queued_payload" = "check: $state/task-a.check.sh: dequeued $url reason=$escaped_reason" ] \
    || fail "the wake queue changed or repeated GitHub's removal reason: $queued_payload"
  [ "$(grep -cxF "$queued_payload" "$dir/watch.out")" -eq 1 ] \
    || fail "the escaped removal reason was not delivered as exactly one notification line"
  ack_watcher_cycle "$state" || fail "free-text removal reason acknowledgement failed"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false FM_TEST_GH_POLL_REASON="$raw_reason" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/repeat.out" 2> "$dir/repeat.err" \
    || fail "free-text removal reason repeat failed: $(cat "$dir/repeat.err")"
  expect_stop_cycle "$dir/repeat.out" "a handled free-text removal woke again"
  pass "GitHub removal reasons preserve long text, quotes, delimiters, Unicode, and escaped control characters"
}

test_verified_queue_drop_wakes_once() {
  local dir state url rc out
  local -x FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50MQ==
  url=https://github.com/o/r/pull/1

  dir=$(make_case queue-drop-once)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "queue drop: could not arm the merge poll"
  queue_merge "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  out=$(FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks run_poll "$dir")
  [ "$out" = "dequeued $url reason=failed_checks event=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50MQ==" ] \
    || fail "queue drop was not captured: $out"
  [ ! -e "$state/task-a.pr-poll-queue-dropped" ] \
    || fail "capturing a queue drop marked it reported before publication"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "queue drop watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/watch.out")" -eq 1 ] \
    || fail "verified queue drop did not wake once: $(cat "$dir/watch.out")"
  [ "$(awk -F '\t' -v key="$state/task-a.check.sh" '$3 == "check" && $4 == key { count++ } END { print count + 0 }' "$state/.wake-queue")" -eq 1 ] \
    || fail "verified queue drop did not publish exactly one wake row"
  ack_watcher_cycle "$state" || fail "queue drop: could not acknowledge the first wake"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch2.out" 2> "$dir/watch2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "second queue drop watcher failed: $(cat "$dir/watch2.err")"
  expect_stop_cycle "$dir/watch2.out" "verified queue drop woke again"

  dir=$(make_case queue-drop-publication-failure)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "publication failure: could not arm the merge poll"
  queue_merge "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  mkdir "$state/.wake-queue.seq"
  : > "$dir/gh.log"
  set +e
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/failed.out" 2> "$dir/failed.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "queue drop watcher succeeded despite publication failure"
  [ -s "$dir/gh.log" ] || fail "publication failure did not reach the poll"
  [ ! -e "$state/task-a.pr-poll-queue-dropped" ] \
    || fail "publication failure consumed an undelivered queue drop"
  [ ! -s "$state/.wake-queue" ] || fail "publication failure left an unexpected wake row"
  rmdir "$state/.wake-queue.seq"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/retry.out" 2> "$dir/retry.err" \
    || fail "queue drop retry failed: $(cat "$dir/retry.err")"
  if [ "$(cat "$dir/retry.out")" = 'check: rearm-resurface' ]; then
    ack_watcher_cycle "$state" || fail "publication failure recovery acknowledgement failed"
    FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
      FM_TEST_GH_POLL_REASON=failed_checks \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/retry.out" 2> "$dir/retry.err" \
      || fail "queue drop retry after recovery failed: $(cat "$dir/retry.err")"
  fi
  [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/retry.out")" -eq 1 ] \
    || fail "queue drop retry did not wake once: $(cat "$dir/retry.out")"
  ack_watcher_cycle "$state" || fail "publication failure retry acknowledgement failed"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/repeat.out" 2> "$dir/repeat.err" \
    || fail "queue drop repeat after recovery failed: $(cat "$dir/repeat.err")"
  expect_stop_cycle "$dir/repeat.out" "published queue drop woke again after a failed append"

  dir=$(make_case queue-then-merged)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "queued merge: could not arm the merge poll"
  queue_merge "$dir" "$url"
  run_merged_poll_cycle "$dir"
  [ "$(grep -c '^check: .*task-a\.check\.sh: merged$' "$dir/watch.out")" -eq 1 ] \
    || fail "queued merge did not wake as merged: $(cat "$dir/watch.out")"
  [ "$(grep -c 'dequeued ' "$dir/watch.out")" -eq 0 ] \
    || fail "queued merge also woke as dequeued: $(cat "$dir/watch.out")"
  assert_poll_absent "$state" task-a

  dir=$(make_case queue-drop-unreadable)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "unreadable drop: could not arm the merge poll"
  queue_merge "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_FAIL=1 \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "unreadable drop watcher failed: $(cat "$dir/watch.err")"
  expect_stop_cycle "$dir/watch.out" "unreadable drop woke"

  dir=$(make_case queue-drop-between-polls)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "unobserved queue: could not arm the merge poll"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_EVENT='' \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/empty.out" 2> "$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "no-event watcher failed: $(cat "$dir/empty.err")"
  expect_stop_cycle "$dir/empty.out" "a poll with no removal event woke as dequeued"
  ack_watcher_cycle "$state" || fail "no-event cycle acknowledgement failed"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "unobserved queue drop watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/watch.out")" -eq 1 ] \
    || fail "queue drop between polls did not wake once: $(cat "$dir/watch.out")"
  [ "$(awk -F '\t' -v key="$state/task-a.check.sh" '$3 == "check" && $4 == key { count++ } END { print count + 0 }' "$state/.wake-queue")" -eq 1 ] \
    || fail "queue drop between polls did not publish exactly one wake row"
  ack_watcher_cycle "$state" || fail "unobserved queue drop acknowledgement failed"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/repeat.out" 2> "$dir/repeat.err" \
    || fail "unobserved queue drop repeat failed: $(cat "$dir/repeat.err")"
  expect_stop_cycle "$dir/repeat.out" "a handled drop between polls woke again"

  dir=$(make_case queue-observed-then-dropped)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "observed queue: could not arm the merge poll"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=true \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/queued.out" 2> "$dir/queued.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "observed queue watcher failed: $(cat "$dir/queued.err")"
  expect_stop_cycle "$dir/queued.out" "a pull request still in the queue woke as dequeued"
  ack_watcher_cycle "$state" || fail "observed queue: could not acknowledge the queued wake"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON='failed checks' \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "observed drop watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed checks$' "$dir/watch.out")" -eq 1 ] \
    || fail "observed queue drop did not preserve GitHub's reason: $(cat "$dir/watch.out")"

  dir=$(make_case queue-drop-contradiction)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "contradiction: could not arm the merge poll"
  queue_merge "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_MERGED=true FM_TEST_GH_POLL_QUEUED=false \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "contradiction watcher failed: $(cat "$dir/watch.err")"
  expect_stop_cycle "$dir/watch.out" "contradictory read woke"

  dir=$(make_case queue-drop-empty-reason)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "empty reason: could not arm the merge poll"
  queue_merge "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON='' \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "empty reason watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=$' "$dir/watch.out")" -eq 1 ] \
    || fail "empty removal reason was not named: $(cat "$dir/watch.out")"

  dir=$(make_case queue-merged-with-removal-reason)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "merged with reason: could not arm the merge poll"
  queue_merge "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged-with-reason watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*task-a\.check\.sh: merged$' "$dir/watch.out")" -eq 1 ] \
    || fail "merged pull request with a removal reason did not wake as merged: $(cat "$dir/watch.out")"
  [ "$(grep -c 'dequeued ' "$dir/watch.out")" -eq 0 ] \
    || fail "merged pull request also woke as dequeued: $(cat "$dir/watch.out")"

  dir=$(make_case queue-reentry-drops-once-each)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "re-entry: could not arm the merge poll"
  queue_merge "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/first.out" 2> "$dir/first.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "re-entry first drop watcher failed: $(cat "$dir/first.err")"
  [ "$(grep -c 'dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/first.out")" -eq 1 ] \
    || fail "re-entry first drop did not wake: $(cat "$dir/first.out")"
  ack_watcher_cycle "$state" || fail "re-entry: could not acknowledge the first drop"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=true \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/back.out" 2> "$dir/back.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "re-entry queue watcher failed: $(cat "$dir/back.err")"
  expect_stop_cycle "$dir/back.out" "re-entry while queued woke as dequeued"
  ack_watcher_cycle "$state" || fail "re-entry: could not acknowledge the return to the queue"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/stale.out" 2> "$dir/stale.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "re-entry stale event watcher failed: $(cat "$dir/stale.err")"
  expect_stop_cycle "$dir/stale.out" "re-entry reported the same removal event again"
  ack_watcher_cycle "$state" || fail "re-entry: could not acknowledge the stale event cycle"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=ci_failure FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50Mg== \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/second.out" 2> "$dir/second.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "re-entry second drop watcher failed: $(cat "$dir/second.err")"
  [ "$(grep -c 'dequeued https://github.com/o/r/pull/1 reason=ci_failure$' "$dir/second.out")" -eq 1 ] \
    || fail "re-entry second drop did not wake once: $(cat "$dir/second.out")"
  ack_watcher_cycle "$state" || fail "re-entry: could not acknowledge the second drop"
  set +e
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=ci_failure FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50Mg== \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/third.out" 2> "$dir/third.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "re-entry repeat watcher failed: $(cat "$dir/third.err")"
  expect_stop_cycle "$dir/third.out" "re-entry second drop woke again"

  dir=$(make_case queue-reentry-between-polls)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err" \
    || fail "unobserved re-entry: could not arm the merge poll"
  queue_merge "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "unobserved re-entry first drop failed: $(cat "$dir/first.err")"
  [ "$(grep -c 'dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/first.out")" -eq 1 ] \
    || fail "unobserved re-entry first drop did not wake once: $(cat "$dir/first.out")"
  ack_watcher_cycle "$state" || fail "unobserved re-entry first drop acknowledgement failed"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50Mg== \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/second.out" 2> "$dir/second.err" \
    || fail "unobserved re-entry second drop failed: $(cat "$dir/second.err")"
  [ "$(grep -c 'dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/second.out")" -eq 1 ] \
    || fail "unobserved re-entry second removal did not wake once: $(cat "$dir/second.out")"
  [ "$(awk -F '\t' -v key="$state/task-a.check.sh" '$3 == "check" && $4 == key { count++ } END { print count + 0 }' "$state/.wake-queue")" -eq 1 ] \
    || fail "unobserved re-entry second removal did not publish exactly one wake row"
  ack_watcher_cycle "$state" || fail "unobserved re-entry second drop acknowledgement failed"
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50Mg== \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/repeat.out" 2> "$dir/repeat.err" \
    || fail "unobserved re-entry repeat failed: $(cat "$dir/repeat.err")"
  expect_stop_cycle "$dir/repeat.out" "unobserved re-entry repeated a handled removal"

  pass "a verified queue drop wakes once, a merge stays a merge, and a bad read stays silent"
}

# The nine stranded open pull requests, plus 4308 at the moment it left the
# queue, are the replay. A re-added pull request and a merged removal are not.
write_queue_sweep_pages() {
  local dir=$1
  mkdir -p "$dir/sweep"
  # shellcheck disable=SC2016 # $n, $reason, $kind, and $queued are jq variables.
  "$REAL_JQ" -n '
    def node($n; $reason; $kind; $queued):
      {number:$n, state:"OPEN", merged:false, isInMergeQueue:$queued,
       timelineItems:{nodes:
         (if $kind == "added" then
            [{__typename:"AddedToMergeQueueEvent", id:("evt"+($n|tostring))}]
          else
            [{__typename:"RemovedFromMergeQueueEvent", id:("evt"+($n|tostring)), reason:$reason}]
          end)}};
    def page($nodes; $more; $cursor):
      {data:{repository:{pullRequests:{
        pageInfo:{hasNextPage:$more, endCursor:(if $more then $cursor else null end)},
        nodes:$nodes}}}};
    page([
      node(3941; "merge_conflict"; "removed"; false),
      node(3950; "merge_conflict"; "removed"; false),
      node(3939; "manual"; "removed"; false),
      node(4006; "merge_conflict"; "removed"; false),
      node(4017; "failed_checks"; "removed"; false),
      node(4308; "failed_checks"; "removed"; false)
    ]; true; "page2")
  ' > "$dir/sweep/page1.json"
  # shellcheck disable=SC2016 # $n, $reason, $kind, and $queued are jq variables.
  "$REAL_JQ" -n '
    def node($n; $reason; $kind; $queued):
      {number:$n, state:"OPEN", merged:false, isInMergeQueue:$queued,
       timelineItems:{nodes:
         (if $kind == "added" then
            [{__typename:"AddedToMergeQueueEvent", id:("evt"+($n|tostring))}]
          else
            [{__typename:"RemovedFromMergeQueueEvent", id:("evt"+($n|tostring)), reason:$reason}]
          end)}};
    def page($nodes; $more; $cursor):
      {data:{repository:{pullRequests:{
        pageInfo:{hasNextPage:$more, endCursor:(if $more then $cursor else null end)},
        nodes:$nodes}}}};
    page([
      node(4111; "merge_conflict"; "removed"; false),
      node(4172; "manual"; "removed"; false),
      node(4183; "merge_conflict"; "removed"; false),
      node(4200; "merge_conflict"; "removed"; false),
      node(3361; "manual"; "added"; false),
      node(9001; "merged"; "removed"; false),
      node(9002; null; "removed"; false),
      node(9003; ""; "removed"; false),
      node(9004; "échec des vérifications"; "removed"; false),
      node(9005; "failed \"checks\"\\path\nnext\tline\rcontrol\u0001 event=not-the-id"; "removed"; false)
    ]; false; "")
  ' > "$dir/sweep/page2.json"
}

test_open_queue_removals_wake_once_across_a_watched_repo() {
  local dir state url spec number reason
  url=https://github.com/groovejones/groove-sight-platform/pull/4308
  dir=$(make_case open-queue-removals)
  state="$dir/home/state"
  write_queue_sweep_pages "$dir"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  add_stop_custom_check "$dir"
  LC_ALL=C FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks FM_TEST_GH_POLL_EVENT=evt4308 \
    FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "open queue sweep failed: $(cat "$dir/watch.err")"
  for spec in \
    3941:merge_conflict 3950:merge_conflict 3939:manual 4006:merge_conflict \
    4017:failed_checks 4111:merge_conflict 4172:manual 4183:merge_conflict \
    4200:merge_conflict 4308:failed_checks
  do
    number=${spec%%:*}
    reason=${spec#*:}
    [ "$(grep -c "dequeued https://github.com/groovejones/groove-sight-platform/pull/${number} reason=${reason}$" "$dir/watch.out")" -eq 1 ] \
      || fail "pull ${number} was not reported once: $(cat "$dir/watch.out")"
  done
  for number in 9002 9003 9004 9005; do
    case "$number" in
      9002|9003) reason= ;;
      9004) reason='échec des vérifications' ;;
      9005) reason='failed \"checks\"\\path\nnext\tline\rcontrol\u0001 event=not-the-id' ;;
    esac
    [ "$(grep -Fxc "check: $ROOT/bin/fm-pr-queue-sweep.sh: dequeued https://github.com/groovejones/groove-sight-platform/pull/${number} reason=${reason}" "$dir/watch.out")" -eq 1 ] \
      || fail "pull ${number} lost or changed its reason: $(cat "$dir/watch.out")"
  done
  ! grep -F 'pull/3361' "$dir/watch.out" >/dev/null \
    || fail "a re-added pull request woke: $(cat "$dir/watch.out")"
  ! grep -F 'pull/9001' "$dir/watch.out" >/dev/null \
    || fail "a merged removal woke: $(cat "$dir/watch.out")"
  [ "$(grep -c 'dequeued ' "$dir/watch.out")" -eq 14 ] \
    || fail "the sweep did not report fourteen removals: $(cat "$dir/watch.out")"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "open queue sweep drain failed: $(cat "$dir/drain.err")"
  for spec in \
    3941:merge_conflict 3950:merge_conflict 3939:manual 4006:merge_conflict \
    4017:failed_checks 4111:merge_conflict 4172:manual 4183:merge_conflict \
    4200:merge_conflict 4308:failed_checks
  do
    number=${spec%%:*}
    reason=${spec#*:}
    [ "$(grep -c "dequeued https://github.com/groovejones/groove-sight-platform/pull/${number} reason=${reason}$" "$dir/drain.out")" -eq 1 ] \
      || fail "drain dropped pull ${number}: $(cat "$dir/drain.out")"
  done
  for number in 9002 9003 9004 9005; do
    case "$number" in
      9002|9003) reason= ;;
      9004) reason='échec des vérifications' ;;
      9005) reason='failed \"checks\"\\path\nnext\tline\rcontrol\u0001 event=not-the-id' ;;
    esac
    [ "$(grep -Fc "dequeued https://github.com/groovejones/groove-sight-platform/pull/${number} reason=${reason}" "$dir/drain.out")" -eq 1 ] \
      || fail "drain dropped pull ${number}: $(cat "$dir/drain.out")"
  done
  [ "$(file_mode "$state/merge-queue-sweep.seen")" = 600 ] \
    || fail "the seen record is not private"
  ack_watcher_cycle "$state" || fail "open queue sweep acknowledgement failed"
  LC_ALL=C FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks FM_TEST_GH_POLL_EVENT=evt4308 \
    FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/repeat.out" 2> "$dir/repeat.err" \
    || fail "open queue sweep repeat failed: $(cat "$dir/repeat.err")"
  expect_stop_cycle "$dir/repeat.out" "a handled removal woke again"

  dir=$(make_case open-queue-removals-unreadable)
  state="$dir/home/state"
  write_queue_sweep_pages "$dir"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  add_stop_custom_check "$dir"
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_SWEEP_FAIL=1 FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/fail.out" 2> "$dir/fail.err" \
    || fail "unreadable queue sweep failed closed: $(cat "$dir/fail.err")"
  expect_stop_cycle "$dir/fail.out" "an unreadable sweep woke"
  [ ! -e "$state/merge-queue-sweep.seen" ] \
    || fail "an unreadable sweep recorded events"

  pass "open pull requests removed from a watched queue wake once"
}

test_seen_record_errors_do_not_block_later_watches() {
  local dir state seen fault round target rc
  for fault in unreadable malformed symlink; do
    dir=$(make_case "later-watches-seen-$fault")
    state="$dir/home/state"
    seen="$state/merge-queue-sweep.seen"
    write_poll_meta "$state" task-a https://github.com/o/r/pull/1
    seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
    write_poll_meta "$state" task-b https://github.com/o/r/pull/3
    seed_canonical_poll "$dir" task-b https://github.com/o/r/pull/3
    write_poll_meta "$state" task-c https://gitlab.example/group/subgroup/project/-/merge_requests/17
    seed_canonical_poll "$dir" task-c https://gitlab.example/group/subgroup/project/-/merge_requests/17
    retire_contributions_observer "$dir"
    add_stop_custom_check "$dir"
    case "$fault" in
      unreadable)
        printf 'fm-merge-queue-sweep-v1\n' > "$seen"
        chmod 0000 "$seen"
        ;;
      malformed)
        printf 'malformed\n' > "$seen"
        chmod 0600 "$seen"
        ;;
      symlink)
        target="$dir/seen-target"
        printf 'kept\n' > "$target"
        ln -s "$target" "$seen"
        ;;
    esac
    for round in 1 2; do
      cat > "$dir/poll-responses.json" <<JSON
{
  "1": {"data": {"repository": {"pullRequest": {
    "state": "OPEN", "merged": false, "isInMergeQueue": false,
    "timelineItems": {"nodes": [{"id": "drop-a-$round", "reason": "failed_checks"}]}
  }}}},
  "3": {"data": {"repository": {"pullRequest": {
    "state": "OPEN", "merged": false, "isInMergeQueue": true,
    "timelineItems": {"nodes": []}
  }}}}
}
JSON
      FM_TEST_GH_LOG="$dir/gh-$round.log" FM_TEST_GH_POLL_RESPONSES="$dir/poll-responses.json" \
        FM_TEST_GLAB_LOG="$dir/glab-$round.log" FM_TEST_GLAB_STATE=opened \
        run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-$round.out" 2> "$dir/watch-$round.err" \
        || fail "$fault seen record blocked later watches in round $round: $(cat "$dir/watch-$round.err")"
      [ "$(grep -Fc 'number=3' "$dir/gh-$round.log")" -eq 1 ] \
        || fail "$fault seen record starved the later GitHub watch in round $round"
      [ "$(grep -Fxc 'mr view 17 -R https://gitlab.example/group/subgroup/project' "$dir/glab-$round.log")" -eq 1 ] \
        || fail "$fault seen record starved the later GitLab watch in round $round"
      [ "$(grep -Fxc "check: $state/task-a.check.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks" "$dir/watch-$round.out")" -eq 1 ] \
        || fail "$fault seen record suppressed the armed removal in round $round"
      [ "$(grep -Fxc "check: $state/z-stop.check.sh: stop-cycle" "$dir/watch-$round.out")" -eq 1 ] \
        || fail "$fault seen record skipped the final check in round $round"
      ! grep -F 'fm-pr-queue-sweep.sh: dequeued ' "$dir/watch-$round.out" >/dev/null \
        || fail "$fault seen record produced a sweep removal in round $round"
      rc=0
      "$ROOT/bin/fm-pr-queue-sweep.sh" --scan "$state" \
        > "$dir/scan.out" 2> "$dir/scan.err" || rc=$?
      [ "$rc" -eq 1 ] || fail "$fault seen record stopped failing the sweep (rc=$rc)"
      if [ "$fault" = symlink ]; then
        [ "$(cat "$target")" = kept ] || fail "an unsafe seen record was followed"
        [ -L "$seen" ] || fail "an unsafe seen record was replaced"
      fi
      ack_watcher_cycle "$state" || fail "$fault seen record round $round acknowledgement failed"
    done
  done
  pass "seen record errors leave later GitHub and GitLab watches polling across restarts"
}

test_open_queue_sweep_exhausts_pages() {
  local dir state page
  dir=$(make_case open-queue-sweep-eleven-pages)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  add_stop_custom_check "$dir"
  mkdir -p "$dir/sweep"
  for page in 1 2 3 4 5 6 7 8 9 10 11; do
    # shellcheck disable=SC2016 # $page is a jq variable.
    "$REAL_JQ" -n --argjson page "$page" '
      {data:{repository:{pullRequests:{
        pageInfo:{hasNextPage:($page < 11),
          endCursor:(if $page < 11 then "page"+(($page+1)|tostring) else null end)},
        nodes:(if $page < 11 then
          [range(($page-1)*100+1; $page*100+1) |
            {number:., state:"OPEN", merged:false, isInMergeQueue:true,
             timelineItems:{nodes:[]}}]
        else
          [{number:1001, state:"OPEN", merged:false, isInMergeQueue:false,
            timelineItems:{nodes:[{__typename:"RemovedFromMergeQueueEvent",
              id:"evt1001", reason:"failed_checks"}]}}]
        end)}}}}
    ' > "$dir/sweep/page${page}.json"
  done
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=true \
    FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "eleven-page queue sweep failed: $(cat "$dir/watch.err")"
  [ "$(grep -Fxc "check: $ROOT/bin/fm-pr-queue-sweep.sh: dequeued https://github.com/o/r/pull/1001 reason=failed_checks" "$dir/watch.out")" -eq 1 ] \
    || fail "the sweep missed the removal after 1,000 open PRs: $(cat "$dir/watch.out")"
  [ "$(grep -c 'dequeued ' "$dir/watch.out")" -eq 1 ] \
    || fail "the sweep reported something other than the eleventh-page removal: $(cat "$dir/watch.out")"
  "$ROOT/bin/fm-pr-queue-sweep.sh" --contains "$state" evt1001 \
    || fail "the eleventh-page removal was not published"
  pass "the queue sweep reads every page of open pull requests"
}

# Arms task-a on a poll template this repository shipped before the current
# file, so the registration records that hash and not the current template.
arm_previous_template_poll() {  # <dir> <url>
  local dir=$1 url=$2 state historical
  state="$dir/home/state"
  historical="$dir/historical-fm-pr-poll.sh"
  git -C "$ROOT" show 38fa6f7bde25e4cd64235581ceb16ca92a8453bc:bin/fm-pr-poll.sh > "$historical"
  chmod 0600 "$historical"
  fm_pr_poll_template_hash_shipped "$POLL" "$(fm_pr_sha256 "$historical")" \
    || fail "previous-template fixture is not a shipped template"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url" "$historical"
  ! cmp -s "$POLL" "$state/task-a.check.sh" \
    || fail "previous-template fixture matched the current template"
  fm_pr_poll_artifacts_valid "$state" task-a "$historical" \
    || fail "previous-template fixture was not valid for the template it was armed on"
  ! fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "previous-template fixture already matched the current template"
}

test_old_template_watch_polls_after_upgrade() {
  local dir state url rc
  local -x FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50MQ==
  url=https://github.com/o/r/pull/1
  dir=$(make_case old-template-upgrade)
  state="$dir/home/state"
  arm_previous_template_poll "$dir" "$url"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "old-template watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/watch.out")" -eq 1 ] \
    || fail "old-template watch did not wake on the dequeue: $(cat "$dir/watch.out")"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "old-template watch was not re-recorded from the current template"
  cmp -s "$POLL" "$state/task-a.check.sh" \
    || fail "re-recorded check is not the current template"
  pass "a watch armed on the previous template keeps polling after the template changes"
}

test_tampered_check_stays_rejected() {
  local dir state url registration_sha check_sha rc out
  local -x FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50MQ==
  url=https://github.com/o/r/pull/1
  dir=$(make_case tampered-check-rejected)
  state="$dir/home/state"
  arm_previous_template_poll "$dir" "$url"
  printf '# tampered\n' >> "$state/task-a.check.sh"
  registration_sha=$(fm_pr_sha256 "$state/task-a.pr-poll-registration")
  check_sha=$(fm_pr_sha256 "$state/task-a.check.sh")
  : > "$dir/gh.log"
  set +e
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "tampered-check watcher failed: $(cat "$dir/watch.err")"
  out=$(cat "$dir/watch.out")
  case "$out" in
    "check: rejected unauthenticated state checks:"*"task-a.check.sh"*) ;;
    *) fail "tampered check was not refused: $out" ;;
  esac
  [ "$(fm_pr_sha256 "$state/task-a.pr-poll-registration")" = "$registration_sha" ] \
    || fail "tampered check was re-recorded"
  [ "$(fm_pr_sha256 "$state/task-a.check.sh")" = "$check_sha" ] \
    || fail "tampered check bytes were replaced"
  ! grep -F 'pullRequest(number:' "$dir/gh.log" >/dev/null 2>&1 \
    || fail "tampered check was queried"
  pass "a tampered check copy stays rejected"
}

test_unshipped_template_hash_is_refused() {
  local dir state registration_sha replacement
  dir=$(make_case unshipped-template-hash)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  replacement=$(printf 'another template\n' | shasum -a 256 | awk '{print $1}')
  awk -v hash="$replacement" 'NR == 9 { $0 = hash } { print }' \
    "$state/task-a.pr-poll-registration" > "$state/.swap"
  chmod 0600 "$state/.swap"
  mv -f -- "$state/.swap" "$state/task-a.pr-poll-registration"
  registration_sha=$(fm_pr_sha256 "$state/task-a.pr-poll-registration")
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  : > "$dir/gh.log"
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "unshipped template hash watcher failed: $(cat "$dir/watch.err")"
  if grep -F 'rejected unauthenticated state checks:' "$dir/watch.out" >/dev/null \
    && grep -F 'task-a.check.sh' "$dir/watch.out" >/dev/null; then
    :
  else
    fail "an unshipped template hash was not refused: $(cat "$dir/watch.out")"
  fi
  [ "$(fm_pr_sha256 "$state/task-a.pr-poll-registration")" = "$registration_sha" ] \
    || fail "an unshipped template hash was re-recorded"
  ! grep -F 'pullRequest(number:' "$dir/gh.log" >/dev/null 2>&1 \
    || fail "an unshipped template hash was queried"
  ! grep -F 'task-a.check.sh: merged' "$dir/watch.out" >/dev/null \
    || fail "an unshipped template hash reported a merge"
  pass "a registration whose template hash was never shipped stays refused"
}

test_interrupted_template_upgrade_finishes_on_the_next_poll() {
  local dir state url check_identity rc device
  local -x FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50MQ==
  url=https://github.com/o/r/pull/1
  for device in unchanged renumbered; do
    dir=$(make_case "interrupted-template-upgrade-$device")
    state="$dir/home/state"
    arm_previous_template_poll "$dir" "$url"
    [ "$device" = unchanged ] || shift_registration_device "$state" task-a
    check_identity=$(fm_pr_file_identity "$state/task-a.check.sh")
    cat "$POLL" > "$state/task-a.check.sh"
    [ "$(fm_pr_file_identity "$state/task-a.check.sh")" = "$check_identity" ] \
      || fail "interrupted upgrade fixture replaced the check file"
    cmp -s "$POLL" "$state/task-a.check.sh" \
      || fail "interrupted upgrade fixture did not leave the current template in place"
    ! fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
      || fail "interrupted upgrade fixture was already valid"
    retire_contributions_observer "$dir"
    add_stop_custom_check "$dir"
    set +e
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
      FM_TEST_GH_POLL_REASON=failed_checks \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "interrupted-template watcher failed: $(cat "$dir/watch.err")"
    [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/watch.out")" -eq 1 ] \
      || fail "interrupted template upgrade did not wake on the dequeue: $(cat "$dir/watch.out")"
    fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
      || fail "interrupted template upgrade did not finish the registration"
    [ "$(fm_pr_file_identity "$state/task-a.check.sh")" = "$check_identity" ] \
      || fail "interrupted template upgrade replaced the check file"
    ack_watcher_cycle "$state" || fail "interrupted upgrade acknowledgement failed"
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/merged.out" 2> "$dir/merged.err" \
      || fail "recovered template watch stopped polling: $(cat "$dir/merged.err")"
    grep -F 'task-a.check.sh: merged' "$dir/merged.out" >/dev/null \
      || fail "recovered template watch missed its merge: $(cat "$dir/merged.out")"
    assert_poll_absent "$state" task-a
  done
  pass "an interrupted template upgrade keeps polling with unchanged or renumbered devices"
}

test_interrupted_template_upgrade_refuses_replaced_artifacts() {
  local dir state artifact registration_hash check_hash
  for artifact in task-a.check.sh task-a.pr-poll; do
    dir=$(make_case "interrupted-template-replaced-$artifact")
    state="$dir/home/state"
    arm_previous_template_poll "$dir" https://github.com/o/r/pull/1
    shift_registration_device "$state" task-a
    cat "$POLL" > "$state/task-a.check.sh"
    cp "$state/$artifact" "$dir/replacement"
    chmod 0600 "$dir/replacement"
    mv -f "$dir/replacement" "$state/$artifact"
    registration_hash=$(fm_pr_sha256 "$state/task-a.pr-poll-registration")
    check_hash=$(fm_pr_sha256 "$state/task-a.check.sh")
    retire_contributions_observer "$dir"
    add_stop_custom_check "$dir"
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
      || fail "replaced interrupted upgrade failed: $(cat "$dir/watch.err")"
    grep -F 'rejected unauthenticated state checks:' "$dir/watch.out" >/dev/null \
      || fail "interrupted upgrade accepted a replaced $artifact: $(cat "$dir/watch.out")"
    [ "$(fm_pr_sha256 "$state/task-a.pr-poll-registration")" = "$registration_hash" ] \
      || fail "replaced artifact registration was rewritten"
    [ "$(fm_pr_sha256 "$state/task-a.check.sh")" = "$check_hash" ] \
      || fail "replaced artifact check was rewritten"
    ! grep -F 'pullRequest(number:' "$dir/gh.log" >/dev/null 2>&1 \
      || fail "replaced artifact was polled"
  done
  pass "interrupted template recovery refuses a replaced check or sidecar"
}

test_old_template_and_renumber_are_both_recovered() {
  local dir state url rc registration_sha check_sha
  local -x FM_TEST_GH_POLL_EVENT=MDEyOlJlbW92ZWRGcm9tTWVyZ2VRdWV1ZUV2ZW50MQ==
  url=https://github.com/o/r/pull/1
  dir=$(make_case old-template-and-renumber)
  state="$dir/home/state"
  arm_previous_template_poll "$dir" "$url"
  shift_registration_device "$state" task-a
  ! fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "old-template renumber fixture was already valid"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "old-template renumber watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*task-a\.check\.sh: dequeued https://github.com/o/r/pull/1 reason=failed_checks$' "$dir/watch.out")" -eq 1 ] \
    || fail "old-template renumber did not wake on the dequeue: $(cat "$dir/watch.out")"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "old-template renumber was not re-recorded from the current template"
  cmp -s "$POLL" "$state/task-a.check.sh" \
    || fail "old-template renumber check is not the current template"

  dir=$(make_case old-template-renumber-tampered)
  state="$dir/home/state"
  arm_previous_template_poll "$dir" "$url"
  shift_registration_device "$state" task-a
  printf '# tampered\n' >> "$state/task-a.check.sh"
  registration_sha=$(fm_pr_sha256 "$state/task-a.pr-poll-registration")
  check_sha=$(fm_pr_sha256 "$state/task-a.check.sh")
  : > "$dir/gh.log"
  set +e
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=false \
    FM_TEST_GH_POLL_REASON=failed_checks \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "tampered renumber watcher failed: $(cat "$dir/watch.err")"
  case "$(cat "$dir/watch.out")" in
    "check: rejected unauthenticated state checks:"*"task-a.check.sh"*) ;;
    *) fail "tampered renumbered check was not refused: $(cat "$dir/watch.out")" ;;
  esac
  [ "$(fm_pr_sha256 "$state/task-a.pr-poll-registration")" = "$registration_sha" ] \
    || fail "tampered renumbered check was re-recorded"
  [ "$(fm_pr_sha256 "$state/task-a.check.sh")" = "$check_sha" ] \
    || fail "tampered renumbered check bytes were replaced"
  ! grep -F 'pullRequest(number:' "$dir/gh.log" >/dev/null 2>&1 \
    || fail "tampered renumbered check was queried"
  pass "a renumbered watch on the previous template keeps polling, and a tampered copy stays refused"
}

write_slow_sweep_page() {  # <dir> <page> <number> <more> <cursor>
  local dir=$1 page=$2 number=$3 more=$4 cursor=$5
  mkdir -p "$dir/sweep"
  # shellcheck disable=SC2016 # $number, $more, and $cursor are jq variables.
  "$REAL_JQ" -n --argjson number "$number" --argjson more "$more" --arg cursor "$cursor" '
    {data:{repository:{pullRequests:{
      pageInfo:{hasNextPage:$more, endCursor:(if $more then $cursor else null end)},
      nodes:[{number:$number, state:"OPEN", merged:false, isInMergeQueue:false,
        timelineItems:{nodes:[{__typename:"RemovedFromMergeQueueEvent",
          id:("evt"+($number|tostring)), reason:"failed_checks"}]}}]}}}}
  ' > "$dir/sweep/$page.json"
}

test_sweep_page_deadline_reports_every_removal() {
  local dir state number
  dir=$(make_case sweep-page-deadline)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  write_slow_sweep_page "$dir" page1 2 true page2
  write_slow_sweep_page "$dir" page2 3 true page3
  write_slow_sweep_page "$dir" page3 4 false ""
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  FM_TEST_CHECK_TIMEOUT=2 FM_TEST_GH_SWEEP_SLEEP=1 \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=true \
    FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "slow page sweep failed: $(cat "$dir/watch.err")"
  for number in 2 3 4; do
    [ "$(grep -Fxc "check: $ROOT/bin/fm-pr-queue-sweep.sh: dequeued https://github.com/o/r/pull/${number} reason=failed_checks" "$dir/watch.out")" -eq 1 ] \
      || fail "a page that fit under the deadline was dropped (pull ${number}): $(cat "$dir/watch.out")"
  done
  pass "each sweep page has its own deadline, so a longer scan still reports every removal"
}

test_progressing_sweep_survives_rearm_past_stall_bound() {
  local dir state page
  dir=$(make_case sweep-progress-liveness)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  for page in 1 2 3 4 5; do
    write_slow_sweep_page "$dir" "page$page" "$((page+1))" true "page$((page+1))"
  done
  write_slow_sweep_page "$dir" page6 7 false ""
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  # Expire the existing beacon before each page leading to rearm completes.
  # Every page must renew it before the next read, using the production stall
  # bound so a valid page's own launch overhead cannot cause eviction.
  FM_WATCHER_STALE_GRACE=900 FM_WATCHER_STALL_BOUND=900 FM_TEST_GH_SWEEP_EXPIRE_BEAT=1 \
    FM_TEST_CHECK_TIMEOUT=10 FM_TEST_GH_SWEEP_SLEEP=1 FM_TEST_GH_SWEEP_REARM="$WATCH" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_POLL_QUEUED=true \
    FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "progressing scan was interrupted: $(cat "$dir/watch.err")"
  [ "$(grep -Fxc 'expired-beacon sweep' "$dir/gh.log")" -eq 5 ] \
    || fail "completed sweep pages did not renew every expired beacon"
  ! grep -Fx 'stale-beacon sweep' "$dir/gh.log" >/dev/null \
    || fail "a completed page left the next read's beacon expired"
  grep -F 'watcher: already running pid ' "$dir/sweep/rearm.out" >/dev/null \
    || fail "rearm evicted the progressing scan: $(cat "$dir/sweep/rearm.out" "$dir/sweep/rearm.err")"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
    > "$dir/drain.out" 2> "$dir/drain.err" || fail "progressing sweep drain failed"
  for page in 2 3 4 5 6 7; do
    [ "$(grep -Fc "dequeued https://github.com/o/r/pull/$page reason=failed_checks" "$dir/drain.out")" -eq 1 ] \
      || fail "the long sweep lost pull $page: $(cat "$dir/drain.out")"
  done
  pass "real page progress keeps a long sweep alive through a concurrent rearm"
}

test_slow_registered_polls_survive_rearm() {
  local dir state number
  dir=$(make_case registered-poll-progress-liveness)
  state="$dir/home/state"
  for number in 1 2 3 4 5 6 7 8; do
    write_poll_meta "$state" "task-$number" "https://github.com/o/r/pull/$number"
    seed_canonical_poll "$dir" "task-$number" "https://github.com/o/r/pull/$number"
  done
  "$REAL_JQ" -n '[range(1;9) | {
    key:tostring,
    value:{data:{repository:{pullRequest:{
      state:"OPEN", merged:false, isInMergeQueue:(. != 8),
      timelineItems:{nodes:(if . == 8 then [{id:"evt8",reason:"failed_checks"}] else [] end)}
    }}}}
  }] | from_entries' > "$dir/poll-responses.json"
  write_slow_sweep_page "$dir" page1 9 false ""
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  # Each poll leading to rearm completes after its beacon has expired.
  # Every next poll must see completion progress at the production stall bound.
  FM_WATCHER_STALE_GRACE=900 FM_WATCHER_STALL_BOUND=900 FM_TEST_GH_POLL_EXPIRE_BEAT=1 FM_TEST_CHECK_TIMEOUT=20 \
    FM_TEST_GH_SLEEP=1 FM_TEST_GH_POLL_REARM="$WATCH" FM_TEST_GH_POLL_REARM_NUMBER=8 \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_POLL_RESPONSES="$dir/poll-responses.json" \
    FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "slow registered polls were interrupted: $(cat "$dir/watch.err")"
  [ "$(grep -Fxc 'expired-beacon poll' "$dir/gh.log")" -eq 7 ] \
    || fail "completed registered polls did not renew every expired beacon"
  ! grep -Fx 'stale-beacon poll' "$dir/gh.log" >/dev/null \
    || fail "a completed poll left the next poll's beacon expired"
  grep -F 'watcher: already running pid ' "$dir/gh.log.rearm.out" >/dev/null \
    || fail "rearm evicted the progressing registered polls: $(cat "$dir/gh.log.rearm.out" "$dir/gh.log.rearm.err")"
  for number in 1 2 3 4 5 6 7 8; do
    [ "$(grep -Fc "number=$number " "$dir/gh.log")" -eq 1 ] \
      || fail "the collected checks skipped or repeated pull $number"
  done
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
    > "$dir/drain.out" 2> "$dir/drain.err" || fail "slow registered poll drain failed"
  for number in 8 9; do
    [ "$(grep -Fc "dequeued https://github.com/o/r/pull/$number reason=failed_checks" "$dir/drain.out")" -eq 1 ] \
      || fail "the long registered-check sweep lost pull $number: $(cat "$dir/drain.out")"
  done
  pass "completed registered polls keep the watcher alive through rearm and deliver the final removal"
}

test_merged_only_watch_still_sweeps_its_repo() {
  local dir state
  dir=$(make_case merged-watch-still-sweeps)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  write_slow_sweep_page "$dir" page1 2 false ""
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "merged-watch sweep failed: $(cat "$dir/watch.err")"
  assert_poll_absent "$state" task-a
  [ "$(grep -Fxc "check: $ROOT/bin/fm-pr-queue-sweep.sh: dequeued https://github.com/o/r/pull/2 reason=failed_checks" "$dir/watch.out")" -eq 1 ] \
    || fail "a repo whose only armed pull request merged was not swept: $(cat "$dir/watch.out")"
  pass "a repository is swept after its only armed pull request merges"
}

test_recovered_merged_watch_still_sweeps_its_repo() {
  local dir state
  dir=$(make_case recovered-merged-watch-still-sweeps)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  write_slow_sweep_page "$dir" page1 2 false ""
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot the merged watch"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish the retirement receipt"
  (
    export FM_STATE_OVERRIDE="$state" FM_HOME="$dir/home"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_wake_append check "$state/task-a.check.sh" "check: $state/task-a.check.sh: merged"
  ) || fail "could not queue the merged wake"
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/recovery.out" 2> "$dir/recovery.err" \
    || fail "receipt recovery failed: $(cat "$dir/recovery.err")"
  grep -F 'check: rearm-resurface' "$dir/recovery.out" >/dev/null \
    || fail "receipt recovery did not resurface its queued wake"
  [ -f "$state/task-a.pr-poll" ] && [ -f "$state/task-a.pr-poll-retirement" ] \
    || fail "receipt recovery lost the repository before its sweep"
  [ ! -e "$state/task-a.check.sh" ] || fail "receipt recovery left a merged poll runnable"
  ack_watcher_cycle "$state" || fail "recovered merge acknowledgement failed"
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "post-recovery sweep failed: $(cat "$dir/watch.err")"
  assert_poll_absent "$state" task-a
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
    > "$dir/drain.out" 2> "$dir/drain.err" || fail "post-recovery sweep drain failed"
  [ "$(grep -Fc 'dequeued https://github.com/o/r/pull/2 reason=failed_checks' "$dir/drain.out")" -eq 1 ] \
    || fail "receipt recovery lost the dropped pull request: $(cat "$dir/drain.out")"
  pass "a recovered merged watch retains its repository through the first completed sweep"
}

test_failed_sweep_keeps_the_repository_for_the_next_cycle() {
  local dir state rc before
  dir=$(make_case failed-sweep-keeps-repo)
  state="$dir/home/state"
  fm_write_meta "$state/task-a.meta" \
    window=firstmate:fm-task-a endpoint_task_id=task-a \
    "worktree=$dir/wt" "project=$dir/project" kind=ship mode=local-only \
    pr=https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  write_slow_sweep_page "$dir" page1 2 false ""
  retire_contributions_observer "$dir"
  add_stop_custom_check "$dir"
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED FM_TEST_GH_SWEEP_FAIL=1 \
    FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/fail.out" 2> "$dir/fail.err" \
    || fail "failed sweep watcher exited: $(cat "$dir/fail.err")"
  ! grep -F 'dequeued https://github.com/o/r/pull/2' "$dir/fail.out" >/dev/null \
    || fail "a failed sweep reported a removal: $(cat "$dir/fail.out")"
  [ -f "$state/task-a.pr-poll" ] && [ -f "$state/task-a.pr-poll-retirement" ] \
    || fail "a failed sweep retired the repository"
  [ ! -e "$state/task-a.check.sh" ] || fail "a failed sweep left the merged poll runnable"
  [ ! -e "$state/merge-queue-sweep.seen" ] || fail "a failed sweep recorded events"
  ack_watcher_cycle "$state" || fail "failed sweep acknowledgement failed"
  shift_retirement_device "$state" task-a
  before=$(poll_artifact_snapshot "$state" task-a)
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown discarded the repository after a failed sweep"
  grep -F 'REFUSED: pending repository merge-queue sweep; preserving task state.' "$dir/teardown.err" >/dev/null \
    || fail "teardown did not refuse its pending sweep: $(cat "$dir/teardown.err")"
  [ "$(poll_artifact_snapshot "$state" task-a)" = "$before" ] \
    || fail "teardown changed the repository's deferred retirement"
  [ -d "$dir/wt/.git" ] || fail "refused teardown removed the task's worktree"
  set +e
  run_check_entry "$dir" task-a https://github.com/o/replacement/pull/3 \
    > "$dir/rearm.out" 2> "$dir/rearm.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "rearm discarded the repository after a failed sweep"
  [ "$(cat "$dir/rearm.err")" = 'error: pending repository merge-queue sweep; preserving task state' ] \
    || fail "rearm did not refuse its pending sweep: $(cat "$dir/rearm.err")"
  [ "$(poll_artifact_snapshot "$state" task-a)" = "$before" ] \
    || fail "rearm changed the repository's deferred retirement"
  FM_TEST_GH_LOG="$dir/gh2.log" FM_TEST_GH_STATE=MERGED FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "the next sweep failed: $(cat "$dir/watch.err")"
  assert_poll_absent "$state" task-a
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
    > "$dir/drain.out" 2> "$dir/drain.err" || fail "next sweep drain failed"
  [ "$(grep -Fc 'dequeued https://github.com/o/r/pull/2 reason=failed_checks' "$dir/drain.out")" -eq 1 ] \
    || fail "the next good sweep lost the removal: $(cat "$dir/drain.out")"
  FM_TEST_GH_HEAD="$(git -C "$dir/wt" rev-parse HEAD)" \
    run_check_entry "$dir" task-a https://github.com/o/replacement/pull/3 \
    > "$dir/rearm.out" 2> "$dir/rearm.err" \
    || fail "rearm failed after the repository sweep: $(cat "$dir/rearm.err")"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "rearm after a successful sweep left an invalid poll"

  dir=$(make_case sweep-page-timeout-fails)
  state="$dir/home/state"
  mkdir -p "$state" "$dir/fakebin" "$dir/sweep"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 2
exit 0
SH
  chmod +x "$dir/fakebin/gh"
  set +e
  PATH="$dir/fakebin:$BASE_PATH" FM_TEST_GH_LOG="$dir/timeout.log" \
    FM_PR_SWEEP_PAGE_TIMEOUT=1 FM_PR_SWEEP_REPOS=$'o/r' \
    "$ROOT/bin/fm-pr-queue-sweep.sh" --scan "$state" > "$dir/timeout.out" 2> "$dir/timeout.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a timed-out sweep page exited 0"
  [ ! -s "$dir/timeout.out" ] || fail "a timed-out sweep page printed a result: $(cat "$dir/timeout.out")"
  pass "a failed sweep keeps the repository until the next sweep reports its removal"
}

test_seen_record_errors_keep_repository_discovery() {
  local dir state seen fault corrupt_seen rc invalid_state
  for fault in unreadable malformed unsafe lookup; do
    dir=$(make_case "seen-record-$fault")
    state="$dir/home/state"
    seen="$state/merge-queue-sweep.seen"
    write_poll_meta "$state" task-a https://github.com/o/r/pull/1
    seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
    write_slow_sweep_page "$dir" page1 2 false ""
    retire_contributions_observer "$dir"
    add_stop_custom_check "$dir"
    printf 'fm-merge-queue-sweep-v1\n' > "$seen"
    chmod 0600 "$seen"
    corrupt_seen=
    case "$fault" in
      unreadable) chmod 0000 "$seen" ;;
      malformed) printf 'fm-merge-queue-sweep-v1\ninvalid event\n' > "$seen" ;;
      unsafe) chmod 0644 "$seen" ;;
      lookup) corrupt_seen=$seen ;;
    esac
    if [ "$fault" != lookup ]; then
      rc=0
      FM_TEST_GH_LOG="$dir/scan-gh.log" PATH="$dir/fakebin:$BASE_PATH" \
        "$ROOT/bin/fm-pr-queue-sweep.sh" --scan "$state" \
        > "$dir/scan.out" 2> "$dir/scan.err" || rc=$?
      [ "$rc" -eq 1 ] || fail "$fault seen record did not fail the scan (rc=$rc)"
      [ ! -s "$dir/scan.out" ] || fail "$fault seen record produced scan output"
    fi
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
      FM_TEST_GH_SWEEP_CORRUPT_SEEN="$corrupt_seen" \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/fail.out" 2> "$dir/fail.err" \
      || fail "$fault seen record interrupted merge delivery: $(cat "$dir/fail.err")"
    [ -f "$state/task-a.pr-poll" ] && [ -f "$state/task-a.pr-poll-retirement" ] \
      || fail "$fault seen record retired the repository before publication"
    [ ! -e "$state/task-a.check.sh" ] || fail "$fault seen record left a merged poll runnable"
    ! grep -F 'dequeued https://github.com/o/r/pull/2' "$dir/fail.out" >/dev/null \
      || fail "$fault seen record published an unverified removal"
    rc=0
    "$ROOT/bin/fm-pr-queue-sweep.sh" --contains "$state" evt2 || rc=$?
    [ "$rc" -eq 2 ] || fail "$fault seen record lost its lookup failure (rc=$rc)"
    ack_watcher_cycle "$state" || fail "$fault seen record merge acknowledgement failed"
    chmod 0600 "$seen"
    printf 'fm-merge-queue-sweep-v1\n' > "$seen"
    FM_TEST_GH_LOG="$dir/retry-gh.log" FM_TEST_GH_STATE=MERGED FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/retry.out" 2> "$dir/retry.err" \
      || fail "$fault seen record recovery failed: $(cat "$dir/retry.err")"
    assert_poll_absent "$state" task-a
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
      > "$dir/drain.out" 2> "$dir/drain.err" || fail "$fault seen record recovery drain failed"
    [ "$(grep -Fc 'dequeued https://github.com/o/r/pull/2 reason=failed_checks' "$dir/drain.out")" -eq 1 ] \
      || fail "$fault seen record lost the removal on retry: $(cat "$dir/drain.out")"
    "$ROOT/bin/fm-pr-queue-sweep.sh" --contains "$state" evt2 \
      || fail "$fault seen record recovery did not record the delivered removal"
  done
  ln -s "$state" "$dir/state-link"
  for invalid_state in "$dir/missing-state" "$dir/state-link"; do
    rc=0
    "$ROOT/bin/fm-pr-queue-sweep.sh" --scan "$invalid_state" \
      > "$dir/invalid.out" 2> "$dir/invalid.err" || rc=$?
    [ "$rc" -eq 1 ] || fail "an invalid state directory was a successful scan (rc=$rc)"
    [ ! -s "$dir/invalid.out" ] || fail "an invalid state directory produced scan output"
  done
  rc=0
  "$ROOT/bin/fm-pr-queue-sweep.sh" --scan > "$dir/invalid.out" 2> "$dir/invalid.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a scan without its state directory succeeded (rc=$rc)"
  pass "seen record errors preserve repository discovery until a removal is delivered"
}

test_completed_repo_removals_survive_another_repo_failure() {
  local dir state failing success before
  for failing in task-a task-b; do
    dir=$(make_case "mixed-sweep-$failing")
    state="$dir/home/state"
    success=task-a
    [ "$failing" != task-a ] || success=task-b
    write_poll_meta "$state" "$success" https://github.com/o/r/pull/1
    seed_canonical_poll "$dir" "$success" https://github.com/o/r/pull/1
    write_poll_meta "$state" "$failing" https://github.com/o/unreadable/pull/1
    seed_canonical_poll "$dir" "$failing" https://github.com/o/unreadable/pull/1
    write_slow_sweep_page "$dir" page1 2 false ""
    retire_contributions_observer "$dir"
    add_stop_custom_check "$dir"
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED \
      FM_TEST_GH_SWEEP_FAIL_REPO=o/unreadable FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
      || fail "mixed sweep failed: $(cat "$dir/watch.err")"
    [ "$(grep -Fc 'dequeued https://github.com/o/r/pull/2 reason=failed_checks' "$dir/watch.out")" -eq 1 ] \
      || fail "an unreadable repository suppressed a completed removal: $(cat "$dir/watch.out")"
    "$ROOT/bin/fm-pr-queue-sweep.sh" --contains "$state" evt2 \
      || fail "the completed removal was not recorded after publication"
    [ -f "$state/$failing.pr-poll" ] && [ -f "$state/$failing.pr-poll-retirement" ] \
      || fail "the unreadable repository lost its deferred retirement"
    [ -f "$state/$success.pr-poll" ] && [ -f "$state/$success.pr-poll-retirement" ] \
      || fail "aggregate sweep failure was treated as success"
    [ ! -e "$state/$failing.check.sh" ] && [ ! -e "$state/$success.check.sh" ] \
      || fail "a mixed sweep left a merged watch runnable"
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
      > "$dir/drain.out" 2> "$dir/drain.err" || fail "mixed sweep drain failed"
    [ "$(grep -Fc 'dequeued https://github.com/o/r/pull/2 reason=failed_checks' "$dir/drain.out")" -eq 1 ] \
      || fail "the completed removal was not delivered: $(cat "$dir/drain.out")"
    ack_watcher_cycle "$state" || fail "mixed sweep acknowledgement failed"
    before=$(poll_artifact_snapshot "$state" "$failing")
    FM_TEST_GH_LOG="$dir/gh2.log" FM_TEST_GH_STATE=MERGED \
      FM_TEST_GH_SWEEP_FAIL_REPO=o/unreadable FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/retry.out" 2> "$dir/retry.err" \
      || fail "mixed sweep retry failed: $(cat "$dir/retry.err")"
    ! grep -F 'dequeued https://github.com/o/r/pull/2' "$dir/retry.out" >/dev/null \
      || fail "a mixed sweep retry duplicated the completed removal"
    [ "$(poll_artifact_snapshot "$state" "$failing")" = "$before" ] \
      || fail "a mixed sweep retry changed the unreadable repository's retirement"
  done
  pass "completed repository removals are delivered once despite earlier or later repository failures"
}

test_unobserved_merge_preserves_repository_before_cleanup_or_rearm() {
  local dir state action before rc
  for action in cleanup rearm; do
    dir=$(make_case "unobserved-merge-$action")
    state="$dir/home/state"
    write_task_meta "$dir"
    printf 'pr=https://github.com/o/r/pull/1\n' >> "$state/task-a.meta"
    seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
    write_slow_sweep_page "$dir" page1 2 false ""
    retire_contributions_observer "$dir"
    add_stop_custom_check "$dir"
    before=$(poll_artifact_snapshot "$state" task-a)
    [ ! -e "$state/task-a.pr-poll-retirement" ] || fail "unobserved merge already has a receipt"
    set +e
    if [ "$action" = cleanup ]; then
      FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
        FM_TEST_GH_STATE=MERGED "$TEARDOWN" task-a --force \
        > "$dir/refused.out" 2> "$dir/refused.err"
    else
      FM_TEST_GH_STATE=MERGED run_check_entry "$dir" task-a https://github.com/other/repo/pull/3 \
        > "$dir/refused.out" 2> "$dir/refused.err"
    fi
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$action removed the last watch before its merge was observed"
    grep -F 'pending repository merge-queue sweep; preserving task state' "$dir/refused.err" >/dev/null \
      || fail "$action refused for another reason: $(cat "$dir/refused.err")"
    [ "$(poll_artifact_snapshot "$state" task-a)" = "$before" ] \
      || fail "$action changed the unobserved merge's authenticated watch"
    [ -d "$dir/wt/.git" ] || fail "$action removed the task's worktree"
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
      || fail "unobserved merge recovery failed: $(cat "$dir/watch.err")"
    assert_poll_absent "$state" task-a
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
      > "$dir/drain.out" 2> "$dir/drain.err" || fail "unobserved merge drain failed"
    [ "$(grep -Fc 'dequeued https://github.com/o/r/pull/2 reason=failed_checks' "$dir/drain.out")" -eq 1 ] \
      || fail "$action lost the repository's dropped pull request: $(cat "$dir/drain.out")"
  done

  dir=$(make_case same-repository-rearm-keeps-discovery)
  state="$dir/home/state"
  write_task_meta "$dir"
  printf 'pr=https://github.com/o/r/pull/1\n' >> "$state/task-a.meta"
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  FM_TEST_GH_HEAD="$(git -C "$dir/wt" rev-parse HEAD)" \
    run_check_entry "$dir" task-a https://github.com/o/r/pull/3 \
    > "$dir/rearm.out" 2> "$dir/rearm.err" \
    || fail "same-repository rearm failed: $(cat "$dir/rearm.err")"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "same-repository rearm left an invalid watch"
  [ "$FM_PR_DATA_URL" = https://github.com/o/r/pull/3 ] || fail "same-repository rearm lost its replacement"
  [ "$("$ROOT/bin/fm-pr-queue-sweep.sh" --repos "$state")" = o/r ] \
    || fail "same-repository rearm lost repository discovery"
  pass "cleanup and cross-repository rearm preserve an unobserved merge until its repository is swept"
}

shift_retirement_device() {
  local state=$1 id=$2 device shifted tmp registration receipt reg_hash=''
  device=$(fm_pr_file_device "$state") || fail "could not read retirement fixture device"
  shifted=$((device + 1))
  registration="$state/$id.pr-poll-registration"
  receipt="$state/$id.pr-poll-retirement"
  tmp=$(mktemp "$state/.test-retirement-device.XXXXXX") || fail "could not stage retirement device shift"
  if [ -f "$registration" ]; then
    awk -v live="$device" -v shifted="$shifted" '
      NR == 10 || NR == 11 { sub("^" live ":", shifted ":") }
      { print }
    ' "$registration" > "$tmp"
    cat "$tmp" > "$registration"
    reg_hash=$(fm_pr_sha256 "$registration") || fail "could not hash shifted registration"
  fi
  awk -v live="$device" -v shifted="$shifted" -v reg_hash="$reg_hash" '
    NR == 10 || NR == 11 || NR == 13 { sub("^" live ":", shifted ":") }
    NR == 12 && reg_hash != "" { $0 = reg_hash }
    { print }
  ' "$receipt" > "$tmp"
  cat "$tmp" > "$receipt"
  rm -f "$tmp"
  [ "$(sed -n 10p "$receipt")" = "$shifted:$(fm_pr_file_inode "$state/$id.pr-poll")" ] \
    || fail "retirement device shift did not preserve the sidecar inode"
}

test_retirement_survives_device_renumbering() {
  local dir state stage before rc
  for stage in full registration sidecar; do
    dir=$(make_case "retirement-renumber-$stage")
    state="$dir/home/state"
    write_task_meta "$dir"
    printf 'pr=https://github.com/o/r/pull/1\n' >> "$state/task-a.meta"
    seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
    fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot retirement renumber fixture"
    fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish retirement renumber receipt"
    case "$stage" in
      registration) rm -f "$state/task-a.check.sh" ;;
      sidecar)
        fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" \
          || fail "could not defer the merged watch before its failed scan"
        ;;
    esac
    shift_retirement_device "$state" task-a
    fm_pr_poll_retirement_state_valid "$state" task-a \
      || fail "$stage retirement did not accept unchanged inodes on the live device"
    write_slow_sweep_page "$dir" page1 2 false ""
    retire_contributions_observer "$dir"
    add_stop_custom_check "$dir"
    if [ "$stage" = sidecar ]; then
      before=$(poll_artifact_snapshot "$state" task-a)
      set +e
      run_check_entry "$dir" task-a https://github.com/other/repo/pull/3 \
        > "$dir/rearm.out" 2> "$dir/rearm.err"
      rc=$?
      set -e
      [ "$rc" -ne 0 ] || fail "renumbered pending retirement allowed cross-repository rearm"
      [ "$(cat "$dir/rearm.err")" = 'error: pending repository merge-queue sweep; preserving task state' ] \
        || fail "rearm rejected the renumbered receipt: $(cat "$dir/rearm.err")"
      set +e
      FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
        "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err"
      rc=$?
      set -e
      [ "$rc" -ne 0 ] || fail "renumbered pending retirement allowed cleanup"
      grep -F 'REFUSED: pending repository merge-queue sweep; preserving task state.' "$dir/teardown.err" >/dev/null \
        || fail "cleanup rejected the renumbered receipt: $(cat "$dir/teardown.err")"
      [ "$(poll_artifact_snapshot "$state" task-a)" = "$before" ] \
        || fail "pending retirement callers changed renumbered artifacts"
      FM_TEST_GH_LOG="$dir/fail-gh.log" FM_TEST_GH_SWEEP_FAIL=1 \
        run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/fail.out" 2> "$dir/fail.err" \
        || fail "renumbered failed scan stopped monitoring: $(cat "$dir/fail.err")"
      ! grep -F 'rejected unauthenticated PR poll retirement' "$dir/fail.out" >/dev/null \
        || fail "renumbered failed scan rejected the retained receipt"
      [ -f "$state/task-a.pr-poll" ] && [ -f "$state/task-a.pr-poll-retirement" ] \
        || fail "renumbered failed scan lost its repository"
      ack_watcher_cycle "$state" || fail "renumbered failed scan acknowledgement failed"
    fi
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=OPEN FM_TEST_GH_SWEEP_DIR="$dir/sweep" \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
      || fail "renumbered retirement watcher failed: $(cat "$dir/watch.err")"
    assert_poll_absent "$state" task-a
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
      > "$dir/drain.out" 2> "$dir/drain.err" || fail "renumbered retirement drain failed"
    [ "$(grep -Fc 'dequeued https://github.com/o/r/pull/2 reason=failed_checks' "$dir/drain.out")" -eq 1 ] \
      || fail "$stage retirement lost a removal after renumbering: $(cat "$dir/drain.out")"
  done
  pass "renumbered retirement receipts keep scanning through every surviving artifact stage"
}

test_retirement_device_recovery_keeps_content_and_inode_checks() {
  local dir state artifact mutation expected_identity expected_hash live_device field
  for artifact in check.sh pr-poll pr-poll-registration; do
    for mutation in replaced altered; do
      dir=$(make_case "retirement-renumber-$artifact-$mutation")
      state="$dir/home/state"
      write_poll_meta "$state" task-a https://github.com/o/r/pull/1
      seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
      fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot changed retirement fixture"
      fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish changed retirement receipt"
      shift_retirement_device "$state" task-a
      fm_pr_poll_retirement_state_valid "$state" task-a || fail "changed retirement fixture was invalid before mutation"
      case "$artifact" in
        check.sh) expected_identity=$FM_PR_RETIRE_CHECK_IDENTITY; expected_hash=$FM_PR_RETIRE_TEMPLATE_HASH ;;
        pr-poll) expected_identity=$FM_PR_RETIRE_DATA_IDENTITY; expected_hash=$FM_PR_RETIRE_DATA_HASH ;;
        pr-poll-registration) expected_identity=$FM_PR_RETIRE_REG_IDENTITY; expected_hash=$FM_PR_RETIRE_REG_HASH ;;
      esac
      if [ "$mutation" = replaced ]; then
        cp "$state/task-a.$artifact" "$state/.replacement"
        chmod 0600 "$state/.replacement"
        mv -f "$state/.replacement" "$state/task-a.$artifact"
      else
        printf 'altered\n' >> "$state/task-a.$artifact"
      fi
      ! fm_pr_poll_retirement_state_valid "$state" task-a \
        || fail "renumber recovery accepted a $mutation $artifact"
      live_device=$(fm_pr_file_device "$state") || fail "could not read live state device"
      ! fm_pr_poll_retirement_remove_exact "$state/task-a.$artifact" "$live_device" "$expected_identity" "$expected_hash" \
        || fail "exact retirement removed a $mutation $artifact"
      [ -f "$state/task-a.$artifact" ] || fail "rejected retirement removed $artifact"
    done
  done
  for field in 10 11 13; do
    dir=$(make_case "retirement-split-device-$field")
    state="$dir/home/state"
    write_poll_meta "$state" task-a https://github.com/o/r/pull/1
    seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
    fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot split-device retirement"
    fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish split-device receipt"
    shift_retirement_device "$state" task-a
    awk -v field="$field" 'NR == field { sub(/^[0-9]+:/, "999999999:") } { print }' \
      "$state/task-a.pr-poll-retirement" > "$state/.split-device"
    cat "$state/.split-device" > "$state/task-a.pr-poll-retirement"
    ! fm_pr_poll_retirement_state_valid "$state" task-a \
      || fail "retirement accepted inconsistent recorded devices in field $field"
  done
  pass "retirement device recovery still refuses replaced inodes and altered content"
}

test_sweep_keeps_later_removal_in_place_after_an_update() {
  local dir state armed_state
  for armed_state in OPEN MERGED; do
    dir=$(make_case "sweep-updated-later-pull-$armed_state")
    state="$dir/home/state"
    write_poll_meta "$state" task-a https://github.com/o/r/pull/1
    seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
    mkdir -p "$dir/sweep"
    "$REAL_JQ" -n '[range(2;103) | {
      number:., createdAt:., updatedAt:., state:"OPEN", merged:false,
      isInMergeQueue:true, timelineItems:{nodes:[]}
    }]' > "$dir/sweep/pulls.json"
    retire_contributions_observer "$dir"
    add_stop_custom_check "$dir"
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE="$armed_state" \
      FM_TEST_GH_SWEEP_DIR="$dir/sweep" FM_TEST_GH_SWEEP_MUTATING=1 \
      run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err" \
      || fail "updated later-page sweep failed: $(cat "$dir/watch.err")"
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" \
      > "$dir/drain.out" 2> "$dir/drain.err" || fail "updated later-page sweep drain failed"
    [ "$(grep -Fc 'dequeued https://github.com/o/r/pull/2 reason=failed_checks' "$dir/drain.out")" -eq 1 ] \
      || fail "an update moved the later removal out of the sweep: $(cat "$dir/drain.out")"
    "$ROOT/bin/fm-pr-queue-sweep.sh" --contains "$state" evt2 \
      || fail "the later-page removal was not durably recorded"
    if [ "$armed_state" = MERGED ]; then
      assert_poll_absent "$state" task-a
      [ -z "$("$ROOT/bin/fm-pr-queue-sweep.sh" --repos "$state")" ] \
        || fail "the completed sweep did not retire the repository's last watch"
    else
      fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
        || fail "the updated later-page sweep retired an unmerged watch"
    fi
  done
  pass "a later-page removal remains discoverable after an update, even when the last armed pull request merges"
}

test_parser_matrix
test_gitlab_merge_watch
test_forgejo_merge_watch
test_forgejo_login_list_shapes
test_gerrit_merge_watch
test_gerrit_arming_records_no_patch_set_revision
test_gerrit_ready_gate_reads_the_published_tree
test_gerrit_nm_ready_gate_requires_recovered_custody
test_merged_poll_retires_once
test_merged_poll_reregistration_after_notification_is_absorbed
test_merged_poll_retries_a_failed_upward_report
test_self_merge_and_poll_publish_one_outcome
test_merged_poll_row_carries_the_merge_authority
test_merged_poll_row_names_no_authority_when_no_record_grants_one
test_authority_persistence_refuses_rebound_metadata
test_authority_persists_before_control_unlock
test_teardown_cannot_race_authority_consumption
test_authority_retirement_preserves_replacement
test_merged_poll_reports_upward_from_a_secondmate_home_once
test_different_merged_pr_for_same_task_is_not_absorbed
test_persistent_secondmate_retirement_is_poll_only
test_retirement_crash_recovery
test_external_merge_transition_retires_only_terminal_poll
test_retirement_refuses_replacement_and_nonterminal_results
test_retirement_queue_failure_and_receipt_tampering
test_gitlab_merged_poll_retires
test_invalid_entrypoints_have_zero_side_effects
test_draft_pull_request_is_not_armed
test_secondmate_record_refuses_a_pr_watch
test_unpushed_named_head_refuses_registration
test_direct_pr_unpushed_commit_refuses_registration
test_valid_recording_and_merge_derivation
test_rejected_metacharacter_bytes_are_inert
test_static_poll_contract
test_github_poll_uses_the_pr_host
test_github_identity_fields_stay_strings
test_dequeue_sweep_reaches_later_checks
test_queue_drop_reason_is_preserved
test_verified_queue_drop_wakes_once
test_open_queue_removals_wake_once_across_a_watched_repo
test_seen_record_errors_do_not_block_later_watches
test_open_queue_sweep_exhausts_pages
test_sweep_keeps_later_removal_in_place_after_an_update
test_old_template_watch_polls_after_upgrade
test_tampered_check_stays_rejected
test_unshipped_template_hash_is_refused
test_interrupted_template_upgrade_finishes_on_the_next_poll
test_interrupted_template_upgrade_refuses_replaced_artifacts
test_old_template_and_renumber_are_both_recovered
test_sweep_page_deadline_reports_every_removal
test_progressing_sweep_survives_rearm_past_stall_bound
test_slow_registered_polls_survive_rearm
test_merged_only_watch_still_sweeps_its_repo
test_recovered_merged_watch_still_sweeps_its_repo
test_failed_sweep_keeps_the_repository_for_the_next_cycle
test_seen_record_errors_keep_repository_discovery
test_completed_repo_removals_survive_another_repo_failure
test_unobserved_merge_preserves_repository_before_cleanup_or_rearm
test_retirement_survives_device_renumbering
test_retirement_device_recovery_keeps_content_and_inode_checks
test_atomic_interruption_leaves_no_partial_artifact
test_concurrent_watcher_sees_only_complete_publication
test_poll_publication_refuses_unsafe_destinations
test_live_artifact_single_link_and_privacy_validation
test_device_renumbered_poll_stays_armed
test_device_rerecord_refuses_tampered_artifacts
test_device_rerecord_serializes_direct_rearm
test_device_rerecord_serializes_rerecord
test_postrename_poll_validation_revokes_and_retries
test_bootstrap_leaves_unauthenticated_checks
test_custom_snapshot_cleanup_on_signal
test_returned_custom_check_descendants_are_drained
test_teardown_removes_poll_artifacts
