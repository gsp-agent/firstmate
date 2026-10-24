#!/usr/bin/env python3
"""Idle-route hints, never routing authority. Called by fm-captain-hold.sh.

select reads one tasks-axi listing; record and check read the row's --full show.
Only successful, locally decidable idle outcomes are recorded under the row lock.
Missing fields, bad stamps and pending bodies always route.
The listing caps bodies at 500 UTF-16 units and names the full length. A hint
digests exactly what the listing shows (that prefix and length) and, separately,
the complete body. The listing alone proves a row idle only when its visible
prefix holds every line an idle route reads: the active hold fields up to the
first `Previous task body:` line, with no resolution record among them. Other
rows that match are printed as `<id>/verify` for one bounded full read (check).
No backend reads or subprocesses happen here.
"""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time


FIELDS = ("id", "state", "held", "hold_kind", "hold_reason", "hold_until", "body")
LIMIT = 500  # tasks-axi's list body limit, in JavaScript (UTF-16) string units
HISTORY = "Previous task body:"  # fm-captain-hold.sh's HOLD_HISTORY_HEADER
MARKER = re.compile(r"\n\.\.\. \(truncated, ([0-9]+) chars total - [^\n]*\)")


def scalar(value):
    return json.loads(value) if value.startswith('"') else value


def columns(line):
    """TOON's flat string cells use JSON escapes, not CSV doubled quotes."""
    values = []
    while line:
        if line.startswith('"'):
            value, end = json.JSONDecoder().raw_decode(line)
        else:
            end = line.find(",")
            if end < 0:
                end = len(line)
            value = line[:end]
        values.append(value)
        if end == len(line):
            break
        if line[end] != ",":
            raise ValueError("invalid listing cell")
        line = line[end + 1:]
    return values


def routing_context(router):
    # Read shared routing code once per batch, never once per listed row.
    try:
        router_hash = hashlib.sha256(router.read_bytes()).hexdigest()
    except FileNotFoundError:
        router_hash = "absent"
    implementation = Path(__file__).with_name("fm-captain-hold.sh").read_bytes()
    return [str(router), router_hash, hashlib.sha256(implementation).hexdigest(),
            os.environ.get("TZ"), time.tzname]


def utf16(text):
    return text.encode("utf-16-le", "surrogatepass")


def listed_body(body):
    """What the listing shows of a complete body: (visible prefix, full length)."""
    raw = utf16(body)
    if len(raw) <= 2 * LIMIT:
        return body, len(raw) // 2
    visible = raw[:2 * LIMIT].decode("utf-16-le", "surrogatepass")
    # slice(0, 500) can split a surrogate pair; Node writes that lone high
    # half to UTF-8 as U+FFFD, so the listing shows U+FFFD there.
    if "\ud800" <= visible[-1] <= "\udbff":
        visible = visible[:-1] + "�"
    return visible, len(raw) // 2


def parse_listed(cell):
    """Invert the listing's truncation into (visible prefix, full length)."""
    raw = utf16(cell)
    if len(raw) <= 2 * LIMIT:
        if "... (truncated," in cell:
            raise ValueError("truncated body")
        return cell, len(raw) // 2
    marker = MARKER.fullmatch(raw[2 * LIMIT:].decode("utf-16-le", "surrogatepass"))
    if not marker or int(marker[1]) <= LIMIT:
        raise ValueError("unrecognized listing truncation")
    return raw[:2 * LIMIT].decode("utf-16-le", "surrogatepass"), int(marker[1])


def listing_proves(visible, length):
    """Whether every body line an idle route reads is inside the listed prefix."""
    if length <= LIMIT:
        return True
    lines = visible.split("\n")[:-1]  # the last listed line may be cut short
    if HISTORY not in lines:
        return False
    # A resolution record's mode lookup is not bounded by the history line.
    return not any(line.startswith("Resolution recorded by ") for line in lines[:lines.index(HISTORY)])


def digest(kind, row, body, context):
    if not all(isinstance(row.get(key), str) for key in FIELDS):
        raise ValueError("incomplete routing fields")
    if context is None:
        raise ValueError("unreadable routing code")
    data = [2, kind, [row[key] for key in FIELDS[:-1]], body, context]
    return hashlib.sha256(json.dumps(data, ensure_ascii=True).encode()).hexdigest()


def due_at(row, now):
    dates = []
    until = row["hold_until"]
    if until not in ("", "-"):
        # Naive timestamp uses the same local calendar as tasks-axi, with DST.
        dates.append(dt.datetime.strptime(until, "%Y-%m-%d").timestamp())
    active = row["body"].split("\nPrevious task body:", 1)[0]
    stamp = re.search(r"^Captain hold set: (.+)$", active, re.M)
    timeout = re.search(r"^Hold timeout seconds: (.+)$", active, re.M)
    if stamp and timeout:
        start = dt.datetime.strptime(stamp[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        seconds = int(timeout[1])
        if not 1 <= seconds <= 9999999:
            raise ValueError("invalid timeout")
        dates.append(start.timestamp() + seconds)
    # A passed moment is consumed by the successful route, not a periodic retry.
    return min((int(value) for value in dates if value > now), default=0)


def read_hint(state, task):
    path = state / "idle" / (task + ".json")
    if path.is_symlink() or not path.is_file():
        raise ValueError("not a regular idle hint")
    with path.open() as source:
        saved_text = source.read(1025)
    if len(saved_text) > 1024:
        raise ValueError("oversized idle hint")
    saved = json.loads(saved_text)
    if not isinstance(saved, dict) or saved.get("version") != 2 or type(saved.get("due")) is not int:
        raise ValueError("unsupported idle hint")
    return saved


def current(saved, key, value, due, now):
    return saved.get(key) == value and saved["due"] == due and (not due or now < due)


def show_row(text):
    row = {}
    for line in text.split("\n"):
        match = re.match(r"^  (\w+): (.*)$", line)
        if match:
            row[match[1]] = scalar(match[2])
    return row


def select(text, state, context, now):
    pending = {path.stem for path in (state / "pending").glob("*.body") if path.is_file()}
    due = set(pending)
    verify = set()
    header = re.search(r"^tasks\[\d+\]\{([^}]+)\}:$", text, re.M)
    keys = header[1].split(",") if header else []
    # Only LF separates TOON records; Unicode line separators can be cell data.
    for line in text.split("\n"):
        match = re.match(r"^  ([A-Za-z0-9._-]+),", line)
        if not match:
            continue
        task = match[1]
        try:
            values = columns(line[2:])
            if len(values) != len(keys):
                raise ValueError("incomplete listing row")
            row = dict(zip(keys, values))
            if row.get("state") == "done" or row.get("hold_kind") != "captain":
                # A missing hold_kind is uncertainty, not evidence of no work.
                if "hold_kind" in row:
                    continue
            if not isinstance(row.get("body"), str):
                raise ValueError("incomplete routing fields")
            visible, length = parse_listed(row["body"])
            listed = digest("listing", row, [visible, length], context)
            if current(read_hint(state, task), "listing", listed, due_at(row, now), now):
                if listing_proves(visible, length):
                    continue
                verify.add(task)
                continue
        except (OSError, ValueError, TypeError, OverflowError):
            pass
        due.add(task)
    # Row children retain slug validation and isolate malformed pending names.
    for task in sorted(due | verify):
        print(task if task in due else task + "/verify")


def check(text, state, context, now, task):
    """Exit 0 only when the row's complete show still matches its idle hint."""
    row = show_row(text)
    if row.get("id") != task or (state / "pending" / (task + ".body")).exists():
        return 1
    full = digest("full", row, row.get("body"), context)
    return 0 if current(read_hint(state, task), "full", full, due_at(row, now), now) else 1


def record(text, state, context, now, task):
    row = show_row(text)
    if row.get("id") != task or (state / "pending" / (task + ".body")).exists():
        return
    body = row.get("body")
    if not isinstance(body, str):
        raise ValueError("incomplete routing fields")
    stamp = {"version": 2, "listing": digest("listing", row, list(listed_body(body)), context),
             "full": digest("full", row, body, context), "due": due_at(row, now)}
    directory = state / "idle"
    os.umask(0o077)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=directory, prefix=".idle-", delete=False) as output:
        path = Path(output.name)
        try:
            json.dump(stamp, output)
            output.close()
            path.replace(directory / (task + ".json"))
        finally:
            path.unlink(missing_ok=True)


def main():
    action, directory, router_path = sys.argv[1:4]
    clock = os.environ.get("FM_CAPTAIN_HOLD_NOW")
    now = (dt.datetime.strptime(clock, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()
           if clock else time.time())
    state, router = Path(directory), Path(router_path)
    try:
        context = routing_context(router)
    except OSError:
        context = None
    text = sys.stdin.read()
    if action == "select":
        select(text, state, context, now)
    elif action == "check":
        try:
            sys.exit(check(text, state, context, now, sys.argv[4]))
        except (OSError, ValueError, TypeError, OverflowError):
            sys.exit(1)  # Any doubt takes the existing row path.
    else:
        try:
            record(text, state, context, now, sys.argv[4])
        except (OSError, ValueError, TypeError, OverflowError):
            pass  # A missing cache entry is safe and must not fail a good route.


if __name__ == "__main__":
    main()
