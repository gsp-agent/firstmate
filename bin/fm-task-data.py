#!/usr/bin/env python3
"""Retain task evidence and hold scratch until the next completed task.

Usage: fm-task-data.py prepare DATA STATE ID
       fm-task-data.py stage DATA STATE ID PROJECT PR
       fm-task-data.py expire DATA STATE ID
The caller must hold STATE/.meta-ID.lock, the lock also used by spawn.
Prepare records the obligation before retirement; stage and expire refuse live tasks.
Only real directories immediately below DATA are accepted; symlinked ancestors,
mounts, and special files refuse before any move or removal.

Keep brief.md, report.md, status, findings, review, and record/ regardless of size.
Also keep .txt/.md/.log/.json files up to 1 MiB outside nested repositories.
Other nested-repository files are scratch unless referenced.
Read the recorded GitHub, GitLab, Forgejo or Gerrit request and its discussion
through fm-task-data-lib.sh, and beads named in retained task evidence through br.
Unavailable references retain all data for retry.
Paths mentioned in these sources or retained evidence override the size/type
limit. Matching a basename conservatively also retains ambiguous references.
Retained symlinks protect targets within validated task/temporary roots, including
through ancestor aliases such as macOS /tmp -> /private/tmp, without widening those roots.

Scratch moves to DATA/ID/.cleanup-hold with its relative paths intact; no bytes
are copied. record/data-cleanup.json records the recovery, not a second task
record. The next successful teardown of a DIFFERENT task expires the hold, after
refreshing references and restoring newly linked files to their original paths.
Recovery before then: move the desired .cleanup-hold/<relative-path> back to
<relative-path> under the same original directory (DATA/ID or a recorded temporary
directory). Never overwrite a new file at that path.
An interrupted move resumes at the next cycle and receives a full new cycle.
Repeated staging never expires its own hold. Active task ids are skipped.
Reusing a finished id retains the reference sources of its earlier recovery.
Temporary directories require a task/bead name and an absolute reference in task
evidence, or the task's recorded tasktmp path. Named scratch must be an immediate
TMPDIR child; recorded tasktmp must be below TMPDIR or the spawn-owned /tmp/fm-ID.
Only directories owned by this user qualify; live-task paths and symlinks never qualify.
Their scratch stays in each original directory's .cleanup-hold, with absolute
original paths recorded in the same receipt for recovery and later expiry.

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


def references(views, sources):
    texts = [local_references(*view) for view in views]
    local = "\n".join(texts)
    beads = set(re.findall(r"\b[Bb]ead(?:_id)?[ \t:=`]*([.]?[\w.]+-[\w-]+)", local))
    sources[-1]["beads"] = sorted(set(sources[-1]["beads"]) | beads)
    for source in sources:
        project, pr = source["project"], source["pr"]
        if pr:
            texts.append(read_command(["bash", str(Path(__file__).absolute().with_name("fm-task-data-lib.sh")),
                                       "references", pr], project))
        for bead in source["beads"]:
            if not Path(project).is_dir():
                raise ValueError(f"cannot locate the bead's project: {project}")
            texts.append(read_command(["br", "--no-auto-flush", "--no-auto-import", "--json", "show", bead], project))
    return unquote(html.unescape("\n".join(texts)))


def linked(rel, text):
    # Basename matching also protects relative Markdown links and escaped JSON
    # paths without guessing which directory a PR or bead used as its base.
    return rel.name in text or json.dumps(rel.name)[1:-1] in text


def symlink_targets(views, text):
    targets = set()

    def locate(path):
        for _ in range(40):
            for root, _, _ in views:
                if path == root or root in path.parents:
                    rel = path.relative_to(root)
                    if rel.parts and rel.parts[0] == HOLD:
                        rel = rel.relative_to(HOLD)
                        path = root / rel
                    actual = path
                    if not actual.exists() and not actual.is_symlink():
                        actual = root / HOLD / rel
                    return root, path, actual
            for ancestor in (*reversed(path.parents), path):
                if ancestor.is_symlink():
                    path = Path(os.path.abspath(ancestor.parent / os.readlink(ancestor))).joinpath(
                        *path.relative_to(ancestor).parts)
                    break
            else:
                return None
        raise ValueError(f"cyclic evidence ancestor alias: {path}")

    for root, files, repos in views:
        for rel in files:
            actual = root / rel
            virtual = root / (rel.relative_to(HOLD) if rel.parts[0] == HOLD else rel)
            if not actual.is_symlink() or not (linked(rel, text) or (
                    rel.parts[0] != HOLD and ordinary_evidence(actual, rel, repos))):
                continue
            path = virtual
            for _ in range(40):
                found = locate(path)
                if found is None:
                    break
                owner, path, _ = found
                targets.add(path)
                relative = path.relative_to(owner)
                for length in range(1, len(relative.parts) + 1):
                    prefix = owner.joinpath(*relative.parts[:length])
                    _, prefix, source = locate(prefix)
                    if source.is_symlink():
                        targets.add(prefix)
                        tail = relative.parts[length:]
                        path = Path(os.path.abspath(prefix.parent / os.readlink(source))).joinpath(*tail)
                        break
                else:
                    break
            else:
                raise ValueError(f"cyclic evidence symlink: {actual}")
    return targets


def temporary_directories(root, state, task_id, text, tasktmp=""):
    supplied_base = Path(os.environ.get("TMPDIR") or tempfile.gettempdir())
    base = real_directory(supplied_base.resolve())
    names = {task_id}
    names.update(re.findall(r"\b[Bb]ead(?:_id)?[ \t:=`]*([.]?[\w.]+-[\w-]+)", text))
    names.update(name.rsplit("-", 1)[-1] for name in tuple(names))
    paths = list(base.iterdir())
    if tasktmp:
        recorded = Path(tasktmp)
        if recorded.is_absolute() and recorded.exists() and not recorded.is_symlink():
            default = Path(f"/tmp/fm-{task_id}").resolve()
            if recorded == Path(f"/tmp/fm-{task_id}"):
                recorded = default
            recorded = real_directory(recorded)
            if recorded not in paths and (base in recorded.parents or recorded == default):
                paths.append(recorded)
    result = []
    for path in paths:
        named = any(path.name == name or path.name.startswith(tuple(name + sep for sep in "-._"))
                    for name in names)
        recorded = bool(tasktmp) and path == Path(tasktmp).resolve()
        mentioned = str(path) in text or str(supplied_base / path.name) in text
        if not recorded and not (named and mentioned):
            continue
        if temporary_live(path, state, task_id):
            continue
        if (path == root or path in root.parents or root in path.parents
                or path == state or path in state.parents or state in path.parents
                or path.is_symlink() or not path.is_dir() or path.stat().st_uid != os.getuid()):
            continue
        real_directory(path)
        info = path.stat()
        result.append({"path": str(path), "device": info.st_dev, "inode": info.st_ino})
    return result


def temporary_live(path, state, task_id):
    for meta in state.glob("*.meta"):
        if meta.name == f"{task_id}.meta":
            continue
        values = dict(line.split("=", 1) for line in meta.read_text().splitlines() if "=" in line)
        original = values.get("tasktmp", "")
        for name in (meta.stem, meta.stem.rsplit("-", 1)[-1]):
            if path.name == name or path.name.startswith(tuple(name + sep for sep in "-._")):
                return True
        if original:
            other = Path(original).resolve()
            if path == other or path in other.parents or other in path.parents:
                return True
    return False


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
    tasktmp = ""
    if action == "prepare":
        if meta.is_symlink() or not meta.is_file():
            raise ValueError("missing or unsafe retiring task record")
        values = dict(line.split("=", 1) for line in meta.read_text().splitlines() if "=" in line)
        if values.get("kind") == "secondmate":
            return
        project, pr, tasktmp = (values.get(key, "") for key in ("project", "pr", "tasktmp"))
    elif meta.exists() or meta.is_symlink():
        raise ValueError(f"task is still live: {task_id}")
    root = data / task_id
    temporary = []
    if not root.exists() and not root.is_symlink():
        if action == "expire":
            return
        temporary = temporary_directories(root, state, task_id, "", tasktmp)
        if not temporary:
            return
        root.mkdir()
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
                or not isinstance(record.get("expired", False), bool)
                or not isinstance(record.get("temporary", []), list)):
            raise ValueError("invalid cleanup record")
        for source in record["sources"]:
            if (not isinstance(source, dict) or not isinstance(source.get("project"), str)
                    or not isinstance(source.get("pr"), str) or not isinstance(source.get("beads"), list)
                    or any(not isinstance(bead, str) for bead in source["beads"])):
                raise ValueError("invalid reference source")
        for item in record.get("temporary", []):
            if (not isinstance(item, dict) or not isinstance(item.get("path"), str)
                    or not isinstance(item.get("device"), int) or not isinstance(item.get("inode"), int)):
                raise ValueError("invalid temporary recovery")
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
    local = unquote(html.unescape(local_references(root, files, repos)))
    if record is None:
        record = {"version": 1, "task": task_id, "sources": [], "complete": False}
    if record.get("expired"):
        record.update(complete=False, expired=False, temporary=[])
    if action in ("prepare", "stage"):
        source = next((item for item in record["sources"]
                       if item["project"] == project and item["pr"] == pr), None)
        if source:
            record["sources"].remove(source)
        record["sources"].append(source or {"project": project, "pr": pr, "beads": []})
        record["sources"][-1]["beads"] = sorted(set(record["sources"][-1]["beads"]) | set(
            re.findall(r"\b[Bb]ead(?:_id)?[ \t:=`]*([.]?[\w.]+-[\w-]+)", local)))
        temporary += temporary_directories(root, state, task_id, local, tasktmp)
        known = {item["path"]: item for item in record.get("temporary", [])}
        for item in temporary:
            if item["path"] not in known:
                path = Path(item["path"]) / HOLD
                if path.exists() or path.is_symlink():
                    raise ValueError(f"unowned temporary recovery: {path}")
                known[item["path"]] = item
        record["temporary"] = list(known.values())
    views = [(root, files, repos)]
    base = real_directory(Path(os.environ.get("TMPDIR") or tempfile.gettempdir()).resolve())
    for item in record.get("temporary", []):
        path = Path(item["path"])
        if ((base not in path.parents and path != Path(f"/tmp/fm-{task_id}").resolve())
                or path == root or path in root.parents or root in path.parents
                or path == state or path in state.parents or state in path.parents):
            raise ValueError("temporary recovery escapes its root")
        if not path.exists() and not path.is_symlink():
            continue
        path = real_directory(path)
        info = path.stat()
        if (info.st_uid != os.getuid() or (info.st_dev, info.st_ino) != (item["device"], item["inode"])):
            raise ValueError(f"temporary recovery directory changed: {path}")
        if temporary_live(path, state, task_id):
            raise ValueError(f"temporary recovery belongs to a live task: {path}")
        recovery = path / HOLD
        if recovery.is_symlink() or (recovery.exists() and not recovery.is_dir()):
            raise ValueError(f"unsafe temporary recovery: {recovery}")
        leaves, _, nested_repos = inventory(path)
        views.append((path, leaves, nested_repos))
    write_record(root, record)
    if action == "prepare":
        return
    if shutil.which("dcg") is None:
        raise ValueError("dcg is unavailable")
    try:
        text = references(views, record["sources"])
    finally:
        write_record(root, record)
    targets = symlink_targets(views, text)

    def protected(path, rel):
        original = path / rel
        return linked(rel, text) or any(original == target or target in original.parents for target in targets)

    scratch = [(path, [rel for rel in leaves if rel.parts[0] not in (HOLD, "record")
                      and not ordinary_evidence(path / rel, rel, nested_repos)
                      and not protected(path, rel)]) for path, leaves, nested_repos in views]
    if action == "expire" and record["complete"]:
        for path, _, _ in views:
            recovery = path / HOLD
            if not recovery.exists():
                continue
            held_files, held_dirs, _ = inventory(recovery)
            remove = []
            for rel in held_files:
                if protected(path, rel):
                    destination = path / rel
                    if destination.exists() or destination.is_symlink():
                        raise ValueError(f"recovery would overwrite: {destination}")
                    safe_parent(path, rel)
                    (recovery / rel).rename(destination)
                else:
                    remove.append(rel)
            remove_entries(recovery, remove, held_dirs)
            guard_command(["rmdir", "--", str(recovery)])
            if path != root and not any(path.iterdir()):
                guard_command(["rmdir", "--", str(path)])
                record["temporary"] = [item for item in record.get("temporary", []) if item["path"] != str(path)]
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
            safe_parent(recovery, rel)
            (path / rel).rename(recovery / rel)
        if not path.exists():
            continue
        remaining_files, remaining_dirs, _ = inventory(path)
        occupied = {parent for leaf in remaining_files if leaf.parts[0] not in (HOLD, "record")
                    for parent in leaf.parents}
        empty = [rel for rel in remaining_dirs if rel.parts[0] not in (HOLD, "record")
                 and rel not in occupied]
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
                or len(sys.argv) != (7 if sys.argv[1] == "stage" else 5)):
            raise ValueError(__doc__)
        cleanup(*sys.argv[1:])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"warning: task data retained for recovery: {error}", file=sys.stderr)
        sys.exit(1)
