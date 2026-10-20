#!/usr/bin/env python3
"""Drive actual tasks, snapshot, summary, and Bearings CLIs in disposable homes."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path("/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5CN7DKM40PFMVES0WRY9R1T")
EVIDENCE = Path("/Users/dalecarman/.no-mistakes/evidence/01M5CN7DKM40PFMVES0WRY9R1T")
WORK = ROOT / ".no-mistakes" / "archived-blocker-live"
WORK.mkdir(parents=True, exist_ok=False)
(WORK / "tmp").mkdir()
BASE_ENV = {k:v for k,v in os.environ.items() if not k.startswith("FM_") and k not in ("TASKS_AXI_FILE", "TASKS_AXI_BACKEND", "TMUX", "TMUX_PANE", "HERDR_SESSION")}
BASE_ENV.update(TMPDIR=str(WORK / "tmp"), PYTHONDONTWRITEBYTECODE="1")
TRANSCRIPT = (EVIDENCE / "archived-blocker-cli-transcript.txt").open("w")
RESULTS = []

def record(s):
    print(s, flush=True)
    TRANSCRIPT.write(s + "\n")
    TRANSCRIPT.flush()

def run(home, args, label=None, env_extra=None, visible=True):
    env = dict(BASE_ENV, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(ROOT))
    if env_extra:
        env.update(env_extra)
    argv = [str(ROOT / "bin" / args[0]), *args[1:]] if args[0].startswith("fm-") else [str(a) for a in args]
    record("$ FM_HOME=" + shlex.quote(str(home)) + " " + shlex.join(argv))
    p = subprocess.run(argv, cwd=ROOT, env=env, text=True, capture_output=True, timeout=90)
    if label:
        (EVIDENCE / label).write_text(p.stdout)
        record("output: " + label)
    if visible and p.stdout:
        record(p.stdout.rstrip())
    if p.stderr:
        record("stderr: " + p.stderr.rstrip())
    if p.returncode:
        raise RuntimeError(f"{shlex.join(argv)} exited {p.returncode}")
    return p.stdout

def new_home(name):
    h = WORK / name
    for child in ("state", "data", "config", "projects"):
        (h / child).mkdir(parents=True)
    (h / ".tasks.toml").write_text('backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    return h

def task(h, *args):
    return run(h, ["fm-tasks-axi.sh", *args])

def snap(h, name, env_extra=None):
    return json.loads(run(h, ["fm-fleet-snapshot.sh", "--json"], name + ".json", env_extra, False))

def rows(s):
    return {r["id"]:r for r in s["backlog"]["records"] if r.get("structured")}

def show(s, ids):
    data = [{k:rows(s)[i].get(k) for k in ("id", "state", "blocked_by_ids", "unresolved_blocker_ids")} for i in ids]
    record(json.dumps(data, indent=2))

try:
    record("Real CLI versions")
    for cmd in (["tasks-axi", "--version"], ["/bin/bash", "--version"], ["jq", "--version"]):
        p = subprocess.run(cmd, text=True, capture_output=True, env=BASE_ENV, timeout=20)
        record(shlex.join(cmd) + "\n" + (p.stdout or p.stderr).rstrip())
        assert p.returncode == 0
    h = new_home("archive-lifecycle")
    task(h, "add", "shipped", "Shipped prerequisite", "--kind", "ship", "--repo", "alpha")
    for i in ("follow-one", "review-follow-two"):
        task(h, "add", i, "Work waiting for shipped prerequisite", "--kind", "ship", "--repo", "alpha", "--blocked-by", "shipped")
    before = snap(h, "01-before-completion")
    show(before, ["follow-one", "review-follow-two"])
    assert not (h / "data/done-archive.md").exists()
    assert all(rows(before)[i]["unresolved_blocker_ids"] == ["shipped"] for i in ("follow-one", "review-follow-two"))
    task(h, "done", "shipped", "--no-prune")
    retained = snap(h, "02-completed-retained")
    show(retained, ["follow-one", "review-follow-two"])
    assert rows(retained)["shipped"]["state"] == "done"
    assert all(rows(retained)[i]["unresolved_blocker_ids"] == [] for i in ("follow-one", "review-follow-two"))
    task(h, "done", "shipped", "--keep", "0")
    for f in ("backlog.md", "done-archive.md"):
        data = (h / "data" / f).read_text()
        (EVIDENCE / ("03-" + f)).write_text(data)
        record(f + " after tasks-axi archive:\n" + data)
    archived = snap(h, "03-archived-current")
    show(archived, ["follow-one", "review-follow-two"])
    assert "shipped" not in rows(archived)
    assert all(rows(archived)[i]["unresolved_blocker_ids"] == [] for i in ("follow-one", "review-follow-two"))

    # Execute the actual pre-fix producer with unchanged sibling dependencies.
    control = WORK / "before-fix-bin"
    control.mkdir()
    for source in (ROOT / "bin").iterdir():
        if source.name != "fm-fleet-snapshot.sh":
            (control / source.name).symlink_to(source, target_is_directory=source.is_dir())
    baseline_source = subprocess.check_output(["git", "show", "929f2631:bin/fm-fleet-snapshot.sh"], cwd=ROOT)
    baseline = control / "fm-fleet-snapshot.sh"
    baseline.write_bytes(baseline_source)
    baseline.chmod(0o755)
    old = json.loads(run(h, [str(baseline), "--json"], "04-before-fix-archived.json", visible=False))
    show(old, ["follow-one", "review-follow-two"])
    assert all(rows(old)[i]["unresolved_blocker_ids"] == ["shipped"] for i in ("follow-one", "review-follow-two"))
    RESULTS.append({"scenario":"Archiving a completed prerequisite keeps both dependent tasks resolved", "result":"pass", "baseline_unresolved":2, "current_unresolved":0, "live":True})

    run(h, ["fm-home-summary-refresh.sh"])
    ledger = json.loads((h / "state/home-summary.json").read_text())
    (EVIDENCE / "05-published-home-summary.json").write_text(json.dumps(ledger, indent=2) + "\n")
    record("Published home summary:\n" + json.dumps(ledger, indent=2))
    assert ledger["valid"] is True
    assert ledger["holds"] == []
    queued = {r["id"]:r for r in ledger["queued"]}
    assert all(queued[i]["unresolved_blocker_ids"] == [] for i in ("follow-one", "review-follow-two"))
    bearings = json.loads(run(h, ["fm-bearings-snapshot.sh", "--json"], "06-bearings-after-archive.json"))
    gates = {r["id"]:r for r in bearings["gates"]}
    assert all(gates[i]["blocked_by"] == "-" for i in ("follow-one", "review-follow-two"))
    RESULTS.append({"scenario":"Refreshing the home summary and Bearings removes the archived prerequisite from current holds", "result":"pass", "live":True})

    m = new_home("mixed-blockers")
    task(m, "add", "shipped", "Archived prerequisite", "--kind", "ship", "--repo", "alpha")
    task(m, "add", "queued-dep", "Still queued", "--kind", "ship", "--repo", "alpha")
    task(m, "add", "flight-dep", "Still in flight", "--kind", "program", "--repo", "alpha")
    task(m, "start", "flight-dep")
    task(m, "add", "gated", "Mixed dependencies", "--kind", "ship", "--repo", "alpha", "--blocked-by", "shipped", "--blocked-by", "queued-dep", "--blocked-by", "flight-dep")
    task(m, "done", "shipped", "--keep", "0")
    # A genuinely missing dependency is an accepted backlog contract input.
    backlog_path = m / "data/backlog.md"
    body = backlog_path.read_text()
    body = body.replace("gated - Mixed dependencies", "gated - Mixed dependencies blocked-by: missing-dep")
    backlog_path.write_text(body)
    mixed = snap(m, "07-mixed-blockers")
    show(mixed, ["gated"])
    assert set(rows(mixed)["gated"]["unresolved_blocker_ids"]) == {"queued-dep", "flight-dep", "missing-dep"}
    assert "shipped" not in rows(mixed)["gated"]["unresolved_blocker_ids"]
    assert rows(mixed)["gated"]["blocked_by_ids"] == ["missing-dep", "shipped", "queued-dep", "flight-dep"]
    mixed_bearings = json.loads(run(m, ["fm-bearings-snapshot.sh", "--json"], "08-mixed-bearings.json"))
    mixed_gate = next(r for r in mixed_bearings["gates"] if r["id"] == "gated")
    assert mixed_gate["blocked_by"] == "missing-dep,queued-dep,flight-dep"
    RESULTS.append({"scenario":"Mixed blockers clear only archived work while queued, in-flight, and missing IDs still block", "result":"pass", "live":True})

    # Re-use an archived ID in the real CLI; current unfinished work wins.
    task(m, "add", "shipped", "Current work with an archived ID", "--kind", "ship", "--repo", "alpha")
    reopened = snap(m, "09-current-record-overrides-archive")
    show(reopened, ["gated", "shipped"])
    assert set(rows(reopened)["gated"]["unresolved_blocker_ids"]) == {"shipped", "queued-dep", "flight-dep", "missing-dep"}
    RESULTS.append({"scenario":"An unfinished current task with an archived ID remains unresolved", "result":"pass", "live":True})

    n = new_home("archive-isolation")
    (n / "data/backlog.md").write_text("## In flight\n\n## Queued\n- [ ] isolated - Foreign archive must not resolve this blocked-by: shipped (repo: alpha) (kind: ship)\n\n## Done\n")
    isolated = snap(n, "10-no-local-archive")
    show(isolated, ["isolated"])
    assert rows(isolated)["isolated"]["unresolved_blocker_ids"] == ["shipped"]
    overridden = snap(n, "11-data-override-own-archive", {"FM_DATA_OVERRIDE":str(h / "data")})
    show(overridden, ["follow-one", "review-follow-two"])
    assert all(rows(overridden)[i]["unresolved_blocker_ids"] == [] for i in ("follow-one", "review-follow-two"))
    RESULTS.append({"scenario":"An absent local archive keeps missing blockers open and a data override reads its own adjacent archive", "result":"pass", "live":True})
    (EVIDENCE / "archived-blocker-scenario-results.json").write_text(json.dumps(RESULTS, indent=2) + "\n")
    record("Scenario outcomes:\n" + json.dumps(RESULTS, indent=2))
except Exception as e:
    record("FAILED: " + repr(e))
    (EVIDENCE / "archived-blocker-scenario-results.json").write_text(json.dumps(RESULTS + [{"error":repr(e)}], indent=2) + "\n")
    raise
finally:
    TRANSCRIPT.close()
