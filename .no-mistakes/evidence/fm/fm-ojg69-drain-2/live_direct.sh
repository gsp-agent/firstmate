#!/usr/bin/env bash
set -eu
root=$PWD
lab="$root/.test-phase-tmp/live-direct"
"$root/bin/fm-lab-home.sh" create "$lab"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$lab/.tasks.toml"
mkdir -p "$lab/data/direct-d1" "$lab/projects/demo"
printf 'standalone scratch\n' > "$lab/data/direct-d1/scratch.bin"
printf 'Retained review\n' > "$lab/data/direct-d1/review.md"
printf 'window=fm-lab-direct:fm-direct-d1\nendpoint_task_id=direct-d1\nworktree=%s/missing\nproject=%s/projects/demo\nkind=ship\nmode=local-only\nspawn_gen=live-direct\n' "$lab" "$lab" > "$lab/state/direct-d1.meta"
cd "$lab"
tmux -S sock new-session -d -s fm-lab-direct
trap 'cd "$lab"; tmux -S sock kill-server 2>/dev/null || true' EXIT
tmux -S sock new-window -d -t fm-lab-direct: -n fm-direct-d1
cd "$root"
export FM_HOME="$lab"
export TMUX='.test-phase-tmp/live-direct/sock,0,0'
export FM_TEARDOWN_DATA_STAGE_TIMEOUT=600
"$root/bin/fm-teardown.sh" direct-d1
bash "$root/bin/fm-task-data-lib.sh" sweep "$lab/data" "$lab/state"
python3 - "$lab" <<'PY'
import json
import sys
from pathlib import Path
home = Path(sys.argv[1])
assert not (home / 'data/backlog.md').exists()
assert not (home / 'state/direct-d1.meta').exists()
assert (home / 'state/.task-data-sweep.rerun').read_text().strip() == 'direct-d1'
assert (home / 'data/direct-d1/.cleanup-hold/scratch.bin').read_text() == 'standalone scratch\n'
assert (home / 'data/direct-d1/review.md').exists()
record = json.loads((home / 'data/direct-d1/record/data-cleanup.json').read_text())
assert record['complete'] is True and record['expired'] is False
print('PASS: direct retirement with no backlog stages scratch, publishes completion, removes metadata and preserves its newest recovery.')
PY
