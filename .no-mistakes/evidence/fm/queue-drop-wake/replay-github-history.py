"""Supplemental recorded-history replay, explicitly not a live GitHub transition."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

root = Path.cwd()
out = Path(__file__).parent
lab = root / ".fm-queue-history-replay"
history = json.loads((out / "github-events.json").read_text())["data"]["repository"]
auth = subprocess.run(["gh", "auth", "token", "--user", "gsp-agent"], capture_output=True, text=True, check=True)
env = dict(os.environ, GH_TOKEN=auth.stdout.strip())
real_gh = shutil.which("gh")
real_jq = shutil.which("jq")
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

def ack(label):
    result = run(label + "-drain", ["bin/fm-wake-drain.sh"])
    match = re.search(r"--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)", result.stderr)
    assert match, result.stderr
    run(label + "-ack", ["bin/fm-wake-drain.sh", "--ack-through", match[1], "--recovery-generation", match[2]])

run("replay-create", ["bin/fm-lab-home.sh", "create", str(lab)])
state = lab / "state"
fixture = lab / "github-replay.json"
nodes = []
for pr in history.values():
    removals = [e for e in pr["timelineItems"]["nodes"] if e["__typename"] == "RemovedFromMergeQueueEvent" and e["reason"] != "merged"]
    event = removals[-1]
    node = {"number": pr["number"], "state": "OPEN", "merged": False, "isInMergeQueue": False, "timelineItems": {"nodes": [event]}}
    nodes.append(node)
fixture_data = {"data": {"repository": {"pullRequest": next(n for n in nodes if n["number"] == 4308), "pullRequests": {"nodes": nodes, "pageInfo": {"hasNextPage": False, "endCursor": None}}}}}
fixture.write_text(json.dumps(fixture_data) + "\n")
(out / "historical-replay-input.json").write_text(json.dumps({"notice": "Recorded GitHub events fetched in this run; PR states reconstructed as OPEN/unmerged immediately after their historical drops. This is replay evidence, not a live GitHub transition.", "response": fixture_data}, indent=2) + "\n")
meta = state / "replay4308.meta"
meta.write_text("kind=ship\nmode=no-mistakes\nworktree=" + str(root) + "\n")
meta.chmod(0o600)
run("replay-arm", ["bin/fm-pr-check.sh", "replay4308", "https://github.com/groovejones/groove-sight-platform/pull/4308"])
sentinel = state / "zz-replay-complete.check.sh"
sentinel.write_text('#!/usr/bin/env bash\nprintf "history replay sweep complete\\n"\n')
sentinel.chmod(0o700)
run("replay-register", ["bin/fm-check-register.sh", "zz-replay-complete"])
fakebin = lab / "external-api-replay"
fakebin.mkdir()
shim = fakebin / "gh"
shim.write_text("#!" + shutil.which("python3") + "\n" + "import json, os, subprocess, sys\n" + "args=sys.argv[1:]\n" + "if args[:2] == ['api','graphql'] and any('pullRequests(states:' in a or 'pullRequest(number:' in a for a in args):\n" + "    filt=args[args.index('--jq')+1]\n" + "    raise SystemExit(subprocess.run([" + repr(real_jq) + ", '-r', filt, " + repr(str(fixture)) + "]).returncode)\n" + "os.execv(" + repr(real_gh) + ", [" + repr(real_gh) + "]+args)\n")
shim.chmod(0o700)
env["PATH"] = str(fakebin) + os.pathsep + os.environ["PATH"]
first = run("history-replay-first-watch", ["bin/fm-watch.sh"])
for node in nodes:
    event = node["timelineItems"]["nodes"][0]
    expected = f"dequeued https://github.com/groovejones/groove-sight-platform/pull/{node['number']} reason={event['reason']}"
    assert sum(expected in line for line in first.stdout.splitlines()) == 1, (node["number"], first.stdout)
(out / "history-replay-durable-queue.tsv").write_bytes((state / ".wake-queue").read_bytes())
(out / "history-replay-event-ids.txt").write_bytes((state / "merge-queue-sweep.seen").read_bytes())
ack("history-replay-first")
second = run("history-replay-repeat-watch", ["bin/fm-watch.sh"])
assert "dequeued " not in second.stdout, second.stdout
ack("history-replay-repeat")
print("Recorded-history replay: all nine named stranded PRs and #4308's 2026-10-14T02:32:46Z failed_checks event emitted once; acknowledged event IDs stayed silent.")
