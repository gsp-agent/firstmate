#!/usr/bin/env bash
# Done check 4 on the real suite: run it through the real runner from the run worktree,
# with a private TMPDIR so test-spawned processes can be told from the fleet's, then
# count test-spawned fm-watch.sh, fm-home-summary and fm-fleet-snapshot at +0, +10, +60 s.
# pids and safe columns only.
# usage: whole-suite.sh <worktree> <private-tmpdir> [runner selection...]
set -u
worktree=$1
private=$2
shift 2
mkdir -p "$private"
cd "$worktree" || exit 2
t0=$(date +%s)
TMPDIR="$private" bin/fm-test-run.sh "$@" </dev/null > "$private.runner.log" 2>&1
printf 'runner exit: %s after %ss\n' "$?" "$(($(date +%s) - t0))"
grep -cE '^ok ' "$private.runner.log" | sed 's/^/ok lines: /'
grep -E '^not ok' "$private.runner.log" | cut -c1-200
tail -5 "$private.runner.log" | cut -c1-200
survivors() {
  # Match the run id and the private dir's name, not their full text: the suite resolves
  # its paths physically, so a literal $private may never appear on a command line.
  pgrep -f "(${worktree##*/}|${private##*/})[^ ]*/fm-(watch|home-summary|fleet-snapshot)" | while read -r p; do
    [ "$p" = "$$" ] && continue
    printf '%s\n' "$p"
  done
}
prev=0
for d in 0 10 60; do
  sleep $((d - prev))
  prev=$d
  list=$(survivors)
  if [ -z "$list" ]; then
    printf '+%ss test-spawned fm-watch/fm-home-summary/fm-fleet-snapshot: none\n' "$d"
  else
    printf '+%ss test-spawned survivors:\n' "$d"
    for p in $list; do ps -o pid=,ppid=,pgid=,stat=,etime=,comm= -p "$p"; done
  fi
done
