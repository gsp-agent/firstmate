#!/usr/bin/env bash
# Task-evidence offload tests; transports stay local, including macOS openrsync checks.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-offload-tests)
test_pid=''
cleanup() {
  if [ -n "$test_pid" ]; then
    kill -TERM "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
python3 - "$ROOT" "$TMP_ROOT" <<'PY' &
import atexit
from datetime import date, timedelta
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tarfile
import time

code, base = map(Path, sys.argv[1:])
active = None

def stop():
    global active
    if active is not None:
        try:
            os.killpg(active.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        active.wait()
        active = None

atexit.register(stop)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))

fake = base / "fakebin"
fake.mkdir()
shim = '''#!/usr/bin/env python3
import json, os, pathlib, runpy, shutil, sys, time
p = pathlib.Path
home = p(os.environ["FM_HOME"])
tool = p(sys.argv[0]).name
with (home / "calls").open("a") as log:
    log.write(tool + "\\n")
mode = os.environ.get("OFFLOAD_FAULT", "")
def remote(name):
    return home / "remote" / name.removeprefix("mini-ts:").lstrip("/")
if tool == "ssh":
    request = json.load(sys.stdin)
    if mode == "mini-unreachable":
        with (home / "archives-seen").open("a") as seen:
            seen.writelines(path.name + "\\n" for path in (home / "data/task-one").glob(".firstmate-offload-*"))
        sys.exit(255)
    path = remote(request["destination"])
    if mode == "remote-failed":
        sys.exit(9)
    if request["action"] == "ready":
        print(json.dumps({"ready": True}))
    elif request["action"] == "prepare":
        path.parent.mkdir(parents=True, exist_ok=True)
        helper = runpy.run_path(os.environ["OFFLOAD_HELPER"])
        print(json.dumps(helper["offload_prepare"](path, request["expected"])))
    else:
        result = runpy.run_path(os.environ["OFFLOAD_HELPER"])["offload_manifest"](path)
        if mode == "remote-mismatch":
            result["checksum"] = "0" * 64
        print(json.dumps(result))
elif tool == "rsync":
    if mode == "copy-failed":
        sys.exit(8)
    source, target = p(sys.argv[-2]), remote(sys.argv[-1])
    if os.environ.get("OFFLOAD_REAL_RSYNC") == "1":
        # openrsync starts its local receiver via PATH; keep that receiver real too.
        os.environ["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        os.execv("/usr/bin/rsync", ["/usr/bin/rsync", *sys.argv[1:-1], str(target)])
    if mode in ("copy-partial", "copy-wrong"):
        if source.is_dir():
            target.mkdir(exist_ok=True)
            if mode == "copy-wrong":
                shutil.copytree(source, target / source.name)
            else:
                (target / "evidence.bin").write_bytes(b"partial")
        else:
            target.write_bytes(b"x" * (source.stat().st_size if mode == "copy-wrong" else 3))
            shutil.copystat(source, target)
        sys.exit(8)
    if source.is_dir():
        # Apple's openrsync nests the named directory without a trailing slash.
        target.mkdir(exist_ok=True)
        destination = target if sys.argv[-2].endswith("/") else target / source.name
        shutil.copytree(source, destination, copy_function=shutil.copy2, dirs_exist_ok=True)
    else:
        shutil.copy2(source, target)
    if mode == "source-changed":
        leaf = next(source.rglob("*.bin")) if source.is_dir() else source
        leaf.write_bytes(b"changed after copy")
elif tool == "backup":
    request = json.load(sys.stdin)
    if mode == "backup-failed" or (mode == "second-backup-failed" and p(request["original"]).name == "z.bin"):
        sys.exit(7)
    if mode == "backup-hang":
        (home / "backup-started").write_text("started")
        time.sleep(600)
    source = remote(request["location"])
    target = home / "independent-backup" / request["checksum"]
    if not target.exists():
        target.parent.mkdir(exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, copy_function=shutil.copy2)
        else:
            shutil.copy2(source, target)
    result = runpy.run_path(os.environ["OFFLOAD_HELPER"])["offload_manifest"](target)
    result.update(independent=True, location="backup-host:" + str(target))
    if mode == "backup-mismatch":
        result["checksum"] = "f" * 64
    print(json.dumps(result))
elif tool == "trash":
    (home / "trash-stdin").write_text(sys.stdin.read())
    source = p(sys.argv[-1])
    trash = home / "Trash"
    trash.mkdir(exist_ok=True)
    source.rename(trash / source.name)
    if mode == "trash-interrupted":
        sys.exit(6)
elif tool == "dcg":
    json.load(sys.stdin)
    if mode == "dcg-deny":
        print(json.dumps({"hookSpecificOutput":{"permissionDecision":"deny"}}))
else:
    sys.exit(88)
'''
for name in ("ssh", "rsync", "backup", "dcg"):
    path = fake / name
    path.write_text(shim)
    path.chmod(0o755)
# Offload must reach Trash only through FM_TASK_DATA_TRASH (production:
# /usr/bin/trash). The `trash` earlier on PATH stands for Homebrew's, whose -s
# securely empties the Trash after reading a y from stdin.
(fake / "safe").mkdir()
(fake / "safe/trash").write_text(shim)
(fake / "safe/trash").chmod(0o755)
(fake / "trash").write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
home = pathlib.Path(os.environ["FM_HOME"])
with (home / "calls").open("a") as log:
    log.write("path-trash\\n")
if sys.stdin.readline().strip().lower() == "y" and (home / "Trash").exists():
    shutil.rmtree(home / "Trash")
    (home / "Trash-emptied").write_text("emptied")
sys.exit(1)
''')
(fake / "trash").chmod(0o755)

def fixture(name, *, status="closed", days=10, configured=True):
    home = base / name
    for directory in ("data/task-one/build", "state", "config", "user"):
        (home / directory).mkdir(parents=True)
    (home / ".tasks.toml").write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\n')
    closed = (date.today() - timedelta(days=days)).isoformat()
    row = f"- [{'x' if status == 'closed' else ' '}] task-one - fixture (repo: example) (closed {closed})\n"
    (home / "data/backlog.md").write_text(row)
    if status == "in-progress":
        (home / "state/task-one.meta").write_text("kind=ship\n")
    task = home / "data/task-one"
    (task / "report.md").write_text("Evidence: [build](build/).\n")
    (task / "build/evidence.bin").write_bytes(b"original-evidence" * 256)
    (task / "build/empty").mkdir()
    if configured:
        (home / "config/task-data-offload.json").write_text(json.dumps({"backup_verifier": [str(fake / "backup")]}))
    return home

def run(home, action, *, fault="", ok=True, real_rsync=False, raw=False, task=("task-one",), stdin="", interrupt=None):
    global active
    env = dict(os.environ, HOME=str(home / "user"), FM_HOME=str(home), PATH=str(fake) + os.pathsep + os.environ["PATH"],
               OFFLOAD_HELPER=str(code / "bin/fm-task-data.py"), OFFLOAD_FAULT=fault, FM_TASK_DATA_SWEEP="off",
               OFFLOAD_REAL_RSYNC="1" if real_rsync else "0", FM_TASK_DATA_TRASH=str(fake / "safe/trash"))
    for name in ("TASKS_AXI_BACKEND", "TASKS_AXI_FILE", "TASKS_AXI_ROOT", "BEADS_DIR", "BEADS_DB", "BR_DB"):
        env.pop(name, None)
    command = ["bash", str(code / "bin/fm-task-data-lib.sh"), action, str(home / "data"), str(home / "state"), *task]
    active = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, start_new_session=True)
    try:
        if interrupt:
            # Stop the run with TERM, as a terminal or supervisor would, once it reaches the marker.
            deadline = time.monotonic() + 60
            while not interrupt.exists():
                assert time.monotonic() < deadline and active.poll() is None, "the run never reached its interrupt point"
                time.sleep(0.05)
            os.killpg(active.pid, signal.SIGTERM)
        stdout, stderr = active.communicate(stdin, timeout=120)
        rc = active.returncode
    finally:
        stop()
    assert (rc == 0) == ok, (command, rc, stdout, stderr)
    if raw:
        return stdout, stderr
    return (stdout if action == "expire" else json.loads(stdout)) if rc == 0 else stderr

def tree(home):
    return sorted((str(path.relative_to(home)), "directory" if path.is_dir() else "file",
                   None if path.is_dir() else path.stat().st_size,
                   None if path.is_dir() else path.stat().st_mtime_ns)
                  for directory in (home / "data", home / "state") for path in directory.rglob("*"))

def copy_fixture(name, kind):
    home = fixture(name)
    source = home / "data/task-one" / ("build" if kind == "directory" else "solo.bin")
    if kind == "file":
        source.write_bytes(b"single-file-evidence" * 256)
        (source.parent / "report.md").write_text("Evidence: [file](solo.bin).\n")
    return home, source

def check_placement(kind, real_rsync=False):
    home, source = copy_fixture(("real-" if real_rsync else "fake-") + kind, kind)
    result = run(home, "offload", real_rsync=real_rsync)
    pointer = json.loads(source.read_text())
    payload = home / "remote" / pointer["location"].removeprefix("mini-ts:").lstrip("/")
    assert len(result["offloaded"]) == 1
    if kind == "directory":
        assert (payload / "evidence.bin").read_bytes() == b"original-evidence" * 256
        assert (payload / "empty").is_dir() and not (payload / "build").exists()
    else:
        assert payload.is_file() and payload.read_bytes() == b"single-file-evidence" * 256

def check_retry(kind, fault):
    home, source = copy_fixture(kind + "-" + fault, kind)
    original = tree(home)
    run(home, "offload", fault=fault, ok=False)
    assert tree(home) == original and not (home / "Trash").exists()
    payload = next((home / "remote").rglob("payload"))
    wrong_file = payload / ("build/evidence.bin" if fault == "copy-wrong" else "evidence.bin") if kind == "directory" else payload
    wrong_bytes = wrong_file.read_bytes()
    result = run(home, "offload")
    assert len(result["offloaded"]) == 1
    preserved = list(payload.parent.glob("incomplete-*/payload"))
    assert len(preserved) == 1, "a mismatched payload must be preserved before retrying"
    saved_file = preserved[0] / wrong_file.relative_to(payload) if kind == "directory" else preserved[0]
    assert saved_file.read_bytes() == wrong_bytes
    calls = (home / "calls").read_text()
    assert run(home, "offload")["offloaded"] == []
    assert (home / "calls").read_text() == calls

def check_verified_reuse():
    home, _ = copy_fixture("verified-reuse", "file")
    run(home, "offload", fault="backup-failed", ok=False)
    copies = (home / "calls").read_text().splitlines().count("rsync")
    assert len(run(home, "offload")["offloaded"]) == 1
    assert (home / "calls").read_text().splitlines().count("rsync") == copies

def check_partial_report():
    home = fixture("partial-report")
    task = home / "data/task-one"
    (task / "a.bin").write_bytes(b"first-evidence")
    (task / "z.bin").write_bytes(b"second-evidence")
    (task / "report.md").write_text("Evidence: [first](a.bin) and [second](z.bin).\n")
    stdout, _ = run(home, "offload", fault="second-backup-failed", ok=False, raw=True)
    result = json.loads(stdout)
    assert [item["path"] for item in result["offloaded"]] == ["a.bin"]
    assert result["total_bytes"] == len(b"first-evidence")
    assert result["failed"]["task"] == "task-one" and result["failed"]["path"] == "z.bin" and result["failed"]["reason"]
    assert json.loads((task / "a.bin").read_text())["format"] == "firstmate-task-evidence-v1"
    assert (task / "z.bin").read_bytes() == b"second-evidence"
    assert [item["path"] for item in run(home, "offload")["offloaded"]] == ["z.bin"]

def git(*args):
    env = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    env.update(GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_NAME="Fixture",
               GIT_COMMITTER_EMAIL="fixture@example.invalid", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    # Detached auto-maintenance would write lock files while a check snapshots the tree.
    return subprocess.run(["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0", *map(str, args)],
                          env=env, check=True, capture_output=True, text=True).stdout.strip()

FORGE = "https://forge.example.invalid/o/r.git"

def forge(home, repository):
    # Test-only rewrite: production classifies the configured forge URL while
    # the transport stays on this disk.
    git("--git-dir", repository, "config", f"url.{home / 'user/forge.git'}.insteadOf", FORGE)

def commit(tree, name, text):
    (tree / name).write_text(text)
    git("-C", tree, "add", name)
    git("-C", tree, "commit", "-q", "-m", text.strip())

def repo_fixture(name, *, remote="forge"):
    home = fixture(name)
    task = home / "data/task-one"
    (task / "report.md").write_text("Completed.\n")
    bare = {"forge": home / "user/forge.git", "inside": task / "origin.git",
            "gate": home / "user/.no-mistakes/repos/0123456789ab.git"}[remote]
    clone = task / "clone"
    git("init", "-q", "--bare", "-b", "main", bare)
    git("init", "-q", "-b", "main", clone)
    (clone / ".gitignore").write_text("*.log\n")
    git("-C", clone, "add", ".gitignore")
    commit(clone, "work.txt", "pushed work\n")
    if remote == "forge":
        forge(home, clone / ".git")
    name = "no-mistakes" if remote == "gate" else "origin"
    git("-C", clone, "remote", "add", name, FORGE if remote == "forge" else bare)
    git("-C", clone, "push", "-q", "-u", name, "main")
    return home, clone

def snapshot(path):
    entries = {}
    for item in sorted(path.rglob("*")):
        rel = str(item.relative_to(path))
        if item.is_symlink():
            entries[rel] = ("link", os.readlink(item))
        elif item.is_dir():
            entries[rel] = ("directory", item.stat().st_mode & 0o777)
        else:
            entries[rel] = ("file", item.stat().st_mode & 0o777, item.read_bytes())
    return entries

def restored(home, pointer, name):
    assert pointer["archive"] == "tar" and pointer["location"].startswith("mini-ts:/Volumes/MINI-DATA/"), pointer
    payload = home / "remote" / pointer["location"].removeprefix("mini-ts:").lstrip("/")
    with tarfile.open(payload) as archive:
        archive.extractall(home / "restored", filter="tar")
    return snapshot(home / "restored" / name)

def unproven_fixture(variant, name=""):
    remote = {"remote-inside": "inside", "gate-only": "gate"}.get(variant, "forge")
    home, clone = repo_fixture(name or "repo-" + variant, remote=remote)
    if variant == "unpushed":
        (clone / "work.txt").write_text("unpushed work\n")
        git("-C", clone, "commit", "-q", "-am", "unpushed work")
    elif variant == "dirty":
        (clone / "work.txt").write_text("uncommitted edit\n")
    elif variant == "untracked":
        (clone / "notes.txt").write_text("untracked notes\n")
    elif variant == "ignored":
        (clone / "run.log").write_text("ignored output\n")
    elif variant == "stash":
        (clone / "work.txt").write_text("stashed edit\n")
        git("-C", clone, "stash", "-q")
    elif variant == "dropped-stash":
        (clone / "work.txt").write_text("stashed then dropped\n")
        git("-C", clone, "stash", "-q")
        git("-C", clone, "stash", "drop", "-q")
    elif variant == "unpushed-tag":
        git("-C", clone, "tag", "-a", "v1", "-m", "release notes kept only here")
    elif variant == "unfinished-rebase":
        commit(clone, "more.txt", "pushed second commit\n")
        git("-C", clone, "push", "-q", "origin", "main")
        try:
            git("-C", clone, "rebase", "-q", "--exec", "false", "HEAD~1")
        except subprocess.CalledProcessError:
            pass
        assert (clone / ".git/rebase-merge").is_dir()
    elif variant == "depopulated-submodule":
        seed, sub = home / "user/sub-seed", home / "user/sub.git"
        git("init", "-q", "--bare", "-b", "main", sub)
        git("init", "-q", "-b", "main", seed)
        commit(seed, "sub.txt", "pushed submodule work\n")
        git("-C", seed, "push", "-q", sub, "main")
        git("-C", clone, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "vendor/x")
        git("-C", clone, "commit", "-q", "-m", "add submodule")
        git("-C", clone, "push", "-q", "origin", "main")
        commit(clone / "vendor/x", "sub.txt", "unpushed submodule work\n")
        git("-C", clone, "submodule", "deinit", "-q", "-f", "vendor/x")
    elif variant in ("skip-worktree", "assume-unchanged"):
        git("-C", clone, "update-index", "--" + variant, "work.txt")
        (clone / "work.txt").write_text("edit status cannot see\n")
    elif variant == "unreadable":
        (clone / ".git/HEAD").write_text("unverified work\n")
    return home, clone

def check_proven_removed():
    home, clone = repo_fixture("repo-proven")
    head = git("-C", clone, "rev-parse", "HEAD")
    plan = run(home, "offload-plan")
    assert [(move["path"], move.get("repository")) for move in plan["moves"]] == [("clone", True)], plan
    result = run(home, "offload")
    assert [(item["path"], item.get("removed")) for item in result["offloaded"]] == [("clone", True)], result
    pointer = json.loads(clone.read_text())
    assert pointer["format"] == "firstmate-task-evidence-v1" and pointer["remotes"] == [FORGE], pointer
    assert pointer["head"] == head and "location" not in pointer, pointer
    assert git("--git-dir", home / "Trash/clone/.git", "rev-parse", "HEAD") == head
    calls = (home / "calls").read_text().splitlines()
    assert "rsync" not in calls and "backup" not in calls, calls
    assert run(home, "offload")["offloaded"] == []
    assert (home / "calls").read_text().splitlines() == calls, "a removed repository's pointer was offloaded again"

def check_unproven_archived(variant):
    home, clone = unproven_fixture(variant)
    before = snapshot(clone)
    result = run(home, "offload")
    assert "clone" in [item["path"] for item in result["offloaded"]], result
    pointer = json.loads(clone.read_text())
    assert "removed" not in pointer, pointer
    assert restored(home, pointer, "clone") == before, "the offloaded archive does not restore the repository exactly"
    assert snapshot(home / "Trash/clone") == before
    assert any((home / "independent-backup").iterdir())
    assert not list((home / "data/task-one").glob(".firstmate-offload-*")), "the local archive copy was left behind"

def check_refused_repository_kept():
    home, clone = unproven_fixture("unpushed", "repo-refused")
    before = snapshot(clone)
    run(home, "offload", fault="backup-failed", ok=False)
    assert snapshot(clone) == before and not (home / "Trash").exists()
    assert not list((home / "data/task-one").glob(".firstmate-offload-*")), "a refused round left its archive copy"
    assert [item["path"] for item in run(home, "offload")["offloaded"]] == ["clone"]

def check_unreachable_mini_writes_no_archive():
    home, clone = unproven_fixture("unpushed", "repo-unreachable")
    before = snapshot(clone)
    run(home, "offload", fault="mini-unreachable", ok=False)
    assert (home / "archives-seen").read_text() == "", "an archive was written before mini-ts answered"
    assert snapshot(clone) == before and not (home / "Trash").exists()
    assert not list((home / "data/task-one").glob(".firstmate-offload-*"))
    assert [item["path"] for item in run(home, "offload")["offloaded"]] == ["clone"]

def check_lanes_join_their_repository(variant):
    home = fixture("repo-lanes-" + variant)
    task = home / "data/task-one"
    (task / "report.md").write_text("Completed.\n")
    git("init", "-q", "--bare", "-b", "main", home / "user/forge.git")
    heru, lane = task / "set/laptop/heru", task / "set/lanes/own"
    git("init", "-q", "-b", "main", heru)
    forge(home, heru / ".git")
    commit(heru, "work.txt", "pushed work\n")
    git("-C", heru, "remote", "add", "origin", FORGE)
    git("-C", heru, "push", "-q", "-u", "origin", "main")
    git("-C", heru, "worktree", "add", "-q", "-b", "lane", lane)
    commit(lane, "lane.txt", "pushed lane work\n")
    git("-C", lane, "push", "-q", "-u", "origin", "lane")
    if variant == "untracked":
        (lane / "notes.txt").write_text("untracked lane notes\n")
    before = snapshot(task / "set")
    plan = run(home, "offload-plan")
    assert [(move["path"], move.get("repository")) for move in plan["moves"]] == [("set", True)], plan
    result = run(home, "offload")
    pointer = json.loads((task / "set").read_text())
    if variant == "pushed":
        assert [(item["path"], item.get("removed")) for item in result["offloaded"]] == [("set", True)], result
        assert pointer["remotes"] == [FORGE], pointer
    else:
        assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("set", "tar")], result
        assert restored(home, pointer, "set") == before
    assert snapshot(home / "Trash/set") == before

def bare_clone(name):
    home = fixture(name)
    task = home / "data/task-one"
    (task / "report.md").write_text("Completed.\n")
    seed = home / "user/seed"
    git("init", "-q", "--bare", "-b", "main", home / "user/forge.git")
    git("init", "-q", "-b", "main", seed)
    commit(seed, "work.txt", "pushed work\n")
    git("-C", seed, "push", "-q", home / "user/forge.git", "main")
    repo = task / "repo.git"
    git("clone", "-q", "--bare", home / "user/forge.git", repo)
    git("--git-dir", repo, "remote", "set-url", "origin", FORGE)
    forge(home, repo)
    return home, repo

def check_bare_worktree_inside_archived():
    home, repo = bare_clone("repo-bare-worktree")
    git("--git-dir", repo, "worktree", "add", "-q", repo / "wt", "main")
    (repo / "wt/work.txt").write_text("uncommitted edit\n")
    (repo / "wt/notes.txt").write_text("untracked work\n")
    before = snapshot(repo)
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("repo.git", "tar")], result
    assert restored(home, json.loads(repo.read_text()), "repo.git") == before

def check_git_dir_stray_archived(kind):
    if kind == "bare":
        home, repo = bare_clone("repo-git-dir-stray-bare")
        git_dir = repo
    else:
        home, repo = repo_fixture("repo-git-dir-stray-work-tree")
        git_dir = repo / ".git"
    (git_dir / "notes.md").write_text("notes a tool wrote inside the git directory\n")
    before = snapshot(repo)
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [(repo.name, "tar")], result
    assert restored(home, json.loads(repo.read_text()), repo.name) == before

def check_outside_parent_worktree_archived():
    home = fixture("repo-outside-parent")
    (home / "data/task-one/report.md").write_text("Completed.\n")
    main = home / "user/main"
    git("init", "-q", "-b", "main", main)
    commit(main, "work.txt", "parent work\n")
    worktree = home / "data/task-one/wt"
    git("-C", main, "worktree", "add", "-q", "-b", "side", worktree)
    (worktree / "notes.txt").write_text("worktree notes\n")
    before, parent = snapshot(worktree), snapshot(main)
    plan = run(home, "offload-plan")
    assert [(move["path"], move.get("repository")) for move in plan["moves"]] == [("wt", True)], plan
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("wt", "tar")], result
    assert restored(home, json.loads(worktree.read_text()), "wt") == before
    assert snapshot(main) == parent, "offload edited the parent repository"
    assert "prunable" in git("-C", main, "worktree", "list", "--porcelain").split()

def check_other_task_worktree_kept():
    home = fixture("repo-other-task-worktree")
    (home / "data/task-one/report.md").write_text("Completed.\n")
    main = home / "data/task-two/main"
    git("init", "-q", "-b", "main", main)
    commit(main, "work.txt", "other task's work\n")
    worktree = home / "data/task-one/wt"
    git("-C", main, "worktree", "add", "-q", "-b", "side", worktree)
    before = snapshot(worktree)
    plan = run(home, "offload-plan")
    assert plan["moves"] == [] and [(item.get("path"), item["reason"]) for item in plan["retained"]] == [
        ("wt", "linked worktree of a repository in another task")], plan
    assert run(home, "offload")["offloaded"] == []
    assert snapshot(worktree) == before and not (home / "calls").exists()

def check_interrupted_offload_releases_lock():
    home = fixture("interrupted-lock")
    run(home, "offload", fault="backup-hang", ok=False, interrupt=home / "backup-started")
    lock = home / "state/.meta-task-one.lock"
    assert not (lock.exists() or lock.is_symlink()), "an offload stopped with TERM left the task meta lock held"
    assert [move["path"] for move in run(home, "offload-plan")["moves"]] == ["build"]
    assert [item["path"] for item in run(home, "offload")["offloaded"]] == ["build"]

def check_trash_never_empties():
    home = fixture("trash-on-path")
    (home / "Trash").mkdir()
    (home / "Trash/earlier.bin").write_bytes(b"recoverable for 24 hours")
    run(home, "offload", stdin="y\n")
    assert "path-trash" not in (home / "calls").read_text().splitlines(), "offload ran the trash found on PATH"
    assert not (home / "Trash-emptied").exists() and (home / "Trash/earlier.bin").is_file()
    assert (home / "Trash/build/evidence.bin").is_file()
    assert (home / "trash-stdin").read_text() == "", "the Trash command could read the caller's stdin"

def check_sweep_offloads(configured):
    home = fixture("sweep-" + ("configured" if configured else "unconfigured"), configured=configured)
    run(home, "sweep", raw=True, task=())
    build = home / "data/task-one/build"
    if configured:
        assert json.loads(build.read_text())["format"] == "firstmate-task-evidence-v1"
        assert (home / "Trash/build/evidence.bin").is_file()
    else:
        assert (build / "evidence.bin").read_bytes() == b"original-evidence" * 256
        assert not (home / "calls").exists(), "an unconfigured sweep contacted the remote"

# Collect the independent review regressions so a broken directory copy cannot
# hide the single-file, retry, or partial-report result on the reviewed head.
regressions = [("fake directory placement", lambda: check_placement("directory")),
               ("fake single-file placement", lambda: check_placement("file"))]
for kind in ("directory", "file"):
    for fault in ("copy-partial", "copy-wrong"):
        regressions.append((kind + " retries " + fault, lambda kind=kind, fault=fault: check_retry(kind, fault)))
regressions.extend([("verified existing payload is reused", check_verified_reuse),
                    ("partial round reports completed moves", check_partial_report),
                    ("a repository proven on its remote is removed with a pointer", check_proven_removed)])
for variant in ("unpushed", "dirty", "untracked", "ignored", "stash", "dropped-stash", "unpushed-tag",
                "unfinished-rebase", "depopulated-submodule", "skip-worktree", "assume-unchanged",
                "remote-inside", "gate-only", "unreadable"):
    regressions.append(("a repository with " + variant + " work is offloaded whole and restores exactly",
                        lambda variant=variant: check_unproven_archived(variant)))
regressions.extend([("a refused repository offload keeps the repository and no archive copy", check_refused_repository_kept),
                    ("an unreachable mini writes no archive and the next pass offloads", check_unreachable_mini_writes_no_archive),
                    ("a repository and its proven lanes in the task are removed as one folder",
                     lambda: check_lanes_join_their_repository("pushed")),
                    ("a repository and a lane with untracked work are offloaded whole as one folder",
                     lambda: check_lanes_join_their_repository("untracked")),
                    ("a bare clone with a dirty worktree inside it is offloaded whole", check_bare_worktree_inside_archived),
                    ("a bare clone with a stray file in its git directory is offloaded whole",
                     lambda: check_git_dir_stray_archived("bare")),
                    ("a clone with a stray file in its .git is offloaded whole",
                     lambda: check_git_dir_stray_archived("work-tree")),
                    ("a worktree of a repository outside DATA is offloaded whole as files", check_outside_parent_worktree_archived),
                    ("a worktree of a repository in another task stays", check_other_task_worktree_kept),
                    ("an offload stopped with TERM releases the task meta lock", check_interrupted_offload_releases_lock),
                    ("offload never runs a trash from PATH or feeds it stdin", check_trash_never_empties),
                    ("a sweep ends with an offload pass", lambda: check_sweep_offloads(True)),
                    ("a sweep in a home without a verifier offloads nothing", lambda: check_sweep_offloads(False))])
if sys.platform == "darwin":
    regressions.extend([("real /usr/bin/rsync directory placement", lambda: check_placement("directory", True)),
                        ("real /usr/bin/rsync single-file placement", lambda: check_placement("file", True))])
failures = []
for name, check in regressions:
    try:
        check()
        print("PASS: " + name, flush=True)
    except (AssertionError, ValueError, OSError, StopIteration, KeyError, TypeError, subprocess.SubprocessError) as error:
        failures.append(name)
        print("FAIL: " + name + ": " + str(error), flush=True)
assert not failures, failures

home = fixture("closed")
before = tree(home)
plan = run(home, "offload-plan")
assert len(plan["moves"]) == 1 and plan["moves"][0]["path"] == "build", plan
assert plan["total_bytes"] == len(b"original-evidence" * 256)
assert tree(home) == before and not (home / "calls").exists(), "plan wrote or used a remote tool"
result = run(home, "offload")
pointer = json.loads((home / "data/task-one/build").read_text())
assert pointer["format"] == "firstmate-task-evidence-v1" and pointer["location"].startswith("mini-ts:/Volumes/MINI-DATA/")
assert pointer["size"] == plan["total_bytes"] and len(pointer["checksum"]) == 64
assert (home / "Trash/build/evidence.bin").read_bytes() == b"original-evidence" * 256
assert (home / "data/task-one/report.md").is_file()
assert len(result["offloaded"]) == 1
calls = (home / "calls").read_text()
assert run(home, "offload")["offloaded"] == []
assert (home / "calls").read_text() == calls, "no-op rerun contacted remote or Trash"
print("PASS: closed-over-seven-days offloads, checksums both copies, keeps Trash and leaves an exact-path pointer; rerun is a no-op", flush=True)

(home / "data/task-one/report.md").write_text("The report no longer names its old evidence path.\n")
(home / "data/task-one/record/data-cleanup.json").write_text(json.dumps({
    "version": 1, "task": "task-one", "complete": False, "sources": [{
        "project": str(home), "pr": "", "beads": [], "backlog": {"data": str(home / "data"), "task": None}}]}))
run(home, "expire")
assert json.loads((home / "data/task-one/build").read_text()) == pointer
assert json.loads((home / "data/task-one/record/data-cleanup.json").read_text())["expired"] is True
print("PASS: normal scratch expiry preserves the pointer after its report reference is removed", flush=True)

for name, status, days in (("open", "open", 10), ("in-progress", "in-progress", 10), ("recent", "closed", 6), ("boundary", "closed", 7)):
    home = fixture(name, status=status, days=days)
    original = tree(home)
    assert run(home, "offload-plan")["moves"] == []
    run(home, "offload", ok=False)
    assert tree(home) == original and not (home / "calls").exists()
print("PASS: open, in-progress, recent and date-only seven-day boundary tasks stay untouched", flush=True)

home = fixture("reopened", status="open")
(home / "data/done-archive.md").write_text("- [x] task-one - fixture (repo: example) (closed 2020-01-01)\n")
assert not run(home, "offload-plan")["moves"]
run(home, "offload", ok=False)
print("PASS: current open row wins over an old archived completion without live metadata", flush=True)

home = fixture("held-repository")
(home / "data/task-one/.cleanup-hold/clone/.git").mkdir(parents=True)
assert not run(home, "offload-plan")["moves"]
run(home, "offload", ok=False)
assert (home / "data/task-one/build/evidence.bin").is_file()
print("PASS: repository work in the scratch recovery hold blocks offload too", flush=True)

home = fixture("no-backup", configured=False)
original = tree(home)
assert run(home, "offload-plan")["moves"]
run(home, "offload", ok=False)
assert tree(home) == original and not (home / "calls").exists()
print("PASS: missing independent backup verifier refuses before remote calls or local writes", flush=True)

for fault in ("remote-failed", "copy-failed", "remote-mismatch", "backup-failed", "backup-mismatch", "dcg-deny"):
    home = fixture(fault)
    original = (home / "data/task-one/build/evidence.bin").read_bytes()
    run(home, "offload", fault=fault, ok=False)
    assert (home / "data/task-one/build/evidence.bin").read_bytes() == original
    assert not (home / "Trash").exists()
print("PASS: failed or mismatched remote/backup copies and denied Trash preserve original bytes", flush=True)

home = fixture("changed")
run(home, "offload", fault="source-changed", ok=False)
assert (home / "data/task-one/build/evidence.bin").read_bytes() == b"changed after copy"
assert not (home / "Trash").exists()
print("PASS: source changes after copying refuse Trash", flush=True)

home = fixture("interrupted")
run(home, "offload", fault="trash-interrupted", ok=False)
assert not (home / "data/task-one/build").exists()
assert (home / "Trash/build/evidence.bin").is_file()
run(home, "offload")
assert json.loads((home / "data/task-one/build").read_text())["backup"].startswith("backup-host:")
assert (home / "calls").read_text().splitlines().count("trash") == 1
print("PASS: interruption after Trash recovers pointer only after reverifying both copies", flush=True)

home = fixture("incidental-only")
(home / "data/task-one/report.md").write_text("Completed without linked evidence.\n")
(home / "data/task-one/brief.md").write_text("Inspect [build](build/) while working.\n")
(home / "data/task-one/build.log").write_text("Output directory: build/\n")
with (home / "data/backlog.md").open("a") as stream:
    stream.write("  A work note mentions [build](build/).\n")
plan = run(home, "offload-plan")
assert plan["moves"] == [], "incidental brief, log or backlog path mentions must not authorize offload"
original = tree(home)
assert run(home, "offload")["offloaded"] == []
assert tree(home) == original, "a no-candidate offload must not create task directories"
assert (home / "data/task-one/build/evidence.bin").read_bytes() == b"original-evidence" * 256
assert not (home / "calls").exists()
print("PASS: brief-only, log-only and backlog-prose-only path mentions do not authorize offload", flush=True)

for locator in ("report", "row", "saved"):
    home = fixture("bead-only-" + locator)
    (home / "data/task-one/report.md").write_text("Completed.\n")
    if locator == "report":
        (home / "data/task-one/report.md").write_text("Bead: .agent-config-fixture\n")
    elif locator == "row":
        with (home / "data/backlog.md").open("a") as stream:
            stream.write("  Bead: .agent-config-fixture\n")
    else:
        (home / "data/task-one/record").mkdir()
        (home / "data/task-one/record/data-cleanup.json").write_text(json.dumps({
            "version": 1, "task": "task-one", "sources": [{"beads": [".agent-config-fixture"],
            "backlog": {"text": "Do not migrate [unrelated](unrelated/) from this saved prose."}}]}))
        (home / "data/task-one/unrelated").mkdir()
        (home / "data/task-one/unrelated/keep.bin").write_bytes(b"must stay")
    database = home / "user/.agent-config-beads/.beads/beads.db"
    database.parent.mkdir(parents=True)
    with sqlite3.connect(database) as db:
        db.execute("CREATE TABLE issues(id TEXT, description TEXT)")
        db.execute("CREATE TABLE comments(issue_id TEXT, text TEXT)")
        db.execute("INSERT INTO issues VALUES (?, ?)", (".agent-config-fixture", "Report archived."))
        db.execute("INSERT INTO comments VALUES (?, ?)", (".agent-config-fixture", "Evidence: [build](build/)."))
    assert [item["path"] for item in run(home, "offload-plan")["moves"]] == ["build"]
    run(home, "offload")
    assert (home / "Trash/build/evidence.bin").is_file()
    if locator == "saved":
        assert (home / "data/task-one/unrelated/keep.bin").read_bytes() == b"must stay"
print("PASS: report/row/saved-source bead IDs resolve local bead comments, while saved-source prose is not move authority", flush=True)

for bead in (".agent-config-unread", "unknown-prefix"):
    home = fixture("unresolved-" + bead)
    (home / "data/task-one/report.md").write_text(f"Evidence: [build](build/). Bead: {bead}\n")
    plan = run(home, "offload-plan")
    assert plan["moves"] == [] and plan["retained"]
    run(home, "offload", ok=False)
    assert (home / "data/task-one/build/evidence.bin").is_file()
    assert not (home / "calls").exists()
print("PASS: unread or unknown named bead sources retain the original without remote calls", flush=True)
PY
test_pid=$!
wait "$test_pid"
test_pid=''
