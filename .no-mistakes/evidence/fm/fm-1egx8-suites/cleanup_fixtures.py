#!/usr/bin/env python3
"""Remove inspected fixture entries one at a time, with dcg checking each action."""
import json
import os
from pathlib import Path
import subprocess

repo = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M595RNA6700Q16CBBH8ZN9M6')
ev = Path('/Users/dalecarman/.no-mistakes/evidence/01M595RNA6700Q16CBBH8ZN9M6')
root = Path((ev/'sandbox-path.txt').read_text().strip())
assert root.parent == repo and root.name.startswith('.nm-focused-') and root.is_dir() and not root.is_symlink()
actions = []
for directory, dirs, files in os.walk(root, topdown=False, followlinks=False):
    base = Path(directory)
    for name in files:
        actions.append(('file', base/name))
    for name in dirs:
        child = base/name
        actions.append(('file' if child.is_symlink() else 'dir', child))
actions.append(('dir', root))
print('Inspected disposable root:', root, flush=True)
print('Top-level entries:', ', '.join(sorted(x.name for x in root.iterdir())), flush=True)
print('Nonrecursive removal actions:', len(actions), flush=True)
for kind, target in actions:
    assert target == root or root in target.parents
    assert target.is_symlink() or target.is_file() or target.is_dir()
    command = ('rm' if kind == 'file' else 'rmdir')+' -- "${NM_TARGET:?}"'
    decision = subprocess.run(['dcg'], input=json.dumps({'tool_name':'Bash', 'tool_input':{'command':command},
                               'cwd':str(repo)}), text=True, capture_output=True, check=True)
    if decision.stdout.strip():
        payload = json.loads(decision.stdout)
        if payload.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny' or payload.get('decision') == 'block':
            raise RuntimeError('dcg refused nonrecursive removal: '+decision.stdout)
    subprocess.run(['bash', str(ev/'remove_one.sh')], env=os.environ | {'NM_KIND':kind, 'NM_TARGET':str(target)},
                   cwd=repo, check=True)
print('Disposable root removed:', not root.exists(), flush=True)
