#!/usr/bin/env bash
# compare.sh <eq-dir> - canonical (sorted-key) comparison of the producer
# outputs; the code root path is normalized. Sorted keys are needed because the
# unchanged backlog decoder (perl JSON::PP, bin/fm-hold-reason-lib.sh) emits
# hash-randomized key order on every run, for old and new code alike.
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK/lab-paths.env
W=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5518WCKZCZZKKA1AW7FWEMK
O=$1
canon() {
  jq -S --arg a "$SCR/before" --arg b "$W" '
    walk(if type == "string" then (gsub($a; "<ROOT>") | gsub($b; "<ROOT>")) else . end)
    | if (.roots? | type) == "object" then .roots.fm_root = "<ROOT>" else . end' "$1"
}
for m in secondmate-home-summary contribution-input json; do
  for pair in before-1:after-1 before-1:after-2 after-1:after-2 before-1:before-2 before-2:after-2; do
    a=${pair%%:*} b=${pair##*:}
    if cmp -s <(canon "$O/${a%-*}-$m-${a##*-}.json") <(canon "$O/${b%-*}-$m-${b##*-}.json"); then r=SAME; else r=DIFF; fi
    printf '%-24s %-9s vs %-9s %s\n' "$m" "$a" "$b" "$r"
  done
done
for f in before-json-1 after-json-1 before-json-2 after-json-2; do
  printf '%s: tasks=%s empty-current-state=[%s]\n' "$f" "$(jq '.tasks | length' "$O/$f.json")" \
    "$(jq -r '[.tasks[] | select(.current_state.source == "none" and .current_state.detail == "") | .id] | join(" ")' "$O/$f.json")"
done
