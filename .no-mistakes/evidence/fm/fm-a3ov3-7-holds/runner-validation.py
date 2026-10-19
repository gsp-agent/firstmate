"""Seconds-only validation of the real runner CLI; no suites are executed."""

import json
import re
import shlex
import subprocess
import time
from pathlib import Path


REPO = Path("/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M592GW4AWJHJT4FZVF69FVG7")
EVIDENCE = Path("/Users/dalecarman/.no-mistakes/evidence/01M592GW4AWJHJT4FZVF69FVG7")
TRANSCRIPT = EVIDENCE / "runner-live-transcript.txt"
RESULT = EVIDENCE / "runner-validation.json"
records = []


def run(args, *, input_bytes=None, expected=0, note=""):
    started = time.monotonic()
    proc = subprocess.run(
        args, cwd=REPO, input=input_bytes, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=120,
    )
    stdout = proc.stdout.decode("utf-8", errors="replace")
    stderr = proc.stderr.decode("utf-8", errors="replace")
    record = {
        "command": shlex.join(args), "note": note,
        "exit": proc.returncode, "duration_seconds": round(time.monotonic() - started, 3),
        "stdout": stdout, "stderr": stderr,
    }
    records.append(record)
    with TRANSCRIPT.open("a") as stream:
        stream.write(f"$ {record['command']}\n")
        if note:
            stream.write(f"[{note}]\n")
        stream.write(stdout)
        stream.write(stderr)
        stream.write(f"[exit={proc.returncode}, elapsed={record['duration_seconds']}s]\n\n")
    print(f"exit={proc.returncode}: {record['command']}", flush=True)
    if expected is not None:
        assert proc.returncode == expected, record
    return proc, stdout, stderr


def paths(stdout):
    return [line.strip() for line in stdout.splitlines() if line.strip()]


def prove(message):
    with TRANSCRIPT.open("a") as stream:
        stream.write(f"OBSERVED: {message}\n\n")
    print(message, flush=True)


assert Path.cwd() == REPO
assert not TRANSCRIPT.exists(), "Preserve earlier evidence; select a new filename."
try:
    run(["/bin/bash", "--version"])
    run(["bash", "--version"])
    before = subprocess.run([
        "git", "show", "e9ffe5b754813e70cab6695e2b23ac25f385ee23^:tests/fm-test-run.test.sh",
    ], cwd=REPO, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    old, _, old_error = run(
        ["/bin/bash", "-n"], input_bytes=before.stdout, expected=None,
        note="Previous committed test file supplied on stdin; expected Bash 3.2 rejection.",
    )
    assert old.returncode != 0, "The reported pre-fix stock Bash failure did not reproduce."
    assert "syntax error" in old_error, old_error
    run(["bash", "-n"], input_bytes=before.stdout,
        note="The same previous file still parses under the PATH Bash.")
    for shell_file in [
        "tests/fm-test-run.test.sh", "bin/fm-test-run.sh",
        "tests/fm-captain-hold-lifecycle.test.sh",
        "tests/fm-captain-hold-lifecycle-lane-a.test.sh",
        "tests/fm-captain-hold-lifecycle-lane-b.test.sh",
    ]:
        run(["/bin/bash", "-n", shell_file])
    run(["bash", "-n", "tests/fm-test-run.test.sh"])
    prove("The previous file is rejected by stock Bash; all five current split/runner shell files parse, and the changed file also parses under PATH Bash.")

    _, coverage, _ = run(["bin/fm-test-run.sh", "--check-coverage"])
    metrics = dict(re.findall(r"\b(parallel_max_ms|parallel_imbalance_ms)=(\d+)", coverage))
    assert set(metrics) == {"parallel_max_ms", "parallel_imbalance_ms"}, coverage

    _, stock_all, _ = run(["/bin/bash", "bin/fm-test-run.sh", "--list", "--all"])
    _, path_all, _ = run(["bin/fm-test-run.sh", "--list", "--all"])
    excluded = {"fm-supervision-host.test.sh", "fm-captain-hold-lifecycle.test.sh"}
    expected = {
        f"tests/{p.name}" for p in (REPO / "tests").glob("*.test.sh")
        if p.is_file() and p.name not in excluded
    }
    actual = paths(stock_all)
    assert set(actual) == expected, {
        "missing": sorted(expected - set(actual)), "extra": sorted(set(actual) - expected),
    }
    assert len(actual) == len(set(actual)), "Scheduled inventory contains duplicate paths."
    assert actual == paths(path_all), "Stock and PATH Bash disagree on the scheduled inventory."
    prove("Both shells emit the same complete scheduled inventory, each path once; both unsplit subjects are excluded and their four wrappers are present.")

    lanes = {}
    for lane in ["portable-parallel-1", "portable-parallel-2"]:
        _, output, _ = run(["bin/fm-test-run.sh", "--list-scheduled", "--lane", lane])
        lanes[lane] = paths(output)
    wrapper_placement = {}
    for letter in ["a", "b"]:
        wrapper = f"tests/fm-captain-hold-lifecycle-lane-{letter}.test.sh"
        memberships = [lane for lane, members in lanes.items() if wrapper in members]
        assert len(memberships) == 1, (wrapper, memberships)
        wrapper_placement[wrapper] = memberships[0]
        assert lanes[memberships[0]][0] == wrapper, "The measured long lane should be scheduled first."
    assert len(set(wrapper_placement.values())) == 2, wrapper_placement
    for members in lanes.values():
        assert "tests/fm-captain-hold-lifecycle.test.sh" not in members
    prove(f"Captain-hold wrappers are first on different parallel shards: {json.dumps(wrapper_placement, sort_keys=True)}")
    prove(f"Coverage planner reports parallel_max_ms={metrics['parallel_max_ms']} and parallel_imbalance_ms={metrics['parallel_imbalance_ms']}; these are modeled estimates, not measured execution times.")

    invalid, _, invalid_error = run([
        "bin/fm-test-run.sh", "--list-scheduled", "--lane", "portable-parallel-3",
    ], expected=None)
    assert invalid.returncode != 0, "Unknown parallel lane was accepted."
    assert "lane" in invalid_error.lower(), invalid_error
    prove("An unknown parallel shard is rejected by the executable runner without starting any suite.")
    RESULT.write_text(json.dumps({
        "result": "pass", "head": "e9ffe5b754813e70cab6695e2b23ac25f385ee23",
        "metrics": metrics, "wrapper_placement": wrapper_placement,
        "scope": "Real runner planning interfaces and requested shell parse checks only; no lane, focused runner suite, live hold replay, lint, or CI execution.",
        "commands": [{k: v for k, v in record.items() if k not in {"stdout", "stderr"}} for record in records],
    }, indent=2) + "\n")
except Exception as exc:
    RESULT.write_text(json.dumps({"result": "fail", "error": str(exc), "commands": records}, indent=2) + "\n")
    raise
