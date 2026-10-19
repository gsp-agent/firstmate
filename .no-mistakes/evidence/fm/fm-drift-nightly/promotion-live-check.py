#!/usr/bin/env python3
"""Drive promotion's emitted branch command in a disposable marked lab."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

root = Path.cwd()
lab = root / ".agent-state/fm-lab-promotion"
ev = Path("/Users/dalecarman/.no-mistakes/evidence/01M5999CSVGBG7SM5134TYA5NC")
env = dict(os.environ)
for key in tuple(env):
    if key.startswith("FM_") or key in {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"}:
        env.pop(key, None)
env.update({"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Firstmate Validation", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Firstmate Validation", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "FM_HOME": str(lab)})
log = ev / "promotion-live-check.log"


def run(args, cwd=root):
    args = [str(x) for x in args]
    cp = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    with log.open("a") as out:
        out.write("$ " + shlex.join(args) + "\n" + cp.stdout + cp.stderr + f"[exit {cp.returncode}]\n")
    assert cp.returncode == 0, cp.stdout + cp.stderr
    return cp.stdout.strip()


run(["bash", root / "bin/fm-lab-home.sh", "create", lab])
repo = lab / "projects/proj"
run(["git", "init", "-q", "-b", "main", repo])
(repo / "base.txt").write_text("base\n")
run(["git", "-C", repo, "add", "--", "base.txt"])
run(["git", "-C", repo, "-c", "commit.gpgsign=false", "commit", "-qm", "lab base"])
for task, prefix in [("promotion-basic", "fix/"), ("promotion-quoted", "$(touch${IFS}injected-marker)/")]:
    slot = lab / "projects" / (task + "-slot")
    run(["git", "-C", repo, "worktree", "add", "-q", "--detach", slot, "HEAD"])
    (lab / "state" / (task + ".meta")).write_text(f"window=fm-{task}\nkind=scout\nworktree={slot}\n")
    run(["bash", root / "bin/fm-brief.sh", task, "fixture-project", "--scout"])
    brief = lab / "data" / task / "brief.md"
    brief.write_text(brief.read_text().replace("{TASK}", "Promote this disposable scout onto its ship branch.")
                     .replace("{FIRSTMATE_SPEC}", "Create the selected branch inside the disposable slot."))
    run(["bash", root / "bin/fm-promote.sh", task, "--mode", "local-only", "--yolo", "off", "--branch-prefix", prefix])
    instructions = (lab / "data" / task / "ship-instructions.md").read_text()
    command = re.search(r"create your branch: `(.*)`\.", instructions).group(1)
    (ev / (task + "-instructions.md")).write_text(instructions)
    create = slot / "create-branch.sh"
    create.write_text("#!/usr/bin/env bash\nset -e\n" + command + "\n")
    run(["bash", create], cwd=slot)
    branch = run(["git", "-C", slot, "branch", "--show-current"])
    assert branch == prefix + task
    assert not (slot / "injected-marker").exists()
    assert run(["git", "-C", repo, "branch", "--show-current"]) == "main"
    assert (lab / "state" / (task + ".meta")).read_text().count("branch=" + branch + "\n") == 1
run(["bash", root / "bin/fm-lab-home.sh", "teardown", lab])
print("PASS real promotion CLI and generated branch commands: literal selected branch, isolated slot, primary unchanged, metacharacters not executed")
