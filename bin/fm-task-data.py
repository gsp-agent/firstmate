#!/usr/bin/env python3
"""Retain task evidence and hold scratch until the next completed task.

Usage: fm-task-data.py prepare DATA STATE ID [PR]
       fm-task-data.py retire DATA STATE ID [PR]
       fm-task-data.py stage DATA STATE ID PROJECT PR
       fm-task-data.py expire DATA STATE ID
       fm-task-data.py pending DATA
       fm-task-data.py plan DATA STATE ID
       fm-task-data.py offload-plan DATA STATE [ID]
       bash fm-task-data-lib.sh offload DATA STATE ID
       fm-task-data.py mark DATA ID cut-off|too-large
Prepare, retire, stage, expire and mark need the caller to hold STATE/.meta-ID.lock, the
lock also used by spawn.
Pending takes no lock and prints, in one pass, each unexpired cleanup record's
task id and expiry mark, tab-separated, least recently tried first.
Plan runs expiry's reference and ownership decisions without writing, locking,
moving or removing anything; its JSON reports allocated scratch bytes, not a
promise of APFS free space (clones and hard links can share blocks).
Prepare records the obligation before retirement; stage and expire refuse live tasks.
Retire stages under the retiring task's existing protection; expiry also refuses pending closes.
Without metadata, prepare reads the latest completed markdown backlog row,
including the configured archive (legacy mode needs tomllib), when there is no
cleanup record or the expired record holds a legacy row.
Checked rows in the current backlog take precedence over archived rows.
Within that source, completion dates order rows; missing or tied dates leave
conflicting owners unresolved under the rules below, so those folders remain whole.
Compatible rows combine their references and preserve any non-empty PR for
the owner check.
PR identity and named beads come from the entire selected row, including its
continuation notes; multiple distinct PRs retain the whole folder.
Named repositories resolve below the backlog home's projects/; absolute repo
paths remain absolute.
Missing, ambiguous, or active rows retain the whole folder.
Legacy row references in the open recovery cycle are refreshed before staging
and expiry, with the original row retained as evidence in the cleanup record.
A row that changes the task's owner in that cycle retains the whole folder.
Only another repository, or another PR where both name one, changes the owner;
a PR the row adds where the record has none is a reference.
A row's bare repo name names a registered project, which a recorded checkout
matches by its directory name or its origin repository's name.
Expired legacy rows and their last refreshed references remain historical
evidence and are no longer compared with the current row when the task id is reused.
Cleanup is limited to DATA/ID; scratch outside DATA is not discovered or staged.
DATA and STATE resolve their home ancestors, including aliases such as /tmp.
Both directories and task directories immediately below DATA must still be real;
symlinked task roots, mounts, and special files refuse before any move or removal.

Keep brief.md, report.md, status, findings, review, and record/ regardless of size,
and read those files and record/'s .txt/.md/.log/.json files for references up to
16 MiB each. A larger one is an unread reference: the folder stays whole and the
file is named in the warning and record.
Also keep .txt/.md/.log/.json files up to 1 MiB outside nested repositories.
Before reading kept text, preparation and staging add up its sizes from lstat.
Over 16 MiB in total, those foreground actions defer it with a "too-large" mark.
Expiry (including the sweep) reads and matches batches of at most 16 MiB,
unions their retained paths, and finishes every reference read before moving
or deleting anything. Repeated filenames share matching work within a batch.
The per-file unread-evidence rule still applies. Named beads are read in batches
of 32 so a large set does not share one reference-command timeout or text buffer.
Other nested-repository files are scratch unless referenced.
Read the recorded GitHub, GitLab, Forgejo or Gerrit request and its discussion,
the owning task's full backlog row, and named beads through fm-task-data-lib.sh.
Backlog sources retain their home addressing in the cleanup record.
A named bead is read from the one database that owns its prefix, whatever
project the task recorded; fm-task-data-lib.sh keeps that prefix map, and an
id whose prefix is not in it is read from the owning Firstmate backlog,
including its configured archive.
A bead its owner reports not found links nothing and is not unread; only an
owner that cannot be read, or a read that times out, leaves it unread.
These br reads clear BEADS_DIR, BEADS_DB, and BR_DB so inherited addressing
cannot select a different database.
Only strings shaped like real bead ids count as bead references, in new
text and in saved cleanup records: an optional leading dot, a lowercase
alphanumeric prefix of at least two characters starting with a letter, one or
more hyphen-separated lowercase alphanumeric segments, and optional numeric
child suffixes such as .1. Dates do not qualify.
A finished task whose required backlog row moved to the configured archive
resolves that row and its named beads from the completed rows, under the same
owner check as the legacy refresh.
Beads named by a readable owning row merge with the supplied beads and
resolve before evidence is classified, the same way completed-row beads do.
Unread task or bead ids appear in each source's unread list in
record/data-cleanup.json. Expiry appends a warning to the task's status before
marking that unread set reported, so later expiry passes do not repeat it.
Prepare, retire and stage still print their own warnings; prepare permits the backlog close.
Staging and expiry retain all data without moving or deleting it while any
reference is unreadable; the next successful teardown of a different task retries.
Retire and stage run under the task's locks, so their evidence and reference
reads and reference matching stop FM_TEARDOWN_DATA_STAGE_TIMEOUT seconds (default 10)
after the action starts, before anything moves; a reference read still running is
killed: the folder stays whole, the warning and the record's retained field name
the limit, and the next teardown of a different task retries it.
Paths mentioned in these sources or retained evidence override the size/type limit.
File references conservatively match basenames; directory references use path/link
syntax and protect all descendants, including symlinks below a linked directory.
Matching decodes URL/HTML encoding, JSON strings, and Markdown destination escapes.
Normalized comparisons preserve original spellings for filesystem identity lookups,
so Unicode names work on both normalization-sensitive and aliasing filesystems.
Retained symlinks protect owned targets and necessary path components in filesystem
order, including symlink-plus-.. paths, filesystem-name aliases, and ancestor aliases
such as macOS /tmp -> /private/tmp, without widening the validated task directory.
Hard-linked task paths share protection: if any alias is kept, all aliases stay or
are restored from recovery. Plan counts each inode once, reclaiming no bytes from
an inode with a kept alias.

Scratch moves to DATA/ID/.cleanup-hold with its relative paths intact; no bytes
are copied. record/data-cleanup.json records the recovery, not a second task
record. The next successful teardown of a DIFFERENT task expires the hold, after
refreshing references and restoring newly linked files or directory descendants
to their original paths under the same retention rules. After releasing its own
locks, that teardown lists pending records, then expires holds least recently
tried first, while FM_TEARDOWN_DATA_EXPIRE_TIMEOUT seconds (default 10) counted
from the end of the listing remain.
Each attempt marks its record tried before it starts, so a hold cut off before
it writes anything still moves behind the others.
An attempt cut off by the budget leaves the deletions it already made done and
the rest of the hold in place, and mark sets expiry "cut-off" in its record.
The next teardown that reaches it gives it one full attempt of exactly
FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT seconds (default 60), whatever remains of
the budget.
If that attempt is cut off too, mark sets expiry "too-large": later foreground
expiry passes skip the hold, keep what remains, and name it in a warning so
it can be expired by hand with `bash fm-task-data-lib.sh expire DATA STATE ID`,
which takes the task's meta lock and refuses a live task.
By-hand expiry stages an incomplete record and expires it in the same run,
so its scratch gets no recovery cycle; it exits non-zero naming a hold it
leaves unexpired.
After releasing its locks, teardown also starts one single-instance
background sweep that uses by-hand expiry for pending holds with no foreground
expiry budget, including holds marked too-large.
fm-task-data-lib.sh owns sweep invocation, locking, and requester handling.
Prepare, retire, stage and expire clear a cut-off mark at their first record
write; a too-large mark stays until expiry finishes.
The holds the budget never reached are named in one warning.
Recovery before then: move the desired .cleanup-hold/<relative-path> back to
DATA/ID/<relative-path>. Never overwrite a new file at that path.
Foreground expiry resumes an interrupted move with a full new recovery cycle.
Repeated staging never expires its own hold. Active task ids are skipped.
Reusing a finished id retains the reference sources of its earlier recovery.

Expiry checks each exact, nonrecursive rm/rmdir command through dcg's Bash hook
before executing it. A denial, unknown response, missing dcg, or command failure
retains the remaining recovery and reports an error. No allowlist is modified.
Moving to the hold does not reclaim disk space; expiry does.
An unread PR is named in the warning and record, retains the whole folder, and
does not fail the cleanup pass; later cleanup retries it before moving any data.

Offload is a second retention round. Each task-data sweep ends with one pass
over every eligible task (fm-task-data-lib.sh owns that pass), and it also runs
by hand for one task.
Offload-plan is read-only and scans the current markdown backlog and its configured
archive once, using canonical report.md and bead description/comment references without forge/network
reads or content hashing; it prints candidates, retained reasons, logical bytes
and allocated bytes (neither is a promise of APFS free space).
A closed backlog row and saved cleanup sources can identify relevant beads;
their path mentions, and those in briefs, logs or other incidental files, do not
authorize offload.
A current unchecked row overrides archived completion. Missing/ambiguous dates,
live metadata, pending closes, a task folder that is itself a repository and
repository work in the scratch recovery hold keep the whole task.
Date-only completion waits through seven complete local calendar days.
Small text and root brief/report files stay. Referenced directories or larger
files may move, but symlink and hardlink evidence stays pending alias ownership.

Each outermost repository outside record/ is one unit, referenced or not. A
repository and its linked worktrees in the same task are one unit: the smallest
folder below the task holding them all, with any other repository inside it.
Every unit is offloaded whole as one tar archive under the copy, checksum and
independent-backup rule below, and its pointer adds archive "tar".
Before writing an archive, offload checks that ssh mini-ts answers and
MINI-DATA is mounted; if not, it writes nothing and the task waits for the next
pass. One archive exists at a time, a temporary file in the task folder removed
through a dcg-checked rm -f right after its move or failure. Its name goes into
record/data-offload.json's archives list before it is written, and only a file
that list names is ever removed: offload removes the task's listed leftovers
first, and offload-plan lists tasks holding any so each offload pass reaches
them, moves or not; a refusal waits for the next pass.
Extended attributes, macOS resource forks included, ride in the archive's
SCHILY.xattr headers.
A linked worktree of a repository in another task or outside DATA (its index,
HEAD, reflog and refs live in that repository, outside any archive), a
repository whose .git is a symlink, a repository with linked worktrees outside
the task or sharing no folder below it, an unreadable worktree record, a
submodule checkout outside its superproject's unit, and any unit holding one of
them at any depth stay in place, named with reasons and sizes in offload-plan's
retained list.

Live offload must run through the shell wrapper, which holds the spawn meta lock.
It requires private config/task-data-offload.json, mode without group/other writes,
containing {"backup_verifier": ["/absolute/trusted/executable", "optional-argument"]}.
The trusted verifier receives
the proposed pointer JSON on stdin after the MINI-DATA copy is checksummed.
It must independently verify a second copy of this exact object on another
physical device/failure domain, then emit JSON with independent:true, location,
checksum and size matching the request. A schedule, a same-drive partition or
an unverified backup is insufficient; a refusal retains the original.
Do not put credentials in verifier arguments or output.

Copies use ssh mini-ts and rsync into /Volumes/MINI-DATA/firstmate-task-evidence,
with a SHA256 content-addressed directory per home/task/source path. Directory
contents land directly in payload/; a single file or repository archive lands
at payload. MINI-DATA
must be mounted. Existing payloads are reused only after manifest verification;
mismatched or incomplete copies are preserved in an incomplete-*/payload sibling
before retrying, without deleting anything on the destination.
The checksum is SHA256 of a canonical JSON tree manifest: sorted
arrays [relative-name,type,mode] for directories and
[relative-name,"file",mode,size,sha256-of-file] for files, with '.' for the root,
ensure_ascii=True and separators (',', ':'). Size is summed file bytes.
Only matching remote and independent-backup manifests allow dcg-checked
`/usr/bin/trash -s` (macOS's own tool, where -s stops on error) on the original,
using the machine's existing Trash expiry (24 hours). It is named by absolute
path because another `trash` earlier on PATH, such as Homebrew's, reads -s as
securely empty the Trash. FM_TASK_DATA_TRASH replaces that path in tests only.
Every dcg-checked command reads stdin from /dev/null, so no prompt can take an
answer from the caller.
A small JSON pointer replaces the exact original pathname, naming the destination,
size, checksum, checksum format and independent backup. Task evidence never
leaves through rm.
record/data-offload.json journals verified moves before Trash, so a retry after
interruption can reverify both copies and finish a missing pointer. Existing
pointers are no-ops. Recovery copies remain in Trash until its normal expiry;
restore an original by first moving its pointer aside, never overwriting work;
a repository archive restores with tar --xattrs -xpf in the pointer's parent
directory, which also restores its extended attributes.
If a later candidate fails, stdout still reports completed moves and total bytes,
plus the failed task/path/reason; the command retains its nonzero exit status.
"""

from array import array
import contextlib
import copy
from datetime import date, timedelta
import hashlib
import html
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import sqlite3
import stat
import string
import subprocess
import sys
import tarfile
import tempfile
import time
import unicodedata
from urllib.parse import unquote


LIMIT = 1024 * 1024
KEPT_LIMIT = 16 * LIMIT
TOTAL_LIMIT = 16 * LIMIT
CHUNK = 1024 * 1024
BEAD_BATCH_SIZE = 32
TEXT = {".txt", ".md", ".log", ".json"}
HOLD = ".cleanup-hold"
RECEIPT = "record/data-cleanup.json"
TASK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
MARKS = ("cut-off", "too-large")
BEAD_ID = re.compile(r"\.?[a-z][a-z0-9]+(?:-[a-z0-9]+)+(?:\.[0-9]+)*")
BEAD_REF = re.compile(r"\b[Bb]eads?(?:_id)?[ \t:=`]+(\.?[a-z][a-z0-9]+(?:-[a-z0-9]+)+(?:\.[0-9]+)*)")


def is_bead_id(value):
    return isinstance(value, str) and BEAD_ID.fullmatch(value) is not None


def bead_ids(text):
    return sorted(set(BEAD_REF.findall(text)))


def unread_named(record, state, task_id, error):
    unread = sorted({item for source in record["sources"] for item in source.get("unread", [])})
    if not unread or record.get("unread_named") == unread:
        return bool(unread)
    with (state / f"{task_id}.status").open("a") as stream:
        stream.write(f"note [at={int(time.time())}]: task data {task_id} retained whole for retry: {error}\n")
    record["unread_named"] = unread
    return False


class UnreadReferences(ValueError):
    pass


class RetainWhole(UnreadReferences):
    pass


class StageLimit(RetainWhole):
    pass


class TooLarge(RetainWhole):
    pass


def check_limit(limit):
    if limit and time.monotonic() > limit[0]:
        raise StageLimit(f"reference matching passed its {limit[1]}s stage limit")


def real_directory(path, *, resolve_parent=False):
    if resolve_parent:
        # Home aliases are trusted input; keep the boundary directory itself
        # and every task path subject to the existing no-symlink check.
        path = Path(path)
        path = path.parent.resolve() / path.name
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
    return files, directories, set(repos)


def ordinary_evidence(path, rel, repos):
    if rel.parts[0] == "record" or str(rel) in ("brief.md", "report.md", "status", "findings", "review"):
        return True
    if any(parent in repos for parent in (rel, *rel.parents)):
        return False
    return path.suffix.lower() in TEXT and path.lstat().st_size <= LIMIT


def read_command(args, project, limit=None):
    timeout = 60
    if limit:
        check_limit(limit)
        timeout = min(timeout, max(limit[0] - time.monotonic(), 0.01))
    # Files, not pipes: a reader's own timed grandchild may outlive the kill
    # and must not hold this read open past the stage limit.
    with tempfile.TemporaryFile("w+") as out, tempfile.TemporaryFile("w+") as err:
        process = subprocess.Popen(args, cwd=project if Path(project).is_dir() else None,
                                   stdout=out, stderr=err, start_new_session=bool(limit))
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if limit:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            else:
                process.kill()
            process.wait()
            check_limit(limit)
            raise
        out.seek(0)
        stdout = out.read()
        if process.returncode:
            err.seek(0)
            raise subprocess.CalledProcessError(process.returncode, args, stdout, err.read())
    if not stdout.strip():
        raise ValueError(f"empty reference response from {args[0]}")
    return stdout


def local_references(root, files, repos, limit=None):
    # Choose and size every file from lstat first, so an oversized total is
    # refused before any content is read.
    paths, oversized, total = [], [], 0
    for rel in files:
        check_limit(limit)
        path = root / rel
        if (rel.parts[0] != HOLD and str(rel) != RECEIPT
                and not path.is_symlink()
                and (path.suffix.lower() in TEXT or path.name in ("status", "findings", "review"))
                and ordinary_evidence(path, rel, repos)):
            size = path.lstat().st_size
            if size > KEPT_LIMIT:
                oversized.append(str(rel))
            else:
                paths.append(path)
                total += size
    if total > TOTAL_LIMIT:
        raise TooLarge(f"kept text totals {total} bytes, over its {TOTAL_LIMIT // LIMIT} MiB cap, so none of it was read")
    texts = []
    for path in paths:
        check_limit(limit)
        texts.append(path.read_text(errors="replace"))
    return "\n".join(texts), oversized


def local_reference_batches(root, files, repos, source, limit=None):
    """Expiry reads the same evidence, one bounded batch at a time."""
    paths, oversized = [], []
    for rel in files:
        check_limit(limit)
        path = root / rel
        if (rel.parts[0] != HOLD and str(rel) != RECEIPT
                and not path.is_symlink()
                and (path.suffix.lower() in TEXT or path.name in ("status", "findings", "review"))
                and ordinary_evidence(path, rel, repos)):
            if path.lstat().st_size > KEPT_LIMIT:
                oversized.append(str(rel))
            else:
                paths.append(path)
    if oversized:
        source["unread"] = sorted(set(source.get("unread", [])) | set(oversized))
        raise RetainWhole(f"kept evidence over 16 MiB: {', '.join(oversized)}")
    texts, size = [], 0
    for path in paths:
        check_limit(limit)
        with path.open("rb") as stream:
            payload = stream.read(KEPT_LIMIT + 1)
        length = len(payload)
        if length > KEPT_LIMIT:
            source["unread"] = sorted(set(source.get("unread", [])) | {str(path.relative_to(root))})
            raise RetainWhole(f"kept evidence grew over 16 MiB: {path.relative_to(root)}")
        if texts and size + length > TOTAL_LIMIT:
            yield unquote(html.unescape("\n".join(texts)))
            texts, size = [], 0
        texts.append(payload.decode(errors="replace"))
        size += length
    if texts:
        yield unquote(html.unescape("\n".join(texts)))


def expiry_reference_batches(views, sources, task_id, limit=None):
    # Resolve ownership and named references before spending matching time on
    # a large archive. Reading local evidence twice keeps both passes bounded;
    # a newly introduced bead on the second read defers the entire expiry.
    for view in views:
        for text in local_reference_batches(*view, sources[-1], limit):
            sources[-1]["beads"] = sorted(set(sources[-1]["beads"]) | set(bead_ids(text)))
    for source in sources:
        # Each bead read has its own bound. Do not put thousands of those
        # serial reads inside a single 60s subprocess or join all their text.
        pending_beads, read_beads = set(source["beads"]), set()
        first = True
        while first or pending_beads:
            first = False
            chunk = sorted(pending_beads)[:BEAD_BATCH_SIZE]
            batch = copy.deepcopy(source)
            batch["beads"] = chunk
            try:
                text = backlog_references(batch, task_id, limit, bead_batch=chunk)
            finally:
                source["backlog"] = batch["backlog"]
                source["unread"] = batch.get("unread", [])
                source["beads"] = sorted(set(source["beads"]) | set(batch["beads"]))
            read_beads.update(chunk)
            pending_beads = set(source["beads"]) - read_beads
            yield unquote(html.unescape(text))
        if source["pr"]:
            try:
                yield unquote(html.unescape(read_command([
                    "bash", str(Path(__file__).absolute().with_name("fm-task-data-lib.sh")),
                    "references", source["pr"]], source["project"], limit)))
            except StageLimit:
                raise
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                source["unread"] = sorted(set(source.get("unread", [])) | {source["pr"]})
                raise RetainWhole(f"unread PR {source['pr']}: {error}") from error
    for view in views:
        for text in local_reference_batches(*view, sources[-1], limit):
            if set(bead_ids(text)) - set(sources[-1]["beads"]):
                raise RetainWhole("local evidence changed during reference reads; retry required")
            yield text


def completed_row_index(data, limit=None):
    try:
        import tomllib
    except ImportError as error:
        raise ValueError("legacy preparation needs Python with tomllib") from error
    location = json.loads(read_command([
        "bash", str(Path(__file__).absolute().with_name("fm-task-data-lib.sh")),
        "backlog-location", str(data),
    ], str(data.parent), limit))
    if (not isinstance(location, dict) or not isinstance(location.get("root"), str)
            or not isinstance(location.get("file"), str) or not location["file"]
            or Path(location["root"]) != data.parent):
        raise ValueError("legacy preparation requires a markdown backlog in its owning home")
    backlog = Path(location["file"])
    archive = backlog.parent / "done-archive.md"
    for config in (Path.home() / ".tasks-axi/config.toml", data.parent / ".tasks.toml"):
        if config.exists() or config.is_symlink():
            markdown = tomllib.loads(config.read_text()).get("markdown", {})
            if not isinstance(markdown, dict):
                raise ValueError(f"invalid markdown configuration in {config}")
            value = markdown.get("archive")
            if value is not None:
                if not isinstance(value, str) or not value.strip():
                    raise ValueError(f"invalid markdown archive in {config}")
                archive = data.parent / value
    if archive == backlog:
        raise ValueError("archive path must not be the active backlog path")
    candidates = {}
    bullet = re.compile(r"^- (?:\[([ x])\] ([A-Za-z0-9][A-Za-z0-9._-]*)|\*\*([A-Za-z0-9][A-Za-z0-9._-]*)\*\*) - (.*)$")
    for path in dict.fromkeys((archive, backlog)):
        if path != backlog and not path.exists() and not path.is_symlink():
            continue
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"unreadable completed-row source: {path}")
        lines = path.read_text().splitlines()
        for index, line in enumerate(lines):
            match = bullet.fullmatch(line)
            if not match:
                continue
            task_id = match[2] or match[3]
            if match[1] != "x":
                if path == backlog:
                    candidates.setdefault(task_id, []).append((True, None, "", ""))
                continue
            end = index + 1
            while end < len(lines) and (not lines[end] or lines[end].startswith("  ")):
                end += 1
            dates = set(re.findall(r"\((?:merged|reported|done|closed) (\d{4}-\d{2}-\d{2})\)", match[4]))
            try:
                completed = date.fromisoformat(next(iter(dates))).isoformat() if len(dates) == 1 else ""
            except ValueError:
                completed = ""
            candidates.setdefault(task_id, []).append((path == backlog, completed, match[4], "\n".join(lines[index:end])))
    return candidates


def completed_rows(data, task_id, limit=None):
    candidates = completed_row_index(data, limit).get(task_id, [])
    if any(row[1] is None for row in candidates):
        raise ValueError("task still has a live backlog row")
    return candidates


def completed_source(data, task_id, limit=None):
    candidates = completed_rows(data, task_id, limit)
    if not candidates:
        raise ValueError("no completed backlog row")
    candidates = [row for row in candidates if row[0]] or candidates
    latest = max(row[1] for row in candidates)
    sources = [completed_row_source(data, title, text)
               for _, completed, title, text in candidates if not completed or completed == latest]
    if any(not same_owner(row, source, limit)
           for index, row in enumerate(sources) for source in sources[index + 1:]):
        raise ValueError("completed backlog rows have different projects or PRs with unproven order")
    source = sources[-1]
    source["pr"] = next((item["pr"] for item in sources if item["pr"]), "")
    source["text"] = "\n".join(item["text"] for item in sources)
    if len(source["text"].encode()) > LIMIT:
        raise ValueError("completed backlog evidence exceeds 1 MiB")
    source["beads"] = sorted({bead for item in sources for bead in item["beads"]})
    return source


def completed_row_source(data, title, text):
    repos = re.findall(r"\((?:[^()]*\+\s*)?repo:\s*([^)]+)\)", title)
    if not repos:
        raise ValueError("completed backlog row has no project")
    repo = repos[-1].strip()
    project = Path(repo).expanduser()
    if not project.is_absolute():
        if len(project.parts) != 1 or str(project) in (".", ".."):
            raise ValueError("completed backlog row has an ambiguous project path")
        project = data.parent / "projects" / project
    prs = set(re.findall(r"https://[^\s<>\"']+/(?:pulls?|merge_requests)/\d+|https://[^\s<>\"']+/c/[^\s<>\"']+/\+/\d+", text))
    if len(prs) > 1:
        raise ValueError("completed backlog row has multiple PRs")
    if len(text.encode()) > LIMIT:
        raise ValueError("completed backlog row exceeds 1 MiB")
    beads = bead_ids(text)
    return {"project": str(project), "repo": repo, "pr": next(iter(prs), ""), "beads": beads, "text": text}


def repository_names(project, limit=None):
    path = Path(project).expanduser()
    if not path.is_absolute():
        return {project}
    names = {path.name}
    if not (path / ".git").exists():
        return names
    try:
        url = read_command(["git", "-C", str(path), "remote", "get-url", "origin"], str(path), limit)
    except StageLimit:
        raise
    except (OSError, ValueError, subprocess.SubprocessError):
        return names
    names.add(re.sub(r"\.git$", "", re.split(r"[/:]", url.strip().rstrip("/"))[-1]))
    return names


def same_owner(row, source, limit=None):
    if row["pr"] and source["pr"] and row["pr"] != source["pr"]:
        return False
    return not repository_names(row["repo"], limit).isdisjoint(
        repository_names(source.get("repo", source["project"]), limit))


def backlog_references(source, task_id, limit=None, *, bead_batch=None):
    backlog = source["backlog"]
    legacy = backlog.get("legacy", False)
    if legacy and not backlog.get("closed", False):
        try:
            completed = completed_source(Path(backlog["data"]), task_id, limit)
        except StageLimit:
            raise
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            source["unread"] = [task_id]
            raise RetainWhole(f"unread completed row {task_id}: {error}") from error
        if not same_owner(completed, source, limit):
            source["unread"] = [task_id]
            raise RetainWhole(f"completed row {task_id} changed project or PR")
        backlog["refreshed_text"] = completed["text"]
        source["beads"] = sorted(set(source["beads"]) | set(completed["beads"]))
    legacy_text = backlog["text"] + "\n" + backlog.get("refreshed_text", "") if legacy else ""
    def read_batch(required, beads):
        try:
            response = json.loads(read_command([
                "bash", str(Path(__file__).absolute().with_name("fm-task-data-lib.sh")),
                "backlog-references", backlog["data"], task_id,
                "1" if required else "0", *beads,
            ], str(Path(backlog["data"]).parent), limit))
            if (not isinstance(response, dict) or not isinstance(response.get("text"), str)
                    or response.get("task") not in (None, task_id)
                    or (required and response.get("task") != task_id)
                    or not isinstance(response.get("unread"), list)
                    or not isinstance(response.get("archived"), list)
                    or any(not isinstance(item, str) for item in response["unread"] + response["archived"])):
                raise ValueError("invalid backlog reference response")
        except StageLimit:
            raise
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            source["unread"] = sorted(set([task_id, *source["beads"]]))
            raise UnreadReferences(f"unread references {', '.join(source['unread'])}: {error}") from error
        # tasks-axi show cannot see archived rows, so the archive decides.
        for bead in response["archived"]:
            try:
                rows = completed_rows(Path(backlog["data"]), bead, limit)
            except StageLimit:
                raise
            except (OSError, ValueError, subprocess.SubprocessError):
                response["unread"].append(bead)
                continue
            response["text"] += "".join(row[3] + "\n" for row in rows)
        return response

    def read_backlog(required):
        # Expiry owns its pending queue: row discovery records new beads but
        # cannot expand the current read. Other callers resolve the full set,
        # with the same subprocess bound even after a row or archive refresh.
        beads = source["beads"] if bead_batch is None else bead_batch
        response = {"task": None, "text": "", "unread": [], "archived": []}
        for offset in range(0, max(len(beads), 1), BEAD_BATCH_SIZE):
            batch = read_batch(required, beads[offset:offset + BEAD_BATCH_SIZE])
            response["task"] = response["task"] or batch["task"]
            response["text"] += batch["text"] + "\n"
            response["unread"] = sorted(set(response["unread"]) | set(batch["unread"]))
            response["archived"] += batch["archived"]
        return response

    response = read_backlog(backlog["task"] is not None and not legacy)
    if not legacy:
        backlog["task"] = response["task"]
    source["unread"] = response["unread"]
    if not legacy and task_id not in source["unread"]:
        discovered = set(bead_ids(response["text"])) - set(source["beads"])
        if discovered:
            source["beads"] = sorted(set(source["beads"]) | discovered)
            if bead_batch is None:
                response = read_backlog(backlog["task"] is not None)
                source["unread"] = response["unread"]
    archived_text = ""
    if not legacy and task_id in source["unread"]:
        try:
            completed = completed_source(Path(backlog["data"]), task_id, limit)
        except StageLimit:
            raise
        except (OSError, ValueError, subprocess.SubprocessError):
            completed = None
        if completed is not None:
            if not same_owner(completed, source, limit):
                raise RetainWhole(f"completed row {task_id} changed project or PR")
            archived_text = completed["text"]
            source["unread"].remove(task_id)
            source["beads"] = sorted(set(source["beads"]) | set(completed["beads"]))
            response = read_backlog(False)
            source["unread"] = response["unread"]
    if source["unread"]:
        raise UnreadReferences(f"unread references: {', '.join(source['unread'])}")
    return legacy_text + "\n" + archived_text + "\n" + response["text"]


def references(views, sources, task_id, limit=None):
    texts, oversized = [], []
    for view in views:
        text, skipped = local_references(*view, limit)
        texts.append(text)
        oversized += skipped
    if oversized:
        sources[-1]["unread"] = sorted(set(sources[-1].get("unread", [])) | set(oversized))
        raise RetainWhole(f"kept evidence over 16 MiB: {', '.join(oversized)}")
    local = "\n".join(texts)
    sources[-1]["beads"] = sorted(set(sources[-1]["beads"]) | set(bead_ids(local)))
    for source in sources:
        project, pr = source["project"], source["pr"]
        texts.append(backlog_references(source, task_id, limit))
        if pr:
            try:
                texts.append(read_command(["bash", str(Path(__file__).absolute().with_name("fm-task-data-lib.sh")),
                                           "references", pr], project, limit))
            except StageLimit:
                raise
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                source["unread"] = sorted(set(source.get("unread", [])) | {pr})
                raise RetainWhole(f"unread PR {pr}: {error}") from error
    return unquote(html.unescape("\n".join(texts)))


def folded_name(name):
    # Dotless i is re.IGNORECASE's extra equivalence beyond casefold.
    return unicodedata.normalize("NFD", name).casefold().replace("\u0131", "i")


def filename_matcher(names):
    """Find candidate basenames in one scan, then let linked verify aliases.

    A prefix trie keeps the regex from trying every filename at each character.
    Lookahead finds overlapping names; terminal prefixes of the longest match
    also count (both 'capture' and 'capture.png' retain their original rules).
    """
    trie = {}
    for name in set(names):
        key = folded_name(name)
        for spelling in (key, folded_name(json.dumps(name)[1:-1])):
            node = trie
            for char in spelling:
                node = node.setdefault(char, {})
            node.setdefault(None, set()).add(key)

    def pattern(node):
        prefix = ""
        while None not in node and len(node) == 1:
            char, node = next(iter(node.items()))
            prefix += re.escape(char)
        branches = [re.escape(char) + pattern(child) for char, child in node.items() if char is not None]
        if not branches:
            return prefix
        suffix = branches[0] if len(branches) == 1 else "(?:" + "|".join(branches) + ")"
        return prefix + ("(?:" + suffix + ")?" if None in node else suffix)

    matcher = re.compile("(?=(" + pattern(trie) + "))") if trie else None

    def candidates(text):
        found = set()
        if matcher is None:
            return found
        for spelling in {match[1] for match in matcher.finditer(text)}:
            node = trie
            for char in spelling:
                node = node[char]
                found.update(node.get(None, ()))
        return found

    return candidates


def linked(rel, text, directory, normalized, offsets, cache=None, candidates=None):
    # Basename matching also protects relative Markdown links and escaped JSON
    # paths without guessing which directory a PR or bead used as its base.
    key = (rel.name, directory)
    matches = cache.get(key) if cache is not None else None
    if matches is None:
        if candidates is not None and folded_name(rel.name) not in candidates:
            if cache is not None:
                cache[key] = set()
            return False
        if not directory and (rel.name in text or json.dumps(rel.name)[1:-1] in text):
            matches = True
        else:
            name = unicodedata.normalize("NFD", rel.name)
            pattern = "(" + re.escape(name) + ")"
            if directory:
                prefix = r'''(?:(?<=[/(`<"'])|:[ \t]+|(?<![\w.-])(?=''' + re.escape(name) + r"/))"
                pattern = prefix + pattern + r'''(?=/?(?:$|[\s)\]}>'",;?#]))'''
            matches = set()
            for match in re.finditer(pattern, normalized, re.IGNORECASE):
                start, end = match.span(1)
                if offsets is not None:
                    start, end = offsets[start], offsets[end - 1] + 1
                matches.add(text[start:end])
        if cache is not None:
            cache[key] = matches
    if matches is True:
        return True
    for spelling in matches:
        alias = rel.with_name(spelling)
        try:
            if os.path.samestat(alias.lstat(), rel.lstat()):
                return True
        except (FileNotFoundError, NotADirectoryError):
            pass
    return False


def protected(path, targets):
    return path in targets or any(parent in targets for parent in path.parents)


def retention_paths(root, files, all_directories, repos, text, limit=None, *, ordinary=True):
    check_limit(limit)
    targets, directories = set(), set()
    # Pointers are durable evidence even if a later report stops linking the
    # original. The offload journal preserves their virtual paths through the
    # ordinary scratch hold/restore cycle as well.
    if ordinary:
        journal = root / OFFLOAD_RECORD
        if journal.exists() or journal.is_symlink():
            if journal.is_symlink() or not journal.is_file() or journal.stat().st_size > LIMIT:
                raise RetainWhole("unsafe offload journal; retain pointer evidence")
            try:
                record = json.loads(journal.read_text())
                if record.get("version") != 1 or not isinstance(record.get("entries"), dict):
                    raise ValueError("invalid offload journal")
                for relative in record["entries"]:
                    rel = Path(relative)
                    if rel.is_absolute() or ".." in rel.parts or not rel.parts:
                        raise ValueError("unsafe pointer path")
                    targets.add(root / rel)
            except (ValueError, AttributeError) as error:
                raise RetainWhole("unread offload journal; retain pointer evidence") from error
    batches = (text,) if isinstance(text, str) else text
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

    for rel in files:
        if ordinary and rel.parts[0] != HOLD and ordinary_evidence(root / rel, rel, repos):
            targets.add(root / rel)
    remaining = files + all_directories
    find_names = filename_matcher(rel.name for rel in remaining)
    for text in batches:
        check_limit(limit)
        if not remaining:
            continue
        decoded = []
        for match in re.finditer(r'"(?:[^"\\]|\\.)*"', text):
            try:
                decoded.append(json.loads(match.group()))
            except ValueError:
                pass
        text = "\n".join([text, *decoded])
        text += "\n" + re.sub(r"\\([" + re.escape(string.punctuation) + r"])", r"\1", text)
        check_limit(limit)
        normalized = unicodedata.normalize("NFD", text)
        candidates = find_names(normalized.casefold().replace("\u0131", "i"))
        offsets = None
        if normalized != text:
            offsets = array("l")
            for start in range(0, len(text), CHUNK):
                check_limit(limit)
                piece = text[start:start + CHUNK]
                offsets.extend(range(start, start + len(piece)) if unicodedata.is_normalized("NFD", piece) else (
                    index for index, character in enumerate(piece, start) for _ in unicodedata.normalize("NFD", character)))
        cache = {}
        unmatched = []
        for rel in remaining:
            check_limit(limit)
            if rel == Path(HOLD):
                continue
            actual = root / rel
            virtual = root / rel.relative_to(HOLD) if rel.parts[0] == HOLD else actual
            if protected(virtual, targets):
                continue
            is_directory = stat.S_ISDIR(entries[actual].st_mode)
            if linked(actual, text, is_directory, normalized, offsets, cache, candidates):
                targets.add(virtual)
                if is_directory:
                    directories.add(virtual)
            else:
                unmatched.append(rel)
        remaining = unmatched

    # Classify every alias before plan deduplicates bytes or cleanup moves or
    # removes paths. Include held aliases under their original virtual paths.
    inodes = {}
    for rel in files:
        check_limit(limit)
        info = entries[root / rel]
        if info.st_nlink > 1:
            inodes.setdefault((info.st_dev, info.st_ino), []).append(virtual_path(root / rel))
    pending_inodes = list(inodes.values())
    pending_links = [root / rel for rel in files if (root / rel).is_symlink()]
    while pending_links or pending_inodes:
        remaining_inodes = []
        for aliases in pending_inodes:
            check_limit(limit)
            if any(path.relative_to(root).parts[0] == "record" or protected(path, targets)
                   for path in aliases):
                targets.update(aliases)
            else:
                remaining_inodes.append(aliases)
        remaining = []
        for actual in pending_links:
            check_limit(limit)
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
        # A retained symlink can protect another inode, and a hard-linked
        # symlink alias can resolve to a different relative target.
        if len(remaining) == len(pending_links) and len(remaining_inodes) == len(pending_inodes):
            break
        pending_links, pending_inodes = remaining, remaining_inodes
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


TRASH = os.environ.get("FM_TASK_DATA_TRASH", "/usr/bin/trash")


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
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL)


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


def pending(data):
    tried = []
    for receipt in real_directory(data, resolve_parent=True).glob(f"*/{RECEIPT}"):
        task_id = receipt.parent.parent.name
        if not TASK_ID.fullmatch(task_id):
            continue
        try:
            info = receipt.lstat()
        except OSError:
            continue
        record = None
        if stat.S_ISREG(info.st_mode) and info.st_size <= LIMIT:
            try:
                record = json.loads(receipt.read_text())
            except (OSError, ValueError):
                pass
        if not (isinstance(record, dict) and record.get("version") == 1 and record.get("expired") is True):
            expiry = record.get("expiry") if isinstance(record, dict) else None
            tried.append((info.st_mtime, task_id, expiry if expiry in MARKS else ""))
    for _, task_id, expiry in sorted(tried):
        print(f"{task_id}\t{expiry}")


def mark(data, task_id, expiry):
    if not TASK_ID.fullmatch(task_id) or expiry not in MARKS:
        raise ValueError("invalid expiry mark")
    root = real_directory(real_directory(data, resolve_parent=True) / task_id)
    receipt = root / RECEIPT
    if (receipt.is_symlink() or not receipt.is_file() or receipt.stat().st_nlink != 1
            or receipt.stat().st_size > LIMIT):
        raise ValueError("unsafe cleanup record")
    record = json.loads(receipt.read_text())
    if not isinstance(record, dict) or record.get("version") != 1 or record.get("task") != task_id:
        raise ValueError("invalid cleanup record")
    record["expiry"] = expiry
    write_record(root, record)


def stage_limit():
    value = os.environ.get("FM_TEARDOWN_DATA_STAGE_TIMEOUT", "")
    seconds = int(value) if value.isdigit() and not value.startswith("0") else 10
    return time.monotonic() + seconds, seconds


OFFLOAD_RECORD = "record/data-offload.json"
OFFLOAD_ROOT = "/Volumes/MINI-DATA/firstmate-task-evidence"
OFFLOAD_POINTER = "firstmate-task-evidence-v1"


def offload_closed(data, state, task_id, rows):
    if not TASK_ID.fullmatch(task_id):
        raise ValueError("invalid task id")
    for suffix in ("meta", "backlog-close"):
        path = state / f"{task_id}.{suffix}"
        if path.exists() or path.is_symlink():
            raise ValueError("task is live or its close is unfinished")
    candidates = rows.get(task_id, [])
    if any(row[1] is None for row in candidates):
        raise ValueError("task still has an open or in-progress backlog row")
    candidates = [row for row in candidates if row[0]] or candidates
    if not candidates or any(not row[1] for row in candidates):
        raise ValueError("closed date is missing or ambiguous")
    closed = max(row[1] for row in candidates)
    # Dates have no time of day: wait through the whole seventh local day.
    if date.today() <= date.fromisoformat(closed) + timedelta(days=7):
        raise ValueError("task has not been closed for seven complete days")
    return closed, "\n".join(row[3] for row in candidates if row[1] == closed)


def offload_bead_text(bead, locations, cache):
    if bead in cache:
        return cache[bead]
    owners = [(prefix, home) for home, prefix in locations if bead.startswith(prefix + "-")]
    if not owners:
        raise ValueError(f"unresolved bead owner: {bead}")
    _, home = max(owners, key=lambda item: len(item[0]))
    path = Path.home() / home / ".beads/beads.db"
    try:
        with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5) as db:
            columns = {row[1] for row in db.execute("PRAGMA table_info(issues)")}
            fields = [name for name in ("description",) if name in columns]
            if "id" not in columns or not fields:
                raise ValueError("unsupported bead database schema")
            projections = [f"substr({name}, 1, {KEPT_LIMIT + 1})" for name in fields]
            result = db.execute("SELECT " + ",".join(projections) + " FROM issues WHERE id = ?", (bead,)).fetchone()
            texts = [value for value in (result or ()) if isinstance(value, str)]
            length = sum(len(value.encode()) for value in texts)
            if length > KEPT_LIMIT:
                raise ValueError("bead evidence exceeds 16 MiB")
            comments = {row[1] for row in db.execute("PRAGMA table_info(comments)")}
            if {"issue_id", "text"} <= comments:
                for row in db.execute(f"SELECT substr(text, 1, {KEPT_LIMIT + 1}) FROM comments WHERE issue_id = ?", (bead,)):
                    if isinstance(row[0], str):
                        length += len(row[0].encode())
                        if length > KEPT_LIMIT:
                            raise ValueError("bead evidence exceeds 16 MiB")
                        texts.append(row[0])
            text = "\n".join(texts)
            if len(text.encode()) > KEPT_LIMIT:
                raise ValueError("bead evidence exceeds 16 MiB")
    except (sqlite3.Error, OSError, ValueError) as error:
        raise ValueError(f"unread bead {bead}: {type(error).__name__}") from error
    if len(text.encode()) + sum(len(value.encode()) for value in cache.values()) <= TOTAL_LIMIT:
        cache[bead] = text
    return text


def offload_repository_marker(path, names, leaves):
    if ".git" in names or ".git" in leaves:
        return path / ".git"
    if {"objects", "refs"} <= set(names) and "HEAD" in leaves:
        return path
    return None


def offload_inventory(root, data):
    # Units: each outermost repository outside record/, joined with its linked
    # worktrees in the task into the smallest folder below the task holding
    # them all. Every repository below it is classified too. Repository work in
    # the scratch recovery hold still belongs to expiry and blocks offload.
    groups = []
    for directory, names, leaves in os.walk(root, followlinks=False):
        path = Path(directory)
        rel = path.relative_to(root)
        if rel.parts[:1] == ("record",):
            names[:] = []
            continue
        marker = offload_repository_marker(path, names, leaves)
        names[:] = [name for name in names if name != ".git"]
        if not marker:
            continue
        if not rel.parts:
            raise ValueError("the task folder is itself a repository")
        if rel.parts[0] == HOLD:
            raise ValueError("the scratch recovery hold contains repository work")
        links, reason = offload_unit_links(path, root, data)
        unit = Path(os.path.commonpath([path, *links]))
        if unit == root:
            unit, reason = path, reason or "shares no folder below the task with its linked worktrees"
        groups.append((unit, reason))
    # A unit inside another moves with it, and anything kept keeps the whole.
    units = {}
    for unit, reason in sorted(groups, key=lambda item: len(item[0].parts)):
        outer = next((path for path in units if path == unit or path in unit.parents), None)
        if outer is None:
            units[unit] = reason
        elif units[outer] is None:
            units[outer] = reason
    return (*inventory(root), units)


def offload_unit_links(repository, root, data):
    """Return the task paths a repository moves with, and why it must stay, if it must."""
    dotgit = repository / ".git"
    links = []
    try:
        if dotgit.is_symlink():
            return links, "its .git is a symlink; its repository lives elsewhere"
        if dotgit.is_file():
            text = dotgit.read_text().strip()
            if not text.startswith("gitdir: "):
                return links, "linked worktree record is unreadable"
            gitdir = (repository / text.removeprefix("gitdir: ")).resolve()
            commondir = gitdir / "commondir"
            common = (gitdir / commondir.read_text().strip()).resolve() if commondir.is_file() else gitdir
            if root in common.parents:
                return [common], None
            if not commondir.is_file():
                return links, "submodule checkout; offloaded only as part of its superproject"
            if common == data or data in common.parents:
                return links, "linked worktree of a repository in another task"
            return links, "linked worktree of a repository outside data/"
        admin = (dotgit if dotgit.is_dir() else repository) / "worktrees"
        for record in sorted(admin.glob("*/gitdir")) if admin.is_dir() and not admin.is_symlink() else ():
            tree = (record.parent / record.read_text().strip()).parent.resolve()
            if not (tree.exists() or tree.is_symlink()) or tree == repository or repository in tree.parents:
                continue
            if root not in tree.parents:
                return links, "has linked worktrees outside the task"
            links.append(tree)
    except (OSError, UnicodeError):
        return links, "linked worktree record is unreadable"
    return links, None


ARCHIVE = ".firstmate-offload-"


def offload_tree_state(path):
    entries = []
    for directory, names, leaves in os.walk(path, followlinks=False):
        for name in (".", *names, *leaves):
            info = os.lstat(os.path.join(directory, name))
            entries.append((os.path.join(directory, name), info.st_mode, info.st_size, info.st_mtime_ns,
                            info.st_ctime_ns, info.st_ino))
    return sorted(entries)


def offload_discard(path):
    # Only this round's own archive copy; task evidence leaves through Trash.
    if path.is_file() and not path.is_symlink():
        guard_command(["rm", "-f", "--", str(path)])


def offload_xattrs(path):
    """Return every extended attribute of path, without following a symlink."""
    if hasattr(os, "listxattr"):
        return {os.fsencode(name): os.getxattr(path, name, follow_symlinks=False)
                for name in os.listxattr(path, follow_symlinks=False)}
    if sys.platform != "darwin":
        return {}
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    libc.listxattr.restype = libc.getxattr.restype = ctypes.c_ssize_t
    libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                              ctypes.c_uint32, ctypes.c_int]
    nofollow, target = 1, os.fsencode(path)

    def read(fetch):
        size = fetch(None, 0)
        if size < 0:
            raise OSError(ctypes.get_errno(), "extended attribute read failed", str(path))
        buffer = ctypes.create_string_buffer(size)
        if fetch(buffer, size) != size:
            raise ValueError(f"extended attributes changed while reading: {path}")
        return buffer.raw

    names = [name for name in read(lambda out, size: libc.listxattr(target, out, size, nofollow)).split(b"\0")
             if name]
    return {name: read(lambda out, size, name=name: libc.getxattr(target, name, out, size, 0, nofollow))
            for name in names}


def offload_archive(source, archive):
    # A repository travels as one tar file: the remote and independent
    # manifests accept a single file, and tar keeps .git, symlinks and hard
    # links exactly. Extended attributes, macOS resource forks included, ride
    # in SCHILY.xattr headers that `tar --xattrs -x` restores.
    for directory, names, leaves in os.walk(source, followlinks=False):
        for name in names + leaves:
            mode = os.lstat(os.path.join(directory, name)).st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
                raise ValueError("special file in repository")

    def carry(info):
        for name, value in offload_xattrs(source.parent / info.name).items():
            info.pax_headers["SCHILY.xattr." + name.decode("utf-8", "surrogateescape")] = (
                value.decode("utf-8", "surrogateescape"))
        return info

    descriptor = os.open(archive, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.PAX_FORMAT) as tar:
            tar.add(source, arcname=source.name, filter=carry)
        stream.flush()
        os.fsync(stream.fileno())


def offload_journal(root, task_id):
    """Read a task's offload journal, or a new one when it has none."""
    path = root / OFFLOAD_RECORD
    if path.parent.is_symlink() or (path.parent.exists() and not path.parent.is_dir()):
        raise ValueError("unsafe offload record directory")
    if not (path.exists() or path.is_symlink()):
        return {"version": 1, "task": task_id, "entries": {}}
    if path.is_symlink() or path.stat().st_size > LIMIT or path.stat().st_nlink != 1:
        raise ValueError("unsafe offload record")
    record = json.loads(path.read_text())
    archives = record.get("archives", []) if isinstance(record, dict) else None
    if (not isinstance(record, dict) or record.get("task") != task_id or record.get("version") != 1
            or not isinstance(record.get("entries"), dict) or not isinstance(archives, list)
            or any(not isinstance(name, str) or not re.fullmatch(re.escape(ARCHIVE) + "[0-9a-f]{16}[.]tar", name)
                   for name in archives)):
        raise ValueError("invalid offload record")
    return record


def offload_pointer(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > LIMIT:
        return False
    try:
        return json.loads(path.read_text()).get("format") == OFFLOAD_POINTER
    except (ValueError, UnicodeError, AttributeError):
        return False


def offload_reference_text(root, row, locations, cache):
    # The broader scratch keep rule reads incidental text too. Moving that
    # evidence needs the narrower authority of a task report or named bead.
    beads = set(bead_ids(row))
    report = root / "report.md"
    text = ""
    if report.exists() or report.is_symlink():
        if report.is_symlink() or not report.is_file() or report.stat().st_size > KEPT_LIMIT:
            raise ValueError("unsafe or oversized task report")
        with report.open("rb") as stream:
            payload = stream.read(KEPT_LIMIT + 1)
        if len(payload) > KEPT_LIMIT:
            raise ValueError("task report exceeds its 16 MiB read limit")
        text = payload.decode(errors="replace")
        beads.update(bead_ids(text))
    receipt = root / RECEIPT
    if receipt.exists() or receipt.is_symlink():
        if (receipt.parent.is_symlink() or receipt.is_symlink() or not receipt.is_file()
                or receipt.stat().st_size > LIMIT):
            raise ValueError("unsafe cleanup sources for bead discovery")
        with receipt.open("rb") as stream:
            payload = stream.read(LIMIT + 1)
        if len(payload) > LIMIT:
            raise ValueError("cleanup sources exceed their 1 MiB read limit")
        record = json.loads(payload)
        if (not isinstance(record, dict) or record.get("version") != 1 or record.get("task") != root.name
                or not isinstance(record.get("sources"), list)):
            raise ValueError("invalid cleanup sources for bead discovery")
        for source in record["sources"]:
            if (not isinstance(source, dict) or not isinstance(source.get("beads"), list)
                    or any(not isinstance(bead, str) for bead in source["beads"])):
                raise ValueError("invalid saved bead references")
            beads.update(bead for bead in source["beads"] if is_bead_id(bead))
    for bead in sorted(beads):
        text += "\n" + offload_bead_text(bead, locations, cache)
        if len(text.encode()) > TOTAL_LIMIT:
            raise ValueError("offload reference text exceeds its 16 MiB read limit")
    return text


def offload_candidates(data, state, task_id, rows, locations, cache):
    """Return the task's moves and the repository units it keeps, with reasons."""
    closed, row = offload_closed(data, state, task_id, rows)
    root = real_directory(data / task_id)
    files, directories, repos, units = offload_inventory(root, data)
    # Only locally available report/bead evidence is needed here. Unlike
    # scratch expiry, offload never consults a forge or reads a live PR.
    text = offload_reference_text(root, row, locations, cache)
    targets, _ = retention_paths(root, files, directories, repos, text, ordinary=False)
    totals = {}
    for leaf in files:
        path = root / leaf
        info = path.lstat()
        blocked = stat.S_ISLNK(info.st_mode) or info.st_nlink != 1
        for ancestor in (path, *path.parents):
            if ancestor == root:
                break
            summary = totals.setdefault(ancestor, [0, 0, 0, False])
            summary[0] += 1
            summary[1] += info.st_size
            summary[2] += info.st_blocks * 512
            summary[3] = summary[3] or blocked
    def outside_units(path):
        # A referenced directory holding a repository moves as its other
        # parts; the repository is its own unit below.
        if not any(path in unit.parents for unit in units):
            return [path]
        return [part for child in sorted(path.iterdir()) if child not in units for part in outside_units(child)]

    selected = []
    for target in sorted(targets, key=lambda item: (len(item.parts), str(item))):
        rel = target.relative_to(root)
        if not rel.parts or rel.parts[0] in (HOLD, "record"):
            continue
        if any(unit == target or unit in target.parents for unit in units):
            continue
        for path in outside_units(target):
            rel = path.relative_to(root)
            if path in selected or any(parent in selected for parent in path.parents):
                continue
            if path.is_file() and (ordinary_evidence(path, rel, repos) or offload_pointer(path)):
                continue
            # Symlinks and multiply linked files may still be in use through an
            # alias outside this task. Retain them until that ownership is proven.
            summary = totals.get(path, [0, 0, 0, False])
            if path.is_symlink() or summary[3]:
                continue
            if summary[0]:
                selected.append(path)
    result, kept = [], []
    for path in selected:
        result.append({"task": task_id, "path": str(path.relative_to(root)), "closed": closed,
                       "size": totals[path][1], "allocated_bytes": totals[path][2],
                       "reason": "report or bead referenced evidence; task closed over seven days"})
    for unit, reason in sorted(units.items()):
        summary = totals.get(unit, [0, 0, 0, False])
        if reason:
            kept.append({"task": task_id, "path": str(unit.relative_to(root)), "reason": reason,
                         "size": summary[1], "allocated_bytes": summary[2]})
            continue
        result.append({"task": task_id, "path": str(unit.relative_to(root)), "closed": closed,
                       "size": summary[1], "allocated_bytes": summary[2], "repository": True,
                       "reason": "repository of a task closed over seven days; offloaded whole as one archive"})
    return result, kept


def offload_context(data, state):
    data, state = real_directory(data, resolve_parent=True), real_directory(state, resolve_parent=True)
    locations = read_command(["bash", str(Path(__file__).absolute().with_name("fm-task-data-lib.sh")),
                              "bead-locations"], str(data.parent))
    return data, state, completed_row_index(data), [line.split() for line in locations.splitlines()], {}


def offload_plan(data, state, task_id=None):
    data, state, rows, locations, cache = offload_context(data, state)
    moves, retained, leftovers = [], [], []
    ids = [task_id] if task_id is not None else sorted(path.name for path in data.iterdir() if path.is_dir())
    for task in ids:
        with contextlib.suppress(OSError, ValueError):
            if TASK_ID.fullmatch(task) and offload_journal(data / task, task).get("archives"):
                leftovers.append(task)
        try:
            lock = state / f".meta-{task}.lock"
            if lock.exists() or lock.is_symlink():
                raise ValueError("task meta lock is present")
            found, kept = offload_candidates(data, state, task, rows, locations, cache)
            moves.extend(found)
            retained.extend(kept)
        except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
            retained.append({"task": task, "reason": str(error)})
    print(json.dumps({"moves": moves, "retained": retained, "leftovers": leftovers,
                      "total_bytes": sum(row["size"] for row in moves),
                      "total_allocated_bytes": sum(row["allocated_bytes"] for row in moves),
                      "backup_required": True}))


def offload_manifest(path):
    entries, size = [], 0
    device = path.lstat().st_dev
    pending = [(path, ".")]
    while pending:
        current, relative = pending.pop()
        info = current.lstat()
        if info.st_dev != device or stat.S_ISLNK(info.st_mode):
            raise ValueError("cross-device or symlink evidence")
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISDIR(info.st_mode):
            entries.append([relative, "directory", mode])
            children = list(current.iterdir())
            names = {child.name for child in children}
            if ".git" in names or {"objects", "refs", "HEAD"} <= names:
                raise ValueError("repository work is never offloaded")
            pending.extend((child, child.name if relative == "." else relative + "/" + child.name)
                           for child in children)
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            digest = hashlib.sha256()
            with current.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            after = current.lstat()
            if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (
                    after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise ValueError("evidence changed while checksumming")
            size += info.st_size
            entries.append([relative, "file", mode, info.st_size, digest.hexdigest()])
        else:
            raise ValueError("special or multiply linked evidence")
    payload = json.dumps(sorted(entries), ensure_ascii=True, separators=(",", ":")).encode()
    return {"checksum": hashlib.sha256(payload).hexdigest(), "size": size}


def offload_prepare(destination, expected):
    if destination.is_symlink():
        raise ValueError("unsafe payload symlink")
    if not destination.exists():
        return {"verified": False}
    try:
        if offload_manifest(destination) == expected:
            return {"verified": True}
    except (OSError, ValueError):
        # An interrupted copy may itself be unreadable or incomplete.
        # Keep it recoverable rather than deleting or merging over it.
        pass
    recovery = Path(tempfile.mkdtemp(prefix="incomplete-", dir=destination.parent))
    destination.rename(recovery / "payload")
    return {"verified": False}


def offload_remote(action, destination, expected=None):
    # Send only fixed code in the remote shell command; paths travel as JSON
    # on stdin. The same manifest function runs on both machines.
    import inspect
    program = ("import os, sys, json, stat, hashlib, tempfile\nfrom pathlib import Path\n"
               + inspect.getsource(offload_manifest) + inspect.getsource(offload_prepare) + '''
request = json.load(sys.stdin)
volume = Path("/Volumes/MINI-DATA")
if volume.is_symlink() or not volume.is_mount():
    raise ValueError("MINI-DATA is not mounted")
if request["action"] == "ready":
    print(json.dumps({"ready": True}))
    raise SystemExit
destination = Path(request["destination"])
relative = destination.relative_to(volume / "firstmate-task-evidence")
if not relative.parts or any(part in (".", "..") for part in relative.parts):
    raise ValueError("unsafe destination")
parent = volume
for part in destination.parent.relative_to(volume).parts:
    parent = parent / part
    if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
        raise ValueError("unsafe destination ancestor")
    if request["action"] == "prepare":
        parent.mkdir(exist_ok=True)
if request["action"] == "prepare":
    print(json.dumps(offload_prepare(destination, request["expected"])))
elif request["action"] == "verify":
    print(json.dumps(offload_manifest(destination)))
else:
    raise ValueError("unknown operation")
''')
    output = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "mini-ts",
                             "python3", "-c", shlex.quote(program)],
                            input=json.dumps({"action": action, "destination": destination, "expected": expected}),
                            capture_output=True, text=True, timeout=86400, check=True)
    return json.loads(output.stdout)


def offload_config(data):
    path = data.parent / "config/task-data-offload.json"
    if (path.parent.resolve() != path.parent or path.is_symlink() or not path.is_file() or path.stat().st_size > LIMIT
            or path.stat().st_mode & 0o022 or path.stat().st_uid != os.getuid() or path.stat().st_nlink != 1):
        raise ValueError("offload disabled: private config/task-data-offload.json with a backup verifier is required")
    config = json.loads(path.read_text())
    command = config.get("backup_verifier") if isinstance(config, dict) else None
    if (not isinstance(command, list) or not command or any(not isinstance(arg, str) or not arg for arg in command)
            or not Path(command[0]).is_absolute() or not os.access(command[0], os.X_OK)):
        raise ValueError("offload disabled: backup_verifier must name a trusted absolute executable")
    return command


def offload_backup(command, pointer):
    result = subprocess.run(command, input=json.dumps(pointer), capture_output=True, text=True,
                            timeout=86400, check=True)
    backup = json.loads(result.stdout)
    if (not isinstance(backup, dict) or backup.get("independent") is not True
            or not isinstance(backup.get("location"), str) or not backup["location"].strip()
            or backup["location"] == pointer["location"]
            or backup.get("checksum") != pointer["checksum"] or backup.get("size") != pointer["size"]):
        raise ValueError("backup verifier did not prove an independent matching copy")
    return backup["location"]


def offload_write(path, value):
    if path.parent.is_symlink() or (path.exists() and (path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1)):
        raise ValueError("unsafe offload record")
    descriptor, name = tempfile.mkstemp(prefix=".data-offload-", dir=path.parent)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    Path(name).replace(path)


def offload(data, state, task_id):
    data, state = real_directory(data, resolve_parent=True), real_directory(state, resolve_parent=True)
    command = offload_config(data)  # Refuse before even contacting the remote.
    data, state, rows, locations, cache = offload_context(data, state)
    offload_closed(data, state, task_id, rows)
    root = real_directory(data / task_id)
    record_path = root / OFFLOAD_RECORD
    record = offload_journal(root, task_id)

    def claim():
        # Journal the copy's name before it exists, so cleanup only ever
        # removes a file this offload created.
        name = f"{ARCHIVE}{secrets.token_hex(8)}.tar"
        record.setdefault("archives", []).append(name)
        safe_directory(root, Path("record"))
        offload_write(record_path, record)
        return root / name

    def release(name):
        if name not in record.get("archives", []):
            return
        leftover = root / name
        if leftover.is_symlink() or (leftover.exists() and not leftover.is_file()):
            raise ValueError(f"unsafe archive copy: {leftover}")
        offload_discard(leftover)
        record["archives"].remove(name)
        offload_write(record_path, record)
    candidates = {item["path"]: item for item in offload_candidates(data, state, task_id, rows, locations, cache)[0]}
    # A crash after Trash but before pointer publication leaves this journal.
    # Complete the pointer only after both copies are freshly verified again.
    for relative, pointer in record["entries"].items():
        rel = Path(relative)
        if rel.is_absolute() or ".." in rel.parts or not rel.parts or rel.parts[0] in ("record", HOLD):
            raise ValueError("unsafe offload journal path")
        path = root / rel
        if not path.exists() and not path.is_symlink():
            candidates[relative] = {"recovery": pointer}
    moved = []
    result = {"offloaded": moved}
    relative = None
    try:
        # An interrupted or refused round can leave its own journaled copy.
        for name in list(record.get("archives", [])):
            with contextlib.suppress(OSError, ValueError, subprocess.SubprocessError):
                release(name)
        for relative, candidate in candidates.items():
            source = root / relative
            if source.parent.resolve() != source.parent:
                raise ValueError("unsafe evidence parent")
            recovery = candidate.get("recovery")
            archive = None
            if candidate.get("repository"):
                try:
                    offload_remote("ready", OFFLOAD_ROOT)
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    raise ValueError("mini-ts did not answer or MINI-DATA is not mounted; no archive written") from error
                before = offload_tree_state(source)
                archive = claim()
            try:
                if archive:
                    try:
                        offload_archive(source, archive)
                    except FileExistsError:
                        # Never this round's file: unlist it rather than remove it.
                        record["archives"].remove(archive.name)
                        offload_write(record_path, record)
                        raise
                if recovery:
                    pointer = recovery
                    destination = pointer["location"].removeprefix("mini-ts:")
                    if (pointer.get("format") != OFFLOAD_POINTER or not pointer["location"].startswith("mini-ts:" + OFFLOAD_ROOT + "/")
                            or pointer.get("original") != str(source)):
                        raise ValueError("invalid offload recovery pointer")
                else:
                    copy = archive or source
                    manifest = offload_manifest(copy)
                    home = hashlib.sha256(str(data).encode()).hexdigest()[:16]
                    identity = hashlib.sha256(relative.encode()).hexdigest()[:16]
                    destination = f"{OFFLOAD_ROOT}/{home}/{task_id}/{identity}/{manifest['checksum']}/payload"
                    pointer = {"format": OFFLOAD_POINTER, "original": str(source), "location": "mini-ts:" + destination,
                               **manifest, "checksum_algorithm": "sha256-canonical-tree-v1", "closed": candidate["closed"]}
                    if archive:
                        pointer["archive"] = "tar"
                    prepared = offload_remote("prepare", destination, manifest)
                    if prepared.get("verified") is not True:
                        copy_source = str(copy) + ("/" if copy.is_dir() else "")
                        subprocess.run(["rsync", "-a", "--", copy_source, "mini-ts:" + destination],
                                       capture_output=True, text=True, timeout=86400, check=True)
                expected = {"checksum": pointer["checksum"], "size": pointer["size"]}
                if offload_remote("verify", destination) != expected:
                    raise ValueError("remote copy checksum or size mismatch; original retained")
                pointer["backup"] = offload_backup(command, pointer)
                offload_closed(data, state, task_id, completed_row_index(data))
                if not recovery:
                    if (offload_tree_state(source) != before) if archive else (offload_manifest(source) != expected):
                        raise ValueError("local evidence changed after copy; original retained")
                    record["entries"][relative] = pointer
                    safe_directory(root, Path("record"))
                    offload_write(record_path, record)
                    guard_command([TRASH, "-s", str(source)])
                    if source.exists() or source.is_symlink():
                        raise ValueError("Trash did not move the original; pointer not published")
                # Never replace newly created work, including a concurrent broken link.
                with source.open("x") as stream:
                    json.dump(pointer, stream, sort_keys=True)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
            finally:
                # A copy left by a refused discard stays journaled for the next pass.
                if archive:
                    with contextlib.suppress(OSError, ValueError, subprocess.SubprocessError):
                        release(archive.name)
            moved.append({"task": task_id, "path": relative, **expected, "location": pointer["location"],
                          **({"archive": "tar"} if pointer.get("archive") else {})})
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.SubprocessError) as error:
        result["failed"] = {"task": task_id, "path": relative, "reason": str(error)}
        raise
    finally:
        result["total_bytes"] = sum(item["size"] for item in moved)
        print(json.dumps(result))


def cleanup(action, data, state, task_id, project="", pr=""):
    dry_run = action == "plan"
    if dry_run:
        action = "expire"

    def save(root, record):
        if not dry_run:
            write_record(root, record)

    if not TASK_ID.fullmatch(task_id):
        raise ValueError("invalid task id")
    limit = stage_limit() if action in ("stage", "retire") else None
    data = real_directory(data, resolve_parent=True)
    state = real_directory(state, resolve_parent=True)
    if dry_run:
        request = state / ".task-data-sweep.rerun"
        if request.exists() and request.read_text().strip() == task_id:
            raise RetainWhole("latest completion keeps its recovery until a different task completes")
        lock = state / f".meta-{task_id}.lock"
        if lock.exists() or lock.is_symlink():
            try:
                pid = int((lock / "pid").read_text().strip())
                if pid <= 0:
                    raise ValueError("invalid lock owner")
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            except (OSError, ValueError) as error:
                raise RetainWhole(f"task lock owner is unresolved: {error}") from error
            else:
                raise RetainWhole("task meta lock is held by a live process")
    meta = state / f"{task_id}.meta"
    values = None
    if action in ("prepare", "retire"):
        if meta.exists() or meta.is_symlink():
            if meta.is_symlink() or not meta.is_file():
                raise ValueError("unsafe retiring task record")
            values = dict(line.split("=", 1) for line in meta.read_text().splitlines() if "=" in line)
            if values.get("kind") == "secondmate":
                return
            project = values.get("project", "")
            pr = pr or values.get("pr", "")
    elif (meta.exists() or meta.is_symlink()
          or (action == "expire" and ((state / f"{task_id}.backlog-close").exists()
                                     or (state / f"{task_id}.backlog-close").is_symlink()))):
        raise ValueError(f"task is still live: {task_id}")
    root = data / task_id
    if not root.exists() and not root.is_symlink():
        return
    root = real_directory(root)
    receipt = root / RECEIPT
    if receipt.parent.is_symlink() or (receipt.parent.exists() and not receipt.parent.is_dir()):
        raise ValueError("unsafe record directory")
    record = None
    legacy = None
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
                        or "task" not in backlog or backlog["task"] not in (None, task_id)
                        or not isinstance(backlog.get("legacy", False), bool)
                        or not isinstance(backlog.get("closed", False), bool)
                        or not isinstance(backlog.get("refreshed_text", ""), str)
                        or (backlog.get("legacy") and not isinstance(backlog.get("text"), str))):
                    raise ValueError("invalid backlog source")
        for source in record["sources"]:
            source["beads"] = sorted({bead for bead in source["beads"] if is_bead_id(bead)})
        if action == "expire" and record.get("expired"):
            if dry_run:
                print(json.dumps({"task": task_id, "eligible": False, "reason": "already expired", "reclaim_bytes": 0}))
            return
    elif action in ("expire", "retire"):
        return
    new_legacy = action == "prepare" and values is None and (
        record is None or (record.get("expired") and any(
            source.get("backlog", {}).get("legacy") for source in record["sources"])))
    if new_legacy or (values is None and record and not record.get("expired")
                      and any(source.get("backlog", {}).get("legacy")
                              and not source["backlog"].get("closed", False) for source in record["sources"])):
        try:
            legacy = completed_source(data, task_id, limit)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            if dry_run:
                raise
            print(f"warning: task data {task_id} retained whole for retry: {error}", file=sys.stderr)
            return
    if action in ("prepare", "retire") and values is None:
        if new_legacy:
            project, pr = legacy["project"], legacy["pr"]
        else:
            project = record["sources"][-1]["project"]
            pr = pr or record["sources"][-1]["pr"]
    hold = root / HOLD
    if hold.is_symlink() or (hold.exists() and not hold.is_dir()):
        raise ValueError("unsafe recovery directory")
    if hold.exists() and record is None:
        raise ValueError("unowned recovery directory")
    files, all_directories, repos = inventory(root)
    too_large = ""
    try:
        check_limit(limit)
        local = ("" if action == "expire" else
                 unquote(html.unescape(local_references(root, files, repos, limit)[0])))
    except StageLimit as error:
        if record is not None:
            record["retained"] = str(error)
            save(root, record)
        print(f"warning: task data {task_id} retained whole for retry: {error}", file=sys.stderr)
        return
    except TooLarge as error:
        too_large, local = str(error), ""
    if record is None:
        record = {"version": 1, "task": task_id, "sources": [], "complete": False}
    if record.get("expired"):
        for source in record["sources"]:
            if source.get("backlog", {}).get("legacy"):
                source["backlog"]["closed"] = True
        record.update(complete=False, expired=False)
    if new_legacy:
        record["sources"].append({
            "project": project, "pr": pr, "beads": legacy["beads"],
            "backlog": {"data": str(data), "task": task_id, "legacy": True, "text": legacy["text"]},
        })
    if action in ("prepare", "stage", "retire"):
        source = next((item for item in record["sources"]
                       if item["project"] == project and item["pr"] == pr
                       and item.get("backlog", {"data": str(data)})["data"] == str(data)), None)
        if source:
            record["sources"].remove(source)
        record["sources"].append(source or {"project": project, "pr": pr, "beads": []})
        record["sources"][-1]["beads"] = sorted(set(record["sources"][-1]["beads"]) | set(bead_ids(local)))
    for source in record["sources"]:
        source.setdefault("backlog", {"data": str(data), "task": None})
    views = [(root, files, repos)]
    if record.get("expiry") != "too-large":
        record.pop("expiry", None)
    record.pop("retained", None)
    if too_large:
        record.update(expiry="too-large", retained=too_large)
    save(root, record)
    if too_large:
        print(f"warning: task data {task_id} retained whole and marked too-large: {too_large}", file=sys.stderr)
        return
    if action == "prepare":
        try:
            backlog_references(record["sources"][-1], task_id)
        except UnreadReferences as error:
            print(f"warning: task data {task_id} retained whole for retry: {error}", file=sys.stderr)
        finally:
            save(root, record)
        return
    if shutil.which("dcg") is None:
        raise ValueError("dcg is unavailable")
    try:
        text = (expiry_reference_batches(views, record["sources"], task_id, limit) if action == "expire"
                else references(views, record["sources"], task_id, limit))
        targets, directories = retention_paths(root, files, all_directories, repos, text, limit)
    except StageLimit as error:
        if dry_run:
            raise
        record["retained"] = str(error)
        print(f"warning: task data {task_id} retained whole for retry: {error}", file=sys.stderr)
        return
    except RetainWhole as error:
        if dry_run:
            raise
        if action != "expire" or not unread_named(record, state, task_id, error):
            print(f"warning: task data {task_id} retained whole for retry: {error}", file=sys.stderr)
        return
    except UnreadReferences as error:
        if dry_run:
            raise
        if action != "expire" or not unread_named(record, state, task_id, error):
            print(f"warning: task data {task_id} retained whole for retry: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    finally:
        save(root, record)
    record.pop("unread_named", None)
    if dry_run:
        reclaim, kept, count = 0, 0, 0
        # retention_paths has already propagated protection across inode aliases.
        seen = set()
        for rel in files:
            virtual = rel.relative_to(HOLD) if rel.parts[0] == HOLD else rel
            info = (root / rel).lstat()
            inode = (info.st_dev, info.st_ino)
            if inode in seen:
                continue
            seen.add(inode)
            allocated = info.st_blocks * 512
            if virtual.parts[0] == "record" or protected(root / virtual, targets):
                kept += allocated
            else:
                reclaim += allocated
                count += 1
        print(json.dumps({"task": task_id, "eligible": True, "reclaim_bytes": reclaim,
                          "kept_bytes": kept, "scratch_files": count}))
        return
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
            record.pop("expiry", None)
            write_record(root, record)
            return
    for path, leaves in scratch:
        for rel in leaves:
            destination = path / HOLD / rel
            if destination.exists() or destination.is_symlink():
                raise ValueError(f"recovery collision: {destination}")
    if not any(leaves for _, leaves in scratch) and not any((path / HOLD).exists() for path, _, _ in views):
        record.update(complete=True, expired=True)
        record.pop("expiry", None)
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
        arities = {"prepare": {5, 6}, "retire": {5, 6}, "stage": {7}, "expire": {5}, "plan": {5}, "pending": {3}, "mark": {5},
                   "offload-plan": {4, 5}, "offload": {5}}
        if len(sys.argv) < 2 or len(sys.argv) not in arities.get(sys.argv[1], ()):
            raise ValueError(__doc__)
        if sys.argv[1] == "offload-plan":
            offload_plan(*sys.argv[2:])
        elif sys.argv[1] == "offload":
            offload(*sys.argv[2:])
        elif sys.argv[1] == "pending":
            pending(sys.argv[2])
        elif sys.argv[1] == "mark":
            mark(*sys.argv[2:])
        elif sys.argv[1] in ("prepare", "retire") and len(sys.argv) == 6:
            cleanup(*sys.argv[1:5], pr=sys.argv[5])
        else:
            cleanup(*sys.argv[1:])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        if sys.argv[1:2] == ["plan"]:
            print(json.dumps({"task": sys.argv[4], "eligible": False, "reason": str(error), "reclaim_bytes": 0}))
            sys.exit(0)
        print(f"warning: task data retained for recovery: {error}", file=sys.stderr)
        sys.exit(1)
