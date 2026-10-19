#!/usr/bin/env bash
# Drives the real bin/fm-test-run.sh: CI shard placement of the supervision-host
# lanes, the scheduled inventory, explicit script mode, and the coverage guard.
set -u
cd "$1" || exit 1
R=bin/fm-test-run.sh
echo "== --list-lanes"; lanes=$($R --list-lanes); printf '%s\n' "$lanes"
count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
echo "portable serial shards: $count"
echo "== supervision-host files per serial shard"
k=1
while [ "$k" -le "$count" ]; do
  hits=$($R --list --lane "portable-serial-${k}of${count}" | grep 'fm-supervision-host' | grep -v -e live-e2e -e attended || true)
  printf 'serial %sof%s: %s\n' "$k" "$count" "$(printf '%s' "$hits" | tr '\n' ' ')"
  k=$((k + 1))
done
echo "== occurrences across all serial shards (each lane exactly once, subject never)"
k=1; all=""
while [ "$k" -le "$count" ]; do all="$all$($R --list --lane "portable-serial-${k}of${count}")
"; k=$((k + 1)); done
for f in tests/fm-supervision-host.test.sh tests/fm-supervision-host-lane-a.test.sh tests/fm-supervision-host-lane-b.test.sh; do
  printf '%s: %s\n' "$f" "$(printf '%s' "$all" | grep -cx "$f")"
done
echo "== also absent from the parallel lanes"
for l in portable-parallel-1 portable-parallel-2; do
  printf '%s: %s\n' "$l" "$($R --list --lane "$l" | grep -c 'fm-supervision-host\(-lane-[ab]\)\?\.test\.sh$')"
done
echo "== --list --all (scheduled inventory)"
$R --list --all | grep -x -e tests/fm-supervision-host.test.sh -e tests/fm-supervision-host-lane-a.test.sh -e tests/fm-supervision-host-lane-b.test.sh
echo "--all count: $($R --list --all | grep -c .); tests/*.test.sh on disk: $(ls tests/*.test.sh | wc -l | tr -d ' ')"
echo "== explicit script mode still selects the whole subject"
$R --list tests/fm-supervision-host.test.sh
echo "== --check-coverage"
$R --check-coverage; echo "check-coverage exit=$?"
