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
import contextlib
from datetime import date, timedelta
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import stat
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
    request = json.load(sys.stdin)
    if mode == "dcg-deny" or (mode == "dcg-deny-rm" and request["tool_input"]["command"].startswith("rm ")):
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
    for name in ("TASKS_AXI_BACKEND", "TASKS_AXI_FILE", "TASKS_AXI_ROOT", "BEADS_DIR", "BEADS_DB", "BR_DB",
                 "FM_TASK_DATA_BEAD_LOCATIONS"):
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
    # A fully pushed repository: its remote is a forge URL that this test
    # rewrites to a bare repository on this disk.
    git("--git-dir", repository, "config", f"url.{home / 'user/forge.git'}.insteadOf", FORGE)

def commit(tree, name, text):
    (tree / name).write_text(text)
    git("-C", tree, "add", name)
    git("-C", tree, "commit", "-q", "-m", text.strip())

def repo_fixture(name):
    home = fixture(name)
    task = home / "data/task-one"
    (task / "report.md").write_text("Completed.\n")
    clone = task / "clone"
    git("init", "-q", "--bare", "-b", "main", home / "user/forge.git")
    git("init", "-q", "-b", "main", clone)
    forge(home, clone / ".git")
    commit(clone, "work.txt", "pushed work\n")
    git("-C", clone, "remote", "add", "origin", FORGE)
    git("-C", clone, "push", "-q", "-u", "origin", "main")
    return home, clone

def snapshot(path):
    entries = {}
    for item in sorted(path.rglob("*")):
        rel = str(item.relative_to(path))
        if item.is_symlink():
            entries[rel] = ("link", os.readlink(item))
        elif item.is_dir():
            entries[rel] = ("directory", item.stat().st_mode & 0o777)
        elif not item.is_file():
            entries[rel] = ("special", stat.S_IFMT(item.lstat().st_mode))
        else:
            entries[rel] = ("file", item.stat().st_mode & 0o777, item.read_bytes())
    return entries

def restored(home, pointer, name):
    assert pointer["archive"] == "tar" and pointer["location"].startswith("mini-ts:/Volumes/MINI-DATA/"), pointer
    payload = home / "remote" / pointer["location"].removeprefix("mini-ts:").lstrip("/")
    with tarfile.open(payload) as archive:
        archive.extractall(home / "restored", filter="tar")
    return snapshot(home / "restored" / name)

def check_repository_archived():
    home, clone = repo_fixture("repo-archived")
    before = snapshot(clone)
    plan = run(home, "offload-plan")
    assert [(move["path"], move.get("repository")) for move in plan["moves"]] == [("clone", True)], plan
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("clone", "tar")], result
    assert restored(home, json.loads(clone.read_text()), "clone") == before, "the archive does not restore the repository exactly"
    assert snapshot(home / "Trash/clone") == before
    assert any((home / "independent-backup").iterdir())
    assert not list((home / "data/task-one").glob(".firstmate-offload-*")), "the local archive copy was left behind"
    calls = (home / "calls").read_text()
    assert run(home, "offload")["offloaded"] == []
    assert (home / "calls").read_text() == calls, "an archived repository's pointer was offloaded again"

def check_refused_repository_kept():
    home, clone = repo_fixture("repo-refused")
    before = snapshot(clone)
    run(home, "offload", fault="backup-failed", ok=False)
    assert snapshot(clone) == before and not (home / "Trash").exists()
    assert not list((home / "data/task-one").glob(".firstmate-offload-*")), "a refused round left its archive copy"
    assert [item["path"] for item in run(home, "offload")["offloaded"]] == ["clone"]

def check_unreachable_mini_writes_no_archive():
    home, clone = repo_fixture("repo-unreachable")
    before = snapshot(clone)
    run(home, "offload", fault="mini-unreachable", ok=False)
    assert (home / "archives-seen").read_text() == "", "an archive was written before mini-ts answered"
    assert snapshot(clone) == before and not (home / "Trash").exists()
    assert not list((home / "data/task-one").glob(".firstmate-offload-*"))
    assert [item["path"] for item in run(home, "offload")["offloaded"]] == ["clone"]

def check_lanes_join_their_repository():
    home = fixture("repo-lanes")
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
    before = snapshot(task / "set")
    plan = run(home, "offload-plan")
    assert [(move["path"], move.get("repository")) for move in plan["moves"]] == [("set", True)], plan
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("set", "tar")], result
    assert restored(home, json.loads((task / "set").read_text()), "set") == before
    assert snapshot(home / "Trash/set") == before

def check_outside_parent_worktree_kept():
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
    assert plan["moves"] == [] and [(item.get("path"), item["reason"]) for item in plan["retained"]] == [
        ("wt", "linked worktree of a repository outside data/")], plan
    assert run(home, "offload")["offloaded"] == []
    assert snapshot(worktree) == before and snapshot(main) == parent and not (home / "calls").exists()

def check_nested_outside_worktree_kept():
    home, clone = repo_fixture("repo-nested-outside-worktree")
    main = home / "user/main"
    git("init", "-q", "-b", "main", main)
    commit(main, "work.txt", "parent work\n")
    git("-C", main, "worktree", "add", "-q", "--detach", clone / "ac-wt")
    commit(clone / "ac-wt", "detached.txt", "a commit only this nested worktree's HEAD reaches\n")
    before, parent = snapshot(clone), snapshot(main)
    plan = run(home, "offload-plan")
    assert plan["moves"] == [] and [(item.get("path"), item["reason"]) for item in plan["retained"]] == [
        ("clone", "linked worktree of a repository outside data/")], plan
    assert run(home, "offload")["offloaded"] == []
    assert snapshot(clone) == before and snapshot(main) == parent and not (home / "calls").exists()

def check_submodule_rides_superproject():
    home, clone = repo_fixture("repo-submodule")
    seed, sub = home / "user/sub-seed", home / "user/sub.git"
    git("init", "-q", "--bare", "-b", "main", sub)
    git("init", "-q", "-b", "main", seed)
    commit(seed, "sub.txt", "submodule work\n")
    git("-C", seed, "push", "-q", sub, "main")
    git("-C", clone, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "vendor/x")
    git("-C", clone, "commit", "-q", "-m", "add submodule")
    before = snapshot(clone)
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("clone", "tar")], result
    assert restored(home, json.loads(clone.read_text()), "clone") == before

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

def check_pass_removes_only_journaled_archives():
    home = fixture("sweep-leftover")
    task = home / "data/task-one"
    (task / "report.md").write_text("Completed.\n")
    owned = ".firstmate-offload-0123456789abcdef.tar"
    (task / owned).write_bytes(b"redundant archive copy")
    (task / ".firstmate-offload-backup.tar").write_bytes(b"a file the task made itself")
    (task / "record").mkdir()
    (task / "record/data-offload.json").write_text(json.dumps(
        {"version": 1, "task": "task-one", "entries": {}, "archives": [owned]}))
    assert run(home, "offload-plan")["moves"] == []
    run(home, "sweep", raw=True, task=())
    assert not (task / owned).exists(), "a journaled archive copy in a task with no moves stayed"
    assert (task / ".firstmate-offload-backup.tar").read_bytes() == b"a file the task made itself", \
        "a file the offload journal does not name was removed"
    assert json.loads((task / "record/data-offload.json").read_text())["archives"] == []

def check_archive_keeps_extended_attributes():
    home, clone = repo_fixture("repo-xattr")
    subprocess.run(["/usr/bin/xattr", "-w", "com.apple.ResourceFork", "unique-resource-bytes", str(clone / "work.txt")],
                   check=True)
    run(home, "offload")
    pointer = json.loads(clone.read_text())
    payload = home / "remote" / pointer["location"].removeprefix("mini-ts:").lstrip("/")
    (home / "restored").mkdir()
    subprocess.run(["/usr/bin/tar", "--xattrs", "-xpf", str(payload), "-C", str(home / "restored")],
                   check=True, capture_output=True)
    fork = subprocess.run(["/usr/bin/xattr", "-p", "com.apple.ResourceFork", str(home / "restored/clone/work.txt")],
                          capture_output=True, text=True)
    assert fork.returncode == 0 and fork.stdout.strip() == "unique-resource-bytes", \
        "the archive dropped the file's resource fork: " + fork.stderr.strip()

def check_unreadable_worktree_record_kept():
    home, clone = repo_fixture("repo-empty-record")
    git("-C", clone, "worktree", "add", "-q", "-b", "side", home / "user/wt")
    (clone / ".git/worktrees/wt/gitdir").write_text("")
    before = snapshot(clone)
    plan = run(home, "offload-plan")
    assert plan["moves"] == [], plan
    assert [(item.get("path"), item["reason"]) for item in plan["retained"]] == \
        [("clone", "linked worktree record is unreadable")], plan
    assert run(home, "offload")["offloaded"] == []
    assert snapshot(clone) == before

def check_acl_repository_kept():
    home, clone = repo_fixture("repo-acl")
    subprocess.run(["/bin/chmod", "+a", "everyone deny write", str(clone / "work.txt")], check=True)
    plan = run(home, "offload-plan")
    assert plan["moves"] == [], plan
    assert [(item.get("path"), item["reason"]) for item in plan["retained"]] == \
        [("clone", "holds access control lists the archive cannot carry")], plan
    assert run(home, "offload")["offloaded"] == []
    acl = subprocess.run(["/bin/ls", "-le", str(clone / "work.txt")], capture_output=True, text=True, check=True).stdout
    assert "everyone deny write" in acl, acl

def check_missing_worktree_record_kept():
    home, clone = repo_fixture("repo-missing-record")
    git("-C", clone, "worktree", "add", "-q", "-b", "side", home / "user/wt")
    (clone / ".git/worktrees/wt/gitdir").unlink()
    before = snapshot(clone)
    plan = run(home, "offload-plan")
    assert plan["moves"] == [], plan
    assert [(item.get("path"), item["reason"]) for item in plan["retained"]] == \
        [("clone", "linked worktree record is unreadable")], plan
    assert run(home, "offload")["offloaded"] == []
    assert snapshot(clone) == before

def check_refused_cleanup_blocks_new_archive():
    home, clone = repo_fixture("repo-refused-cleanup")
    task = home / "data/task-one"
    owned = ".firstmate-offload-0123456789abcdef.tar"
    (task / owned).write_bytes(b"redundant archive copy")
    (task / "record").mkdir()
    (task / "record/data-offload.json").write_text(json.dumps(
        {"version": 1, "task": "task-one", "entries": {}, "archives": [owned]}))
    before = snapshot(clone)
    run(home, "offload", fault="dcg-deny-rm", ok=False)
    assert sorted(path.name for path in task.glob(".firstmate-offload-*")) == [owned], \
        "a new archive copy was written while an earlier one stayed on disk"
    assert json.loads((task / "record/data-offload.json").read_text())["archives"] == [owned]
    assert snapshot(clone) == before

def check_flagged_repository_kept():
    home, clone = repo_fixture("repo-flags")
    subprocess.run(["/usr/bin/chflags", "uchg", str(clone / "work.txt")], check=True)
    try:
        plan = run(home, "offload-plan")
        assert plan["moves"] == [], plan
        assert [(item.get("path"), item["reason"]) for item in plan["retained"]] == \
            [("clone", "holds file flags the archive cannot carry")], plan
        assert run(home, "offload")["offloaded"] == []
        assert os.lstat(clone / "work.txt").st_flags & stat.UF_IMMUTABLE
    finally:
        subprocess.run(["/usr/bin/chflags", "nouchg", str(clone / "work.txt")], check=True)

def kept_reason(name, damage):
    home, clone = repo_fixture(name)
    damage(home, clone)
    before = snapshot(clone)
    plan = run(home, "offload-plan")
    assert plan["moves"] == [], plan
    assert run(home, "offload")["offloaded"] == []
    assert snapshot(clone) == before
    return [(item.get("path"), item["reason"]) for item in plan["retained"]]

def check_unclean_worktree_records_kept():
    def stale(home, clone):
        git("-C", clone, "worktree", "add", "-q", "-b", "side", home / "user/wt")
        shutil.rmtree(home / "user/wt")
    def no_backlink(home, clone):
        git("-C", clone, "worktree", "add", "-q", "-b", "side", home / "user/wt")
        (home / "user/wt/.git").write_text("gitdir: " + str(home / "user/elsewhere") + "\n")
    for name, damage in (("stale", stale), ("no-backlink", no_backlink)):
        reasons = kept_reason("repo-record-" + name, damage)
        assert reasons == [("clone", "linked worktree record is unreadable")], (name, reasons)

def check_uncarried_metadata_kept():
    def sparse(home, clone):
        with (clone / "disk.img").open("wb") as stream:
            stream.truncate(64 * 1024 * 1024)
    reasons = kept_reason("repo-meta-sparse", sparse)
    assert reasons == [("clone", "holds sparse or compressed files the archive would expand")], reasons
    # A special file anywhere keeps the whole task, named, before any unit is weighed.
    home, clone = repo_fixture("repo-meta-fifo")
    os.mkfifo(clone / "pipe")
    before = snapshot(clone)
    plan = run(home, "offload-plan")
    assert plan["moves"] == [] and [item["reason"].split(":")[0] for item in plan["retained"]] == \
        ["special file in task data"], plan
    run(home, "offload", ok=False)
    assert snapshot(clone) == before and not (home / "calls").exists()

def check_offloads_take_one_lock():
    home = fixture("one-offload-at-a-time")
    shutil.copytree(home / "data/task-one", home / "data/task-two")
    closed = (date.today() - timedelta(days=10)).isoformat()
    with (home / "data/backlog.md").open("a") as stream:
        stream.write(f"- [x] task-two - fixture (repo: example) (closed {closed})\n")
    env = dict(os.environ, HOME=str(home / "user"), FM_HOME=str(home), PATH=str(fake) + os.pathsep + os.environ["PATH"],
               OFFLOAD_HELPER=str(code / "bin/fm-task-data.py"), OFFLOAD_FAULT="backup-hang", FM_TASK_DATA_SWEEP="off",
               OFFLOAD_REAL_RSYNC="0", FM_TASK_DATA_TRASH=str(fake / "safe/trash"))
    first = subprocess.Popen(["bash", str(code / "bin/fm-task-data-lib.sh"), "offload", str(home / "data"),
                              str(home / "state"), "task-one"], env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        while not (home / "backup-started").exists():
            assert time.monotonic() < deadline and first.poll() is None, "the first offload never reached its backup"
            time.sleep(0.05)
        stderr = run(home, "offload", task=("task-two",), ok=False)
        assert "another offload is running" in stderr, stderr
        assert (home / "data/task-two/build/evidence.bin").is_file()
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(first.pid, signal.SIGTERM)
        first.communicate(timeout=60)

def check_reopened_task_leftover_removed():
    home = fixture("reopened-leftover", status="open")
    task = home / "data/task-one"
    owned = ".firstmate-offload-0123456789abcdef.tar"
    (task / owned).write_bytes(b"redundant archive copy")
    (task / "record").mkdir()
    (task / "record/data-offload.json").write_text(json.dumps(
        {"version": 1, "task": "task-one", "entries": {}, "archives": [owned]}))
    run(home, "offload", ok=False)
    assert not (task / owned).exists(), "a reopened task kept its journaled archive copy"
    assert json.loads((task / "record/data-offload.json").read_text())["archives"] == []

def check_separated_git_dir_kept():
    home = fixture("repo-separate-git-dir")
    task = home / "data/task-one"
    (task / "report.md").write_text("Completed.\n")
    git("init", "-q", "--separate-git-dir", task / "repo.git", home / "user/work")
    git("init", "-q", "--bare", "-b", "main", task / "plain.git")
    before = snapshot(task / "repo.git")
    plan = run(home, "offload-plan")
    assert [move["path"] for move in plan["moves"]] == ["plain.git"], plan
    assert [(item.get("path"), item["reason"]) for item in plan["retained"]] == \
        [("repo.git", "git directory of a checkout outside the unit")], plan
    assert [item["path"] for item in run(home, "offload")["offloaded"]] == ["plain.git"]
    assert snapshot(task / "repo.git") == before
    git("-C", home / "user/work", "status", "--short")

def check_borrowing_repository_kept():
    home = fixture("repo-borrows-outside")
    task = home / "data/task-one"
    (task / "report.md").write_text("Completed.\n")
    seed = home / "user/seed"
    git("init", "-q", "-b", "main", seed)
    commit(seed, "shared.txt", "shared history\n")
    clone = task / "clone"
    git("clone", "-q", "--shared", seed, clone)
    before = snapshot(clone)
    plan = run(home, "offload-plan")
    assert plan["moves"] == [], plan
    assert [(item.get("path"), item["reason"]) for item in plan["retained"]] == \
        [("clone", "borrows objects from a repository outside the unit")], plan
    assert run(home, "offload")["offloaded"] == []
    assert snapshot(clone) == before
    git("-C", clone, "log", "-1", "--format=%s")

def check_unknown_bead_text_ignored():
    home = fixture("bead-ordinary-text")
    (home / "data/task-one/report.md").write_text(
        "Evidence: [build](build/). Bead: be-still and Bead: .agent-config and Beads: no-mistakes\n")
    plan = run(home, "offload-plan")
    assert [item["path"] for item in plan["moves"]] == ["build"], plan
    run(home, "offload")
    assert (home / "Trash/build/evidence.bin").is_file()

def check_added_bead_homes_resolve():
    home = fixture("bead-added-homes")
    database = home / "user/dev/PfizerOutDoCancerV3/.beads/beads.db"
    database.parent.mkdir(parents=True)
    with sqlite3.connect(database) as db:
        db.execute("CREATE TABLE config(key TEXT NOT NULL, value TEXT NOT NULL)")
        db.execute("INSERT INTO config VALUES ('issue_prefix', 'pfizer')")
        db.execute("CREATE TABLE issues(id TEXT, description TEXT)")
        db.execute("CREATE TABLE comments(issue_id TEXT, text TEXT)")
        db.execute("INSERT INTO issues VALUES (?, ?)", ("pfizer-fixture", "Report archived."))
        db.execute("INSERT INTO comments VALUES (?, ?)", ("pfizer-fixture", "Evidence: [build](build/)."))
    (home / "data/task-one/report.md").write_text("Evidence: none. Bead: pfizer-fixture\n")
    assert [item["path"] for item in run(home, "offload-plan")["moves"]] == ["build"]

def check_sub_attempt_uses_parent_date():
    home = fixture("sub-attempt-date")
    sub = home / "data/task-one-sub"
    (sub / "build").mkdir(parents=True)
    (sub / "build/evidence.bin").write_bytes(b"original-evidence" * 256)
    (sub / "report.md").write_text("Evidence: [build](build/).\n")
    plan = run(home, "offload-plan", task=("task-one-sub",))
    assert [(item["task"], item["path"]) for item in plan["moves"]] == [("task-one-sub", "build")], plan
    run(home, "offload", task=("task-one-sub",))
    assert (home / "Trash/build/evidence.bin").is_file()
    lonely = home / "data/lonely-task"
    (lonely / "build").mkdir(parents=True)
    (lonely / "build/evidence.bin").write_bytes(b"original-evidence" * 256)
    (lonely / "report.md").write_text("Evidence: [build](build/).\n")
    plan = run(home, "offload-plan", task=("lonely-task",))
    assert plan["moves"] == [] and plan["retained"], plan
    # Its own checked row with two dates decides, not the older parent row.
    own = home / "data/task-one-own"
    (own / "build").mkdir(parents=True)
    (own / "build/evidence.bin").write_bytes(b"original-evidence" * 256)
    (own / "report.md").write_text("Evidence: [build](build/).\n")
    recent = date.today() - timedelta(days=2)
    with (home / "data/backlog.md").open("a") as stream:
        stream.write(f"- [x] task-one-own - retry (merged {recent - timedelta(days=1)}) (closed {recent})\n")
    plan = run(home, "offload-plan", task=("task-one-own",))
    assert plan["moves"] == [] and "seven complete days" in plan["retained"][0]["reason"], plan

def check_discovered_bead_home_resolves():
    home = fixture("bead-discovered-home")
    database = home / "user/dev/operator-proj/.beads/beads.db"
    database.parent.mkdir(parents=True)
    (database.parent / "config.yaml").write_text("# issue_prefix: operator\n")
    with sqlite3.connect(database) as db:
        db.execute("CREATE TABLE issues(id TEXT, description TEXT)")
        db.execute("CREATE TABLE comments(issue_id TEXT, text TEXT)")
        db.execute("INSERT INTO issues VALUES (?, ?)", ("operator-fixture", "Report archived."))
        db.execute("INSERT INTO comments VALUES (?, ?)", ("operator-fixture", "Evidence: [build](build/)."))
    (home / "data/task-one/report.md").write_text("Evidence: none. Bead: operator-fixture\n")
    assert [item["path"] for item in run(home, "offload-plan")["moves"]] == ["build"]

def check_orphan_newest_write():
    home = fixture("orphan-newest-write")
    old = home / "data/orphan-old"
    (old / "build").mkdir(parents=True)
    (old / "build/evidence.bin").write_bytes(b"original-evidence" * 256)
    (old / "report.md").write_text("Evidence: [build](build/).\n")
    past = time.time() - 20 * 86400
    for path in sorted(old.rglob("*"), reverse=True):
        os.utime(path, (past, past))
    os.utime(old, (past, past))
    plan = run(home, "offload-plan", task=("orphan-old",))
    assert [(item["task"], item["path"]) for item in plan["moves"]] == [("orphan-old", "build")], plan
    recent = home / "data/orphan-recent"
    (recent / "build").mkdir(parents=True)
    (recent / "build/evidence.bin").write_bytes(b"original-evidence" * 256)
    (recent / "report.md").write_text("Evidence: [build](build/).\n")
    plan = run(home, "offload-plan", task=("orphan-recent",))
    assert plan["moves"] == [] and "seven complete days" in plan["retained"][0]["reason"], plan

def age(path, days):
    past = time.time() - days * 86400
    for item in [*path.rglob("*"), path]:
        os.utime(item, (past, past), follow_symlinks=False)

def check_orphan_repository_offloads():
    home, clone = repo_fixture("orphan-repository")
    (home / "data/backlog.md").write_text("")
    age(home / "data/task-one", 20)
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("clone", "tar")], result
    assert json.loads(clone.read_text())["format"] == "firstmate-task-evidence-v1"

def check_orphan_retries_after_failed_run():
    home, clone = repo_fixture("orphan-retry")
    (home / "data/backlog.md").write_text("")
    age(home / "data/task-one", 20)
    run(home, "offload", fault="backup-failed", ok=False)
    assert (clone / ".git").is_dir() and (home / "data/task-one/record/data-offload.json").is_file()
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("clone", "tar")], result

def bead_store(beads, rows, comments):
    beads.mkdir(parents=True)
    (beads / "config.yaml").write_text("# issue_prefix: obs\n")
    with sqlite3.connect(beads / "beads.db") as db:
        db.execute("CREATE TABLE issues(id TEXT, description TEXT, created_at TEXT, updated_at TEXT)")
        db.execute("CREATE TABLE comments(issue_id TEXT, text TEXT)")
        db.executemany("INSERT INTO issues VALUES (?, '', ?, ?)", rows)
        db.executemany("INSERT INTO comments VALUES (?, ?)", comments)

def check_tied_bead_homes():
    home = fixture("bead-tied-homes")
    created = "2026-10-13T05:09:57.644071+00:00"
    # A stale worktree copy sorts before the live home and holds the same bead.
    bead_store(home / "user/dev/agent-observer-beads/.beads",
               [("obs-copy", created, "2026-10-14T04:52:51.023697+00:00"),
                ("obs-split", "2026-10-01T00:00:00+00:00", "2026-10-01T00:00:00+00:00")],
               [("obs-copy", "Evidence: none yet.")])
    bead_store(home / "user/dev/agent-observer/.beads",
               [("obs-copy", created, "2026-10-14T08:58:30.436810+00:00"),
                ("obs-split", "2026-10-02T00:00:00+00:00", "2026-10-02T00:00:00+00:00")],
               [("obs-copy", "Evidence: [build](build/).")])
    (home / "data/task-one/report.md").write_text("Evidence: none. Bead: obs-copy\n")
    assert [item["path"] for item in run(home, "offload-plan")["moves"]] == ["build"]
    (home / "data/task-one/report.md").write_text("Evidence: [build](build/). Bead: obs-split\n")
    plan = run(home, "offload-plan")
    assert plan["moves"] == [] and "different beads share its id" in plan["retained"][0]["reason"], plan

def check_orphan_offloads_every_unit():
    home = fixture("orphan-two-units")
    task = home / "data/task-one"
    (task / "more").mkdir()
    (task / "more/evidence.bin").write_bytes(b"more-evidence" * 256)
    (task / "report.md").write_text("Evidence: [build](build/) and [more](more/).\n")
    (home / "data/backlog.md").write_text("")
    age(task, 20)
    result = run(home, "offload")
    assert sorted(item["path"] for item in result["offloaded"]) == ["build", "more"], result

def check_outside_links_carried():
    home, clone = repo_fixture("repo-outside-links")
    (home / "user/shared.bin").write_bytes(b"shared by a hard link")
    os.link(home / "user/shared.bin", clone / "linked.bin")
    (clone / "elsewhere").symlink_to(home / "user/shared.bin")
    before = snapshot(clone)
    result = run(home, "offload")
    assert [(item["path"], item.get("archive")) for item in result["offloaded"]] == [("clone", "tar")], result
    assert restored(home, json.loads(clone.read_text()), "clone") == before
    assert (home / "user/shared.bin").read_bytes() == b"shared by a hard link"

# Collect the independent review regressions so a broken directory copy cannot
# hide the single-file, retry, or partial-report result on the reviewed head.
regressions = [("fake directory placement", lambda: check_placement("directory")),
               ("fake single-file placement", lambda: check_placement("file"))]
for kind in ("directory", "file"):
    for fault in ("copy-partial", "copy-wrong"):
        regressions.append((kind + " retries " + fault, lambda kind=kind, fault=fault: check_retry(kind, fault)))
regressions.extend([("verified existing payload is reused", check_verified_reuse),
                    ("partial round reports completed moves", check_partial_report),
                    ("a fully pushed repository is offloaded whole as one archive, never removed", check_repository_archived),
                    ("a refused repository offload keeps the repository and no archive copy", check_refused_repository_kept),
                    ("an unreachable mini writes no archive and the next pass offloads", check_unreachable_mini_writes_no_archive),
                    ("a repository and its lanes in the task are offloaded whole as one folder", check_lanes_join_their_repository),
                    ("a worktree of a repository outside DATA stays untouched", check_outside_parent_worktree_kept),
                    ("a clone holding a detached worktree of a repository outside DATA stays",
                     check_nested_outside_worktree_kept),
                    ("a clone with a checked-out submodule is offloaded whole with it", check_submodule_rides_superproject),
                    ("a worktree of a repository in another task stays", check_other_task_worktree_kept),
                    ("an offload stopped with TERM releases the task meta lock", check_interrupted_offload_releases_lock),
                    ("offload never runs a trash from PATH or feeds it stdin", check_trash_never_empties),
                    ("a sweep ends with an offload pass", lambda: check_sweep_offloads(True)),
                    ("a sweep in a home without a verifier offloads nothing", lambda: check_sweep_offloads(False)),
                    ("an offload pass removes only archive copies its journal names", check_pass_removes_only_journaled_archives),
                    ("a repository whose worktree record is empty stays", check_unreadable_worktree_record_kept),
                    ("a repository whose worktree record is missing stays", check_missing_worktree_record_kept),
                    ("no new archive while an earlier copy is still on disk", check_refused_cleanup_blocks_new_archive),
                    ("stale or inconsistent worktree records keep the unit", check_unclean_worktree_records_kept),
                    ("special and sparse files keep the unit", check_uncarried_metadata_kept),
                    ("hard links and symlinks reaching outside the unit are archived exactly", check_outside_links_carried),
                    ("a by-hand offload waits for the offload another run holds", check_offloads_take_one_lock),
                    ("a reopened task's journaled archive copy is still removed", check_reopened_task_leftover_removed),
                    ("a separated git directory stays while a bare one is archived", check_separated_git_dir_kept),
                    ("a repository borrowing objects from outside its unit stays", check_borrowing_repository_kept),
                    ("bead-like ordinary text does not hold a task", check_unknown_bead_text_ignored),
                    ("newly mapped bead homes resolve", check_added_bead_homes_resolve),
                    ("a sub-attempt takes its parent task's close date", check_sub_attempt_uses_parent_date),
                    ("a bead home absent from the old typed table resolves by discovery", check_discovered_bead_home_resolves),
                    ("an orphan task takes its folder's newest write as its close date", check_orphan_newest_write),
                    ("an old orphan's repository offloads despite the offload's own writes", check_orphan_repository_offloads),
                    ("an old orphan offloads every referenced directory in one run", check_orphan_offloads_every_unit),
                    ("an old orphan whose repository offload failed retries on the next pass",
                     check_orphan_retries_after_failed_run),
                    ("tied bead homes resolve by br's record, and different beads under one id hold the task",
                     check_tied_bead_homes)])
if sys.platform == "darwin":
    regressions.extend([("a repository archive keeps resource forks and other extended attributes",
                         check_archive_keeps_extended_attributes),
                        ("a repository holding an access control list stays", check_acl_repository_kept),
                        ("a repository holding file flags stays", check_flagged_repository_kept),("real /usr/bin/rsync directory placement", lambda: check_placement("directory", True)),
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
        db.execute("CREATE TABLE config(key TEXT NOT NULL, value TEXT NOT NULL)")
        db.execute("INSERT INTO config VALUES ('issue_prefix', '.agent-config')")
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

home = fixture("unresolved-.agent-config-unread")
unread_home = home / "user/.agent-config-beads/.beads"
unread_home.mkdir(parents=True)
(unread_home / "beads.db").write_bytes(b"not a database")
(unread_home / "config.yaml").write_text("# issue_prefix: .agent-config\n")
(home / "data/task-one/report.md").write_text("Evidence: [build](build/). Bead: .agent-config-unread\n")
plan = run(home, "offload-plan")
assert plan["moves"] == [] and plan["retained"]
run(home, "offload", ok=False)
assert (home / "data/task-one/build/evidence.bin").is_file()
assert not (home / "calls").exists()
print("PASS: an unread bead source with a known home retains the original without remote calls", flush=True)

home = fixture("unresolved-unknown-prefix")
(home / "data/task-one/report.md").write_text("Evidence: [build](build/). Bead: unknown-prefix\n")
assert [item["path"] for item in run(home, "offload-plan")["moves"]] == ["build"]
run(home, "offload")
assert (home / "Trash/build/evidence.bin").is_file()
print("PASS: a bead-like string with no known home is ordinary text and does not hold the task", flush=True)

home = fixture("unreadable-bead-home")
broken = home / "user/dev/broken-home/.beads"
broken.mkdir(parents=True)
(broken / "beads.db").write_bytes(b"not a database")
(home / "data/task-one/report.md").write_text("Evidence: [build](build/). Bead: unknown-prefix\n")
plan = run(home, "offload-plan")
assert plan["moves"] == [] and "bead homes on this machine could not be read" in plan["retained"][0]["reason"], plan
print("PASS: a bead home whose record cannot be read holds bead-like text instead of making it ordinary", flush=True)
PY
test_pid=$!
wait "$test_pid"
test_pid=''
