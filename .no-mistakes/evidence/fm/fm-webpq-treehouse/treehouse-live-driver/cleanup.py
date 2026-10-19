import json
import os
from pathlib import Path
import shlex
import subprocess

from prepare import EVIDENCE, ENV, LAB, WORKTREE

def guarded(argv, cwd):
    event = {'tool_name': 'Bash', 'tool_input': {'command': shlex.join(argv)}, 'cwd': str(cwd)}
    guard = subprocess.run(['dcg'], cwd=cwd, input=json.dumps(event), text=True, capture_output=True, timeout=30)
    if guard.returncode:
        raise RuntimeError(guard.stdout + guard.stderr)
    if guard.stdout.strip():
        decision = json.loads(guard.stdout)
        if decision.get('decision') == 'deny' or decision.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny':
            raise RuntimeError(guard.stdout)
    subprocess.run(argv, cwd=cwd, env=ENV, check=True, timeout=60, capture_output=True)

assert LAB.parent == WORKTREE and LAB.is_dir() and not LAB.is_symlink()
entries = [json.loads(line) for line in (EVIDENCE / 'treehouse-live-transcript.jsonl').read_text().splitlines()]
last = entries[-1]
assert last['argv'] == ['treehouse', 'status', '--json'], last
slots = json.loads(last['stdout'])
assert len(slots) == 24 and all(slot['status'] == 'available' for slot in slots)
for slot in slots:
    path = Path(slot['path'])
    assert path.is_relative_to(LAB / 'pool')
    if path.exists():
        guarded(['git', 'worktree', 'remove', os.path.relpath(path, LAB / 'primary')], LAB / 'primary')
print('Git safely removed all 24 clean, released fixture worktrees.', flush=True)
worktrees = subprocess.check_output(['git', 'worktree', 'list', '--porcelain'], cwd=LAB / 'primary', env=ENV, text=True)
assert worktrees.count('worktree ') == 1, worktrees

# Explicit non-recursive removal: every file is named; rmdir only removes empty directories.
files = []
directories = []
for current, dirnames, filenames in os.walk(LAB, topdown=False, followlinks=False):
    base = Path(current)
    for name in filenames:
        files.append(base / name)
    for name in dirnames:
        path = base / name
        if path.is_symlink():
            files.append(path)
    directories.append(base)
for path in files + directories:
    assert path == LAB or path.is_relative_to(LAB), path
for index in range(0, len(files), 25):
    guarded(['rm', '--', *(str(path.relative_to(LAB)) for path in files[index:index + 25])], LAB)
directories = [path for path in directories if path != LAB]
for index in range(0, len(directories), 25):
    guarded(['rmdir', '--', *(str(path.relative_to(LAB)) for path in directories[index:index + 25])], LAB)
guarded(['rmdir', '--', LAB.name], WORKTREE)
assert not LAB.exists()
(EVIDENCE / 'treehouse-cleanup.txt').write_text('All 24 test leases were released.\nGit removed the 24 clean disposable worktrees without force.\nExplicit, dcg-checked file removal and empty-directory removal cleared the remaining fixture.\nNo fixture directory remains in the run worktree.\n')
print('Removed the remaining disposable fixture using dcg-checked non-recursive commands.', flush=True)
