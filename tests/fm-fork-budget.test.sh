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
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cleanup() { fm_test_cleanup; }
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
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

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

request() {  # <home> <now> <epoch> [interval]
  PATH="$FAKEBIN:$PATH" FM_HOME_SUMMARY_INTERVAL="${4:-2}" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_SNAPSHOT_NOW="$2" FM_SNAPSHOT_NOW_EPOCH="$3" \
    "$WRITER" --request
}

generated_of() { jq -r '.generated // ""' "$1/state/home-summary.json" 2>/dev/null || true; }

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
pass "main-home requests fork no producer and leave no mark"

# Budget 2: a burst of secondmate requests coalesces into one publication.
i=0
while [ "$i" -lt 5 ]; do
  request "$MATE_HOME" 2026-08-28T10:00:00Z 1787911200 &
  i=$((i + 1))
done
wait
wait_generated "$MATE_HOME" 2026-08-28T10:00:00Z \
  || fail "secondmate request burst never published"
sleep 1
[ "$(generated_of "$MATE_HOME")" = "2026-08-28T10:00:00Z" ] \
  || fail "request burst published more than once"
[ ! -e "$MATE_HOME/state/.home-summary-dirty" ] \
  || fail "dirty mark left after the coalesced publication"
pass "secondmate request burst coalesces to one publication"

# Budget 3: a request inside the interval is deferred, not a second walk;
# the pending mark publishes once the interval has passed.
request "$MATE_HOME" 2026-08-28T10:01:00Z 1787911260 30 \
  || fail "in-interval request must exit 0"
sleep 2
[ "$(generated_of "$MATE_HOME")" = "2026-08-28T10:00:00Z" ] \
  || fail "in-interval request republished inside FM_HOME_SUMMARY_INTERVAL"
# Age the ledger past the interval; the next request publishes at once.
python3 -c 'import os,sys,time; p=sys.argv[1]; old=time.time()-60; os.utime(p,(old,old))' \
  "$MATE_HOME/state/home-summary.json"
request "$MATE_HOME" 2026-08-28T10:01:00Z 1787911260 30 \
  || fail "post-interval request must exit 0"
wait_generated "$MATE_HOME" 2026-08-28T10:01:00Z 100 \
  || fail "deferred request never published after the interval"
pass "in-interval request defers to one publication per interval"

echo "fm-fork-budget: all assertions passed"
