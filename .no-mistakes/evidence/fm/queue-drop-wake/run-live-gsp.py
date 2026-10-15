import json
import os
from pathlib import Path
import re
import subprocess

root = Path.cwd()
out = Path(__file__).parent
lab = root / ".fm-queue-live"
auth = subprocess.run(["gh", "auth", "token", "--user", "gsp-agent"], capture_output=True, text=True, check=True)
env = dict(os.environ, GH_TOKEN=auth.stdout.strip())
for key in list(env):
    if key.startswith("FM_") or key.startswith("HERDR_") or key in ("TMUX", "TMUX_PANE", "TASKS_AXI_FILE", "TASKS_AXI_BACKEND"):
        env.pop(key)
env.update(FM_HOME=str(lab), FM_BACKEND="tmux", FM_CHECK_INTERVAL="0", FM_POLL="0.1", FM_HEARTBEAT="999999", FM_SIGNAL_GRACE="0")
commands = []

def run(label, args, extra=None, timeout=120):
    command_env = dict(env, **(extra or {}))
    result = subprocess.run(args, cwd=root, env=command_env, text=True, capture_output=True, timeout=timeout)
    (out / (label + ".stdout.txt")).write_text(result.stdout)
    (out / (label + ".stderr.txt")).write_text(result.stderr)
    commands.append({"label": label, "command": args, "exit": result.returncode})
    (out / "live-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    if result.returncode:
        raise RuntimeError(label + " exit " + str(result.returncode) + ": " + result.stderr)
    return result

def ack(label):
    result = run(label + "-drain", ["bin/fm-wake-drain.sh"])
    match = re.search(r"--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)", result.stderr)
    assert match, "Missing acknowledgement command: " + result.stderr
    run(label + "-ack", ["bin/fm-wake-drain.sh", "--ack-through", match[1], "--recovery-generation", match[2]])

run("live-create", ["bin/fm-lab-home.sh", "create", str(lab)])
state = lab / "state"
meta = state / "live3941.meta"
meta.write_text("kind=ship\nmode=no-mistakes\nworktree=" + str(root) + "\n")
meta.chmod(0o600)
run("live-arm", ["bin/fm-pr-check.sh", "live3941", "https://github.com/groovejones/groove-sight-platform/pull/3941"])
sentinel = state / "zz-lab-complete.check.sh"
sentinel.write_text('#!/usr/bin/env bash\nprintf "isolated live sweep complete\\n"\n')
sentinel.chmod(0o700)
run("live-register-sentinel", ["bin/fm-check-register.sh", "zz-lab-complete"])
poll_args = ["bin/fm-pr-poll.sh", "--validated", "github", "https://github.com/groovejones/groove-sight-platform/pull/3941", "github.com", "groovejones/groove-sight-platform", "3941"]
poll = run("live-host-bound-poll", poll_args, {"GH_HOST": "unrelated-enterprise.invalid", "FM_PR_POLL_ID": "live3941", "FM_PR_POLL_STATE": str(state)})
assert "dequeued https://github.com/groovejones/groove-sight-platform/pull/3941 reason=merge_conflict event=" in poll.stdout
assert not (state / "live3941.pr-poll-queue-dropped").exists(), "Poll consumed event before publication"
scan = run("live-open-scan", ["bin/fm-pr-queue-sweep.sh", "--scan", str(state)])
expected = {3941: "merge_conflict", 3950: "merge_conflict", 4006: "merge_conflict", 4017: "failed_checks", 4111: "merge_conflict", 4172: "manual", 4183: "merge_conflict", 4200: "merge_conflict"}
for number, reason in expected.items():
    assert f"dequeued https://github.com/groovejones/groove-sight-platform/pull/{number} reason={reason} event=" in scan.stdout, number
assert "/pull/4308 " not in scan.stdout, "Merged PR surfaced as a drop"
assert "/pull/3939 " not in scan.stdout, "Closed PR surfaced in open sweep"
first = run("live-first-watch", ["bin/fm-watch.sh"])
for number, reason in expected.items():
    matches = [line for line in first.stdout.splitlines() if f"dequeued https://github.com/groovejones/groove-sight-platform/pull/{number} reason={reason}" in line]
    assert len(matches) == 1, (number, matches)
assert "isolated live sweep complete" in first.stdout
(out / "live-durable-wake-queue.tsv").write_bytes((state / ".wake-queue").read_bytes())
(out / "live-removal-event-ids.txt").write_bytes((state / "merge-queue-sweep.seen").read_bytes())
(out / "live-armed-drop-marker.txt").write_bytes((state / "live3941.pr-poll-queue-dropped").read_bytes())
ack("live-first")
second = run("live-repeat-watch", ["bin/fm-watch.sh"])
assert "dequeued " not in second.stdout, "Handled removal repeated"
assert "isolated live sweep complete" in second.stdout
assert (state / "live3941.check.sh").is_file(), "Unmerged PR watch was retired"
ack("live-repeat")
print("Real GitHub: armed #3941 and seven unwatched open removals emitted with exact reasons; merged #4308 and closed #3939 excluded; acknowledged events stayed silent on repeat.")
print("All product commands used the marked disposable home:", lab)
