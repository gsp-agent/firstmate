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
  "axi logs "*) printf '%s\n' "${FAKE_CI_LOG:-}" ;;
  "runs "*) printf '%s\n' "${FAKE_RUNS_LIST:-}" ;;
  "daemon status ") printf 'daemon running\n' ;;
esac
exit 0
SH
# A herdr whose pane is gone: the read fails and the pane lookup answers
# pane_not_found, which fm_backend_agent_state owns as missing.
cat > "$FAKEBIN/herdr" <<'SH'
#!/bin/sh
printf 'x %s herdr\n' "$$" >> "$FM_FORK_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  "pane read") exit 1 ;;
  "pane get") printf '{"error":{"code":"pane_not_found","message":"no such pane"}}\n'; exit 1 ;;
esac
exit 0
SH
# shellcheck disable=SC2016 # The stand-in, not this script, expands $$ and $@.
printf '#!/bin/sh\nprintf "x %%s git\\n" "$$" >> "$FM_FORK_LOG"\nexec %s "$@"\n' "$REAL_GIT" > "$FAKEBIN/git"
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes" "$FAKEBIN/herdr" "$FAKEBIN/git"

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
printf 'crew-state startup (no metadata): %s processes (budget 3)\n' "$STARTUP"
# Base c78421c3: 22, of which 21 were library loads resolving their own
# directory through cd/pwd subshells, two glyph lists and a uname per load.
# Now only the script itself runs, plus one uname read where Bash is not built
# for Darwin (a substitution and its child).
[ "$STARTUP" -le 3 ] || fail "startup: fm-crew-state.sh started $STARTUP processes before its first read; budget is 3"
pass "loading fm-crew-state.sh and its libraries starts no directory, glyph or repeat uname process"

budget() {  # <label> <task-id> <expected-line> <budget>
  local extra
  count_call "$1" "$2"
  assert_equals "$3" "$CALL_LINE" "$1: verdict unchanged"
  extra=$((CALL_PROCS - STARTUP))
  printf 'crew-state %s: %s processes, %s beyond startup (budget %s)\n' "$1" "$CALL_PROCS" "$extra" "$4"
  [ "$extra" -le "$4" ] || fail "$1: fm-crew-state.sh started $extra processes beyond startup; budget is $4"
}

# Base 11c85a6c: 16 beyond startup, the four metadata reads at four processes
# each.
budget torn-down gone "state: unknown · source: none · worktree gone (torn down?)" 0
pass "a torn-down crew's metadata reads start no process"

# Base 11c85a6c: 37 beyond startup; changed 15 (status-log fold, branch, pane probe).
budget secondmate mate "state: working · source: status-log · watching" 20
pass "a secondmate's status-log read starts no metadata, mapping or note process"

# Base 11c85a6c: 141 beyond startup; changed 122 (three bounded run reads and their fields).
# Base c750dec0: 122; changed 53 (field, trim and line reads in-shell, one subshell
# and no mechanism probe or cat per bounded call).
budget attributed-run crew-run "state: working · source: run-step · validating (running) · run: 01RUN" 60
pass "an attributed run read starts no metadata or backend-field process"

# The shapes the live fleet reads most (.agent-config-8c70c: 53 live crews on
# 10-30 cost 138-217 processes a call, and a crew whose herdr pane was gone
# cost ~7,800). Each owns one worktree branch; the fake no-mistakes serves the
# run named by the FAKE_* environment set before its count.
crew_case_wt() {  # <dir> <branch>: a worktree on <branch>, its head in CASE_HEAD
  fm_git_init_commit "$1"
  git -C "$1" checkout -q -b "$2" || fail "could not branch $1"
  CASE_HEAD=$(git -C "$1" rev-parse HEAD)
}
case_overview() {  # <branch> <status> <head>
  printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  01CASE,%s,%s,%s,""\n' "$1" "$2" "$3"
}

# A terminal failed run that ended at the ci monitor: every step row is read
# for the held-green shape and the ci log is read for its marker.
crew_case_wt "$CREW_HOME/wt-held" fm/crew-held
fm_write_meta "$CREW_HOME/state/crew-held.meta" "window=fm:fm-crew-held" "worktree=$CREW_HOME/wt-held" \
  "harness=claude" "kind=ship" "backend=tmux" "project=fixture" "mode=no-mistakes"
printf 'working: step one\n' > "$CREW_HOME/state/crew-held.status"
FAKE_AXI_HOME=$(case_overview fm/crew-held failed "$CASE_HEAD")
FAKE_AXI_STATUS=$(cat <<EOF
run:
  id: "01CASE"
  branch: fm/crew-held
  status: failed
  head: "$CASE_HEAD"
  pr: "https://github.com/o/r/pull/203"
  findings: none
outcome: failed
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,0
  rebase,completed,0,0
  review,completed,0,0
  test,completed,0,0
  document,completed,0,0
  lint,completed,0,0
  push,completed,0,0
  pr,completed,0,0
  ci,failed,0,76127890
EOF
)
FAKE_CI_LOG='all CI checks passed - still monitoring until merged or closed'
export FAKE_AXI_HOME FAKE_AXI_STATUS FAKE_CI_LOG
# Base c750dec0: 200 beyond startup (five subshells per step row); changed 72.
budget held-green-ci crew-held "state: failed · source: run-step · run failed · run: 01CASE" 80
pass "a failed run's step rows and ci marker are read without a process per row"

# A run parked at its review gate with a findings table: the gate, its count
# and the action column are read positionally.
crew_case_wt "$CREW_HOME/wt-park" fm/crew-park
fm_write_meta "$CREW_HOME/state/crew-park.meta" "window=fm:fm-crew-park" "worktree=$CREW_HOME/wt-park" \
  "harness=claude" "kind=ship" "backend=tmux" "project=fixture" "mode=no-mistakes"
printf 'working: step one\n' > "$CREW_HOME/state/crew-park.status"
FAKE_AXI_HOME=$(case_overview fm/crew-park running "$CASE_HEAD")
FAKE_AXI_STATUS=$(cat <<EOF
run:
  id: "01CASE"
  branch: fm/crew-park
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$CASE_HEAD"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
)
export FAKE_AXI_HOME FAKE_AXI_STATUS
# Base c750dec0: 157 beyond startup; changed 55.
budget parked-gate crew-park "state: parked · source: run-step · parked at review: 2 finding(s) · ask-user: authority decision · run: 01CASE" 60
pass "a parked gate's name, count and owed answer are read without field processes"

# The run the CLI reports belongs to another crew, so the runs ledger is walked
# for this branch: 40 rows of other branches, as on a busy shared repo.
crew_case_wt "$CREW_HOME/wt-ledger" fm/crew-ledger
fm_write_meta "$CREW_HOME/state/crew-ledger.meta" "window=fm:fm-crew-ledger" "worktree=$CREW_HOME/wt-ledger" \
  "harness=claude" "kind=ship" "backend=tmux" "project=fixture" "mode=no-mistakes"
printf 'working: step one\n' > "$CREW_HOME/state/crew-ledger.status"
FAKE_AXI_HOME=$(case_overview fm/other running "$CASE_HEAD")
FAKE_AXI_STATUS=$(printf 'run:\n  id: "01CASE"\n  branch: fm/other\n  status: running\n  head: "%s"\n' "$CASE_HEAD")
FAKE_RUNS_LIST=$(i=0; while [ "$i" -lt 40 ]; do
  printf '  completed  fm/other-%s %s  2026-10-30 17:00\n' "$i" "$CASE_HEAD"; i=$((i + 1)); done)
export FAKE_AXI_HOME FAKE_AXI_STATUS FAKE_RUNS_LIST
# Base c750dec0: 112 beyond startup (a subshell per ledger row); changed 51.
budget runs-ledger crew-ledger "state: unknown · source: pane · harness state unavailable (unknown missing)" 56
pass "walking the runs ledger starts no process per row"
FAKE_RUNS_LIST=

# A herdr crew whose pane is gone: the retained terminal outcomes are searched
# for this incarnation's intentional close. 40 records of other tasks must cost
# nothing per record.
fm_write_meta "$CREW_HOME/state/crew-gone.meta" "window=default:w1:p2" "worktree=$CREW_HOME/wt-ledger" \
  "harness=claude" "kind=ship" "backend=herdr" "spawn_gen=s1.1.1"
printf 'working: step one\n' > "$CREW_HOME/state/crew-gone.status"
mkdir -p "$CREW_HOME/state/terminal-outcomes"
FAKE_AXI_HOME='' FAKE_AXI_STATUS=''
export FAKE_AXI_HOME FAKE_AXI_STATUS
count_call gone-none crew-gone
GONE_NONE=$CALL_PROCS
i=0
while [ "$i" -lt 40 ]; do
  printf 'schema=fm-terminal-outcome.v1\nfingerprint=f%s\ntask_id=other-%s\nincarnation=s1.1.1\nstate=done\npane_close_target=default:w1:p2\n' \
    "$i" "$i" > "$CREW_HOME/state/terminal-outcomes/f$i.presented"
  i=$((i + 1))
done
# Base c750dec0: 528 beyond startup, twelve per record; changed 40, none per record.
budget herdr-gone crew-gone "state: unknown · source: none · backend target gone: default:w1:p2" 45
[ "$CALL_PROCS" -eq "$GONE_NONE" ] \
  || fail "herdr-gone: 40 other tasks' terminal outcomes cost $((CALL_PROCS - GONE_NONE)) processes; each record must cost none"
pass "a gone herdr pane's retained-outcome search starts no process per record"

# The fork-free directory reads must resolve exactly what the cd/pwd subshells
# did, for a normal absolute path (the fast path) and for every shape that still
# takes the subshell: relative, dot and dot-dot components, a doubled slash,
# and a symlinked directory, whose logical path both keep.
ln -s "$ROOT/bin" "$TMP_ROOT/linked-bin" || fail "load: could not link the bin directory"
cat > "$TMP_ROOT/load-probe.sh" <<'SH'
# load-probe.sh <library-path>: source one library by exactly that path and
# print "<name> same" or "<name> differ" for each value it resolves at load.
src=$1
unset FM_ROOT FM_ROOT_OVERRIDE FM_HOME _FM_UNAME _FM_CLASSIFY_UNAME_S
want_dir=$(cd "$(dirname "$src")" && pwd)
want_root=$(cd "$(dirname "$src")/.." && pwd)
. "$src" || { echo "load failed"; exit 1; }
same() {  # <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "$1 same"; else echo "$1 differ"; fi
}
case "${src##*/}" in
  fm-nm-run-lib.sh) same nm-run-dir "$_FM_NM_RUN_LIB_DIR" "$want_dir" ;;
  fm-classify-lib.sh)
    same classify-dir "$_FM_CLASSIFY_LIB_DIR" "$want_dir"
    same crew-state-bin "$FM_CREW_STATE_BIN" "$want_dir/fm-crew-state.sh"
    same kernel-name "$_FM_CLASSIFY_UNAME_S" "$(uname -s 2>/dev/null)"
    ;;
  fm-backend.sh)
    same backend-dir "$FM_BACKEND_LIB_DIR" "$want_dir"
    same backend-root "$FM_BACKEND_DEFAULT_ROOT" "$want_root"
    same fm-root "$FM_ROOT" "$want_root"
    ;;
  fm-dod-lib.sh)
    same dod-siblings "$(declare -F fm_pr_url_parse status_current_line fm_nm_field fm_brief_heading_parse 2>/dev/null | wc -l | tr -d ' ')" 4
    same dod-scratch "${_fm_dod_lib_dir-unset}" unset
    ;;
  fm-composer-lib.sh)
    same agent-glyphs "$FM_COMPOSER_AGENT_PROMPT_GLYPHS" "$(printf '%s\n' '❯' '›' '⟩' '→' '❭')"
    same shell-glyphs "$FM_COMPOSER_SHELL_PROMPT_GLYPHS" "$(printf '%s\n' '>' '$' '%' '#')"
    ;;
esac
SH
LOAD_OUT=
for lib in fm-nm-run-lib.sh fm-classify-lib.sh fm-backend.sh fm-dod-lib.sh fm-composer-lib.sh; do
  for src in "$ROOT/bin/$lib" "$ROOT/bin/../bin/$lib" "$ROOT/bin/./$lib" "$ROOT//bin/$lib" \
    "$TMP_ROOT/linked-bin/$lib" "bin/$lib" "./bin/$lib"; do
    LOAD_OUT="$LOAD_OUT$(cd "$ROOT" && "$BASH" "$TMP_ROOT/load-probe.sh" "$src" 2>&1)"$'\n'
  done
done
assert_not_contains "$LOAD_OUT" "differ" "load: a library resolved a different value than its cd/pwd subshell"
assert_not_contains "$LOAD_OUT" "load failed" "load: a library failed to load"
[ "$(printf '%s' "$LOAD_OUT" | grep -c ' same$')" -eq 77 ] || fail "load: expected 77 matching values$(printf '\n%s' "$LOAD_OUT")"
pass "library directories, root, kernel name and glyph lists resolve as the subshells did for all path shapes"
