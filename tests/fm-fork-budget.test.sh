#!/usr/bin/env bash
# Fork-budget coverage (.agent-config-ks05d / .agent-config-ixisl): a hot
# loop's poll must stay inside its fork budget. The home-summary trigger is
# the fleet's largest measured spawner (one synchronous walk is ~25,200
# processes on the live home), so its budget is: a side-band --request forks
# no producer at all in a main home, and in a secondmate home any burst of
# requests coalesces into at most one publication per FM_HOME_SUMMARY_INTERVAL.
# A change that makes a request publish synchronously, publish in a main
# home, or republish inside the interval fails here.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-budget)
MAIN_HOME="$TMP_ROOT/main-home"
MATE_HOME="$TMP_ROOT/mate-home"
DEFER_HOME="$TMP_ROOT/defer-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REAL_BASH=$(command -v bash)
SAMPLER_PID=

cleanup() {
  local home pid
  if [ -n "$SAMPLER_PID" ]; then
    kill "$SAMPLER_PID" 2>/dev/null || true
    wait "$SAMPLER_PID" 2>/dev/null || true
  fi
  for home in "$MATE_HOME" "$DEFER_HOME"; do
    if IFS= read -r pid 2>/dev/null < "$home/state/.home-summary-drain.lock/pid"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/bash" <<'SH'
#!/bin/bash
if [ "${1:-}" = "$FM_TEST_SUMMARY_PRODUCER" ]; then
  printf '%s\n' "$FM_SNAPSHOT_NOW_EPOCH" >> "$FM_HOME/state/producer-invocations"
fi
exec "$FM_TEST_SUMMARY_BASH" "$@"
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes" "$FAKEBIN/bash"

mk_home() {  # <dir> <secondmate 0|1>
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects/task" "$1/bin"
  printf '# fixture home\n' > "$1/AGENTS.md"
  [ "$2" -eq 1 ] && printf 'mate\n' > "$1/.fm-secondmate-home"
  fm_git_init_commit "$1/projects/task"
  cat > "$1/data/backlog.md" <<'EOF'
## In flight
- [ ] ledger-task - Publish the home ledger (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
  fm_write_meta "$1/state/ledger-task.meta" \
    "window=fmtest:fm-ledger-task" \
    "worktree=$1/projects/task" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=fm.ledger123456"
}
mk_home "$MAIN_HOME" 0
mk_home "$MATE_HOME" 1
mk_home "$DEFER_HOME" 1

request() {  # <home> <now> <epoch> [interval]
  PATH="$FAKEBIN:$PATH" FM_HOME_SUMMARY_INTERVAL="${4:-2}" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_SNAPSHOT_NOW="$2" FM_SNAPSHOT_NOW_EPOCH="$3" \
    FM_TEST_SUMMARY_PRODUCER="$ROOT/bin/fm-fleet-snapshot.sh" \
    FM_TEST_SUMMARY_BASH="$REAL_BASH" \
    "$WRITER" --request
}

generated_of() { jq -r '.generated // ""' "$1/state/home-summary.json" 2>/dev/null || true; }

producer_calls() {
  if [ -f "$1/state/producer-invocations" ]; then
    wc -l < "$1/state/producer-invocations"
  else
    printf '0\n'
  fi
}

wait_generated() {  # <home> <want> [tenths]
  local i=0
  while [ "$i" -lt "${3:-100}" ]; do
    [ "$(generated_of "$1")" = "$2" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# Budget 1: a main home has no ledger reader, so a request is a no-op:
# no publication, no dirty mark, however often a poll asks.
i=0
while [ "$i" -lt 5 ]; do
  request "$MAIN_HOME" 2026-08-28T10:00:00Z 1787911200 \
    || fail "main-home request $i must exit 0"
  i=$((i + 1))
done
[ ! -e "$MAIN_HOME/state/home-summary.json" ] \
  || fail "main-home request published a ledger nobody reads"
[ ! -e "$MAIN_HOME/state/.home-summary-dirty" ] \
  || fail "main-home request left a dirty mark"
[ "$(producer_calls "$MAIN_HOME")" -eq 0 ] || fail "main-home request ran the producer"
pass "main-home requests fork no producer and leave no mark"

# Budget 2: a burst of secondmate requests coalesces into one publication.
SAMPLES="$TMP_ROOT/burst-generations.json"
SAMPLE_STOP="$TMP_ROOT/burst-sample-stop"
python3 - "$MATE_HOME/state/home-summary.json" "$SAMPLES" "$SAMPLE_STOP" <<'PY' &
import json
from pathlib import Path
import sys
import time

ledger, output, stop = map(Path, sys.argv[1:])
generations = set()
deadline = time.monotonic() + 30
while True:
    try:
        document = json.loads(ledger.read_text())
    except FileNotFoundError:
        pass
    else:
        generations.add((document["generated"], document["generated_epoch"]))
    if stop.exists():
        break
    if time.monotonic() >= deadline:
        raise SystemExit("burst sampling did not finish within 30 seconds")
    time.sleep(0.01)
output.write_text(json.dumps([
    {"generated": generated, "generated_epoch": epoch}
    for generated, epoch in sorted(generations)
]))
PY
SAMPLER_PID=$!
BURST_PIDS=()
i=0
while [ "$i" -lt 5 ]; do
  burst_now=$(printf '2026-08-28T10:00:%02dZ' "$i")
  request "$MATE_HOME" "$burst_now" "$((1787911200 + i))" 30 &
  BURST_PIDS+=("$!")
  i=$((i + 1))
done
for pid in "${BURST_PIDS[@]}"; do wait "$pid" || fail "burst request failed"; done
i=0
while [ ! -s "$MATE_HOME/state/home-summary.json" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -s "$MATE_HOME/state/home-summary.json" ] || fail "secondmate request burst never published"
sleep 1
: > "$SAMPLE_STOP"
wait "$SAMPLER_PID" || fail "burst ledger sampling failed"
SAMPLER_PID=
jq -e 'length == 1' "$SAMPLES" >/dev/null || fail "burst exposed multiple ledger generations"
[ "$(producer_calls "$MATE_HOME")" -eq 1 ] || fail "request burst ran more than one producer"
pass "secondmate request burst coalesces to one publication"

# Budget 3: a request inside the interval is deferred, not a second walk;
# the pending mark publishes once the interval has passed.
request "$DEFER_HOME" 2026-08-28T10:00:00Z 1787911200 30 \
  || fail "initial deferral fixture request failed"
wait_generated "$DEFER_HOME" 2026-08-28T10:00:00Z \
  || fail "initial deferral fixture never published"
i=0
while [ -e "$DEFER_HOME/state/.home-summary-drain.lock" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ ! -e "$DEFER_HOME/state/.home-summary-drain.lock" ] || fail "initial deferral drain did not finish"
request "$DEFER_HOME" 2026-08-28T10:01:00Z 1787911260 30 \
  || fail "in-interval request must exit 0"
sleep 2
[ "$(generated_of "$DEFER_HOME")" = "2026-08-28T10:00:00Z" ] \
  || fail "in-interval request republished inside FM_HOME_SUMMARY_INTERVAL"
[ "$(producer_calls "$DEFER_HOME")" -eq 1 ] || fail "in-interval request ran another producer"
# Age the ledger past the interval; the next request publishes at once.
python3 - "$DEFER_HOME/state" <<'PY'
import os
from pathlib import Path
import sys
import time

state = Path(sys.argv[1])
old = time.time() - 60
os.utime(state / "home-summary.json", (old, old))
(state / ".home-summary-attempt").write_text(f"{int(old)}\n")
PY
request "$DEFER_HOME" 2026-08-28T10:01:00Z 1787911260 30 \
  || fail "post-interval request must exit 0"
wait_generated "$DEFER_HOME" 2026-08-28T10:01:00Z 100 \
  || fail "deferred request never published after the interval"
[ "$(producer_calls "$DEFER_HOME")" -eq 2 ] || fail "deferred request exceeded its producer budget"
pass "in-interval request defers to one publication per interval"

echo "fm-fork-budget: all assertions passed"
