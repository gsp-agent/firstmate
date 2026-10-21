#!/usr/bin/env python3
"""Exercise non-Herdr refusal reporting with a real private tmux server."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

ROOT = Path.cwd()
BASE = ROOT / ".fm-live-validation" / "tmux"
BASE.mkdir()
HOME_DIR = ROOT / "v"
HOME_DIR.mkdir()
EVIDENCE = Path("/Users/dalecarman/.no-mistakes/evidence/01M5ED7CG2SMYGRW9YHV37RPT2")
REAL_TMUX = shutil.which("tmux")
ORIGINAL_PATH = os.environ["PATH"]
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("FM_", "HERDR_", "TASKS_AXI_")) and k not in ("TMUX", "TMUX_PANE", "ZELLIJ", "ZELLIJ_SESSION_NAME")}
ENV.update(FM_HOME=str(HOME_DIR), FM_SPAWN_NO_GUARD="1", TMPDIR=str(BASE), TMUX_TMPDIR=str(HOME_DIR / "tmux"), TREEHOUSE_ROOT=str(BASE / "pool"), SHELL="/bin/bash", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
transcript = []
results = []
started = False

def record(msg):
    print(msg, flush=True)
    transcript.append(msg)
    (EVIDENCE / "live-tmux-transcript.log").write_text("\n".join(transcript) + "\n")

def run(args, *, cwd=ROOT, env=None, check=True, timeout=90):
    start = time.monotonic()
    p = subprocess.run([str(a) for a in args], cwd=cwd, env=env or ENV, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    elapsed = time.monotonic() - start
    record(f"$ {shlex.join([str(a) for a in args])}\nexit={p.returncode} elapsed={elapsed:.3f}s\n{p.stdout}{p.stderr}")
    if check and p.returncode:
        raise RuntimeError(p.stderr)
    return p, elapsed

def tmux(*args, check=True):
    return run([REAL_TMUX, "-L", "fm-lab", *args], check=check)

try:
    run([ROOT / "bin/fm-lab-home.sh", "create", HOME_DIR])
    (HOME_DIR / "tmux").mkdir(mode=0o700)
    (HOME_DIR / "state/.last-watcher-beat").touch()
    project = BASE / "project"
    project.mkdir()
    run(["git", "init", "-q", "-b", "main", project])
    (project / "README.md").write_text("Isolated non-Herdr refusal proof.\n")
    (project / "treehouse.toml").write_text(f'max_trees = 1\nroot = "{ENV["TREEHOUSE_ROOT"]}"\n')
    run(["git", "-C", project, "add", "README.md", "treehouse.toml"])
    run(["git", "-C", project, "-c", "user.name=Spawn Test", "-c", "user.email=spawn-test@example.invalid", "commit", "-qm", "Seed tmux test pool"])
    p, _ = run(["treehouse", "get", "--lease", "--json"], cwd=project)
    lease = json.loads(p.stdout)["path"]
    tmux("-f", "/dev/null", "new-session", "-d", "-s", "firstmate", "-x", "120", "-y", "40", "-c", project, "/bin/bash", "--noprofile", "--norc")
    started = True
    tmux("set-option", "-g", "default-shell", "/bin/bash")
    tmux("set-option", "-g", "default-command", "/bin/bash --noprofile --norc")
    bindir = BASE / "bin"
    bindir.mkdir()
    wrapper = bindir / "tmux"
    wrapper.write_text("#!/usr/bin/env python3\nimport os,sys,pathlib\na=sys.argv[1:]\nflag=pathlib.Path(os.environ['TMUX_FAILURE_FLAG'])\nfault=os.environ.get('TMUX_CLOSE_FAULT')=='1'\nif fault and a and a[0]=='kill-window': flag.touch()\nbad=fault and flag.exists() and (a[0] in ('kill-window','list-windows') or (a[0]=='display-message' and '#{pane_id}' in a))\nsocket='fm-lab-unreachable' if bad else 'fm-lab'\nos.execve(os.environ['REAL_TMUX'],[os.environ['REAL_TMUX'],'-L',socket,*a],dict(os.environ))\n")
    wrapper.chmod(0o700)
    spawn_env = {**ENV, "PATH": str(bindir) + ":" + ORIGINAL_PATH, "REAL_TMUX": REAL_TMUX, "TMUX_FAILURE_FLAG": str(BASE / "fault-active")}
    for scenario in ("normal-close", "status1-unreadable"):
        task = "pool-" + scenario
        run([ROOT / "bin/fm-brief.sh", task, "tmux-live-fixture", "--scout"], env=ENV)
        brief = HOME_DIR / "data" / task / "brief.md"
        brief.write_text(brief.read_text().replace("{TASK}", "Exercise non-Herdr pool-full refusal.").replace("{FIRSTMATE_SPEC}", "Disposable live verification; no publication."))
        task_env = {**spawn_env, "TMUX_CLOSE_FAULT": "1" if scenario == "status1-unreadable" else "0"}
        for attempt in ((1, 2) if scenario == "normal-close" else (1,)):
            p, elapsed = run([ROOT / "bin/fm-spawn.sh", task, project, "bash /dev/null", "--scout", "--backend", "tmux"], env=task_env, check=False)
            assert p.returncode != 0
            assert "all 1 worktrees are in use or dirty (max_trees = 1)" in p.stderr
            assert "could not confirm closure" in p.stderr and f"inspect window firstmate:fm-{task}" in p.stderr
            assert "was closed" not in p.stderr and "already exists" not in p.stderr
            assert not (HOME_DIR / "state" / (task + ".meta")).exists()
            q, _ = tmux("list-windows", "-t", "firstmate", "-F", "#{window_name}")
            if scenario == "normal-close":
                assert f"fm-{task}" not in q.stdout
            else:
                assert f"fm-{task}" in q.stdout
                lookup = BASE / "lookup.sh"
                lookup.write_text("#!/bin/bash\n. " + shlex.quote(str(ROOT / "bin/fm-backend.sh")) + "\nfm_backend_target_exists tmux " + shlex.quote("firstmate:fm-" + task) + "\n")
                status, _ = run(["bash", lookup], env=task_env, check=False)
                assert status.returncode == 1, status
                raw, _ = tmux("capture-pane", "-p", "-t", "firstmate:fm-" + task, "-S", "-200")
                (EVIDENCE / "tmux-status1-surviving-window.txt").write_text(raw.stdout)
                tmux("kill-window", "-t", "firstmate:fm-" + task)
            results.append({"scenario": scenario, "attempt": attempt, "result": "pass", "elapsed_seconds": round(elapsed, 3), "returncode": p.returncode})
            record("SCENARIO PASS: " + json.dumps(results[-1]))
    run(["treehouse", "return", lease], cwd=project)
except Exception as exc:
    record("DRIVER ERROR: " + repr(exc))
    results.append({"result": "error", "detail": repr(exc)})
    raise
finally:
    if started:
        tmux("kill-server", check=False)
    (EVIDENCE / "live-tmux-results.json").write_text(json.dumps(results, indent=2) + "\n")
