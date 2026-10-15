import json
from pathlib import Path
import shlex
import subprocess
import sys

root = Path.cwd()
out = Path(__file__).parent
names = sys.argv[1:] or [".fm-queue-live", ".fm-queue-live-order", ".fm-queue-history-replay"]
allowed = {".fm-queue-live", ".fm-queue-live-order", ".fm-queue-history-replay", ".fm-queue-validation-tests", ".fm-queue-publication-live"}
records = []

def guarded(args):
    command = shlex.join(args)
    decision = subprocess.run(["dcg", "test", command, "--format", "json"], text=True, capture_output=True, check=True)
    record = json.loads(decision.stdout)
    assert record["decision"] == "allow", record
    subprocess.run(args, check=True)

for name in names:
    assert name in allowed, name
    path = root / name
    assert path.parent == root and path.is_dir() and not path.is_symlink(), path
    if name != ".fm-queue-validation-tests":
        assert (path / ".fm-lab-home").is_file(), path
        subprocess.run(["bin/fm-lab-home.sh", "teardown", str(path)], check=True)
    items = list(path.rglob("*"))
    files = [p for p in items if p.is_symlink() or not p.is_dir()]
    directories = sorted([p for p in items if p.is_dir() and not p.is_symlink()], key=lambda p: len(p.parts), reverse=True)
    # Only explicit nonrecursive file removals, then empty-directory removals.
    for file in files:
        guarded(["rm", "-f", str(file)])
    for directory in directories + [path]:
        guarded(["rmdir", str(directory)])
    records.append({"path": str(path), "files_removed": len(files), "empty_directories_removed": len(directories) + 1, "exists_after": path.exists()})
suffix = "tests" if names == [".fm-queue-validation-tests"] else "publication" if names == [".fm-queue-publication-live"] else "labs"
(out / ("cleanup-" + suffix + ".json")).write_text(json.dumps(records, indent=2) + "\n")
print("Removed inspected disposable state using dcg-checked nonrecursive removals:", ", ".join(names))
