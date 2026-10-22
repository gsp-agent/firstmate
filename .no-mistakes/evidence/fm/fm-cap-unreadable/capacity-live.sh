#!/usr/bin/env bash
set -u
ROOT=$PWD
LAB="$ROOT/.nm-capacity-live"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR TASKS_AXI_FILE TASKS_AXI_BACKEND FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE FM_PROJECT_CAPACITY_CREW_STATE
[ -f "$LAB/.fm-lab-home" ] || bash bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB"
export FM_SPAWN_NO_GUARD=1
export FM_BACKEND=tmux
export FM_PROJECT_CAPACITY_CREW_TIMEOUT=10
PROJECT="$LAB/projects/capacity-project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
printf 'capacity-project 1\n' > "$LAB/config/project-capacity"
printf 'codex\n' > "$LAB/config/crew-harness"
python3 - "$LAB" "$PROJECT" <<'SETUP'
import sys
from pathlib import Path
lab, project = map(Path, sys.argv[1:])
(lab/'state/slow.meta').write_text(f'kind=scout\nproject={project}\nworktree={project}\nharness=codex\n')
(lab/'state/slow.status').write_text('note: disposable slow-state workload\n'*100000)
(lab/'state/unknown.meta').write_text(f'kind=scout\nproject={project}\nworktree={lab}/gone\nharness=codex\n')
SETUP
. bin/fm-backend.sh
. bin/fm-secondmate-registry-lib.sh
. bin/fm-wake-lib.sh
. bin/fm-project-capacity-lib.sh
lock=$(fm_treehouse_project_lock_path "$PROJECT")
echo '== Actual reader: slow persisted status exceeds the ten-second read bound =='
. bin/fm-timeout-lib.sh
start=$SECONDS
fm_run_timed 10 env FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 bash bin/fm-crew-state.sh slow
rc=$?
printf 'reader exit=%s elapsed=%ss\n' "$rc" "$((SECONDS-start))"
[ "$rc" = 124 ] || exit 10
echo '== Actual reader: a readable unknown answer =='
bash bin/fm-crew-state.sh unknown
echo '== Occupancy count with a real timed-out reader and a readable unknown =='
fm_project_capacity_occupants "$lock" "$PROJECT" "$LAB/state" candidate
rc=$?
printf 'count exit=%s occupants=%s holders=%s error=%s\n' "$rc" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" "$FM_PROJECT_CAPACITY_ERROR"
[ "$rc" = 0 ] && [ "$FM_PROJECT_CAPACITY_OCCUPANTS" = 1 ] && [ "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" = 'slow (state unreadable)' ] || exit 11
echo '== Real spawn at capacity: defer, do not refuse unreadable count =='
bash bin/fm-spawn.sh candidate "$PROJECT" --scout --backend tmux > "$LAB/deferred.txt" 2>&1
rc=$?
cat "$LAB/deferred.txt"
printf 'spawn exit=%s candidate metadata=%s\n' "$rc" "$([ -e "$LAB/state/candidate.meta" ] && echo present || echo absent)"
[ "$rc" = 75 ] && [ ! -e "$LAB/state/candidate.meta" ] || exit 12
echo '== Real spawn below capacity: crosses admission, reaches missing-brief guard =='
printf 'capacity-project 2\n' > "$LAB/config/project-capacity"
bash bin/fm-spawn.sh candidate "$PROJECT" --scout --backend tmux > "$LAB/admitted.txt" 2>&1
rc=$?
cat "$LAB/admitted.txt"
printf 'spawn exit=%s\n' "$rc"
[ "$rc" = 1 ] && grep -F 'has no brief at inaccessible data path' "$LAB/admitted.txt" || exit 13
echo '== Missing crew-state dependency: all resident records hold slots =='
export FM_PROJECT_CAPACITY_CREW_STATE="$LAB/missing-reader"
fm_project_capacity_occupants "$lock" "$PROJECT" "$LAB/state" candidate
rc=$?
printf 'count exit=%s occupants=%s holders=%s error=%s\n' "$rc" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" "$FM_PROJECT_CAPACITY_ERROR"
[ "$rc" = 0 ] && [ "$FM_PROJECT_CAPACITY_OCCUPANTS" = 2 ] || exit 14
bash bin/fm-spawn.sh candidate "$PROJECT" --scout --backend tmux > "$LAB/missing.txt" 2>&1
rc=$?
cat "$LAB/missing.txt"
printf 'spawn exit=%s\n' "$rc"
[ "$rc" = 75 ] || exit 15
echo '== Recover real reader: unknown holds no slot =='
unset FM_PROJECT_CAPACITY_CREW_STATE
printf 'note: short readable record\n' > "$LAB/state/slow.status"
fm_project_capacity_occupants "$lock" "$PROJECT" "$LAB/state" candidate
rc=$?
printf 'count exit=%s occupants=%s holders=%s error=%s\n' "$rc" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" "$FM_PROJECT_CAPACITY_ERROR"
[ "$rc" = 0 ] && [ "$FM_PROJECT_CAPACITY_OCCUPANTS" = 0 ] || exit 16
echo 'Live capacity checks complete.'
