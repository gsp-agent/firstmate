#!/usr/bin/env bash
set -u
ROOT=$PWD
LAB="$ROOT/.nm-capacity-live"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE
export FM_HOME="$LAB"
export FM_PROJECT_CAPACITY_CREW_STATE="$ROOT/bin/fm-crew-state.sh"
export FM_PROJECT_CAPACITY_CREW_TIMEOUT=10
. bin/fm-backend.sh
. bin/fm-secondmate-registry-lib.sh
. bin/fm-wake-lib.sh
. bin/fm-timeout-lib.sh
lock=$(fm_treehouse_project_lock_path "$LAB/projects/capacity-project")
python3 - "$LAB/state/slow.status" <<'DATA'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text('note: disposable slow-state workload\n'*100000)
DATA
echo '== Before P0 fix: e9fdc88a capacity library, actual crew-state reader =='
. "$LAB/capacity-before.sh"
fm_project_capacity_occupants "$lock" "$LAB/projects/capacity-project" "$LAB/state" candidate
rc=$?
printf 'count exit=%s occupants=%s holders=%s error=%s\n' "$rc" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" "$FM_PROJECT_CAPACITY_ERROR"
[ "$rc" = 1 ] || exit 20
echo '== After P0 fix: same records and actual crew-state reader =='
. bin/fm-project-capacity-lib.sh
fm_project_capacity_occupants "$lock" "$LAB/projects/capacity-project" "$LAB/state" candidate
rc=$?
printf 'count exit=%s occupants=%s holders=%s error=%s\n' "$rc" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" "$FM_PROJECT_CAPACITY_ERROR"
[ "$rc" = 0 ] && [ "$FM_PROJECT_CAPACITY_OCCUPANTS" = 1 ] || exit 21
