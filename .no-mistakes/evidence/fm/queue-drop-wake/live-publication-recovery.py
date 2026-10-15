import json
import os
from pathlib import Path
import re
import shutil
import subprocess

root = Path.cwd()
out = Path(__file__).parent
lab = root / ".fm-queue-publication-live"
real_gh = shutil.which("gh")
auth = subprocess.run(["gh", "auth", "token", "--user", "gsp-agent"], capture_output=True, text=True, check=True)
env = dict(os.environ, GH_TOKEN=auth.stdout.strip())
for key in list(env):
    if key.startswith("FM_") or key.startswith("HERDR_") or key in ("TMUX", "TMUX_PANE", "TASKS_AXI_FILE", "TASKS_AXI_BACKEND"):
        env.pop(key)
env.update(FM_HOME=str(lab), FM_BACKEND="tmux", FM_CHECK_INTERVAL="0", FM_POLL="0.1", FM_HEARTBEAT="999999", FM_SIGNAL_GRACE="0")

def run(label, args, expect=0):
    result = subprocess.run(args, cwd=root, env=env, text=True, capture_output=True, timeout=120)
    (out / (label + ".stdout.txt")).write_text(result.stdout)
    (out / (label + ".stderr.txt")).write_text(result.stderr)
    assert (result.returncode == 0) == (expect == 0), (label, result.returncode, result.stderr)
    return result

def ack(label):
    result = run(label + "-drain", ["bin/fm-wake-drain.sh"])
    match = re.search(r"--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)", result.stderr)
    if not match and not result.stdout.strip():
        return
    assert match, result.stderr
    run(label + "-ack", ["bin/fm-wake-drain.sh", "--ack-through", match[1], "--recovery-generation", match[2]])

if not lab.exists():
    run("publication-create", ["bin/fm-lab-home.sh", "create", str(lab)])
else:
    assert (lab / ".fm-lab-home").is_file()
state = lab / "state"
meta = state / "retry3941.meta"
meta.write_text("kind=ship\nmode=no-mistakes\nworktree=" + str(root) + "\n")
meta.chmod(0o600)
run("publication-arm", ["bin/fm-pr-check.sh", "retry3941", "https://github.com/groovejones/groove-sight-platform/pull/3941"])
ack("publication-initial")
run("publication-unregister-observer", ["bin/fm-check-unregister.sh", "contributions"])
sentinel = state / "zz-publication-complete.check.sh"
sentinel.write_text('#!/usr/bin/env bash\nprintf "publication retry sweep complete\\n"\n')
sentinel.chmod(0o700)
run("publication-register", ["bin/fm-check-register.sh", "zz-publication-complete"])
auditbin = lab / "gh-audit"
auditbin.mkdir()
audit = auditbin / "gh"
request_log = lab / "real-gh-requests.jsonl"
audit.write_text("#!" + shutil.which("python3") + "\n" + "import json, os, sys\n" + "with open(" + repr(str(request_log)) + ", 'a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')\n" + "os.execv(" + repr(real_gh) + ", [" + repr(real_gh) + "]+sys.argv[1:])\n")
audit.chmod(0o700)
env["PATH"] = str(auditbin) + os.pathsep + os.environ["PATH"]
sequence = state / ".wake-queue.seq"
saved = state / ".wake-queue.seq.saved-by-test"
assert not saved.exists()
had_sequence = sequence.is_file()
if had_sequence:
    sequence.rename(saved)
sequence.mkdir()
run("live-publication-failure", ["bin/fm-watch.sh"], expect=1)
requests = [json.loads(line) for line in request_log.read_text().splitlines()]
assert any(any("pullRequest(number:" in arg for arg in request) for request in requests), "The failing sweep never read the real PR"
marker = state / "retry3941.pr-poll-queue-dropped"
assert not marker.exists(), "Failed publication consumed the removal"
assert not (state / ".wake-queue").read_text(), "Failed append unexpectedly queued a notification"
(out / "live-publication-failure-state.json").write_text(json.dumps({"real_github_pr_queried": True, "marker_exists": marker.exists(), "queue_bytes": (state / ".wake-queue").stat().st_size, "fault": "Wake sequence path replaced by a directory, preserving its original file"}, indent=2) + "\n")
decision = subprocess.run(["dcg", "test", "rmdir " + str(sequence), "--format", "json"], text=True, capture_output=True, check=True)
assert json.loads(decision.stdout)["decision"] == "allow"
subprocess.run(["rmdir", str(sequence)], check=True)
if had_sequence:
    saved.rename(sequence)
retry = run("live-publication-retry", ["bin/fm-watch.sh"])
if retry.stdout.strip() == "check: rearm-resurface":
    ack("publication-recovery")
    retry = run("live-publication-retry-after-recovery", ["bin/fm-watch.sh"])
expected = "dequeued https://github.com/groovejones/groove-sight-platform/pull/3941 reason=merge_conflict"
assert sum(expected in line for line in retry.stdout.splitlines()) == 1, retry.stdout
assert marker.is_file(), "Successful publication did not record the event"
drain = run("live-publication-success-drain", ["bin/fm-wake-drain.sh"])
assert expected in drain.stdout, drain.stdout
match = re.search(r"--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)", drain.stderr)
assert match, drain.stderr
run("live-publication-success-ack", ["bin/fm-wake-drain.sh", "--ack-through", match[1], "--recovery-generation", match[2]])
repeat = run("live-publication-repeat", ["bin/fm-watch.sh"])
assert "dequeued " not in repeat.stdout, repeat.stdout
ack("publication-repeat")
(out / "live-publication-real-gh-requests.jsonl").write_bytes(request_log.read_bytes())
print("Live GitHub publication failure: the real PR was read, failed queue storage left no consumed marker, repair delivered exactly one armed-PR wake, and the acknowledged event stayed silent.")
