import os
from pathlib import Path
import subprocess

root = Path("/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5CN7DKM40PFMVES0WRY9R1T")
evidence = Path("/Users/dalecarman/.no-mistakes/evidence/01M5CN7DKM40PFMVES0WRY9R1T")
work = root / ".no-mistakes" / "archived-blocker-regression"
work.mkdir(parents=True, exist_ok=False)
(work / "tmp").mkdir()
env = {k:v for k,v in os.environ.items() if not k.startswith("FM_") and k not in ("TASKS_AXI_FILE", "TASKS_AXI_BACKEND", "TMUX", "TMUX_PANE", "HERDR_SESSION")}
env.update(TMPDIR=str(work / "tmp"), PYTHONDONTWRITEBYTECODE="1", PATH="/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ["PATH"])
cmd = ["/bin/bash", "bin/fm-test-run.sh", "tests/fm-fleet-snapshot-view.test.sh", "--json", str(evidence / "snapshot-regression-timing.json")]
with (evidence / "snapshot-regression.txt").open("w") as log:
    p = subprocess.run(cmd, cwd=root, env=env, text=True, stdout=log, stderr=subprocess.STDOUT, timeout=180)
print((evidence / "snapshot-regression.txt").read_text())
raise SystemExit(p.returncode)
