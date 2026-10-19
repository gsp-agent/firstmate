#!/usr/bin/env bash
# Behavioral tests for the stale changes-requested reporting in
# bin/fm-pr-queue-sweep.sh and its durable round record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) shift; jq_filter=${1-} ;;
    -f|-F)
      shift
      case "${1-}" in
        cursor=*) cursor=${1#cursor=} ;;
      esac
      ;;
  esac
  shift
done
[ -n "$jq_filter" ] || exit 91
page=$cursor
[ "$page" != null ] && [ -n "$page" ] || page=page1
[ -f "$FM_TEST_SWEEP_DIR/$page.json" ] || exit 91
"$FM_TEST_REAL_JQ" -r "$jq_filter" "$FM_TEST_SWEEP_DIR/$page.json"
SH
chmod +x "$FAKEBIN/gh"

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
    {data:{repository:{pullRequests:{
      pageInfo:{hasNextPage:false, endCursor:null},
      nodes:[{number:7, state:"OPEN", merged:false, isInMergeQueue:false,
        isDraft:$draft, reviewDecision:$decision, headRefOid:$head,
        author:{login:"prauthor"},
        statusCheckRollup:{state:$checks},
        commits:{nodes:[{commit:{oid:$head, committedDate:($committed | todate)}}]},
        latestReviews:{nodes:($reviewers | map({author:{login:.}, state:"CHANGES_REQUESTED", commit:{oid:$head}}))},
        timelineItems:{nodes:[]}}]}}}}' > "$dir/sweep/page1.json"
}

scan() {  # <dir> <state> <now>
  local dir=$1 state=$2 now=$3
  FM_TEST_REAL_JQ="$REAL_JQ" FM_TEST_SWEEP_DIR="$dir/sweep" \
    FM_PR_SWEEP_REPOS='o/r' FM_CR_FIXROUND_NOW="$now" \
    PATH="$FAKEBIN:$BASE_PATH" "$SCRIPT" --scan "$state"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_stale_changes_requested_reports_round_one() {
  local dir state out
  dir="$TMP_ROOT/round-one"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev","otherdev"]'
  out=$(scan "$dir" "$state" "$NOW") || fail "round-one scan failed"
  [ "$out" = "changes-requested $URL head=$HEAD round=1 reviewers=chipdev,otherdev
queue-empty o/r" ] \
    || fail "stale changes-requested pull request did not report round 1: $out"
  pass "a stale green changes-requested pull request reports round 1"
}

test_fresh_or_ungreen_pull_requests_stay_silent() {
  local dir state out spec decision checks draft age
  for spec in \
    'CHANGES_REQUESTED SUCCESS false 3600' \
    'CHANGES_REQUESTED FAILURE false 18000' \
    'CHANGES_REQUESTED PENDING false 18000' \
    'CHANGES_REQUESTED SUCCESS true 18000' \
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
  pass "fresh, ungreen, draft, and non-changes-requested pull requests stay silent"
}

test_rounds_advance_then_escalate_and_survive_restart() {
  local dir state out record
  dir="$TMP_ROOT/rounds"
  state="$dir/state"
  record="$state/changes-requested-sweep.seen"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'

  out=$(scan "$dir" "$state" "$NOW") || fail "round 1 scan failed"
  case "$out" in *" round=1 "*) ;; *) fail "first scan did not report round 1: $out" ;; esac
  FM_CR_FIXROUND_NOW="$NOW" PATH="$FAKEBIN:$BASE_PATH" \
    "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" round1 || fail "round 1 record failed"
  [ "$(file_mode "$record")" = 600 ] || fail "the round record is not private"
  grep -Fx "$URL $HEAD 1 $NOW 0" "$record" >/dev/null \
    || fail "round 1 was not recorded durably: $(cat "$record")"

  out=$(scan "$dir" "$state" "$NOW") || fail "repeat scan failed"
  case "$out" in *changes-requested*) fail "a recorded round 1 reported again at once: $out" ;; esac

  out=$(scan "$dir" "$state" "$((NOW + 18000))") || fail "round 2 scan failed"
  case "$out" in *" round=2 "*) ;; *) fail "second stale interval did not report round 2: $out" ;; esac
  FM_CR_FIXROUND_NOW="$((NOW + 18000))" PATH="$FAKEBIN:$BASE_PATH" \
    "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" round2 || fail "round 2 record failed"

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
    "$SCRIPT" --cr-record "$state" "$URL" "$HEAD" round2 || fail "seed record failed"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD2" 18000 '["chipdev"]'
  out=$(scan "$dir" "$state" "$NOW") || fail "new-head scan failed"
  case "$out" in *" head=$HEAD2 round=1 "*) ;; *) fail "a new head did not restart at round 1: $out" ;; esac
  pass "a new head restarts the round count"
}

test_record_refusals_and_malformed_record_fail_the_scan() {
  local dir state
  dir="$TMP_ROOT/refusals"
  state="$dir/state"
  mkdir -p "$state"
  write_pr_page "$dir" CHANGES_REQUESTED SUCCESS false "$HEAD" 18000 '["chipdev"]'
  PATH="$FAKEBIN:$BASE_PATH" "$SCRIPT" --cr-record "$state" \
    'https://example.com/o/r/pull/7' "$HEAD" round1 2>/dev/null \
    && fail "a non-GitHub URL was recorded"
  PATH="$FAKEBIN:$BASE_PATH" "$SCRIPT" --cr-record "$state" \
    "$URL" 'not-a-head' round1 2>/dev/null \
    && fail "a malformed head was recorded"
  PATH="$FAKEBIN:$BASE_PATH" "$SCRIPT" --cr-record "$state" \
    "$URL" "$HEAD" round3 2>/dev/null \
    && fail "an unknown round action was recorded"
  printf 'malformed\n' > "$state/changes-requested-sweep.seen"
  chmod 0600 "$state/changes-requested-sweep.seen"
  scan "$dir" "$state" "$NOW" >/dev/null 2>&1 \
    && fail "a malformed round record did not fail the scan"
  pass "record refusals are loud and a malformed record fails the scan"
}

test_stale_changes_requested_reports_round_one
test_fresh_or_ungreen_pull_requests_stay_silent
test_rounds_advance_then_escalate_and_survive_restart
test_new_head_restarts_rounds
test_record_refusals_and_malformed_record_fail_the_scan
