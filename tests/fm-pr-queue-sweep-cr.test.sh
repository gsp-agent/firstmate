#!/usr/bin/env bash
# Behavioral tests for the stale changes-requested reporting in
# bin/fm-pr-queue-sweep.sh and its durable round record.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SCRIPT="$ROOT/bin/fm-pr-queue-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-queue-sweep-cr-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the sweep's jq programs with the real jq, which was not found"
REAL_JQ=$(command -v jq)
BASE_PATH=$PATH

HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
URL=https://github.com/o/r/pull/7
NOW=2000000000

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
jq_filter=
cursor=null
number=
query=
paginate=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) shift; jq_filter=${1-} ;;
    --paginate) paginate=1 ;;
    -f|-F)
      shift
      case "${1-}" in
        cursor=*) cursor=${1#cursor=} ;;
        number=*) number=${1#number=} ;;
        query=*) query=${1#query=} ;;
      esac
      ;;
  esac
  shift
done
[ -n "$jq_filter" ] || exit 91
if [ -n "$number" ]; then
  case "$query" in
    *'latestOpinionatedReviews('*) ;;
    *)
      "$FM_TEST_REAL_JQ" --argjson number "$number" '
        {data:{repository:{pullRequest:([
          .data.repository.pullRequests.nodes[] | select(.number == $number)
          | {state, merged, headRefOid}
        ] | first // null)}}}
      ' "$FM_TEST_SWEEP_DIR/page1.json" | "$FM_TEST_REAL_JQ" -r "$jq_filter"
      exit $?
      ;;
  esac
  if [ -n "${FM_TEST_REVIEW_BEAT_LOG:-}" ]; then
    if [ "$(uname)" = Darwin ]; then
      modified=$(/usr/bin/stat -f %m "$FM_PR_SWEEP_BEAT") || exit 91
    else
      modified=$(stat -c %Y "$FM_PR_SWEEP_BEAT") || exit 91
    fi
    if [ "$(( $(date +%s) - modified ))" -lt 900 ]; then
      printf 'fresh\n' >> "$FM_TEST_REVIEW_BEAT_LOG"
    else
      printf 'stale\n' >> "$FM_TEST_REVIEW_BEAT_LOG"
    fi
    touch -t 200001010000 "$FM_PR_SWEEP_BEAT" || exit 91
  fi
  [ "${FM_TEST_REVIEW_STATUS:-0}" -eq 0 ] || exit "$FM_TEST_REVIEW_STATUS"
  page=page1
  while :; do
    response="$FM_TEST_SWEEP_DIR/reviews-$number-$page.json"
    if [ ! -f "$response" ] && [ "$page" = page1 ]; then
      response="$FM_TEST_SWEEP_DIR/page1.json"
    fi
    [ -f "$response" ] || exit 91
    [ -z "${FM_TEST_REVIEW_LOG:-}" ] || printf '%s %s\n' "$number" "$page" >> "$FM_TEST_REVIEW_LOG"
    "$FM_TEST_REAL_JQ" \
      '.data.repository.pullRequest |= {author, latestOpinionatedReviews}' "$response" \
      | "$FM_TEST_REAL_JQ" -r "$jq_filter" || exit 91
    [ "$paginate" -eq 1 ] || break
    more=$("$FM_TEST_REAL_JQ" -r \
      '.data.repository.pullRequest.latestOpinionatedReviews.pageInfo.hasNextPage' "$response")
    [ "$more" = true ] || break
    page=$("$FM_TEST_REAL_JQ" -r \
      '.data.repository.pullRequest.latestOpinionatedReviews.pageInfo.endCursor' "$response")
  done
  exit 0
fi
page=$cursor
[ "$page" != null ] && [ -n "$page" ] || page=page1
[ -f "$FM_TEST_SWEEP_DIR/$page.json" ] || exit 91
"$FM_TEST_REAL_JQ" -r "$jq_filter" "$FM_TEST_SWEEP_DIR/$page.json"
SH
chmod +x "$FAKEBIN/gh"

cat > "$FAKEBIN/launch" <<'SH'
#!/usr/bin/env bash
[ "$2" -eq 0 ] || exit "$2"
printf '%s\n' "$3" >> "$1"
SH
chmod +x "$FAKEBIN/launch"

cat > "$FAKEBIN/launch-waiting" <<'SH'
#!/usr/bin/env bash
touch "$4/launch-started"
perl -MTime::HiRes=sleep -e 'for (1..500) { last if -e $ARGV[0]; sleep 0.02 }' "$4/contender-finished"
exec "$5" "$1" "$2" "$3"
SH
chmod +x "$FAKEBIN/launch-waiting"

# Write one sweep page holding a single pull request with the given review
# state. Ages are seconds before FM_CR_FIXROUND_NOW.
write_pr_page() {  # <dir> <decision> <check-state> <draft> <head> <age-secs> <reviewers-json>
  local dir=$1 decision=$2 checks=$3 draft=$4 head=$5 age=$6 reviewers=$7
  mkdir -p "$dir/sweep"
  # shellcheck disable=SC2016 # jq program text is literal.
  "$REAL_JQ" -n \
    --arg decision "$decision" --arg checks "$checks" --arg head "$head" \
    --argjson draft "$draft" --argjson committed "$((NOW - age))" \
    --argjson reviewers "$reviewers" '
    ($reviewers | map({author:{login:.}, state:"CHANGES_REQUESTED", commit:{oid:$head}})) as $reviews |
    {data:{repository:{pullRequests:{
      pageInfo:{hasNextPage:false, endCursor:null},
      nodes:[{number:7, state:"OPEN", merged:false, isInMergeQueue:false,
        isDraft:$draft, reviewDecision:$decision, headRefOid:$head,
        author:{login:"prauthor"},
        statusCheckRollup:{state:$checks},
        commits:{nodes:[{commit:{oid:$head, committedDate:($committed | todate)}}]},
        latestReviews:{nodes:$reviews},
        timelineItems:{nodes:[]}}]},
      pullRequest:{author:{login:"prauthor"},
        latestReviews:{nodes:$reviews},
        latestOpinionatedReviews:{nodes:$reviews, pageInfo:{hasNextPage:false, endCursor:null}}}
    }}}' > "$dir/sweep/page1.json"
}

write_review_page() {
  local dir=$1 page=$2 more=$3 cursor=$4 reviews=$5
  "$REAL_JQ" -n --argjson reviews "$reviews" --argjson more "$more" --arg cursor "$cursor" '
    {data:{repository:{pullRequest:{author:{login:"prauthor"},
      latestOpinionatedReviews:{nodes:$reviews, pageInfo:{hasNextPage:$more, endCursor:$cursor}}
    }}}}' > "$dir/sweep/reviews-7-$page.json" || fail "could not write reviewer page $page"
}

scan() {  # <dir> <state> <now> [repos]
  local dir=$1 state=$2 now=$3
  FM_TEST_REAL_JQ="$REAL_JQ" FM_TEST_SWEEP_DIR="$dir/sweep" \
    FM_PR_SWEEP_REPOS="${4-o/r}" FM_CR_FIXROUND_NOW="$now" \
    PATH="$FAKEBIN:$BASE_PATH" "$SCRIPT" --scan "$state"
}

discover_repos() {
  FM_TEST_REAL_JQ="$REAL_JQ" FM_TEST_SWEEP_DIR="$1/sweep" \
    PATH="$FAKEBIN:$BASE_PATH" "$SCRIPT" --repos "$2"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_pending_rounds_keep_repository_discovery_after_retirement() {
  local dir state out repos template
  dir="$TMP_ROOT/retired-last-poll"
  state="$dir/state"
  template="$ROOT/bin/fm-pr-poll.sh"
  mkdir -p "$state" "$dir/wt"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_write_meta "$state/last.meta" "window=fm-last" "worktree=$dir/wt" \
    'pr=https://github.com/o/r/pull/9'
  fm_pr_poll_prepare "$state" last github https://github.com/o/r/pull/9 github.com o/r 9 "$template" \
    || fail "could not prepare the last armed poll"
  fm_pr_poll_publish_prepared || fail "could not publish the last armed poll"
  fm_pr_poll_snapshot_capture "$state" last "$template" || fail "could not snapshot the last poll"
  fm_pr_poll_retirement_publish "$state" last "$template" merged || fail "could not begin poll retirement"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
  out=$(scan "$dir" "$state" "$NOW" '') || fail "last-poll sweep failed"
  case "$out" in *" round=1 reviewers=chipdev"*) ;; *) fail "last-poll sweep missed the unarmed PR: $out" ;; esac
  case "$out" in *"queue-empty o/r"*) ;; *) fail "last-poll sweep did not allow retirement: $out" ;; esac
  FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn || fail "replacement fix task did not launch"
  fm_pr_poll_retirement_recover_all "$state" "$template" o/r || fail "last poll retirement failed"
  [ ! -e "$state/last.pr-poll" ] && [ ! -e "$state/last.check.sh" ] \
    && [ ! -e "$state/last.pr-poll-retirement" ] || fail "the last armed poll was not retired"
  repos=$(discover_repos "$dir" "$state") || fail "pending-round repository discovery failed"
  [ "$repos" = o/r ] || fail "pending round lost repository discovery after poll retirement"
  out=$(scan "$dir" "$state" "$((NOW + 18000))" '') || fail "round 2 scan after retirement failed"
  case "$out" in *" round=2 reviewers=chipdev"*) ;; *) fail "round 2 was lost after retirement: $out" ;; esac
  FM_CR_FIXROUND_NOW="$((NOW + 18000))" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round2 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "round 2 after retirement did not launch"
  [ "$(discover_repos "$dir" "$state")" = o/r ] || fail "round 2 lost repository discovery"
  out=$(scan "$dir" "$state" "$((NOW + 36000))" '') || fail "escalation scan after retirement failed"
  case "$out" in *" rounds=2 reviewers=chipdev"*) ;; *) fail "escalation was lost after retirement: $out" ;; esac
  "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" escalated || fail "post-retirement escalation record failed"
  [ -z "$(discover_repos "$dir" "$state")" ] || fail "an escalated round retained repository discovery"
  out=$(scan "$dir" "$state" "$((NOW + 72000))" '') || fail "post-escalation discovery failed"
  [ -z "$out" ] || fail "an escalated round alone still scheduled a sweep: $out"
  pass "pending rounds retain discovery across poll retirement and restarts until escalation"
}

test_exhausted_rounds_escalate_after_checks_stop_passing() {
  local dir state out checks action
  for checks in FAILURE PENDING ERROR ''; do
    dir="$TMP_ROOT/exhausted-${checks:-missing}"
    state="$dir/state"
    mkdir -p "$state"
    write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
    for action in round1 round2; do
      FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" "$action" -- \
        "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "exhausted-round seed failed"
    done
    write_pr_page "$dir" CHANGES_REQUESTED "$checks" false "$HEAD" 18000 '["chipdev"]'
    out=$(scan "$dir" "$state" "$((NOW + 18000))") || fail "exhausted-round scan failed"
    case "$out" in
      *"changes-requested-escalated $URL head=$HEAD rounds=2 reviewers=chipdev"*) ;;
      *) fail "exhausted same-head rounds did not escalate with checks=$checks: $out" ;;
    esac
    "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" escalated || fail "ungreen escalation record failed"
    out=$(scan "$dir" "$state" "$((NOW + 36000))") || fail "repeat ungreen escalation scan failed"
    case "$out" in *changes-requested*) fail "ungreen escalation repeated: $out" ;; esac
  done
  pass "exhausted same-head rounds escalate after failed, pending, errored, or missing checks"
}

test_historical_rounds_do_not_retain_repository_discovery() {
  local dir state out transition rounds action current_head pr_state merged
  for rounds in 1 2; do
    for transition in moved closed merged; do
      dir="$TMP_ROOT/historical-$rounds-$transition"
      state="$dir/state"
      mkdir -p "$state"
      write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
      FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
        "$FAKEBIN/launch" "$dir/launches" 0 spawn || fail "historical round 1 seed failed"
      if [ "$rounds" -eq 2 ]; then
        FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round2 -- \
          "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "historical round 2 seed failed"
      fi
      [ "$(discover_repos "$dir" "$state")" = o/r ] || fail "a current open round did not retain discovery"
      current_head=$HEAD
      pr_state=OPEN
      merged=false
      case "$transition" in
        moved) current_head=$HEAD2 ;;
        closed) pr_state=CLOSED ;;
        merged) pr_state=MERGED; merged=true ;;
      esac
      "$REAL_JQ" --arg head "$current_head" --arg state "$pr_state" --argjson merged "$merged" \
        '.data.repository.pullRequests.nodes[0] as $pr |
        .data.repository.pullRequests.nodes = [
          ($pr + {headRefOid:$head, state:$state, merged:$merged} | .commits.nodes[0].commit.oid = $head),
          ($pr + {number:8})
        ]' "$dir/sweep/page1.json" > "$dir/sweep/transition.json"
      mv "$dir/sweep/transition.json" "$dir/sweep/page1.json"
      out=$(discover_repos "$dir" "$state") || fail "historical repository discovery failed"
      [ -z "$out" ] || fail "a $transition round retained historical repository discovery"
      out=$(scan "$dir" "$state" "$((NOW + 36000))" '') || fail "historical-only scan failed"
      [ -z "$out" ] || fail "a historical round swept unrelated pull requests: $out"
    done
  done
  dir="$TMP_ROOT/one-current-round"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
  "$REAL_JQ" '.data.repository.pullRequests.nodes[0] as $pr |
    .data.repository.pullRequests.nodes = [($pr + {state:"CLOSED"}), ($pr + {number:8})]
  ' "$dir/sweep/page1.json" > "$dir/sweep/mixed.json"
  mv "$dir/sweep/mixed.json" "$dir/sweep/page1.json"
  for action in 7 8; do
    FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "https://github.com/o/r/pull/$action" "$HEAD" round1 -- \
      "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "mixed round seed failed"
  done
  [ "$(discover_repos "$dir" "$state")" = o/r ] || fail "a closed sibling hid the outstanding current-head round"
  out=$(scan "$dir" "$state" "$((NOW + 18000))" '') || fail "mixed pending scan failed"
  case "$out" in *"https://github.com/o/r/pull/8 head=$HEAD round=2 "*) ;; *) fail "the current sibling lost round 2: $out" ;; esac
  pass "closed, merged, and superseded rounds retain no repository while current siblings do"
}

test_reviewer_lookups_refresh_progress_on_success_and_failure() {
  local dir state out status action
  for status in 0 1 124; do
    dir="$TMP_ROOT/reviewer-progress-$status"
    state="$dir/state"
    mkdir -p "$state"
    touch "$dir/beacon"
    write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
    "$REAL_JQ" '.data.repository.pullRequests.nodes[0] as $pr |
      .data.repository.pullRequests.nodes = [range(7;10) as $n | $pr + {number:$n}]
    ' "$dir/sweep/page1.json" > "$dir/sweep/multiple.json"
    mv "$dir/sweep/multiple.json" "$dir/sweep/page1.json"
    FM_CR_FIXROUND_NOW="$((NOW - 18000))" "$SCRIPT" --cr-dispatch "$state" https://github.com/o/r/pull/8 "$HEAD" round1 -- \
      "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "round 2 progress seed failed"
    for action in round1 round2; do
      FM_CR_FIXROUND_NOW="$((NOW - 18000))" "$SCRIPT" --cr-dispatch "$state" https://github.com/o/r/pull/9 "$HEAD" "$action" -- \
        "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "escalation progress seed failed"
    done
    out=$(FM_PR_SWEEP_BEAT="$dir/beacon" FM_TEST_REVIEW_BEAT_LOG="$dir/progress" \
      FM_TEST_REVIEW_STATUS="$status" scan "$dir" "$state" "$NOW") || fail "review progress scan failed for status $status"
    [ "$(cat "$dir/progress")" = "fresh
fresh
fresh" ] || fail "reviewer lookup status $status left a stale progress beacon"
    case "$out" in *"$URL head=$HEAD round=1 "*) ;; *) fail "progress scan lost round 1: $out" ;; esac
    case "$out" in *"https://github.com/o/r/pull/8 head=$HEAD round=2 "*) ;; *) fail "progress scan lost round 2: $out" ;; esac
    case "$out" in *"https://github.com/o/r/pull/9 head=$HEAD rounds=2 "*) ;; *) fail "progress scan lost escalation: $out" ;; esac
  done
  pass "every reviewer lookup refreshes progress after success, failure, or timeout"
}

test_later_comments_do_not_hide_blocking_reviewers() {
  local dir state out
  dir="$TMP_ROOT/comment-after-changes"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
  "$REAL_JQ" '
    .data.repository.pullRequests.nodes[0].latestReviews.nodes[0].state = "COMMENTED" |
    .data.repository.pullRequest.latestReviews.nodes[0].state = "COMMENTED"
  ' "$dir/sweep/page1.json" > "$dir/sweep/comment.json"
  mv "$dir/sweep/comment.json" "$dir/sweep/page1.json"
  out=$(scan "$dir" "$state" "$NOW") || fail "comment-after-changes scan failed"
  case "$out" in
    *" round=1 reviewers=chipdev"*) ;;
    *) fail "a later comment hid the blocking reviewer: $out" ;;
  esac
  pass "a later comment preserves the reviewer's blocking verdict"
}

test_blocking_reviewers_are_collected_from_every_page() {
  local dir state out approvals
  dir="$TMP_ROOT/reviewer-pagination"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '[]'
  approvals=$("$REAL_JQ" -n '[range(1;101) | {author:{login:("dev" + tostring)}, state:"APPROVED"}]')
  write_review_page "$dir" page1 true page2 "$approvals"
  write_review_page "$dir" page2 false '' '[{"author":{"login":"chipdev"},"state":"CHANGES_REQUESTED"}]'
  out=$(FM_TEST_REVIEW_LOG="$dir/review-pages" scan "$dir" "$state" "$NOW") \
    || fail "paginated reviewer scan failed"
  case "$out" in
    *" round=1 reviewers=chipdev"*) ;;
    *) fail "the blocker on the second reviewer page was lost: $out" ;;
  esac
  [ "$(cat "$dir/review-pages")" = "7 page1
7 page2" ] || fail "review collection did not consume both pages"
  pass "blocking reviewers beyond the first 100 are named"
}

test_missing_reviewer_names_do_not_suppress_any_round() {
  local dir state out
  dir="$TMP_ROOT/unnamed-reviewers"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '[]'
  write_review_page "$dir" page1 false '' '[
    {"author":null,"state":"CHANGES_REQUESTED"},
    {"author":{"login":"prauthor"},"state":"CHANGES_REQUESTED"},
    {"author":{"login":"otherdev"},"state":"APPROVED"}
  ]'
  out=$(scan "$dir" "$state" "$NOW") || fail "unnamed-reviewer scan failed"
  case "$out" in *" round=1 reviewers=unknown"*) ;; *) fail "unnamed round 1 was skipped: $out" ;; esac
  FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "unnamed round 1 dispatch failed"
  out=$(scan "$dir" "$state" "$((NOW + 18000))") || fail "unnamed round 2 scan failed"
  case "$out" in *" round=2 reviewers=unknown"*) ;; *) fail "unnamed round 2 was skipped: $out" ;; esac
  FM_CR_FIXROUND_NOW="$((NOW + 18000))" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round2 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn || fail "unnamed round 2 dispatch failed"
  out=$(scan "$dir" "$state" "$((NOW + 36000))") || fail "unnamed escalation scan failed"
  case "$out" in *" rounds=2 reviewers=unknown"*) ;; *) fail "unnamed escalation was skipped: $out" ;; esac
  write_review_page "$dir" page1 true missing '[]'
  out=$(scan "$dir" "$state" "$((NOW + 36000))") || fail "failed-review-lookup scan failed"
  case "$out" in *" rounds=2 reviewers=unknown"*) ;; *) fail "a failed review lookup suppressed escalation: $out" ;; esac
  pass "unavailable reviewer names never suppress rounds or escalation"
}

wait_for_launch_start() {
  local dir=$1 pid=$2 ticks=0
  while [ ! -e "$dir/launch-started" ] && [ "$ticks" -lt 500 ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.02
    ticks=$((ticks + 1))
  done
  [ -e "$dir/launch-started" ]
}

test_concurrent_round_record_writers_preserve_all_prs() {
  local dir state other_url pid first_status=0 other_status=0
  dir="$TMP_ROOT/concurrent-records"
  state="$dir/state"
  other_url=https://github.com/o/r/pull/8
  mkdir -p "$state"
  FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "concurrent round 1 seed failed"
  FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$other_url" "$HEAD" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn || fail "other PR round 1 seed failed"
  FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$other_url" "$HEAD" round2 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "other PR round 2 seed failed"
  FM_CR_FIXROUND_NOW="$((NOW + 18000))" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round2 -- \
    "$FAKEBIN/launch-waiting" "$dir/launches" 0 relaunch "$dir" "$FAKEBIN/launch" \
    > "$dir/first.out" 2> "$dir/first.err" &
  pid=$!
  wait_for_launch_start "$dir" "$pid" || fail "the first concurrent launch never started"
  "$SCRIPT" --cr-record "$state" "$other_url" "$HEAD" escalated \
    > "$dir/other.out" 2> "$dir/other.err" || other_status=$?
  touch "$dir/contender-finished"
  wait "$pid" || first_status=$?
  [ "$first_status" -eq 0 ] && [ "$other_status" -eq 0 ] \
    || fail "concurrent writers failed: $(cat "$dir/first.err" "$dir/other.err")"
  grep -Fx "$URL $HEAD 2 $((NOW + 18000)) 0" "$state/changes-requested-sweep.seen" >/dev/null \
    || fail "a concurrent escalation lost the second dispatched round"
  grep -Fx "$other_url $HEAD 2 $NOW 1" "$state/changes-requested-sweep.seen" >/dev/null \
    || fail "a concurrent dispatch erased another pull request's escalation"
  pass "concurrent dispatch and escalation preserve both pull-request records"
}

test_concurrent_duplicate_round_dispatches_launch_once() {
  local dir state pid first_status=0 other_status=0
  dir="$TMP_ROOT/concurrent-duplicate"
  state="$dir/state"
  mkdir -p "$state"
  FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
    "$FAKEBIN/launch-waiting" "$dir/launches" 0 relaunch "$dir" "$FAKEBIN/launch" \
    > "$dir/first.out" 2> "$dir/first.err" &
  pid=$!
  wait_for_launch_start "$dir" "$pid" || fail "the first duplicate launch never started"
  FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn \
    > "$dir/other.out" 2> "$dir/other.err" || other_status=$?
  touch "$dir/contender-finished"
  wait "$pid" || first_status=$?
  [ "$first_status" -eq 0 ] && [ "$other_status" -eq 0 ] \
    || fail "duplicate dispatches failed: $(cat "$dir/first.err" "$dir/other.err")"
  [ "$(cat "$dir/launches")" = relaunch ] || fail "concurrent duplicates launched the same round twice"
  grep -Fx "$URL $HEAD 1 $NOW 0" "$state/changes-requested-sweep.seen" >/dev/null \
    || fail "duplicate dispatches corrupted the first-round record"
  pass "concurrent duplicate wakes dispatch their round only once"
}

test_stale_changes_requested_reports_round_one() {
  local dir state out draft
  for draft in false true; do
    dir="$TMP_ROOT/round-one-$draft"
    state="$dir/state"
    mkdir -p "$state"
    write_pr_page "$dir" CHANGES_REQUESTED SUCCESS "$draft" "$HEAD" 18000 '["chipdev","otherdev"]'
    out=$(scan "$dir" "$state" "$NOW") || fail "round-one scan failed"
    [ "$out" = "changes-requested $URL head=$HEAD round=1 reviewers=chipdev,otherdev
queue-empty o/r" ] \
      || fail "stale changes-requested pull request (draft=$draft) did not report round 1: $out"
  done
  pass "draft and ready stale green changes-requested pull requests report round 1"
}

test_wakes_and_unsuccessful_dispatches_do_not_consume_rounds() {
  local dir state out rc status
  dir=$(make_case deferred-dispatch)
  state="$dir/state"
  mkdir -p "$dir/config"
  printf 'tmux\n' > "$dir/config/backend"
  cp "$FAKEBIN/gh" "$dir/fakebin/gh"
  printf 'github\n%s\ngithub.com\no/r\n7\n' "$URL" > "$state/watch.pr-poll"
  touch "$state/home-summary.json"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'

  FM_TEST_REAL_JQ="$REAL_JQ" FM_TEST_SWEEP_DIR="$dir/sweep" FM_CR_FIXROUND_NOW="$NOW" \
    perl -e 'alarm 60; exec @ARGV' env FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
      FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_POLL=0.02 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      PATH="$dir/fakebin:$BASE_PATH" "$ROOT/bin/fm-watch.sh" \
      > "$dir/watch.out" 2> "$dir/watch.err" \
    || fail "changes-requested watcher failed: $(cat "$dir/watch.err")"
  grep -F "changes-requested $URL head=$HEAD round=1 reviewers=chipdev" "$state/.wake-queue" >/dev/null \
    || fail "watcher did not durably publish the fix wake: $(cat "$dir/watch.out")"
  [ ! -e "$state/changes-requested-sweep.seen" ] \
    || fail "publishing a wake consumed a round before the deferred launch"

  for status in 75 1; do
    rc=0
    FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
      "$FAKEBIN/launch" "$dir/launches" "$status" spawn || rc=$?
    [ "$rc" -eq "$status" ] || fail "dispatch did not preserve launch status $status (got $rc)"
    [ ! -e "$dir/launches" ] || fail "an unsuccessful launch started a worker"
    [ ! -e "$state/changes-requested-sweep.seen" ] \
      || fail "a deferred or failed dispatch consumed a round"
    out=$(scan "$dir" "$state" "$((NOW + 36000))") || fail "post-deferral scan failed"
    case "$out" in
      *" head=$HEAD round=1 "*) ;;
      *) fail "a deferred or failed dispatch advanced the round: $out" ;;
    esac
  done
  pass "a durable wake, capacity deferral, and failed launch consume no round"
}

test_fresh_or_ungreen_pull_requests_stay_silent() {
  local dir state out spec decision checks draft age
  for spec in \
    'CHANGES_REQUESTED SUCCESS false 3600' \
    'CHANGES_REQUESTED FAILURE false 18000' \
    'CHANGES_REQUESTED PENDING false 18000' \
    'APPROVED SUCCESS false 18000' \
    'REVIEW_REQUIRED SUCCESS false 18000'; do
    # shellcheck disable=SC2086
    set -- $spec
    decision=$1
    checks=$2
    draft=$3
    age=$4
    dir="$TMP_ROOT/silent-$decision-$checks-$draft-$age"
    state="$dir/state"
    mkdir -p "$state"
    write_pr_page "$dir" "$decision" "$checks" "$draft" "$HEAD" "$age" '["chipdev"]'
    out=$(scan "$dir" "$state" "$NOW") || fail "silent-case scan failed for $spec"
    case "$out" in
      *changes-requested*) fail "case $spec reported a fix round: $out" ;;
    esac
  done
  pass "fresh, ungreen, and non-changes-requested pull requests stay silent"
}

test_rounds_advance_then_escalate_and_survive_restart() {
  local dir state out record rc
  dir="$TMP_ROOT/rounds"
  state="$dir/state"
  record="$state/changes-requested-sweep.seen"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'

  out=$(scan "$dir" "$state" "$NOW") || fail "round 1 scan failed"
  case "$out" in *" round=1 "*) ;; *) fail "first scan did not report round 1: $out" ;; esac
  FM_CR_FIXROUND_NOW="$NOW" PATH="$FAKEBIN:$BASE_PATH" \
    "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
      "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "round 1 dispatch failed"
  [ "$(file_mode "$record")" = 600 ] || fail "the round record is not private"
  grep -Fx "$URL $HEAD 1 $NOW 0" "$record" >/dev/null \
    || fail "round 1 was not recorded durably: $(cat "$record")"

  out=$(scan "$dir" "$state" "$NOW") || fail "repeat scan failed"
  case "$out" in *changes-requested*) fail "a recorded round 1 reported again at once: $out" ;; esac
  FM_CR_FIXROUND_NOW="$((NOW + 18000))" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "repeat round 1 dispatch failed"
  [ "$(wc -l < "$dir/launches" | tr -d ' ')" -eq 1 ] || fail "round 1 launched twice"
  grep -Fx "$URL $HEAD 1 $NOW 0" "$record" >/dev/null \
    || fail "repeat round 1 changed the dispatch time"

  out=$(scan "$dir" "$state" "$((NOW + 18000))") || fail "round 2 scan failed"
  case "$out" in *" round=2 "*) ;; *) fail "second stale interval did not report round 2: $out" ;; esac
  rc=0
  FM_CR_FIXROUND_NOW="$((NOW + 18000))" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round2 -- \
    "$FAKEBIN/launch" "$dir/launches" 75 spawn || rc=$?
  [ "$rc" -eq 75 ] || fail "round 2 capacity deferral did not propagate"
  grep -Fx "$URL $HEAD 1 $NOW 0" "$record" >/dev/null \
    || fail "round 2 capacity deferral changed the round record"
  out=$(scan "$dir" "$state" "$((NOW + 36000))") || fail "deferred round 2 scan failed"
  case "$out" in *" round=2 "*) ;; *) fail "deferred round 2 escalated: $out" ;; esac
  FM_CR_FIXROUND_NOW="$((NOW + 18000))" PATH="$FAKEBIN:$BASE_PATH" \
    "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round2 -- \
      "$FAKEBIN/launch" "$dir/launches" 0 spawn || fail "round 2 dispatch failed"
  [ "$(cat "$dir/launches")" = "relaunch
spawn" ] || fail "the two rounds did not dispatch a relaunch and a spawn"

  out=$(scan "$dir" "$state" "$((NOW + 36000))") || fail "escalation scan failed"
  [ "$(printf '%s\n' "$out" | grep -c 'changes-requested-escalated')" -eq 1 ] \
    || fail "two rounds with no new head did not escalate: $out"
  FM_CR_FIXROUND_NOW="$((NOW + 36000))" PATH="$FAKEBIN:$BASE_PATH" \
    "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" escalated || fail "escalation record failed"

  out=$(scan "$dir" "$state" "$((NOW + 72000))") || fail "post-escalation scan failed"
  case "$out" in *changes-requested*) fail "an escalated pull request reported again: $out" ;; esac

  # Recording the same round twice is a no-op and keeps one line per pull request.
  FM_CR_FIXROUND_NOW="$((NOW + 72000))" PATH="$FAKEBIN:$BASE_PATH" \
    "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" escalated || fail "repeat escalation record failed"
  [ "$(grep -c "^$URL " "$record")" -eq 1 ] || fail "the record grew duplicate lines: $(cat "$record")"
  pass "rounds advance on stale intervals, escalate after two, and survive restarts"
}

test_new_head_restarts_rounds() {
  local dir state out
  dir="$TMP_ROOT/new-head"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
  FM_CR_FIXROUND_NOW="$NOW" PATH="$FAKEBIN:$BASE_PATH" \
    "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
      "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "seed round 1 failed"
  FM_CR_FIXROUND_NOW="$NOW" PATH="$FAKEBIN:$BASE_PATH" \
    "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round2 -- \
      "$FAKEBIN/launch" "$dir/launches" 0 relaunch || fail "seed round 2 failed"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD2" 18000 '["chipdev"]'
  out=$(scan "$dir" "$state" "$NOW") || fail "new-head scan failed"
  case "$out" in *" head=$HEAD2 round=1 "*) ;; *) fail "a new head did not restart at round 1: $out" ;; esac
  FM_CR_FIXROUND_NOW="$NOW" "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD2" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn || fail "new-head round 1 dispatch failed"
  grep -Fx "$URL $HEAD2 1 $NOW 0" "$state/changes-requested-sweep.seen" >/dev/null \
    || fail "a new head did not reset the dispatched count"
  pass "a new head restarts the round count"
}

test_queue_removal_keeps_its_reason() {
  local dir state out
  dir="$TMP_ROOT/queue-removal"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" APPROVED SUCCESS true "$HEAD" 18000 '[]'
  "$REAL_JQ" '.data.repository.pullRequests.nodes[0].timelineItems.nodes = [
    {__typename:"RemovedFromMergeQueueEvent", id:"evt7", reason:"failed_checks"}
  ]' "$dir/sweep/page1.json" > "$dir/sweep/removal.json"
  mv "$dir/sweep/removal.json" "$dir/sweep/page1.json"
  out=$(scan "$dir" "$state" "$NOW") || fail "queue-removal scan failed"
  [ "$out" = "dequeued $URL reason=failed_checks event=evt7
queue-empty o/r" ] || fail "the sweep lost the queue removal or its reason: $out"
  pass "queue removals preserve their reason alongside review-state reporting"
}

test_record_refusals_and_malformed_record_fail_the_scan() {
  local dir state
  dir="$TMP_ROOT/refusals"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
  "$SCRIPT" --cr-dispatch "$state" 'https://example.com/o/r/pull/7' "$HEAD" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn 2>/dev/null \
    && fail "a non-GitHub URL was recorded"
  "$SCRIPT" --cr-dispatch "$state" "$URL" 'not-a-head' round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn 2>/dev/null \
    && fail "a malformed head was recorded"
  "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round3 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn 2>/dev/null \
    && fail "an unknown round action was recorded"
  "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" round1 2>/dev/null \
    && fail "a round was recorded without dispatch"
  "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" escalated 2>/dev/null \
    && fail "an escalation was recorded without two dispatched rounds"
  "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round2 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn 2>/dev/null \
    && fail "round 2 was dispatched without round 1"
  [ ! -e "$dir/launches" ] || fail "an invalid dispatch launched a worker"
  printf 'malformed\n' > "$state/changes-requested-sweep.seen"
  chmod 0600 "$state/changes-requested-sweep.seen"
  scan "$dir" "$state" "$NOW" >/dev/null 2>&1 \
    && fail "a malformed round record did not fail the scan"
  discover_repos "$dir" "$state" >/dev/null 2>&1 \
    && fail "a malformed round record did not fail repository discovery"
  "$SCRIPT" --cr-dispatch "$state" "$URL" "$HEAD" round1 -- \
    "$FAKEBIN/launch" "$dir/launches" 0 spawn 2>/dev/null \
    && fail "a malformed round record did not fail dispatch"
  [ ! -e "$dir/launches" ] || fail "a malformed round record launched a worker"
  pass "record refusals are loud and a malformed record fails the scan"
}

if [ "$#" -gt 0 ]; then
  "$@"
  exit $?
fi

test_exhausted_rounds_escalate_after_checks_stop_passing
test_historical_rounds_do_not_retain_repository_discovery
test_pending_rounds_keep_repository_discovery_after_retirement
test_reviewer_lookups_refresh_progress_on_success_and_failure
test_later_comments_do_not_hide_blocking_reviewers
test_blocking_reviewers_are_collected_from_every_page
test_missing_reviewer_names_do_not_suppress_any_round
test_concurrent_round_record_writers_preserve_all_prs
test_concurrent_duplicate_round_dispatches_launch_once
test_wakes_and_unsuccessful_dispatches_do_not_consume_rounds
test_stale_changes_requested_reports_round_one
test_fresh_or_ungreen_pull_requests_stay_silent
test_rounds_advance_then_escalate_and_survive_restart
test_new_head_restarts_rounds
test_queue_removal_keeps_its_reason
test_record_refusals_and_malformed_record_fail_the_scan
