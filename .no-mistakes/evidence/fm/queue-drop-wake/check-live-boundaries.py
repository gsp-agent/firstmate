import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
out = Path(__file__).parent
lab = root / ".fm-queue-live"
auth = subprocess.run(["gh", "auth", "token", "--user", "gsp-agent"], capture_output=True, text=True, check=True)
env = dict(os.environ, GH_TOKEN=auth.stdout.strip())
for key in list(env):
    if key.startswith("FM_") or key.startswith("HERDR_") or key in ("TMUX", "TMUX_PANE", "TASKS_AXI_FILE", "TASKS_AXI_BACKEND"):
        env.pop(key)
env.update(FM_HOME=str(lab), FM_PR_POLL_STATE=str(lab / "state"), FM_PR_POLL_ID="boundary")
source = subprocess.run(["git", "show", "20dcbf91520b1816663b81873ad67d0b93b3e4d6:bin/fm-pr-poll.sh"], check=True, capture_output=True)
baseline = out / "baseline-fm-pr-poll.sh"
baseline.write_bytes(source.stdout)
tail = ["--validated", "github", "https://github.com/groovejones/groove-sight-platform/pull/3941", "github.com", "groovejones/groove-sight-platform", "3941"]
checks = [
    ("baseline-live-poll", ["bash", str(baseline)] + tail, env, ""),
    ("target-live-poll", ["bin/fm-pr-poll.sh"] + tail, env, "dequeued https://github.com/groovejones/groove-sight-platform/pull/3941 reason=merge_conflict event="),
    ("live-unreadable-api", ["bin/fm-pr-poll.sh"] + tail, dict(env, GH_TOKEN="invalid-disposable-test-token"), ""),
    ("live-merged-poll", ["bin/fm-pr-poll.sh", "--validated", "github", "https://github.com/groovejones/groove-sight-platform/pull/4308", "github.com", "groovejones/groove-sight-platform", "4308"], env, "merged\n"),
]
report = []
for label, command, command_env, expected in checks:
    result = subprocess.run(command, env=command_env, cwd=root, text=True, capture_output=True, timeout=60)
    (out / (label + ".stdout.txt")).write_text(result.stdout)
    (out / (label + ".stderr.txt")).write_text(result.stderr)
    assert result.returncode == 0, (label, result.returncode, result.stderr)
    assert result.stdout == expected if not expected.startswith("dequeued ") else result.stdout.startswith(expected), (label, result.stdout)
    report.append({"label": label, "command": command, "exit": result.returncode, "stdout": result.stdout})
(out / "live-boundary-checks.json").write_text(json.dumps(report, indent=2) + "\n")
print("Same live PR: baseline emitted zero notifications; target emitted one removal with GitHub's reason. A denied API read stayed silent; merged #4308 emitted only merged.")
