#!/usr/bin/env bash
# Live scenario: a Codex crew pane comes back with its session on a lab Herdr
# restore. Two crew panes in one throwaway fm-lab-* session:
#   A - relaunched onto codex by this change's bin/fm-spawn.sh
#   B - relaunched onto codex by the base commit's bin/fm-spawn.sh (control)
# Both run the stand-in codex inside a nested worktree shell (the crew shape).
# Then the lab server is stopped and re-provisioned, and Herdr's own
# resume_agents_on_restore decides what each restored pane gets typed into it.
# The machine's real restore gate (agent-config codex() wrapper ->
# herdr-restore.py gate) runs in the restored pane against a lab-only
# HERDR_RESTORE_STATE seeded by herdr-restore.py record from the lab server.
#
# usage: restore.sh <run-worktree> <base-tree> <out-dir>
set -u
WTROOT=$1 BASE=$2 OUT=$3
cd "$WTROOT" || exit 1
# shellcheck source=/dev/null
. "$WTROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$WTROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { say "SCENARIO ERROR: $*"; exit 1; }

LAB=$("$WTROOT/bin/fm-herdr-lab.sh" name crewrestore) || die "no lab name"
export HERDR_SESSION="$LAB"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-restore.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd -P)
RSTATE="$SCRATCH/herdr-restore-state"
CODEX_HOME_LAB="$SCRATCH/codex-home"
mkdir -p "$RSTATE" "$CODEX_HOME_LAB"
STANDIN_DIR=$(fm_test_tmproot fm-crew-restore-standin) || die "no stand-in dir"
STANDIN_BIN=$(fm_agent_standin "$STANDIN_DIR") || die "no stand-in binary"

LAB_UP=0
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$LAB_UP" = 1 ]; then
    "$WTROOT/bin/fm-herdr-lab.sh" teardown "$LAB" >/dev/null 2>&1 && say "lab $LAB torn down" || say "TEARDOWN FAILED for $LAB"
  fi
  for d in "$SCRATCH"/home/state/*.git-hooks; do [ -d "$d" ] && chmod u+w "$d"; done
  rm -rf "${SCRATCH:?}"
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT

# The lab server's environment reaches every pane shell it starts, restored
# ones included: keep the restore gate's state and Codex's home inside the lab.
lab_provision() {
  HERDR_RESTORE_STATE="$RSTATE" CODEX_HOME="$CODEX_HOME_LAB" "$WTROOT/bin/fm-herdr-lab.sh" provision "$LAB"
}
lab_run() { "$WTROOT/bin/fm-herdr-lab.sh" run "$LAB" "$@"; }

say "lab session: $LAB"
lab_provision || die "provision failed"
LAB_UP=1

PROJ="$SCRATCH/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' >"$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state"

FAKEBIN="$SCRATCH/fakebin"
AGENT_DIR="$SCRATCH/agent"
mkdir -p "$FAKEBIN" "$AGENT_DIR"
ln -s "$STANDIN_BIN" "$AGENT_DIR/codex"
cat >"$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
# Stand-in codex: writes the rollout Codex writes for its worktree, draws the
# in-turn footer the spawn's launch gate reads, then becomes a codex-named
# foreground process for Herdr to register.
n=\$(( \$(cat "$SCRATCH/codex-runs" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > "$SCRATCH/codex-runs"
id=\$(uuidgen | tr 'A-Z' 'a-z')
printf '%s %s %s\n' "\$id" "\$PWD" "\$*" >> "$SCRATCH/codex-launches"
day="\${CODEX_HOME:-\$HOME/.codex}/sessions/\$(date +%Y/%m/%d)"
mkdir -p "\$day"
printf '{"type":"session_meta","payload":{"id":"%s","session_id":"%s","cwd":"%s"}}\n' "\$id" "\$id" "\$PWD" \
  > "\$day/rollout-\$(date +%Y-%m-%dT%H-%M-%S)-\$id.jsonl"
printf '%s\n' '• Working (1s • esc to interrupt)'
exec "$AGENT_DIR/codex"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"

# shellcheck source=/dev/null
. "$WTROOT/bin/fm-backend.sh"
fm_backend_source herdr || die "fm_backend_source herdr failed"

make_task() { # <id> -> sets PANE_<id>
  local id=$1 wt="$SCRATCH/wt-$1" raw container seeded ids tab pane
  git -C "$PROJ" worktree add --quiet -b "$id" "$wt"
  mkdir -p "$HOME_DIR/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nRestore check.\n\n## Firstmate spec\nKeep it.\n' >"$HOME_DIR/data/$id/brief.md"
  raw=$(fm_backend_herdr_container_ensure "$wt") || die "container_ensure $id"
  container=${raw%%$'\t'*}; seeded=${raw#*$'\t'}
  ids=$(fm_backend_herdr_create_task "$container" "fm-$id" "$wt" "$seeded") || die "create_task $id"
  read -r tab pane <<<"$ids"
  {
    echo "window=$LAB:$pane"; echo "endpoint_task_id=$id"; echo "worktree=$wt"; echo "project=$PROJ"
    echo "harness=codex"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"
    echo "model=default"; echo "effort=default"; echo "backend=herdr"; echo "herdr_session=$LAB"
    echo "herdr_workspace_id=${container#*:}"; echo "herdr_tab_id=$tab"; echo "herdr_pane_id=$pane"
  } >"$HOME_DIR/state/$id.meta"
  # The crew shape: a nested interactive worktree shell under the pane's top shell.
  fm_backend_herdr_send_text_line "$LAB:$pane" "bash --noprofile --norc -i" || die "nested shell $id"
  sleep 1
  fm_backend_herdr_send_text_line "$LAB:$pane" "export PATH=$FAKEBIN_Q:\$PATH" || die "PATH $id"
  sleep 1
  printf -v "PANE_$id" '%s' "$pane"
  say "task $id: pane $pane worktree $wt"
}

spawn_codex() { # <bin-root> <id>
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$LAB" FM_SPAWN_NO_GUARD=1 CODEX_HOME="$CODEX_HOME_LAB" \
    "$1/bin/fm-spawn.sh" "$2" --relaunch --harness codex 2>&1
}

binding() { fm_backend_herdr_pane_agent_session_ref "$LAB" "$1" || true; }

make_task crewa
make_task crewb
make_task crewc

say "--- spawn crewa with THIS change's fm-spawn (codex crew, Herdr backend)"
spawn_codex "$WTROOT" crewa | sed 's/^/    spawn(crewa): /'
say "--- spawn crewc with THIS change's fm-spawn (second codex crew)"
spawn_codex "$WTROOT" crewc | sed 's/^/    spawn(crewc): /'
say "--- spawn crewb with the BASE commit's fm-spawn (control)"
spawn_codex "$BASE" crewb | sed 's/^/    spawn(crewb): /'

SID_A=$(awk -v wt="$SCRATCH/wt-crewa" '$2==wt {print $1}' "$SCRATCH/codex-launches" | tail -1)
SID_C=$(awk -v wt="$SCRATCH/wt-crewc" '$2==wt {print $1}' "$SCRATCH/codex-launches" | tail -1)
SID_B=$(awk -v wt="$SCRATCH/wt-crewb" '$2==wt {print $1}' "$SCRATCH/codex-launches" | tail -1)
say "codex session written by crewa's codex: ${SID_A:-none}"
say "codex session written by crewc's codex: ${SID_C:-none}"
say "codex session written by crewb's codex: ${SID_B:-none}"
say "codex launch args crewa: $(awk -v wt="$SCRATCH/wt-crewa" '$2==wt {$1="";$2=""; print}' "$SCRATCH/codex-launches" | tail -1 | cut -c1-200)"
say "Herdr binding before restore, crewa pane $PANE_crewa: $(binding "$PANE_crewa" | tr '\t' ' ')"
say "Herdr binding before restore, crewc pane $PANE_crewc: $(binding "$PANE_crewc" | tr '\t' ' ')"
say "Herdr binding before restore, crewb pane $PANE_crewb: $(binding "$PANE_crewb" | tr '\t' ' ')"
say "state/crewa.codex-resume:"; sed 's/^/    /' "$HOME_DIR/state/crewa.codex-resume" 2>&1 | cut -c1-200
say "state/crewb.codex-resume: $( [ -e "$HOME_DIR/state/crewb.codex-resume" ] && echo present || echo absent)"
say "pane agent state crewa: $(fm_backend_herdr_pane_agent_state "$LAB" "$PANE_crewa")  crewb: $(fm_backend_herdr_pane_agent_state "$LAB" "$PANE_crewb")"

# Seed the restore gate's lab-only record of this server, as the machine
# sampler does each minute for the default server.
cat >"$SCRATCH/herdr-lab-run" <<EOF
#!/usr/bin/env bash
exec "$WTROOT/bin/fm-herdr-lab.sh" run "$LAB" "\$@"
EOF
chmod +x "$SCRATCH/herdr-lab-run"
HERDR_RESTORE_STATE="$RSTATE" HERDR_RESTORE_HERDR="$SCRATCH/herdr-lab-run" \
  python3 "$HOME/.agent-config/scripts/herdr-restore.py" record || die "restore record failed"
say "restore gate record of the lab server (before restart):"
jq -c --arg a "$PANE_crewa" --arg c "$PANE_crewc" --arg b "$PANE_crewb" '{server, panes: {crewa: .panes[$a], crewc: .panes[$c], crewb: .panes[$b]}}' "$RSTATE/record.json" | sed 's/^/    /'

say "--- stopping the lab Herdr server (crew processes die with it)"
"$WTROOT/bin/fm-herdr-lab.sh" stop "$LAB" >/dev/null || die "stop failed"
sleep 2
say "--- restarting the lab Herdr server (restore)"
lab_provision || die "re-provision failed"
RESTARTED=$(date +%s)

# Watch the restored panes until the gate has decided and a resume ran.
i=0
while [ "$i" -lt 100 ]; do
  grep -q "start codex $SID_A" "$RSTATE/restore.log" 2>/dev/null && grep -q "start codex $SID_C" "$RSTATE/restore.log" 2>/dev/null && break
  sleep 2; i=$((i + 1))
done
sleep 5
say "restore gate log (lab HERDR_RESTORE_STATE/restore.log), $(( $(date +%s) - RESTARTED ))s after restart:"
sed 's/^/    /' "$RSTATE/restore.log" 2>/dev/null || say "    (no gate log)"
say "Herdr binding after restore, crewa pane $PANE_crewa: $(binding "$PANE_crewa" | tr '\t' ' ')"
say "Herdr binding after restore, crewc pane $PANE_crewc: $(binding "$PANE_crewc" | tr '\t' ' ')"
say "Herdr binding after restore, crewb pane $PANE_crewb: $(binding "$PANE_crewb" | tr '\t' ' ')"
for id in crewa crewc crewb; do
  pane_var="PANE_$id"
  say "restored pane $id (${!pane_var}) process-info foreground:"
  lab_run pane process-info --pane "${!pane_var}" | jq -c '[.result.process_info.foreground_processes[]? | {name, argv}]' | sed 's/^/    /'
  say "restored pane $id (${!pane_var}) screen (last 25 lines):"
  lab_run pane read "${!pane_var}" --source recent --lines 40 --format text 2>&1 | grep -v '^[[:space:]]*$' | tail -12 | cut -c1-160 | sed 's/^/    | /'
done
say "done"
