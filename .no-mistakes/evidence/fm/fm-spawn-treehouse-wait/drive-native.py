#!/usr/bin/env python3
"""Drive fm-spawn from inside a real Herdr lab pane, without a CLI proxy."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

ROOT = Path.cwd()
BASE = ROOT / ".fm-live-validation/native"
BASE.mkdir()
E = Path("/Users/dalecarman/.no-mistakes/evidence/01M5ED7CG2SMYGRW9YHV37RPT2")
HELPER = ROOT / "bin/fm-herdr-lab.sh"
env = {k: v for k, v in os.environ.items() if not k.startswith(("FM_", "HERDR_", "TASKS_AXI_")) and k not in ("TMUX", "TMUX_PANE", "ZELLIJ", "ZELLIJ_SESSION_NAME", "CLAUDECODE")}
env.update(TMPDIR=str(BASE), TREEHOUSE_ROOT=str(BASE / "pool"), GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", FM_HERDR_LAB_STATE_DIR=str(BASE / "lab-state"))
lines = []
results = []
ready = False
session = ""

def log(s):
    print(s, flush=True)
    lines.append(s)
    (E / "native-herdr-transcript.log").write_text("\n".join(lines) + "\n")

def run(args, *, cwd=ROOT, check=True):
    start = time.time()
    p = subprocess.run([str(x) for x in args], cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=100)
    log(f"$ {shlex.join([str(x) for x in args])}\nexit={p.returncode} elapsed={time.time()-start:.3f}s\n{p.stdout}{p.stderr}")
    if check and p.returncode:
        raise RuntimeError(p.stderr)
    return p

def lab(*args, check=True):
    return run([HELPER, "run", session, *args], check=check)

def inventory(name):
    ws = json.loads(lab("workspace", "list").stdout)["result"]["workspaces"]
    out = {"workspaces": ws, "tabs": [], "panes": []}
    for w in ws:
        for k in ("tab", "pane"):
            out[k + "s"].extend(json.loads(lab(k, "list", "--workspace", w["workspace_id"]).stdout)["result"][k + "s"])
    (E / (name + "-inventory.json")).write_text(json.dumps(out, indent=2) + "\n")
    return out

def brief(task):
    run([ROOT / "bin/fm-brief.sh", task, "native-spawn-fixture", "--scout", "--herdr-lab"])
    p = home / "data" / task / "brief.md"
    p.write_text(p.read_text().replace("{TASK}", "Exercise isolated spawn startup and working-directory handoff.").replace("{FIRSTMATE_SPEC}", "Disposable live CLI proof; no publication or external messages."))

def spawn_in_pane(task, extra_wait=0):
    script = BASE / (task + ".sh")
    output = BASE / (task + ".output")
    done = BASE / (task + ".done")
    if done.exists():
        done.unlink()
    cmd = [ROOT / "bin/fm-spawn.sh", task, project, "bash " + shlex.quote(str(worker)), "--scout", "--backend", "herdr"]
    script.write_text("#!/bin/bash\nunset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE\nexport FM_HOME=" + shlex.quote(str(home)) + "\nexport FM_SPAWN_NO_GUARD=1\ndate +%s > " + shlex.quote(str(BASE / (task + ".started"))) + "\n" + shlex.join([str(x) for x in cmd]) + " > " + shlex.quote(str(output)) + " 2>&1\nresult=$?\nprintf '%s %s\\n' \"$result\" \"$(date +%s)\" > " + shlex.quote(str(done)) + "\n")
    timing = E / "native-treehouse-timing.log"
    prior = len(timing.read_text().splitlines()) if timing.exists() else 0
    log("Native pane command: " + shlex.join([str(x) for x in cmd]))
    lab("pane", "run", parent, "bash " + shlex.quote(str(script)))
    deadline = time.time() + 140
    while not done.exists() and time.time() < deadline:
        time.sleep(0.2)
    assert done.exists(), task + " did not return by 140 seconds"
    status, finished = map(int, done.read_text().split())
    started = int((BASE / (task + ".started")).read_text())
    text = output.read_text()
    log(f"Native fm-spawn {task}: exit={status} total={finished-started}s\n" + text)
    (E / ("native-" + task + ".log")).write_text(text)
    events = [s.split() for s in timing.read_text().splitlines()[prior:]]
    ends = [s for s in events if s[0] == "end"]
    latency = finished - int(ends[0][1]) if ends else None
    log(f"Native fm-spawn {task}: seconds after real Treehouse return={latency}; Treehouse events={events}")
    return status, text, latency, finished-started

try:
    home = BASE / "home"
    home.mkdir()
    run([ROOT / "bin/fm-lab-home.sh", "create", home])
    env["FM_HOME"] = str(home)
    (home / "state/.last-watcher-beat").touch()
    project = BASE / "project"
    project.mkdir()
    run(["git", "init", "-q", "-b", "main", project])
    (project / "README.md").write_text("Native Herdr spawn proof.\n")
    (project / "treehouse.toml").write_text('max_trees = 1\nroot = "' + env["TREEHOUSE_ROOT"] + '"\n')
    run(["git", "-C", project, "add", "README.md", "treehouse.toml"])
    run(["git", "-C", project, "-c", "user.name=Native Spawn Test", "-c", "user.email=native-test@example.invalid", "commit", "-qm", "Seed native pool"])
    origin = BASE / "origin.git"
    run(["git", "clone", "--quiet", "--bare", project, origin])
    run(["git", "-C", project, "remote", "add", "origin", "file://" + str(origin)])
    worker = BASE / "worker.sh"
    worker.write_text("#!/bin/bash\npwd > " + shlex.quote(str(BASE / "worker-cwd.txt")) + "\nprintf 'WORKER_STARTED cwd=%s\\n' \"$PWD\"\nread -r -t 60 unused || true\n")
    shell_home = BASE / "shell-home"
    shell_home.mkdir()
    clean_shell = BASE / "clean-shell"
    clean_shell.write_text("#!/bin/bash\nexec /bin/bash --noprofile --norc -i\n")
    clean_shell.chmod(0o700)
    bindir = BASE / "bin"
    bindir.mkdir()
    real_treehouse = shutil.which("treehouse")
    wrapper = bindir / "treehouse"
    wrapper.write_text("#!/bin/bash\nif [ \"${1:-}\" = get ]; then\n  printf 'start %s\\n' \"$(date +%s)\" >> " + shlex.quote(str(E / "native-treehouse-timing.log")) + "\n  " + shlex.quote(real_treehouse) + " \"$@\"\n  result=$?\n  printf 'end %s %s\\n' \"$(date +%s)\" \"$result\" >> " + shlex.quote(str(E / "native-treehouse-timing.log")) + "\n  exit \"$result\"\nfi\nexec " + shlex.quote(real_treehouse) + " \"$@\"\n")
    wrapper.chmod(0o700)
    env.update(PATH=str(bindir) + ":" + env["PATH"], ZDOTDIR=str(shell_home), SHELL=str(clean_shell), BASH_ENV="/dev/null")
    (shell_home / ".zshrc").write_text("export PATH=" + shlex.quote(env["PATH"]) + "\nexport SHELL=" + shlex.quote(str(clean_shell)) + "\n")
    session = run([HELPER, "name", "native-pool"]).stdout.strip()
    env["HERDR_SESSION"] = session
    run([HELPER, "provision", session])
    ready = True
    ws = json.loads(lab("workspace", "create", "--label", "firstmate", "--cwd", ROOT).stdout)["result"]
    parent = ws["root_pane"]["pane_id"]
    initial = inventory("native-baseline")
    lease = json.loads(run(["treehouse", "get", "--lease", "--json"], cwd=project).stdout)["path"]
    for layout in ("flat", "projected"):
        (home / "config/herdr-presentation-spaces").write_text("off\n" if layout == "flat" else "on\n")
        task = "native-pool-" + layout
        brief(task)
        for attempt in (1, 2):
            status, text, latency, total = spawn_in_pane(task)
            state = inventory(task + "-" + str(attempt))
            assert status != 0 and "all 1 worktrees are in use or dirty (max_trees = 1)" in text
            assert "was closed" in text and "already exists" not in text
            assert not (home / "state" / (task + ".meta")).exists()
            assert all(len(state[k]) == len(initial[k]) for k in ("workspaces", "tabs", "panes"))
            assert latency is not None
            results.append({"scenario": layout + " pool-full", "attempt": attempt, "result": "pass" if latency < 20 else "slow", "after_treehouse_return_seconds": latency, "total_seconds": total})
            log("SCENARIO: " + json.dumps(results[-1]))
    run(["treehouse", "return", lease], cwd=project)
    slow = BASE / "slow-upload-pack.sh"
    slow.write_text("#!/bin/bash\nprintf 'delayed-fetch %s\\n' \"$(date +%s)\" >> " + shlex.quote(str(E / "native-slow-fetch.log")) + "\nsleep 8\nexec git-upload-pack \"$@\"\n")
    slow.chmod(0o700)
    run(["git", "-C", project, "config", "remote.origin.uploadpack", slow])
    task = "native-slow-success"
    brief(task)
    status, text, latency, total = spawn_in_pane(task)
    state = inventory(task)
    assert status == 0, text
    meta = home / "state" / (task + ".meta")
    pairs = dict(row.split("=", 1) for row in meta.read_text().splitlines() if "=" in row)
    (E / "native-slow-success.meta").write_text(meta.read_text())
    capture = lab("pane", "read", pairs["herdr_pane_id"], "--lines", "200").stdout
    (E / "native-slow-success-pane.txt").write_text(capture)
    proof = BASE / "worker-cwd.txt"
    deadline = time.time() + 10
    while not proof.exists() and time.time() < deadline:
        time.sleep(0.2)
    assert proof.exists() and proof.read_text().strip() == pairs["worktree"]
    assert (E / "native-slow-fetch.log").exists()
    results.append({"scenario": "slow successful real setup", "result": "pass", "total_seconds": total, "worktree": pairs["worktree"]})
    log("SCENARIO: " + json.dumps(results[-1]))
except Exception as exc:
    log("DRIVER ERROR: " + repr(exc))
    results.append({"result": "error", "detail": repr(exc)})
    raise
finally:
    if ready:
        result = run([HELPER, "teardown", session], check=False)
        log("Lab teardown and default-session tripwire: " + ("PASS" if result.returncode == 0 else "FAIL"))
    (E / "native-herdr-results.json").write_text(json.dumps(results, indent=2) + "\n")
