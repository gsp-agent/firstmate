import json
import os
from pathlib import Path
import re
import subprocess

root = Path.cwd()
out = Path(__file__).parent
lab = root / ".fm-queue-live-order"
auth = subprocess.run(["gh", "auth", "token", "--user", "gsp-agent"], capture_output=True, text=True, check=True)
env = dict(os.environ, GH_TOKEN=auth.stdout.strip())
for key in list(env):
    if key.startswith("FM_") or key.startswith("HERDR_") or key in ("TMUX", "TMUX_PANE", "TASKS_AXI_FILE", "TASKS_AXI_BACKEND"):
        env.pop(key)
env.update(FM_HOME=str(lab), FM_BACKEND="tmux", FM_CHECK_INTERVAL="0", FM_POLL="0.1", FM_HEARTBEAT="999999", FM_SIGNAL_GRACE="0")

def run(label, args):
    result = subprocess.run(args, cwd=root, env=env, text=True, capture_output=True, timeout=120)
    (out / (label + ".stdout.txt")).write_text(result.stdout)
    (out / (label + ".stderr.txt")).write_text(result.stderr)
    assert result.returncode == 0, (label, result.returncode, result.stderr)
    return result

run("order-create", ["bin/fm-lab-home.sh", "create", str(lab)])
state = lab / "state"
for number in (3941, 4017):
    task = "live" + str(number)
    meta = state / (task + ".meta")
    meta.write_text("kind=ship\nmode=no-mistakes\nworktree=" + str(root) + "\n")
    meta.chmod(0o600)
    run("order-arm-" + str(number), ["bin/fm-pr-check.sh", task, f"https://github.com/groovejones/groove-sight-platform/pull/{number}"])
for name, message in [("aa-early", "earlier registered check result"), ("live3942", "intervening registered check result"), ("zz-late", "final registered check result")]:
    check = state / (name + ".check.sh")
    check.write_text('#!/usr/bin/env bash\n' + 'if [ -e "$FM_HOME/state/.last-check" ]; then printf "ERROR premature sweep completion\\n"; fi\n' + 'printf "' + message + '\\n"\n')
    check.chmod(0o700)
    run("order-register-" + name, ["bin/fm-check-register.sh", name])
result = run("live-sweep-order-watch", ["bin/fm-watch.sh"])
expected = ["earlier registered check result", "dequeued https://github.com/groovejones/groove-sight-platform/pull/3941 reason=merge_conflict", "intervening registered check result", "dequeued https://github.com/groovejones/groove-sight-platform/pull/4017 reason=failed_checks", "final registered check result"]
positions = [result.stdout.index(value) for value in expected]
assert positions == sorted(positions), result.stdout
assert "ERROR premature sweep completion" not in result.stdout, result.stdout
assert (state / ".last-check").is_file(), "No sweep completion timestamp"
drain = run("live-sweep-order-drain", ["bin/fm-wake-drain.sh"])
for expected_drop in (expected[1], expected[3]):
    assert expected_drop in drain.stdout, "Armed PR notification missing from delivered main queue"
match = re.search(r"--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)", drain.stderr)
assert match, drain.stderr
run("live-sweep-order-ack", ["bin/fm-wake-drain.sh", "--ack-through", match[1], "--recovery-generation", match[2]])
print("Live GitHub sweep: earlier, middle, and final registered checks all ran; both real PR removals reached the main wake drain; completion timestamp appeared only after all checks.")
