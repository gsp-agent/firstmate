#!/usr/bin/env python3
"""Retain task evidence and hold scratch until the next completed task.

Usage: fm-task-data.py stage DATA STATE ID PROJECT PR
       fm-task-data.py expire DATA STATE ID
The caller must hold STATE/.meta-ID.lock, the lock also used by spawn.
An existing task record always refuses, including forced teardown callers.
Only real directories immediately below DATA are accepted; symlinked ancestors,
mounts, and special files refuse before any move or removal.

Keep report.md, brief.md, record/, and .txt/.md/.log/.json files up to 1 MiB.
Nested repositories are scratch, except for files named in evidence references.
Read the recorded GitHub PR with its comments/reviews and beads named in the
brief through gh-axi and br. Unavailable references retain all data for retry.
Paths mentioned in these sources or retained evidence override the size/type
limit. Matching a basename conservatively also retains ambiguous references.

Scratch moves to DATA/ID/.cleanup-hold with its relative paths intact; no bytes
are copied. record/data-cleanup.json records the recovery, not a second task
record. The next successful teardown of a DIFFERENT task expires the hold, after
refreshing references and restoring newly linked files to their original paths.
Recovery before then: move the desired .cleanup-hold/<relative-path> back to
DATA/ID/<relative-path>. Never overwrite a new file at that path.
An interrupted move resumes at the next cycle and receives a full new cycle.
Repeated staging never expires its own hold. Active task ids are skipped.
Reusing a finished id retains the reference sources of its earlier recovery.

Expiry checks each exact, nonrecursive rm/rmdir command through dcg's Bash hook
before executing it. A denial, unknown response, missing dcg, or command failure
retains the remaining recovery and reports an error. No allowlist is modified.
Moving to the hold does not reclaim disk space; expiry does.
"""

import html
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import unquote


LIMIT = 1024 * 1024
TEXT = {".txt", ".md", ".log", ".json"}
HOLD = ".cleanup-hold"
RECEIPT = "record/data-cleanup.json"


def real_directory(path):
    path = Path(os.path.abspath(path))
    if path.resolve() != path or not path.is_dir():
        raise ValueError(f"not a real directory: {path}")
    return path


def inventory(root):
    def unreadable(error):
        raise error

    files, directories, repos = [], [], []
    device = root.stat().st_dev
    for directory, names, leaves in os.walk(root, followlinks=False, onerror=unreadable):
        parent = Path(directory)
        if ".git" in names or ".git" in leaves:
            repos.append(parent.relative_to(root))
        for name in names + leaves:
            path = parent / name
            info = path.lstat()
            if info.st_dev != device:
                raise ValueError(f"cross-device task data: {path}")
            if stat.S_ISDIR(info.st_mode):
                directories.append(path.relative_to(root))
            elif stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                files.append(path.relative_to(root))
            else:
                raise ValueError(f"special file in task data: {path}")
    return files, directories, repos


def ordinary_evidence(path, rel, repos):
    if rel.parts[0] == "record" or str(rel) in ("brief.md", "report.md", "status", "findings", "review"):
        return True
    if any(repo == rel or repo in rel.parents for repo in repos):
        return False
    return path.suffix.lower() in TEXT and path.lstat().st_size <= LIMIT


def read_command(args, project):
    result = subprocess.run(args, cwd=project if Path(project).is_dir() else None,
                            capture_output=True, text=True, timeout=60, check=True)
    if not result.stdout.strip():
        raise ValueError(f"empty reference response from {args[0]}")
    return result.stdout


def references(root, files, repos, sources):
    texts = []
    for rel in files:
        path = root / rel
        if path.is_symlink() and ordinary_evidence(path, rel, repos):
            target = path.resolve()
            if root in target.parents:
                texts.append(str(target.relative_to(root)))
        if (rel.parts[0] != HOLD and str(rel) != RECEIPT
                and not path.is_symlink()
                and (path.suffix.lower() in TEXT or path.name in ("status", "findings", "review"))
                and ordinary_evidence(path, rel, repos)):
            if path.stat().st_size > LIMIT:
                raise ValueError(f"reference text exceeds 1 MiB: {path}")
            texts.append(path.read_text(errors="replace"))
    local = "\n".join(texts)
    beads = set(re.findall(r"\b[Bb]ead(?:_id)?[ \t:=`]*([.]?[\w.]+-[\w-]+)", local))
    sources[-1]["beads"] = sorted(set(sources[-1]["beads"]) | beads)
    for source in sources:
        project, pr = source["project"], source["pr"]
        if pr:
            if not re.fullmatch(r"https://github\.com/[^/]+/[^/]+/pull/[0-9]+", pr):
                raise ValueError("unsupported PR reference; retaining task data")
            texts.append(read_command(["gh-axi", "pr", "view", pr, "--full", "--comments", "--reviews"], project))
        for bead in source["beads"]:
            if not Path(project).is_dir():
                raise ValueError(f"cannot locate the bead's project: {project}")
            texts.append(read_command(["br", "--no-auto-flush", "--no-auto-import", "--json", "show", bead], project))
    return unquote(html.unescape("\n".join(texts)))


def linked(rel, text):
    # Basename matching also protects relative Markdown links and escaped JSON
    # paths without guessing which directory a PR or bead used as its base.
    return rel.name in text or json.dumps(rel.name)[1:-1] in text


def safe_parent(root, relative):
    parent = root
    for part in relative.parts[:-1]:
        parent = parent / part
        if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
            raise ValueError(f"unsafe recovery parent: {parent}")
        parent.mkdir(exist_ok=True)
    return parent


def write_record(root, record):
    safe_parent(root, Path(RECEIPT))
    path = root / RECEIPT
    if path.is_symlink() or (path.exists() and path.stat().st_nlink != 1):
        raise ValueError(f"unsafe cleanup record: {path}")
    descriptor, name = tempfile.mkstemp(prefix=".data-cleanup-", dir=path.parent)
    temporary = Path(name)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(record, stream)
        stream.write("\n")
    temporary.replace(path)


def guard_command(args):
    payload = {"tool_name": "Bash", "tool_input": {"command": shlex.join(args)}}
    result = subprocess.run(["dcg"], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=30, check=True)
    if result.stdout.strip():
        response = json.loads(result.stdout)
        if not isinstance(response, dict) or not isinstance(response.get("hookSpecificOutput"), dict):
            raise ValueError("unknown dcg response")
        decision = response["hookSpecificOutput"].get("permissionDecision")
        if decision != "allow":
            raise ValueError(f"dcg refused cleanup: {result.stdout.strip()}")
    subprocess.run(args, check=True)


def remove_entries(root, files, directories):
    # Commands name only leaves under the validated hold. Symlinks are unlinked,
    # never traversed, and rmdir refuses a directory that changed or is nonempty.
    for offset in range(0, len(files), 128):
        paths = []
        for rel in files[offset:offset + 128]:
            path = root / rel
            if path.parent.resolve() != path.parent or path.is_dir() and not path.is_symlink():
                raise ValueError(f"cleanup target changed: {path}")
            paths.append(str(path))
        guard_command(["rm", "-f", "--", *paths])
    directories = sorted(directories, key=lambda p: len(p.parts), reverse=True)
    for offset in range(0, len(directories), 128):
        paths = []
        for rel in directories[offset:offset + 128]:
            path = root / rel
            if path.is_symlink() or path.resolve() != path:
                raise ValueError(f"cleanup directory changed: {path}")
            paths.append(str(path))
        guard_command(["rmdir", "--", *paths])


def cleanup(action, data, state, task_id, project="", pr=""):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", task_id):
        raise ValueError("invalid task id")
    data, state = real_directory(data), real_directory(state)
    meta = state / f"{task_id}.meta"
    if meta.exists() or meta.is_symlink():
        raise ValueError(f"task is still live: {task_id}")
    root = data / task_id
    if not root.exists() and not root.is_symlink():
        return
    root = real_directory(root)
    receipt = root / RECEIPT
    if receipt.parent.is_symlink() or (receipt.parent.exists() and not receipt.parent.is_dir()):
        raise ValueError("unsafe record directory")
    record = None
    if receipt.exists() or receipt.is_symlink():
        if (receipt.is_symlink() or receipt.stat().st_nlink != 1
                or receipt.stat().st_size > LIMIT):
            raise ValueError("unsafe cleanup record")
        record = json.loads(receipt.read_text())
        if (not isinstance(record, dict) or record.get("version") != 1
                or record.get("task") != task_id
                or not isinstance(record.get("complete"), bool)
                or not isinstance(record.get("sources"), list) or not record["sources"]
                or not isinstance(record.get("expired", False), bool)):
            raise ValueError("invalid cleanup record")
        for source in record["sources"]:
            if (not isinstance(source, dict) or not isinstance(source.get("project"), str)
                    or not isinstance(source.get("pr"), str) or not isinstance(source.get("beads"), list)
                    or any(not isinstance(bead, str) for bead in source["beads"])):
                raise ValueError("invalid reference source")
        if action == "expire" and record.get("expired"):
            return
    elif action == "expire":
        return
    hold = root / HOLD
    if hold.is_symlink() or (hold.exists() and not hold.is_dir()):
        raise ValueError("unsafe recovery directory")
    if hold.exists() and record is None:
        raise ValueError("unowned recovery directory")
    files, _, repos = inventory(root)
    candidates = [rel for rel in files if rel.parts[0] not in (HOLD, "record")
                  and not ordinary_evidence(root / rel, rel, repos)]
    if action == "stage" and not candidates and not hold.exists():
        return
    if record is None or record.get("expired"):
        record = {"version": 1, "task": task_id, "sources": [], "complete": False}
    if action == "stage":
        source = next((item for item in record["sources"]
                       if item["project"] == project and item["pr"] == pr), None)
        if source:
            record["sources"].remove(source)
        record["sources"].append(source or {"project": project, "pr": pr, "beads": []})
    write_record(root, record)
    if shutil.which("dcg") is None:
        raise ValueError("dcg is unavailable")
    try:
        text = references(root, files, repos, record["sources"])
    finally:
        write_record(root, record)
    if action == "expire" and record and record["complete"]:
        if hold.exists():
            held_files, held_dirs, _ = inventory(hold)
            remove = []
            for rel in held_files:
                if linked(rel, text):
                    destination = root / rel
                    if destination.exists() or destination.is_symlink():
                        raise ValueError(f"recovery would overwrite: {destination}")
                    safe_parent(root, rel)
                    (hold / rel).rename(destination)
                else:
                    remove.append(rel)
            remove_entries(hold, remove, held_dirs)
            guard_command(["rmdir", "--", str(hold)])
        record["expired"] = True
        write_record(root, record)
        return
    scratch = [rel for rel in candidates if not linked(rel, text)]
    if not scratch and not hold.exists():
        record.update(complete=True, expired=True)
        write_record(root, record)
        return
    record["complete"] = False
    write_record(root, record)
    hold.mkdir(exist_ok=True)
    for rel in scratch:
        destination = hold / rel
        if destination.exists() or destination.is_symlink():
            raise ValueError(f"recovery collision: {destination}")
        safe_parent(hold, rel)
        (root / rel).rename(destination)
    remaining_files, remaining_dirs, _ = inventory(root)
    occupied = {parent for leaf in remaining_files if leaf.parts[0] not in (HOLD, "record")
                for parent in leaf.parents}
    empty = [rel for rel in remaining_dirs if rel.parts[0] not in (HOLD, "record")
             and rel not in occupied]
    remove_entries(root, [], empty)
    record["complete"] = True
    write_record(root, record)
    print(f"task data {task_id}: scratch recoverable in {hold} until the next completed task")


if __name__ == "__main__":
    if sys.argv[1:] == ["--help"]:
        print(__doc__)
        sys.exit(0)
    try:
        if (len(sys.argv) < 2 or sys.argv[1] not in ("stage", "expire")
                or len(sys.argv) != (7 if sys.argv[1] == "stage" else 5)):
            raise ValueError(__doc__)
        cleanup(*sys.argv[1:])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"warning: task data retained for recovery: {error}", file=sys.stderr)
        sys.exit(1)
