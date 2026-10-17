#!/usr/bin/env bash
# A/B the two cleanup-marker-lock cases of tests/fm-watch-triage.test.sh on this
# branch's tree and the pre-branch tree (116fdc52), alternating, <n> rounds.
set -u
head=$1 base=$2 n=${3:-3}
for i in $(seq 1 "$n"); do
  for side in head base; do
    d=$head; [ "$side" = base ] && d=$base
    t0=$(date +%s)
    mkdir -p "$d/scratch-$i"
    out=$(cd "$d" && TMPDIR="$d/scratch-$i" bash tests/fm-one-cleanup-lock.test.sh 2>&1)
    rc=$?
    printf 'round %s %s rc=%s %ss load1=%s :: %s\n' "$i" "$side" "$rc" "$(( $(date +%s) - t0 ))" \
      "$(sysctl -n vm.loadavg | awk '{print $2}')" "$(printf '%s' "$out" | grep -E '^(ok|not ok)' | tr '\n' '|')"
  done
done
