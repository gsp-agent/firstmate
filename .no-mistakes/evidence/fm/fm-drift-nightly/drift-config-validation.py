#!/usr/bin/env python3
"""Exercise generated launchd configuration without loading an operator job."""
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess

root = Path.cwd()
work = root / ".agent-state/drift-test-phase/config-check"
ev = Path("/Users/dalecarman/.no-mistakes/evidence/01M5999CSVGBG7SM5134TYA5NC")
script = root / "bin/fm-drift-nightly.sh"
work.mkdir(parents=True)
env = dict(os.environ)
for key in tuple(env):
    if key.startswith("FM_") or key in {"GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"}:
        env.pop(key, None)
env.update({
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Firstmate Validation", "GIT_AUTHOR_EMAIL": "test@example.invalid",
    "GIT_COMMITTER_NAME": "Firstmate Validation", "GIT_COMMITTER_EMAIL": "test@example.invalid",
    "TMPDIR": str(work.parent / "tmp"),
    "FM_HOME": str(work / "home"), "FM_STATE_OVERRIDE": str(work / "home/state"),
    "FM_DATA_OVERRIDE": str(work / "home/data"), "FM_CONFIG_OVERRIDE": str(work / "home/config"),
    "FM_DRIFT_AGENT_DIR": str(work / "agents"),
    # Deliberately refuse all scheduler operations. This is configuration and
    # failure-handling evidence, never evidence of a real launchd installation.
    "FM_DRIFT_LAUNCHCTL": shutil.which("false"),
})
transcript = ev / "configuration-commands.log"


def run(args, expect=0):
    args = [str(v) for v in args]
    result = subprocess.run(args, cwd=root, env=env, text=True, capture_output=True)
    text = "$ " + shlex.join(args) + "\n" + result.stdout + result.stderr + f"[exit {result.returncode}]\n"
    with transcript.open("a") as handle:
        handle.write(text)
    assert result.returncode == expect, text
    return result


upstream = work / "upstream"
repo = work / "repo<&\"' test>"
log = work / "logs<&\"' test>" / "drift.log"
run(["git", "init", "-q", "-b", "main", upstream])
(upstream / "baseline.txt").write_text("upstream\n")
run(["git", "-C", upstream, "add", "--", "baseline.txt"])
run(["git", "-C", upstream, "-c", "commit.gpgsign=false", "commit", "-qm", "configuration baseline"])
run(["git", "clone", "-q", upstream, repo])
run(["git", "-C", repo, "remote", "rename", "origin", "kunchenguid"])

run(["bash", script, "install", "--dry-run", "--repo", repo, "--log", log])
assert not (work / "agents").exists()
run(["bash", script, "uninstall", "--dry-run"])
assert not (work / "agents").exists()
run(["bash", script, "install", "--hour", "24", "--repo", repo, "--log", log], 2)
run(["bash", script, "install", "--repo", repo, "--log", "relative.log"], 2)
assert not (work / "agents").exists()

run(["bash", script, "install", "--hour", "3", "--minute", "17", "--repo", repo, "--log", log], 2)
plist = work / "agents/dev.firstmate.drift-nightly.plist"
with plist.open("rb") as handle:
    model = plistlib.load(handle)
assert model["Label"] == "dev.firstmate.drift-nightly"
assert model["StartCalendarInterval"] == {"Hour": 3, "Minute": 17}
assert model["ProgramArguments"] == ["/bin/bash", str(script), "nightly", "--repo", str(repo), "--log", str(log)]
assert model["StandardOutPath"] == model["StandardErrorPath"] == str(log)
assert log.parent.is_dir()
(ev / "generated-nightly.plist").write_bytes(plist.read_bytes())
(ev / "generated-nightly-model.json").write_text(json.dumps(model, indent=2) + "\n")

# Execute the exact generated public command and output destinations. This
# drives the nightly job payload, but does not claim launchd scheduling.
with log.open("ab") as output:
    result = subprocess.run(model["ProgramArguments"], cwd=root, env=env, stdout=output, stderr=output)
assert result.returncode == 0, log.read_text()
(ev / "generated-job-execution.log").write_bytes(log.read_bytes())
before = plist.read_bytes()
run(["bash", script, "uninstall"], 2)
assert plist.read_bytes() == before
assert "exit: 0\n" in log.read_text()

empty_env = dict(env, FM_DRIFT_AGENT_DIR=str(work / "empty-agents"))
result = subprocess.run(["bash", str(script), "uninstall"], cwd=root, env=empty_env, text=True, capture_output=True)
assert result.returncode == 0 and result.stdout == "uninstalled: absent\n"
with transcript.open("a") as handle:
    handle.write("$ FM_DRIFT_AGENT_DIR=<disposable empty directory> bash bin/fm-drift-nightly.sh uninstall\n" + result.stdout)
print("PASS generated schedule, XML paths, exact job execution, dry runs, invalid inputs, and refusal to delete on scheduler error")
print("UNTESTED loading and unloading a real launchd job: the workspace boundary forbids modifying the user's launchd domain")
