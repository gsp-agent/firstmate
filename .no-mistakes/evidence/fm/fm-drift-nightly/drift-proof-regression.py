#!/usr/bin/env python3
"""Reproduce the dirty-proof regression with the before and shipped CLIs."""
import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path.cwd()
work = root / ".agent-state/drift-test-phase/proof-regression"
work.mkdir(parents=True)
ev = Path("/Users/dalecarman/.no-mistakes/evidence/01M5999CSVGBG7SM5134TYA5NC")
env = dict(os.environ)
for key in tuple(env):
    if key.startswith("FM_") or key in {"GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"}:
        env.pop(key, None)
env.update({"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Firstmate Validation", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Firstmate Validation", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "TMPDIR": str(work.parent / "tmp"), "FM_HOME": str(work / "home")})
transcript = ev / "committed-proof-regression.log"


def run(args, expected=0, save=True):
    args = [str(x) for x in args]
    cp = subprocess.run(args, cwd=root, env=env, capture_output=True, text=True)
    if save:
        with transcript.open("a") as output:
            output.write("$ " + shlex.join(args) + "\n" + cp.stdout + cp.stderr + f"[exit {cp.returncode}]\n")
    assert cp.returncode == expected, cp.stdout + cp.stderr
    return cp.stdout.strip()


old = work / "before-fm-drift-nightly.sh"
old.write_text(run(["git", "show", "a1b862808fe29fa0f5364c4a4f713d23941731d2:bin/fm-drift-nightly.sh"], save=False) + "\n")
repo = work / "repo"
run(["git", "init", "-q", "-b", "main", repo])
(repo / "base.txt").write_text("base\n")
run(["git", "-C", repo, "add", "--", "base.txt"])
run(["git", "-C", repo, "-c", "commit.gpgsign=false", "commit", "-qm", "baseline"])
run(["git", "-C", repo, "branch", "upstream"])
(repo / "unproven.txt").write_text("custom\n")
run(["git", "-C", repo, "add", "--", "unproven.txt"])
run(["git", "-C", repo, "-c", "commit.gpgsign=false", "commit", "-qm", "unproven change"])
sha = run(["git", "-C", repo, "rev-parse", "HEAD"])
(repo / "drift-proof.txt").write_text(sha + "\n")
before = run(["bash", old, "check", "--no-fetch", "--repo", repo, "--upstream", "upstream"])
after = run(["bash", root / "bin/fm-drift-nightly.sh", "check", "--no-fetch", "--repo", repo, "--upstream", "upstream"], expected=1)
assert "keep: " + sha in before and "path-ok: unproven.txt" in before
assert "unproven: " + sha in after and "path-drift: unproven.txt" in after
print("PASS before fix: an untracked proof falsely approves the commit (exit 0); shipped fix: it remains unproven (exit 1)")
