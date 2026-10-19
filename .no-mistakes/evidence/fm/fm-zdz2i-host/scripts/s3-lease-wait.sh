#!/usr/bin/env bash
# S3: the real fm-lease.sh against a disposable lab home while a teardown-shaped
# holder (fm_lease_guard, the call bin/fm-teardown.sh makes) keeps the
# lease-command lock: --wait gives up with 75 and changes nothing, the
# unbounded form still waits, and both complete once the teardown ends.
# Usage: s3-lease-wait.sh <worktree>
set -u
WT=$(cd "$1" && pwd -P)
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
touch "$LAB/config/supervision-host"
lease() { FM_HOME="$LAB" FM_SUPERVISION_ACTOR=branch "$WT/bin/fm-lease.sh" "$@"; }
# A live session-lock holder, so the branch lease reads live.
perl -e '$0="claude"; sleep 600' & HOLDER=$!
printf '%s\n' "$HOLDER" > "$LAB/state/.lock"
lease claim demo --actor branch; echo "claim demo as branch: rc=$?"
echo "lease before: $(lease check demo)"
# The teardown fixture: holds the lease-command lock until teardown.done.
FM_HOME="$LAB" FM_SUPERVISION_ACTOR=main bash -c '
  . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-lease-lib.sh"
  fm_lease_guard other-task "teardown (fixture)"
  printf "%s\n" "$$" > "$FM_HOME/teardown.held"
  while [ ! -e "$FM_HOME/teardown.done" ]; do sleep 0.1; done
  fm_lease_guard_release' _ "$WT" &
TD=$!
for _ in $(seq 1 50); do [ -s "$LAB/teardown.held" ] && break; sleep 0.1; done
echo "teardown fixture pid $(cat "$LAB/teardown.held") holds the lease-command lock: $(cat "$LAB/state/.fm-lease-command.lock/pid")"

echo; echo '$ fm-lease.sh --wait 3 release-actor --actor branch   (teardown running)'
s=$SECONDS; lease --wait 3 release-actor --actor branch; rc=$?
echo "rc=$rc after $((SECONDS - s))s; lease file after (unchanged): $(cat "$LAB/state/.lease-demo")"
echo; echo '$ fm-lease.sh --wait 0 claim demo --actor branch   (teardown running)'
s=$SECONDS; lease --wait 0 claim demo --actor branch; rc=$?
echo "rc=$rc after $((SECONDS - s))s"
echo; echo '$ fm-lease.sh --wait 1 check demo   (read-only command, teardown running)'
lease --wait 1 check demo; echo "rc=$?"
echo; echo '$ fm-lease.sh --wait 3x check demo   (malformed bound)'
lease --wait 3x check demo; echo "rc=$?"

echo; echo '$ fm-lease.sh release-actor --actor branch   (no --wait, teardown running)'
lease release-actor --actor branch & UNB=$!
sleep 4
if kill -0 "$UNB" 2>/dev/null; then echo "still waiting after 4s (unbounded form keeps its old contract)"; else echo "UNEXPECTED: returned while the lock was held"; fi
echo "lease file while it waits: $(cat "$LAB/state/.lease-demo")"
: > "$LAB/teardown.done"; wait "$TD"
wait "$UNB"; echo "teardown ended -> unbounded release-actor rc=$?; lease check rc: $(lease check demo >/dev/null 2>&1; echo $?) (1 = no lease)"

lease claim demo --actor branch
echo; echo '$ fm-lease.sh --wait 3 release-actor --actor branch   (lock free)'
s=$SECONDS; lease --wait 3 release-actor --actor branch; rc=$?
echo "rc=$rc after $((SECONDS - s))s; lease check rc: $(lease check demo >/dev/null 2>&1; echo $?) (1 = no lease)"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
echo "LAB=$LAB"
