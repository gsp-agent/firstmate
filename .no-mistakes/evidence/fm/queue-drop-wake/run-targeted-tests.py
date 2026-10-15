import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = Path(__file__).parent
scratch = root / ".fm-queue-validation-tests"
scratch.mkdir(mode=0o700)
env = dict(os.environ, TMPDIR=str(scratch), FM_TEST_MACHINE_GATE="")
for key in ["FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE", "FM_HOME", "TASKS_AXI_FILE", "TASKS_AXI_BACKEND"]:
    env.pop(key, None)
command = ["bin/fm-test-run.sh", "tests/fm-pr-check-security.test.sh", "--per-script-timeout-secs", "1500", "--json", str(evidence / "targeted-tests.json")]
with (evidence / "targeted-tests.log").open("w") as log:
    result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=1600)
print("Targeted PR monitoring regression exit:", result.returncode)
print("Evidence:", evidence / "targeted-tests.log")
raise SystemExit(result.returncode)
