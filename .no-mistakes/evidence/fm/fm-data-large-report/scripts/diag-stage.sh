#!/usr/bin/env bash
# Time prepare and stage of a near-16 MiB report with 200 unmatched files, by phase.
set -u
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M561HYK2NJK7SVS9P7S2W9X9
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-diag.XXXXXX"); D=$(cd -P "$D" && pwd -P); echo "$D" >> "$(dirname "$0")/labs.txt"
mkdir -p "$D/data/task-x1/clone" "$D/state" "$D/project"
python3 - "$D/data/task-x1" <<'PY'
import os, sys
task = sys.argv[1]
line = "Ordinary review notes that name none of the cloned files.\n"
with open(os.path.join(task, "report.md"), "w", encoding="utf-8") as s:
    s.write(line * ((16 * 1024 * 1024 - 4096) // len(line)))
    s.write("Reviewed by José.\n")
for n in range(200):
    open(os.path.join(task, "clone", f"scratch-{n:03}.bin"), "w").write("scratch\n")
PY
git -C "$D/project" init -q
t0=$(python3 -c 'import time;print(time.time())')
python3 "$WT/bin/fm-task-data.py" prepare "$D/data" "$D/state" task-x1 2>&1 | tail -2
t1=$(python3 -c 'import time;print(time.time())')
FM_TEARDOWN_DATA_STAGE_TIMEOUT=2 python3 "$WT/bin/fm-task-data.py" stage "$D/data" "$D/state" task-x1 "$D/project" '' 2>&1 | tail -2
t2=$(python3 -c 'import time;print(time.time())')
python3 - "$WT/bin/fm-task-data.py" "$D" <<'PY'
import importlib.util, sys, time, html
from urllib.parse import unquote
spec = importlib.util.spec_from_file_location("ftd", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from pathlib import Path
root = Path(sys.argv[2]) / "data" / "task-x1"
t = time.monotonic(); files, dirs, repos = m.inventory(root); print(f"inventory {time.monotonic()-t:.2f}s")
t = time.monotonic(); text, _ = m.local_references(root, files, repos); print(f"local_references read {time.monotonic()-t:.2f}s ({len(text)} chars)")
t = time.monotonic(); local = unquote(html.unescape(text)); print(f"unquote+unescape {time.monotonic()-t:.2f}s")
t = time.monotonic()
try:
    m.retention_paths(root, files, dirs, repos, local, (time.monotonic() + 2, 2))
except m.RetainWhole as e:
    print(f"retention_paths raised after {time.monotonic()-t:.2f}s: {e}")
else:
    print(f"retention_paths finished in {time.monotonic()-t:.2f}s")
PY
echo "prepare wall $(python3 -c "print(round($t1-$t0,2))")s; stage wall $(python3 -c "print(round($t2-$t1,2))")s"
uptime
