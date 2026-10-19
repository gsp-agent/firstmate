"""Drive the real planner after the initial driver deadline; never run suites."""

import json
import os
import re
import shlex
import signal
import subprocess
import time
from pathlib import Path

REPO = Path("/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M592GW4AWJHJT4FZVF69FVG7")
EVIDENCE = Path("/Users/dalecarman/.no-mistakes/evidence/01M592GW4AWJHJT4FZVF69FVG7")
TRANSCRIPT = EVIDENCE / "runner-planner-transcript.txt"
RESULT = EVIDENCE / "runner-planner-result.json"
records = []
assert Path.cwd() == REPO
assert not TRANSCRIPT.exists(), "Preserve earlier evidence."


def run(args, expected=0):
    started = time.monotonic()
    print(f"START {shlex.join(args)}", flush=True)
    proc = subprocess.Popen(args, cwd=REPO, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = proc.communicate(timeout=600)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            stdout, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            stdout, stderr = proc.communicate()
    output = stdout.decode("utf-8", errors="replace")
    error = stderr.decode("utf-8", errors="replace")
    elapsed = round(time.monotonic() - started, 3)
    records.append({"command": shlex.join(args), "exit": proc.returncode,
                    "duration_seconds": elapsed, "timed_out": timed_out})
    with TRANSCRIPT.open("a") as stream:
        stream.write(f"$ {shlex.join(args)}\n{output}{error}")
        stream.write(f"[exit={proc.returncode}, elapsed={elapsed}s, timed_out={timed_out}]\n\n")
    print(f"END exit={proc.returncode}, elapsed={elapsed}s", flush=True)
    assert not timed_out, "Planner exceeded the second driver's 600s limit."
    if expected is not None:
        assert proc.returncode == expected, error or output
    return output, error, proc.returncode


def observe(message):
    with TRANSCRIPT.open("a") as stream:
        stream.write(f"OBSERVED: {message}\n\n")
    print(message, flush=True)


try:
    stock, _, _ = run(["/bin/bash", "bin/fm-test-run.sh", "--list", "--all"])
    modern, _, _ = run(["bin/fm-test-run.sh", "--list", "--all"])
    actual = stock.splitlines()
    excluded = {"fm-supervision-host.test.sh", "fm-captain-hold-lifecycle.test.sh"}
    expected = {f"tests/{p.name}" for p in (REPO / "tests").glob("*.test.sh")
                if p.is_file() and p.name not in excluded}
    assert set(actual) == expected, {"missing": sorted(expected - set(actual)),
                                     "extra": sorted(set(actual) - expected)}
    assert len(actual) == len(set(actual)), "Duplicate scheduled inventory paths."
    assert actual == modern.splitlines(), "Stock and PATH Bash emit different inventories."
    observe("Both shells emit the same complete inventory exactly once; the two unsplit subjects are excluded and all four wrappers are scheduled.")

    lanes = {}
    for lane in ["portable-parallel-1", "portable-parallel-2"]:
        output, _, _ = run(["bin/fm-test-run.sh", "--list-scheduled", "--lane", lane])
        lanes[lane] = output.splitlines()
    placement = {}
    for letter in ["a", "b"]:
        wrapper = f"tests/fm-captain-hold-lifecycle-lane-{letter}.test.sh"
        membership = [lane for lane, members in lanes.items() if wrapper in members]
        assert len(membership) == 1, (wrapper, membership)
        placement[wrapper] = membership[0]
        assert lanes[membership[0]][0] == wrapper, "Long measured lane is not scheduled first."
    assert len(set(placement.values())) == 2, placement
    assert all("tests/fm-captain-hold-lifecycle.test.sh" not in members for members in lanes.values())
    observe("Captain-hold wrappers are scheduled first on different shards: " + json.dumps(placement, sort_keys=True))

    output, error, code = run(["bin/fm-test-run.sh", "--list-scheduled", "--lane", "portable-parallel-3"], expected=None)
    assert code != 0 and "lane" in (output + error).lower(), (code, output, error)
    observe("The real runner rejects an unknown parallel shard without starting a suite.")

    coverage, _, _ = run(["bin/fm-test-run.sh", "--check-coverage"])
    metrics = dict(re.findall(r"\b(parallel_max_ms|parallel_imbalance_ms)=(\d+)", coverage))
    assert set(metrics) == {"parallel_max_ms", "parallel_imbalance_ms"}, coverage
    observe("Coverage planner metrics: " + json.dumps(metrics, sort_keys=True) + "; these are estimates, not measured CI durations.")
    RESULT.write_text(json.dumps({"result": "pass", "metrics": metrics,
                                  "wrapper_placement": placement, "commands": records}, indent=2) + "\n")
except Exception as exc:
    RESULT.write_text(json.dumps({"result": "fail", "error": str(exc),
                                  "commands": records}, indent=2) + "\n")
    raise
