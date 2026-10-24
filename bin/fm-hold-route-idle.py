#!/usr/bin/env python3
"""Idle-route hints, never routing authority. Called by fm-captain-hold.sh.

select reads one tasks-axi listing; record reads the row's original --full show.
Only successful, locally decidable idle outcomes are recorded under the row lock.
Missing fields, truncated bodies, bad stamps and pending bodies always route.
The listing currently caps bodies at 500 UTF-16 units; do not hash its excerpt
as if it were the complete body. No backend reads or subprocesses happen here.
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


def fingerprint(row, context):
    if not all(isinstance(row.get(key), str) for key in FIELDS):
        raise ValueError("incomplete routing fields")
    body = row["body"]
    if len(body.encode("utf-16-le", "surrogatepass")) > 1000:
        raise ValueError("body exceeds the complete listing boundary")
    if "... (truncated," in body:
        raise ValueError("truncated body")
    if context is None:
        raise ValueError("unreadable routing code")
    data = [1, [row[key] for key in FIELDS], context]
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


def snapshot(row, context, now):
    return {"version": 1, "digest": fingerprint(row, context), "due": due_at(row, now)}


def select(text, state, context, now):
    pending = {path.stem for path in (state / "pending").glob("*.body") if path.is_file()}
    due = set(pending)
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
            expected = snapshot(row, context, now)
            path = state / "idle" / (task + ".json")
            if path.is_symlink() or not path.is_file():
                raise ValueError("not a regular idle hint")
            with path.open() as source:
                saved_text = source.read(1025)
            if len(saved_text) > 1024:
                raise ValueError("oversized idle hint")
            saved = json.loads(saved_text)
            if saved == expected and type(saved.get("due")) is int and (not saved["due"] or now < saved["due"]):
                continue
        except (OSError, ValueError, TypeError, OverflowError):
            pass
        due.add(task)
    # Row children retain slug validation and isolate malformed pending names.
    print("\n".join(sorted(due)))


def record(text, state, context, now, task):
    row = {}
    for line in text.split("\n"):
        match = re.match(r"^  (\w+): (.*)$", line)
        if match:
            row[match[1]] = scalar(match[2])
    if row.get("id") != task or (state / "pending" / (task + ".body")).exists():
        return
    stamp = snapshot(row, context, now)
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
    else:
        try:
            record(text, state, context, now, sys.argv[4])
        except (OSError, ValueError, TypeError, OverflowError):
            pass  # A missing cache entry is safe and must not fail a good route.


if __name__ == "__main__":
    main()
