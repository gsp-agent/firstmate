#!/usr/bin/env python3
"""Exercise fm-spawn against real, disposable Herdr/Treehouse processes."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

ROOT = Path.cwd()
BASE = ROOT / ".fm-live-validation" / "clean"
BASE.mkdir()
(BASE / "tmp").mkdir()
EVIDENCE = Path("/Users/dalecarman/.no-mistakes/evidence/01M5ED7CG2SMYGRW9YHV37RPT2")
LAB_HELPER = ROOT / "bin/fm-herdr-lab.sh"
ORIGINAL_PATH = os.environ["PATH"]
REAL_HERDR = shutil.which("herdr")
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("FM_", "HERDR_", "TASKS_AXI_")) and k not in ("TMUX", "TMUX_PANE", "ZELLIJ", "ZELLIJ_SESSION_NAME", "CLAUDECODE")}
ENV.update(TMPDIR=str(BASE / "tmp"), TREEHOUSE_ROOT=str(BASE / "treehouse-root"), SHELL="/bin/bash", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", FM_HERDR_LAB_STATE_DIR=str(BASE / "herdr-lab-state"))
transcript = []
results = []
session = None
provisioned = False
lease = None

def record(message):
    print(message, flush=True)
    transcript.append(message)
    (EVIDENCE / "live-herdr-clean-transcript.log").write_text("\n".join(transcript) + "\n")

def run(args, *, cwd=ROOT, env=None, timeout=90, check=True, show=True):
    begin = time.monotonic()
    p = subprocess.run([str(a) for a in args], cwd=cwd, env=env or ENV, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    elapsed = time.monotonic() - begin
    if show:
        record(f"$ {shlex.join([str(a) for a in args])}\nexit={p.returncode} elapsed={elapsed:.3f}s\n{p.stdout}{p.stderr}")
    if check and p.returncode:
        raise RuntimeError(f"command failed ({p.returncode}): {args!r}: {p.stderr}")
    return p, elapsed

def lab(*args, check=True):
    return run([LAB_HELPER, "run", session, *args], check=check)

def inventory(label):
    p, _ = lab("workspace", "list")
    workspaces = json.loads(p.stdout)["result"]["workspaces"]
    snapshot = {"workspaces": workspaces, "tabs": [], "panes": []}
    for workspace in workspaces:
        wid = workspace["workspace_id"]
        for kind in ("tab", "pane"):
            q, _ = lab(kind, "list", "--workspace", wid)
            snapshot[kind + "s"].extend(json.loads(q.stdout)["result"][kind + "s"])
    (EVIDENCE / f"{label}-inventory.json").write_text(json.dumps(snapshot, indent=2) + "\n")
    return snapshot

def scaffold(home, task):
    run([ROOT / "bin/fm-brief.sh", task, "spawn-live-fixture", "--scout", "--herdr-lab"], env={**ENV, "FM_HOME": str(home)})
    path = home / "data" / task / "brief.md"
    content = path.read_text().replace("{TASK}", "Exercise isolated spawn startup and record the observed working directory.").replace("{FIRSTMATE_SPEC}", "Disposable live-validation fixture; no publication or external communication.")
    path.write_text(content)

try:
    home = BASE / "home"
    home.mkdir()
    run([ROOT / "bin/fm-lab-home.sh", "create", home])
    ENV["FM_HOME"] = str(home)
    ENV["FM_SPAWN_NO_GUARD"] = "1"
    (home / "state/.last-watcher-beat").touch()
    project = BASE / "project"
    project.mkdir()
    run(["git", "init", "-q", "-b", "main", project])
    (project / "README.md").write_text("Disposable Firstmate spawn-validation project.\n")
    (project / "treehouse.toml").write_text(f'max_trees = 1\nroot = "{ENV["TREEHOUSE_ROOT"]}"\n')
    run(["git", "-C", project, "add", "README.md", "treehouse.toml"])
    run(["git", "-C", project, "-c", "user.name=Spawn Live Test", "-c", "user.email=spawn-test@example.invalid", "commit", "-qm", "Seed disposable pool"])
    origin = BASE / "project-origin.git"
    run(["git", "clone", "--bare", "--quiet", project, origin])
    run(["git", "-C", project, "remote", "add", "origin", "file://" + str(origin)])
    worker = BASE / "worker.sh"
    worker.write_text("#!/bin/bash\nprintf 'worker-cwd=%s\\n' \"$PWD\"\nprintf '%s\\n' \"$PWD\" > " + shlex.quote(str(BASE / "worker-cwd.txt")) + "\nread -r -t 45 _ || true\n")
    worker.chmod(0o700)
    raw_launch = "bash " + shlex.quote(str(worker))

    # All adapter traffic goes through the canonical lab helper; nothing is mocked.
    bindir = BASE / "bin"
    bindir.mkdir()
    shell_home = BASE / "shell-home"
    shell_home.mkdir()
    wrapper = bindir / "herdr"
    wrapper.write_text('''#!/bin/bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "$2" = "$HERDR_LAB_SESSION" ] || exit 2
    shift 2
  else
    args+=("$1")
    shift
  fi
done
if [ "${args[0]}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "${args[@]}" --session "$HERDR_LAB_SESSION"
fi
if { [ "${args[0]}" = workspace ] || [ "${args[0]}" = tab ]; } && [ "${args[1]:-}" = create ]; then
  args+=(--env "HOME=$LAB_SHELL_HOME" --env "ZDOTDIR=$LAB_SHELL_HOME" --env "SHELL=/bin/bash" --env "PATH=$LAB_PANE_PATH" --env "REAL_TREEHOUSE=$REAL_TREEHOUSE" --env "TREEHOUSE_TIMING_LOG=$TREEHOUSE_TIMING_LOG")
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
''')
    wrapper.chmod(0o700)
    treehouse_wrapper = bindir / "treehouse"
    treehouse_wrapper.write_text('''#!/bin/bash
if [ "${1:-}" = get ]; then
  printf 'start %s\\n' "$(date +%s)" >> "$TREEHOUSE_TIMING_LOG"
  "$REAL_TREEHOUSE" "$@"
  result=$?
  printf 'end %s %s\\n' "$(date +%s)" "$result" >> "$TREEHOUSE_TIMING_LOG"
  exit "$result"
fi
exec "$REAL_TREEHOUSE" "$@"
''')
    treehouse_wrapper.chmod(0o700)
    p, _ = run([LAB_HELPER, "name", "spawn-pool"])
    session = p.stdout.strip()
    ENV.update(HERDR_SESSION=session, HERDR_LAB_SESSION=session, HERDR_ORIGINAL_PATH=ORIGINAL_PATH, REAL_HERDR=REAL_HERDR, HERDR_LAB_HELPER=str(LAB_HELPER), REAL_TREEHOUSE=shutil.which("treehouse"), TREEHOUSE_TIMING_LOG=str(EVIDENCE / "live-treehouse-timing.log"), LAB_SHELL_HOME=str(shell_home), LAB_PANE_PATH=str(bindir) + ":" + ORIGINAL_PATH)
    # provision internally performs prepare and records the default-session tripwire.
    run([LAB_HELPER, "provision", session])
    provisioned = True
    lab("workspace", "create", "--label", "firstmate", "--cwd", project, "--env", "HOME=" + str(shell_home), "--env", "ZDOTDIR=" + str(shell_home))
    baseline = inventory("baseline")
    p, _ = run(["treehouse", "get", "--lease", "--json"], cwd=project)
    leased = json.loads(p.stdout)
    record("Lease response: " + json.dumps(leased))
    lease = leased.get("path") or leased.get("worktree", {}).get("path")
    assert lease, leased
    run(["treehouse", "status"], cwd=project)
    spawn_env = {**ENV, "PATH": str(bindir) + ":" + ORIGINAL_PATH}
    for layout in ("flat", "projected"):
        (home / "config/herdr-presentation-spaces").write_text("off\n" if layout == "flat" else "on\n")
        task = "pool-" + layout
        scaffold(home, task)
        for attempt in (1, 2):
            timing_path = Path(ENV["TREEHOUSE_TIMING_LOG"])
            prior_events = len(timing_path.read_text().splitlines()) if timing_path.exists() else 0
            p, elapsed = run([ROOT / "bin/fm-spawn.sh", task, project, raw_launch, "--scout", "--backend", "herdr"], env=spawn_env, check=False)
            spawn_finished = time.time()
            timing = [row.split() for row in timing_path.read_text().splitlines()[prior_events:]]
            sent = [row for row in timing if row[0] == "start"]
            returned = [row for row in timing if row[0] == "end"]
            assert sent and returned, timing
            after_return = spawn_finished - int(returned[0][1])
            record(f"Timing: total spawn {elapsed:.3f}s; Treehouse itself {int(returned[0][1]) - int(sent[0][1])}s; refusal after Treehouse returned {after_return:.3f}s (one-second timestamp precision)")
            after = inventory(f"{task}-{attempt}")
            assert p.returncode != 0, p.stdout
            assert "all 1 worktrees are in use or dirty (max_trees = 1)" in p.stderr, p.stderr
            assert str(project) in p.stderr
            assert "was closed" in p.stderr and "could not confirm closure" not in p.stderr
            assert "already exists" not in p.stderr
            assert not (home / "state" / (task + ".meta")).exists()
            assert len(after["workspaces"]) == len(baseline["workspaces"]) and len(after["panes"]) == len(baseline["panes"]) and len(after["tabs"]) == len(baseline["tabs"]), after
            assert after_return < 20, after_return
            results.append({"scenario": f"{layout} pool-full attempt {attempt}", "result": "pass", "elapsed_seconds": round(elapsed, 3), "after_treehouse_return_seconds": round(after_return, 3), "returncode": p.returncode, "workspace_count": len(after["workspaces"]), "pane_count": len(after["panes"]), "tab_count": len(after["tabs"])})
            record("SCENARIO PASS: " + json.dumps(results[-1]))
    run(["treehouse", "return", lease], cwd=project)
    lease = None

    # A real Git transport adds latency to a successful Treehouse acquisition.
    slow_transport = BASE / "slow-upload-pack.sh"
    slow_transport.write_text("#!/bin/bash\nprintf 'slow-fetch-start %s\\n' \"$(date +%s)\" >> " + shlex.quote(str(BASE / "slow-fetch.log")) + "\nsleep 8\nexec git-upload-pack \"$@\"\n")
    slow_transport.chmod(0o700)
    run(["git", "-C", project, "config", "remote.origin.uploadpack", str(slow_transport)])
    (home / "config/herdr-presentation-spaces").write_text("on\n")
    task = "slow-success"
    scaffold(home, task)
    p, elapsed = run([ROOT / "bin/fm-spawn.sh", task, project, raw_launch, "--scout", "--backend", "herdr"], env=spawn_env, check=False)
    after = inventory(task)
    assert p.returncode == 0, p.stderr
    meta = home / "state" / (task + ".meta")
    assert meta.exists()
    (EVIDENCE / "slow-success.meta").write_text(meta.read_text())
    pairs = dict(row.split("=", 1) for row in meta.read_text().splitlines() if "=" in row)
    pane = pairs["herdr_pane_id"]
    capture, _ = lab("pane", "read", pane, "--lines", "200")
    (EVIDENCE / "slow-success-pane.txt").write_text(capture.stdout)
    proof = BASE / "worker-cwd.txt"
    deadline = time.monotonic() + 10
    while not proof.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    assert proof.exists(), capture.stdout
    assert proof.read_text().strip() == pairs["worktree"], (proof.read_text(), pairs)
    assert pairs["worktree"] != str(project)
    assert (BASE / "slow-fetch.log").exists()
    assert elapsed >= 8, elapsed
    results.append({"scenario": "delayed real Treehouse setup launches shell worker", "result": "pass", "elapsed_seconds": round(elapsed, 3), "worker_cwd": proof.read_text().strip()})
    record("SCENARIO PASS: " + json.dumps(results[-1]))
except Exception as exc:
    record("DRIVER ERROR: " + repr(exc))
    results.append({"result": "error", "detail": repr(exc)})
    raise
finally:
    if provisioned:
        p, _ = run([LAB_HELPER, "teardown", session], check=False)
        record("Lab teardown and unchanged-default-session tripwire: " + ("PASS" if p.returncode == 0 else "FAIL"))
    (EVIDENCE / "live-herdr-results.json").write_text(json.dumps(results, indent=2) + "\n")
