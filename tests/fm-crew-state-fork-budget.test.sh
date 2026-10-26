#!/usr/bin/env bash
# Per-call process budget for bin/fm-crew-state.sh (.agent-config-ks05d.4).
# The watcher's crew checks, the supervision host, the reaper and the captain
# call this reader once per crew, so each process it starts per call repeats
# across the fleet on every poll. Counted with the shared fork-budget counter
# (an inherited DEBUG trap plus logging PATH shims) and reported beyond the
# script's own startup, measured on a call that has no metadata, so library
# load costs that differ between platforms cancel out. The metadata, status
# verb, state mapping and note reads must start no process.
# shellcheck source=tests/watch-fork-budget-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-fork-budget-helpers.sh"

CREW_HOME="$TMP_ROOT/crew-home"
FAKEBIN="$TMP_ROOT/crew-fakebin"
mkdir -p "$CREW_HOME/state" "$FAKEBIN"
REAL_GIT=$(command -v git) || { echo 'skip: git not found'; exit 0; }

# Logging stand-ins: an idle tmux pane, a no-mistakes that serves the run named
# by the FAKE_* environment, and git, which the reader also runs directly.
cat > "$FAKEBIN/tmux" <<'SH'
#!/bin/sh
printf 'x %s tmux\n' "$$" >> "$FM_FORK_LOG"
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/bin/sh
printf 'x %s no-mistakes\n' "$$" >> "$FM_FORK_LOG"
case "${1:-} ${2:-} ${3:-}" in
  "axi  ") printf '%s\n' "${FAKE_AXI_HOME:-}" ;;
  "axi status "*) printf '%s\n' "${FAKE_AXI_STATUS:-}" ;;
  "runs "*) printf '%s\n' "${FAKE_RUNS_LIST:-}" ;;
  "daemon status ") printf 'daemon running\n' ;;
esac
exit 0
SH
# shellcheck disable=SC2016 # The stand-in, not this script, expands $$ and $@.
printf '#!/bin/sh\nprintf "x %%s git\\n" "$$" >> "$FM_FORK_LOG"\nexec %s "$@"\n' "$REAL_GIT" > "$FAKEBIN/git"
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes" "$FAKEBIN/git"

WT="$CREW_HOME/wt"
fm_git_init_commit "$WT"
git -C "$WT" checkout -q -b fm/crew-run || fail "could not branch the crew worktree"
RUN_HEAD=$(git -C "$WT" rev-parse HEAD)
fm_write_meta "$CREW_HOME/state/gone.meta" "window=fm:fm-gone" "worktree=$TMP_ROOT/torn-down" \
  "harness=claude" "kind=ship" "backend=tmux"
fm_write_meta "$CREW_HOME/state/mate.meta" "window=fm:fm-mate" "worktree=$WT" \
  "harness=claude" "kind=secondmate" "backend=tmux"
printf 'working: watching\n' > "$CREW_HOME/state/mate.status"
fm_write_meta "$CREW_HOME/state/crew-run.meta" "window=fm:fm-crew-run" "worktree=$WT" \
  "harness=claude" "kind=ship" "backend=tmux" "project=fixture" "mode=no-mistakes"
printf 'working: step one\n' > "$CREW_HOME/state/crew-run.status"
FAKE_AXI_STATUS=$(cat <<EOF
run:
  id: "01RUN"
  branch: fm/crew-run
  status: running
  head: "$RUN_HEAD"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
)
FAKE_AXI_HOME=$(cat <<EOF
count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  01RUN,fm/crew-run,running,$RUN_HEAD,""
EOF
)
export FAKE_AXI_STATUS FAKE_AXI_HOME

# Distinct processes one call starts, into CALL_PROCS, with its verdict in
# CALL_LINE. The first call warms the fixture; the second is the one counted.
count_call() {  # <label> <task-id>
  local log="$TMP_ROOT/$1.forks" _
  for _ in warm counted; do
    : > "$log"
    CALL_LINE=$(unset TMUX FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE FM_FORK_MARK
      PATH="$FAKEBIN:$SHIMS:$REAL_PATH" FM_HOME="$CREW_HOME" FM_ROOT_OVERRIDE="$ROOT" \
        FM_STATE_OVERRIDE="$CREW_HOME/state" FM_CREW_STATE_NO_FORGE=1 \
        NM_HOME="$TMP_ROOT/no-mistakes-unused" BASH_ENV="$COUNTER" FM_FORK_LOG="$log" \
        "$BASH" "$ROOT/bin/fm-crew-state.sh" "$2" 2>/dev/null)
  done
  CALL_PROCS=$(awk '($1 == "p" || $1 == "x") && $2 != "" && !seen[$2]++ { c++ } END { print c + 0 }' "$log")
}

CALL_LINE=
CALL_PROCS=0
count_call startup no-such-task
assert_equals "state: unknown · source: none · no metadata for no-such-task" "$CALL_LINE" "startup: no-metadata verdict"
STARTUP=$CALL_PROCS
printf 'crew-state startup (no metadata): %s processes\n' "$STARTUP"

budget() {  # <label> <task-id> <expected-line> <budget>
  local extra
  count_call "$1" "$2"
  assert_equals "$3" "$CALL_LINE" "$1: verdict unchanged"
  extra=$((CALL_PROCS - STARTUP))
  printf 'crew-state %s: %s processes, %s beyond startup (budget %s)\n' "$1" "$CALL_PROCS" "$extra" "$4"
  [ "$extra" -le "$4" ] || fail "$1: fm-crew-state.sh started $extra processes beyond startup; budget is $4"
}

# Startup is 22 on both. Base 11c85a6c: 16 beyond startup, the four metadata
# reads at four processes each.
budget torn-down gone "state: unknown · source: none · worktree gone (torn down?)" 0
pass "a torn-down crew's metadata reads start no process"

# Base 11c85a6c: 37 beyond startup; changed 15 (status-log fold, branch, pane probe).
budget secondmate mate "state: working · source: status-log · watching" 20
pass "a secondmate's status-log read starts no metadata, mapping or note process"

# Base 11c85a6c: 141 beyond startup; changed 122 (three bounded run reads and their fields).
budget attributed-run crew-run "state: working · source: run-step · validating (running) · run: 01RUN" 130
pass "an attributed run read starts no metadata or backend-field process"
