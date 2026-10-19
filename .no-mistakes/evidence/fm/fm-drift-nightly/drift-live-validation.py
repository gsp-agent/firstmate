#!/usr/bin/env python3
"""Drive the shipped drift guard on disposable Git histories and homes."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path.cwd()
WORK = ROOT / ".agent-state/drift-test-phase"
EV = Path("/Users/dalecarman/.no-mistakes/evidence/01M5999CSVGBG7SM5134TYA5NC")
TARGET = "881214e1b05b1db04a216538b5fd32f95430fa72"
UPSTREAM = "7df545bf74ff729ed1733f77b0aea02a9b164ac1"
BASE = "20dcbf91520b1816663b81873ad67d0b93b3e4d6"
SCRIPT = ROOT / "bin/fm-drift-nightly.sh"
ENV = dict(os.environ)
for key in tuple(ENV):
    if key.startswith("FM_") or key in {
        "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "TASKS_AXI_FILE", "TASKS_AXI_BACKEND",
    }:
        ENV.pop(key, None)
ENV.update({
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Firstmate Validation", "GIT_AUTHOR_EMAIL": "test@example.invalid",
    "GIT_COMMITTER_NAME": "Firstmate Validation", "GIT_COMMITTER_EMAIL": "test@example.invalid",
    "TMPDIR": str(WORK / "tmp"), "LC_ALL": "C",
    "FM_HOME": str(WORK / "default-home"),
})
WORK.mkdir(parents=True, exist_ok=True)
(WORK / "tmp").mkdir(exist_ok=True)
EV.mkdir(parents=True, exist_ok=True)
RESULTS = []
TRANSCRIPT = EV / "live-commands.log"


def run(argv, expect=0, env=None, label=None, cwd=ROOT):
    argv = [str(v) for v in argv]
    cp = subprocess.run(argv, cwd=cwd, env=env or ENV, capture_output=True, text=True)
    text = "$ " + shlex.join(argv) + "\n" + cp.stdout + cp.stderr + f"[exit {cp.returncode}]\n"
    with TRANSCRIPT.open("a") as handle:
        handle.write(text)
    if label:
        (EV / label).write_text(text)
    if expect is not None and cp.returncode != expect:
        raise AssertionError(text)
    return cp


def git(repo, *args, **kw):
    return run(["git", "-C", repo, *args], **kw).stdout.strip()


def commit(repo, message, *paths):
    git(repo, "add", "--", *paths)
    git(repo, "-c", "commit.gpgsign=false", "commit", "-qm", message)
    return git(repo, "rev-parse", "HEAD")


def check(repo, label, expect=0, *args):
    return run(["bash", SCRIPT, "check", "--no-fetch", "--repo", repo,
                *args], expect=expect, label=label)


def scenario(name, fn):
    try:
        evidence = fn()
        RESULTS.append({"name": name, "result": "pass", "live": True,
                        "evidence": evidence, "reason": ""})
        print("PASS " + name, flush=True)
    except Exception as exc:
        RESULTS.append({"name": name, "result": "fail", "live": True,
                        "evidence": "live-commands.log", "reason": str(exc)})
        print("FAIL " + name + ": " + str(exc), flush=True)


def history_copy():
    bundle = WORK / "submitted-history.bundle"
    run(["git", "bundle", "create", bundle, "HEAD"])
    repo = WORK / "submitted-history"
    run(["git", "init", "-q", repo])
    git(repo, "fetch", "-q", bundle, "HEAD:refs/heads/submitted")
    git(repo, "switch", "-q", "--detach", TARGET)
    git(repo, "cat-file", "-e", UPSTREAM + "^{commit}")
    return repo


HISTORY = history_copy()


def shipped_check():
    cp = check(HISTORY, "submitted-fork-check.log", 0, "--upstream", UPSTREAM)
    lines = cp.stdout.splitlines()
    assert not any(line.startswith(("path-drift:", "carried-unproven:")) for line in lines)
    manifest = git(HISTORY, "show", TARGET + ":drift-proof.txt")
    expected = [line.split()[1:3] for line in manifest.splitlines() if line.startswith("pending: ")]
    pending = [line.split()[1:3] for line in lines if line.startswith("pending: ")]
    assert sorted(pending) == sorted(expected)
    assert len(pending) == 26 and all(bead == ".agent-config-dtjsb" for _, bead in pending)
    assert any(line.startswith("keep: " + TARGET) for line in lines)
    (EV / "submitted-fork-summary.json").write_text(json.dumps({
        "target": TARGET, "upstream": UPSTREAM,
        "counts": {prefix: sum(line.startswith(prefix + ":") for line in lines)
                   for prefix in ["path-ok", "path-drift", "carried-unproven", "pending", "keep", "unproven"]},
        "pending": expected, "exit": cp.returncode,
    }, indent=2) + "\n")
    return "submitted-fork-check.log; submitted-fork-summary.json"


scenario("Check the submitted fork: its exact accepted tree passes and every pending commit stays visible", shipped_check)


def later_edits():
    guard = HISTORY / "bin/fm-drift-nightly.sh"
    proof = HISTORY / "drift-proof.txt"
    guard.write_text(guard.read_text() + "\n# adversarial later guard edit\n")
    proof.write_text(proof.read_text() + "\n# adversarial later proof edit\n")
    later = commit(HISTORY, "adversarial later guard and proof edits", "bin/fm-drift-nightly.sh", "drift-proof.txt")
    cp = check(HISTORY, "later-guard-and-proof-drift.log", 1, "--upstream", UPSTREAM)
    assert "path-drift: bin/fm-drift-nightly.sh\n" in cp.stdout
    assert "path-drift: drift-proof.txt\n" in cp.stdout
    assert "unproven: " + later in cp.stdout
    return "later-guard-and-proof-drift.log"


scenario("Commit later edits to the guard and proof: neither file is exempt from drift detection", later_edits)


def dirty_proof():
    proof = HISTORY / "drift-proof.txt"
    later = git(HISTORY, "rev-parse", "HEAD")
    proof.write_text(proof.read_text() + later + "\n")
    check(HISTORY, "working-tree-proof-tamper.log", 1, "--upstream", UPSTREAM)
    git(HISTORY, "add", "--", "drift-proof.txt")
    cp = check(HISTORY, "staged-proof-tamper.log", 1, "--upstream", UPSTREAM)
    assert "path-drift: bin/fm-drift-nightly.sh\n" in cp.stdout
    assert "unproven: " + later in cp.stdout
    assert "keep: " + later not in cp.stdout
    return "working-tree-proof-tamper.log; staged-proof-tamper.log"


scenario("Try to approve an unproven commit through dirty or staged proof: both attempts remain red", dirty_proof)


def recover_cut():
    repo = WORK / "cut-recovery"
    run(["git", "init", "-q", repo])
    git(repo, "fetch", "-q", WORK / "submitted-history.bundle", "HEAD")
    git(repo, "switch", "-q", "--detach", BASE)
    bundle = ROOT / "archives/fork-cuts.bundle"
    run(["git", "-C", repo, "bundle", "verify", bundle], label="archive-verify.log")
    ref = "refs/heads/archive/814465e1383e1654aea41db0544c28cd1f30fa92-before-r16-proof-cuts"
    git(repo, "fetch", "-q", bundle, ref)
    sha = "b606779ed08299d160ccbb154ec7c0dc8277b9d8"
    run(["git", "-C", repo, "-c", "commit.gpgsign=false", "cherry-pick", sha], label="cut-restoration.log")
    assert git(repo, "rev-parse", "HEAD^") == BASE
    restored = git(repo, "rev-parse", "HEAD^{tree}")
    original = git(repo, "rev-parse", sha + "^{tree}")
    assert restored == original
    heads = run(["git", "bundle", "list-heads", bundle]).stdout
    assert len(heads.splitlines()) == 9
    (EV / "cut-restoration-state.json").write_text(json.dumps({
        "cut_commit": sha, "restored_parent": BASE,
        "original_tree": original, "restored_tree": restored,
        "archive_heads": heads.splitlines(),
    }, indent=2) + "\n")
    return "archive-verify.log; cut-restoration.log; cut-restoration-state.json"


scenario("Recover an archived cut into a disposable repository: the documented fetch and cherry-pick restore its original tree", recover_cut)


def make_nightly(name):
    home = WORK / name / "home"
    upstream = WORK / name / "upstream"
    repo = WORK / name / "repo"
    home.mkdir(parents=True)
    run(["git", "init", "-q", "-b", "main", upstream])
    (upstream / "base.txt").write_text("upstream\n")
    commit(upstream, "upstream baseline", "base.txt")
    run(["git", "clone", "-q", upstream, repo])
    git(repo, "remote", "rename", "origin", "kunchenguid")
    env = dict(ENV, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / "state"),
               FM_DATA_OVERRIDE=str(home / "data"), FM_CONFIG_OVERRIDE=str(home / "config"))
    return home, repo, env


def nightly(repo, home, env, log, expected):
    args = ["bash", SCRIPT, "nightly", "--repo", repo, "--log", log]
    with log.open("a") as output:
        cp = subprocess.run([str(v) for v in args], env=env, cwd=ROOT,
                            stdout=output, stderr=subprocess.STDOUT, text=True)
    with TRANSCRIPT.open("a") as output:
        output.write("$ " + shlex.join([str(v) for v in args]) + f" >> {log}\n[exit {cp.returncode}]\n")
    assert cp.returncode == expected, log.read_text()


def nightly_notes():
    home, repo, env = make_nightly("nightly-green-red")
    log = EV / "nightly-green-red.log"
    nightly(repo, home, env, log, 0)
    assert len(list((home / "state/inbox").glob("*.note"))) == 0
    (repo / "unexpected.txt").write_text("unproven\n")
    commit(repo, "unproven nightly change", "unexpected.txt")
    nightly(repo, home, env, log, 1)
    nightly(repo, home, env, log, 1)
    notes = list((home / "state/inbox").glob("*.note"))
    assert len(notes) == 1
    note = notes[0].read_text()
    assert "path-drift: unexpected.txt\n" in note
    assert str(log) in note
    (EV / "nightly-red-inbox.note").write_text(note)
    queue = (home / "state/.wake-queue").read_text()
    assert len(queue.splitlines()) == 1, queue
    (EV / "nightly-red-wake-queue.tsv").write_text(queue)
    assert log.read_text().count("run: ") == 3
    assert "exit: 0\n" in log.read_text() and log.read_text().count("exit: 1\n") == 2
    run(["bash", ROOT / "bin/fm-inbox.sh", "receipts", "--all-pending"], env=env, label="nightly-inbox-receipts.json.log")
    return "nightly-green-red.log; nightly-red-inbox.note; nightly-red-wake-queue.tsv; nightly-inbox-receipts.json.log"


scenario("Run the nightly command green, red, and red again: logs persist and only one same-day inbox note and wake are created", nightly_notes)


def nightly_error():
    home, repo, env = make_nightly("nightly-error")
    git(repo, "remote", "remove", "kunchenguid")
    log = EV / "nightly-check-error.log"
    nightly(repo, home, env, log, 2)
    notes = list((home / "state/inbox").glob("*.note"))
    assert len(notes) == 1
    note = notes[0].read_text()
    assert "error: kunchenguid remote is missing" in note
    assert "exit 2" in note
    (EV / "nightly-error-inbox.note").write_text(note)
    return "nightly-check-error.log; nightly-error-inbox.note"


scenario("Run nightly when its upstream remote is missing: exit 2 is logged and delivered as a red inbox note", nightly_error)


def pending_merge():
    repo = WORK / "accepted-merge"
    run(["git", "init", "-q", "-b", "main", repo])
    (repo / "base.txt").write_text("base\n")
    base = commit(repo, "merge baseline", "base.txt")
    git(repo, "branch", "upstream")
    git(repo, "switch", "-q", "-c", "side")
    (repo / "side.txt").write_text("carried change\n")
    side = commit(repo, "carried custom commit", "side.txt")
    git(repo, "switch", "-q", "main")
    git(repo, "-c", "commit.gpgsign=false", "merge", "-q", "--no-ff", "-m", "accepted merge", "side")
    merge = git(repo, "rev-parse", "HEAD")
    proof = repo / "proof.txt"
    proof.write_text(merge + "\n")
    cp = check(repo, "carried-unproven-refused.log", 1, "--upstream", "upstream", "--proof", proof)
    assert "carried-unproven: " + side in cp.stdout
    proof.write_text(merge + "\npending: " + side + " .agent-config-dtjsb\n")
    cp = check(repo, "carried-pending-visible.log", 0, "--upstream", "upstream", "--proof", proof)
    assert "pending: " + side + " .agent-config-dtjsb carried custom commit" in cp.stdout
    assert "keep: " + side not in cp.stdout
    return "carried-unproven-refused.log; carried-pending-visible.log"


scenario("Accept a merge carrying an unlisted commit: it fails until that commit is explicitly pending with its named bead", pending_merge)

(EV / "live-scenarios.json").write_text(json.dumps(RESULTS, indent=2) + "\n")
sys.exit(1 if any(r["result"] == "fail" for r in RESULTS) else 0)
