#!/usr/bin/env python3
"""Retain task evidence and hold scratch until the next completed task.

Usage: fm-task-data.py prepare DATA STATE ID [PR]
       fm-task-data.py stage DATA STATE ID PROJECT PR
       fm-task-data.py expire DATA STATE ID
The caller must hold STATE/.meta-ID.lock, the lock also used by spawn.
Prepare records the obligation before retirement; stage and expire refuse live tasks.
Cleanup is limited to DATA/ID; scratch outside DATA is not discovered or staged.
Only real directories immediately below DATA are accepted; symlinked ancestors,
mounts, and special files refuse before any move or removal.

Keep brief.md, report.md, status, findings, review, and record/ regardless of size.
Also keep .txt/.md/.log/.json files up to 1 MiB outside nested repositories.
Other nested-repository files are scratch unless referenced.
Read the recorded GitHub, GitLab, Forgejo or Gerrit request and its discussion,
the owning task's full backlog row, and named beads through fm-task-data-lib.sh.
Backlog sources retain their home addressing in the cleanup record.
Unavailable references retain all data for retry.
Paths mentioned in these sources or retained evidence override the size/type limit.
File references conservatively match basenames; directory references use path/link
syntax and protect all descendants, including symlinks below a linked directory.
Matching decodes URL/HTML encoding, JSON strings, and Markdown destination escapes.
Normalized comparisons preserve original spellings for filesystem identity lookups,
so Unicode names work on both normalization-sensitive and aliasing filesystems.
Retained symlinks protect owned targets and necessary path components in filesystem
order, including symlink-plus-.. paths, filesystem-name aliases, and ancestor aliases
such as macOS /tmp -> /private/tmp, without widening the validated task directory.

Scratch moves to DATA/ID/.cleanup-hold with its relative paths intact; no bytes
are copied. record/data-cleanup.json records the recovery, not a second task
record. The next successful teardown of a DIFFERENT task expires the hold, after
refreshing references and restoring newly linked files or directory descendants
to their original paths under the same retention rules.
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
import string
import subprocess
import sys
import tempfile
import unicodedata
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


def local_references(root, files, repos):
    texts = []
    for rel in files:
        path = root / rel
        if (rel.parts[0] != HOLD and str(rel) != RECEIPT
                and not path.is_symlink()
                and (path.suffix.lower() in TEXT or path.name in ("status", "findings", "review"))
                and ordinary_evidence(path, rel, repos)):
            if path.stat().st_size > LIMIT:
                raise ValueError(f"reference text exceeds 1 MiB: {path}")
            texts.append(path.read_text(errors="replace"))
    return "\n".join(texts)


def backlog_references(source, task_id):
    backlog = source["backlog"]
    response = json.loads(read_command([
        "bash", str(Path(__file__).absolute().with_name("fm-task-data-lib.sh")),
        "backlog-references", backlog["data"], task_id,
        "1" if backlog["task"] is not None else "0", *source["beads"],
    ], str(Path(backlog["data"]).parent)))
    if (not isinstance(response, dict) or not isinstance(response.get("text"), str)
            or response.get("task") not in (None, task_id)
            or (backlog["task"] is not None and response.get("task") != task_id)):
        raise ValueError("invalid backlog reference response")
    backlog["task"] = response["task"]
    return response["text"]


def references(views, sources, task_id):
    texts = [local_references(*view) for view in views]
    local = "\n".join(texts)
    beads = set(re.findall(r"\b[Bb]ead(?:_id)?[ \t:=`]*([.]?[\w.]+-[\w-]+)", local))
    sources[-1]["beads"] = sorted(set(sources[-1]["beads"]) | beads)
    for source in sources:
        project, pr = source["project"], source["pr"]
        if pr:
            texts.append(read_command(["bash", str(Path(__file__).absolute().with_name("fm-task-data-lib.sh")),
                                       "references", pr], project))
        texts.append(backlog_references(source, task_id))
    return unquote(html.unescape("\n".join(texts)))


def linked(rel, text, directory, normalized, offsets):
    # Basename matching also protects relative Markdown links and escaped JSON
    # paths without guessing which directory a PR or bead used as its base.
    if not directory and (rel.name in text or json.dumps(rel.name)[1:-1] in text):
        return True
    name = unicodedata.normalize("NFD", rel.name)
    pattern = "(" + re.escape(name) + ")"
    if directory:
        prefix = r'''(?:(?<=[/(`<"'])|:[ \t]+|(?<![\w.-])(?=''' + re.escape(name) + r"/))"
        pattern = prefix + pattern + r'''(?=/?(?:$|[\s)\]}>'",;?#]))'''
    for match in re.finditer(pattern, normalized, re.IGNORECASE):
        start, end = match.span(1)
        alias = rel.with_name(text[offsets[start]:offsets[end - 1] + 1])
        try:
            if os.path.samestat(alias.lstat(), rel.lstat()):
                return True
        except (FileNotFoundError, NotADirectoryError):
            pass
    return False


def protected(path, targets):
    return path in targets or any(parent in targets for parent in path.parents)


def retention_paths(root, files, all_directories, repos, text):
    targets, directories = set(), set()
    decoded = []
    for match in re.finditer(r'"(?:[^"\\]|\\.)*"', text):
        try:
            decoded.append(json.loads(match.group()))
        except ValueError:
            pass
    text = "\n".join([text, *decoded])
    text += "\n" + re.sub(r"\\([" + re.escape(string.punctuation) + r"])", r"\1", text)
    normalized = unicodedata.normalize("NFD", text)
    offsets = [index for index, character in enumerate(text)
               for _ in unicodedata.normalize("NFD", character)]
    entries = {root / rel: (root / rel).lstat() for rel in files + all_directories}
    children = {}
    for path, info in entries.items():
        children.setdefault(path.parent, {})[path.name] = (path, info)
    root_info = root.lstat()

    def inventory_path(path):
        siblings = children.get(path.parent, {})
        if path.name not in siblings:
            try:
                info = path.lstat()
            except (FileNotFoundError, NotADirectoryError):
                return path
            candidates = sorted(siblings.values(), key=lambda item:
                                unicodedata.normalize("NFD", item[0].name).casefold()
                                != unicodedata.normalize("NFD", path.name).casefold())
            for entry, entry_info in candidates:
                if os.path.samestat(info, entry_info):
                    return entry
        return path

    def virtual_path(path):
        rel = path.relative_to(root)
        if rel.parts and rel.parts[0] == HOLD:
            rel = rel.relative_to(HOLD)
        return root / rel

    def locate(path):
        if path == root or root in path.parents:
            path = virtual_path(inventory_path(path))
            actual = path
            if not actual.exists() and not actual.is_symlink():
                actual = root / HOLD / path.relative_to(root)
            actual = inventory_path(actual)
            return root, virtual_path(actual), actual
        try:
            if os.path.samestat(path.lstat(), root_info):
                return root, root, root
        except (FileNotFoundError, NotADirectoryError):
            pass
        return None, path, path

    for rel in files + all_directories:
        if rel == Path(HOLD):
            continue
        actual = root / rel
        is_directory = stat.S_ISDIR(entries[actual].st_mode)
        if linked(actual, text, is_directory, normalized, offsets) or (
                not is_directory and rel.parts[0] != HOLD and ordinary_evidence(actual, rel, repos)):
            targets.add(virtual_path(actual))
            if is_directory:
                directories.add(virtual_path(actual))

    pending_links = [root / rel for rel in files if (root / rel).is_symlink()]
    while pending_links:
        remaining = []
        for actual in pending_links:
            virtual = virtual_path(actual)
            if not protected(virtual, targets):
                remaining.append(actual)
                continue
            path = Path(virtual.anchor)
            pending = list(virtual.parts[1:])
            followed = 0
            while pending:
                part = pending.pop(0)
                if part == "..":
                    path = path.parent
                    continue
                owner, path, source = locate(path / part)
                if source.is_symlink():
                    if owner is not None:
                        targets.add(path)
                    followed += 1
                    if followed > 40:
                        raise ValueError(f"cyclic evidence symlink: {actual}")
                    target = Path(os.readlink(source))
                    if target.is_absolute():
                        path = Path(target.anchor)
                        pending = list(target.parts[1:]) + pending
                    else:
                        path = path.parent
                        pending = list(target.parts) + pending
                else:
                    if owner is not None and pending:
                        directories.add(path)
            owner, path, _ = locate(path)
            if owner is not None:
                targets.add(path)
        if len(remaining) == len(pending_links):
            break
        pending_links = remaining
    return targets, directories


def safe_directory(root, relative):
    parent = root
    for part in relative.parts:
        parent = parent / part
        if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
            raise ValueError(f"unsafe recovery parent: {parent}")
        parent.mkdir(exist_ok=True)
    return parent


def write_record(root, record):
    safe_directory(root, Path(RECEIPT).parent)
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
    # Commands name only validated leaves or empty directories. Symlinks are
    # unlinked, never traversed, and rmdir refuses changed or nonempty directories.
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
    values = None
    if action == "prepare":
        if meta.exists() or meta.is_symlink():
            if meta.is_symlink() or not meta.is_file():
                raise ValueError("unsafe retiring task record")
            values = dict(line.split("=", 1) for line in meta.read_text().splitlines() if "=" in line)
            if values.get("kind") == "secondmate":
                return
            project = values.get("project", "")
            pr = pr or values.get("pr", "")
    elif meta.exists() or meta.is_symlink():
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
            if "backlog" in source:
                backlog = source["backlog"]
                if (not isinstance(backlog, dict) or not isinstance(backlog.get("data"), str)
                        or not Path(backlog["data"]).is_absolute()
                        or "task" not in backlog or backlog["task"] not in (None, task_id)):
                    raise ValueError("invalid backlog source")
        if action == "expire" and record.get("expired"):
            return
    elif action == "expire":
        return
    if action == "prepare" and values is None:
        if record is None:
            raise ValueError("missing retiring task record and cleanup sources")
        project = record["sources"][-1]["project"]
        pr = pr or record["sources"][-1]["pr"]
    hold = root / HOLD
    if hold.is_symlink() or (hold.exists() and not hold.is_dir()):
        raise ValueError("unsafe recovery directory")
    if hold.exists() and record is None:
        raise ValueError("unowned recovery directory")
    files, all_directories, repos = inventory(root)
    local = unquote(html.unescape(local_references(root, files, repos)))
    if record is None:
        record = {"version": 1, "task": task_id, "sources": [], "complete": False}
    if record.get("expired"):
        record.update(complete=False, expired=False)
    if action in ("prepare", "stage"):
        source = next((item for item in record["sources"]
                       if item["project"] == project and item["pr"] == pr
                       and item.get("backlog", {"data": str(data)})["data"] == str(data)), None)
        if source:
            record["sources"].remove(source)
        record["sources"].append(source or {"project": project, "pr": pr, "beads": []})
        record["sources"][-1]["beads"] = sorted(set(record["sources"][-1]["beads"]) | set(
            re.findall(r"\b[Bb]ead(?:_id)?[ \t:=`]*([.]?[\w.]+-[\w-]+)", local)))
    for source in record["sources"]:
        source.setdefault("backlog", {"data": str(data), "task": None})
    views = [(root, files, repos)]
    write_record(root, record)
    if action == "prepare":
        try:
            backlog_references(record["sources"][-1], task_id)
        finally:
            write_record(root, record)
        return
    if shutil.which("dcg") is None:
        raise ValueError("dcg is unavailable")
    try:
        text = references(views, record["sources"], task_id)
    finally:
        write_record(root, record)
    targets, directories = retention_paths(root, files, all_directories, repos, text)

    scratch = [(path, [rel for rel in leaves if rel.parts[0] not in (HOLD, "record")
                      and not protected(path / rel, targets)]) for path, leaves, _ in views]
    if action == "expire" and record["complete"]:
        for path, _, _ in views:
            recovery = path / HOLD
            if not recovery.exists():
                continue
            for directory in sorted(directories):
                if path == directory or path in directory.parents:
                    safe_directory(path, directory.relative_to(path))
            held_files, held_dirs, _ = inventory(recovery)
            remove = []
            for rel in held_files:
                if protected(path / rel, targets):
                    destination = path / rel
                    if destination.exists() or destination.is_symlink():
                        raise ValueError(f"recovery would overwrite: {destination}")
                    safe_directory(path, rel.parent)
                    (recovery / rel).rename(destination)
                else:
                    remove.append(rel)
            remove_entries(recovery, remove, held_dirs)
            guard_command(["rmdir", "--", str(recovery)])
        if not any(leaves for _, leaves in scratch):
            record["expired"] = True
            write_record(root, record)
            return
    for path, leaves in scratch:
        for rel in leaves:
            destination = path / HOLD / rel
            if destination.exists() or destination.is_symlink():
                raise ValueError(f"recovery collision: {destination}")
    if not any(leaves for _, leaves in scratch) and not any((path / HOLD).exists() for path, _, _ in views):
        record.update(complete=True, expired=True)
        write_record(root, record)
        return
    record.update(complete=False, expired=False)
    write_record(root, record)
    for path, leaves in scratch:
        recovery = path / HOLD
        if leaves:
            recovery.mkdir(exist_ok=True)
        for rel in leaves:
            safe_directory(recovery, rel.parent)
            (path / rel).rename(recovery / rel)
        if not path.exists():
            continue
        remaining_files, remaining_dirs, _ = inventory(path)
        occupied = {parent for leaf in remaining_files if leaf.parts[0] not in (HOLD, "record")
                    for parent in leaf.parents}
        empty = [rel for rel in remaining_dirs if rel.parts[0] not in (HOLD, "record")
                 and rel not in occupied and path / rel not in directories
                 and not protected(path / rel, targets)]
        remove_entries(path, [], empty)
    record["complete"] = True
    write_record(root, record)
    print(f"task data {task_id}: scratch recoverable in {hold} until the next completed task")


if __name__ == "__main__":
    if sys.argv[1:] == ["--help"]:
        print(__doc__)
        sys.exit(0)
    try:
        if (len(sys.argv) < 2 or sys.argv[1] not in ("prepare", "stage", "expire")
                or len(sys.argv) not in ({5, 6} if sys.argv[1] == "prepare"
                                        else {7} if sys.argv[1] == "stage" else {5})):
            raise ValueError(__doc__)
        if sys.argv[1] == "prepare" and len(sys.argv) == 6:
            cleanup(*sys.argv[1:5], pr=sys.argv[5])
        else:
            cleanup(*sys.argv[1:])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"warning: task data retained for recovery: {error}", file=sys.stderr)
        sys.exit(1)
