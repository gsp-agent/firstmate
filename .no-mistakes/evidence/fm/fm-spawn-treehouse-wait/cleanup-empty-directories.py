import json
from pathlib import Path
import shlex
import subprocess

root = Path.cwd()
directories = []
for name in (".fm-live-validation", "v"):
    target = root / name
    if not target.exists():
        continue
    for entry in target.rglob("*"):
        assert entry.is_dir() and not entry.is_symlink(), entry
        directories.append(entry)
    directories.append(target)

for directory in sorted(directories, key=lambda p: len(p.parts), reverse=True):
    assert not directory.name.startswith("-") and not list(directory.iterdir())
    args = ["rmdir", directory.name]
    guard = subprocess.run(["dcg"], cwd=directory.parent, input=json.dumps({"tool_name": "Bash", "tool_input": {"command": shlex.join(args)}}), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if guard.returncode or '"deny"' in guard.stdout or '"block"' in guard.stdout:
        print("Cleanup refused for", directory, guard.stdout, flush=True)
        raise SystemExit(1)
    subprocess.run(args, cwd=directory.parent, check=True)
    print("Removed empty directory:", directory.relative_to(root), flush=True)
print("All disposable fixture directories removed.", flush=True)
