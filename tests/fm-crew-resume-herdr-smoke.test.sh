#!/usr/bin/env bash
# tests/fm-crew-resume-herdr-smoke.test.sh - real-herdr smoke test for the Codex
# crew session report (bin/fm-crew-resume-lib.sh, bin/fm-spawn.sh).
#
# A Codex crew is launched into a Herdr pane and then relaunched in the same
# pane. After each launch the pane must be bound to that launch's own Codex
# session, read back from Herdr's registry, and state/<id>.codex-resume must
# name it: a relaunch replaces the earlier binding, so nothing stays bound to
# the retired session. A relaunch onto another harness then leaves neither a
# Codex binding nor a Codex resume record, and that harness's own session
# report binds the pane.
#
# No real Codex runs. The stand-in `codex` writes the session rollout Codex
# writes for its worktree, draws the in-turn footer the spawn's launch gate
# reads, and then becomes a codex-named foreground process, which is what Herdr
# registers as the pane's codex agent.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh). Skips cleanly when herdr or jq is missing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by bin/fm-claude-trust.sh for the claude relaunch)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

STANDIN_DIR=$(fm_test_tmproot fm-crew-resume-herdr-standin) || {
  printf 'not ok - %s\n' "could not create the stand-in directory" >&2
  exit 1
}
STANDIN_BIN=$(fm_agent_standin "$STANDIN_DIR") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}

SESSION="fm-lab-crew-resume-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
LAB_PREPARED=0
cleanup_all() {
  local status=$? cleanup_status=0
  trap - EXIT
  if [ "$LAB_PREPARED" = 1 ]; then
    herdr_safe_stop_and_delete "$SESSION" || {
      echo "not ok - could not tear down Herdr crew resume lab session: $SESSION" >&2
      cleanup_status=1
    }
  fi
  if [ -n "$SCRATCH" ]; then
    if [ -d "$SCRATCH/home/state/hresume.git-hooks" ]; then
      chmod u+w "$SCRATCH/home/state/hresume.git-hooks" || cleanup_status=1
    fi
    rm -rf "$SCRATCH" || {
      echo "not ok - could not remove Herdr crew resume scratch tree: $SCRATCH" >&2
      cleanup_status=1
    }
  fi
  fm_test_cleanup
  [ "$cleanup_status" = 0 ] || status=1
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
LAB_PREPARED=1

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-resume-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hresume"
cat > "$HOME_DIR/data/hresume/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the Codex crew session report on a real Herdr pane.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF

PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hresume "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hresume" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hresume"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=codex"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hresume.meta"

FAKEBIN="$SCRATCH/fakebin"
AGENT_DIR="$SCRATCH/agent"
CODEX_HOME_LAB="$SCRATCH/codex-home"
mkdir -p "$FAKEBIN" "$AGENT_DIR" "$CODEX_HOME_LAB"
ln -s "$STANDIN_BIN" "$AGENT_DIR/codex"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$SCRATCH/codex-runs" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > "$SCRATCH/codex-runs"
id=fm-crew-resume-session-\$n
day="\${CODEX_HOME:-\$HOME/.codex}/sessions/\$(date +%Y/%m/%d)"
mkdir -p "\$day"
printf '{"type":"session_meta","payload":{"id":"%s","session_id":"%s","cwd":"%s"}}\n' "\$id" "\$id" "\$PWD" \
  > "\$day/rollout-\$(date +%Y-%m-%dT%H-%M-%S)-\$id.jsonl"
printf '%s\n' '• Working (1s • esc to interrupt)'
exec "$AGENT_DIR/codex"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the stand-in codex on the pane PATH"

relaunch_codex() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 CODEX_HOME="$CODEX_HOME_LAB" \
    "$ROOT/bin/fm-spawn.sh" hresume --relaunch --harness codex 2>&1
}

assert_bound_to() {  # <session-id> <label>
  local want=$1 label=$2 bound
  bound=$(fm_backend_herdr_pane_agent_session_ref "$SESSION" "$PANE_ID") || bound=
  [ "$bound" = "codex	$want" ] \
    || fail "$label: the Herdr pane is bound to '${bound:-nothing}', not codex session $want"
  [ "$(sed -n 's/^session_id=//p' "$HOME_DIR/state/hresume.codex-resume" 2>/dev/null)" = "$want" ] \
    || fail "$label: state/hresume.codex-resume does not name session $want: $(cat "$HOME_DIR/state/hresume.codex-resume" 2>&1)"
}

stop_codex() {
  local pid i=0
  pid=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[0].pid // empty')
  [ -n "$pid" ] || fail "could not read the codex stand-in pid from pane process-info"
  kill "$pid" 2>/dev/null || fail "could not stop the codex stand-in"
  while [ "$i" -lt 50 ]; do
    [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" != shell ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "the pane did not return to its shell after the codex stand-in stopped"
}

OUT=$(relaunch_codex) || fail "the first codex launch into the Herdr pane failed: $OUT"
assert_not_contains "$OUT" "did not take Codex session" "the first codex launch warned that Herdr did not take its session"
assert_bound_to fm-crew-resume-session-1 "first launch"
pass "real herdr: a codex crew launch binds the pane to its own session and records it"

stop_codex
OUT=$(relaunch_codex) || fail "the codex relaunch into the same Herdr pane failed: $OUT"
assert_not_contains "$OUT" "did not take Codex session" "the codex relaunch warned that Herdr did not take its session"
assert_bound_to fm-crew-resume-session-2 "relaunch"
pass "real herdr: a codex relaunch replaces the pane's binding to the retired session with its own"

# A relaunch's report can reach Herdr before Herdr notices the old process is
# gone, while the pane is still bound to the retired session. The report must
# replace that binding too, not be accepted and ignored.
# shellcheck source=bin/fm-crew-resume-lib.sh
. "$ROOT/bin/fm-crew-resume-lib.sh"
fm_crew_report_codex_session "$SESSION" "$PANE_ID" fm-crew-resume-session-3 \
  || fail "a report into a pane still bound to session 2 did not take session 3: $(fm_backend_herdr_pane_agent_session_ref "$SESSION" "$PANE_ID")"
pass "real herdr: a codex session report replaces a binding Herdr still holds for an earlier session"

# A relaunch onto another harness must leave no Codex binding behind for that
# harness's own session report to fight. The stand-in claude reports its session
# from inside the pane the way a Herdr hook does, naming no session start - the
# report a pane still bound to Codex would keep ignoring - and then becomes a
# claude-named agent. Its folder-trust registration goes to a throwaway
# CLAUDE_CONFIG_DIR.
CLAUDE_CONFIG_LAB="$SCRATCH/claude-config"
mkdir -p "$CLAUDE_CONFIG_LAB"
ln -s "$STANDIN_BIN" "$AGENT_DIR/claude"
printf -v HERDR_BIN_Q '%q' "$(command -v herdr)"
cat > "$FAKEBIN/claude" <<EOF
#!/usr/bin/env bash
( for _ in \$(seq 1 60); do
    $HERDR_BIN_Q pane report-agent-session "\$HERDR_PANE_ID" --source herdr:claude --agent claude \\
      --agent-session-id fm-crew-resume-claude-1 --session "$SESSION" >/dev/null 2>&1
    sleep 0.5
  done ) &
exec "$AGENT_DIR/claude"
EOF
chmod +x "$FAKEBIN/claude"
stop_codex
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_LAB" \
  "$ROOT/bin/fm-spawn.sh" hresume --relaunch --harness claude 2>&1) \
  || fail "the relaunch from codex onto claude failed: $OUT"
assert_not_contains "$OUT" "still holds Codex session" "the relaunch onto claude warned that the retired Codex binding survived"
[ ! -e "$HOME_DIR/state/hresume.codex-resume" ] || fail "the relaunch onto claude left the Codex resume record behind"
i=0
until [ "$(fm_backend_herdr_pane_agent_session_ref "$SESSION" "$PANE_ID")" = "claude"$'\t'"fm-crew-resume-claude-1" ]; do
  [ "$i" -lt 60 ] || fail "claude's own session report never bound the pane, which holds '$(fm_backend_herdr_pane_agent_session_ref "$SESSION" "$PANE_ID")'"
  sleep 0.5
  i=$((i + 1))
done
pass "real herdr: a relaunch from codex onto another harness drops the Codex binding and record, and that harness's own session report binds the pane"
