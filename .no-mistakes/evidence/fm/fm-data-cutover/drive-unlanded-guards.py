#!/usr/bin/env python3
"""Drive real retirement refusals in marked lab homes, without any session backend."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53B462Z5XMWXCWAM0Z5M7BA')
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M53B462Z5XMWXCWAM0Z5M7BA')
log = (evidence / 'unlanded-guards.log').open('w')

def run(args, env, expected=0):
    print('$ ' + shlex.join(map(str, args)), file=log, flush=True)
    p = subprocess.run(list(map(str, args)), cwd=root, env=env,
                       capture_output=True, text=True, timeout=120)
    print(p.stdout + p.stderr + 'exit=' + str(p.returncode), file=log, flush=True)
    assert p.returncode == expected, p.stderr
    return p

results = []
for variant in ('dirty', 'unpushed'):
    h = root / '.test-phase' / ('fm-lab-' + variant)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('FM_', 'TASKS_AXI_', 'BEADS_', 'BR_', 'GIT_', 'TMUX'))
           and k not in ('STATE', 'DATA', 'CONFIG', 'PROJECTS')}
    env.update(FM_HOME=str(h), HOME=str(h / 'user'),
               XDG_CONFIG_HOME=str(h / 'xdg-config'), XDG_CACHE_HOME=str(h / 'xdg-cache'),
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
    run([root / 'bin/fm-lab-home.sh', 'create', h], env)
    for directory in ('user', 'xdg-config', 'xdg-cache', 'data/task-x1'):
        (h / directory).mkdir()
    env['TMPDIR'] = str(h / 'tmp')
    (h / 'tmp').mkdir()
    (h / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
    (h / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n- [ ] task-x1 - preserve this work (repo: demo)\n\n## Queued\n\n## Done\n')
    project = h / 'projects/demo'
    run(['git', 'init', '-q', '-b', 'main', project], env)
    (project / 'proof.bin').write_bytes(b'baseline')
    run(['git', '-C', project, 'add', 'proof.bin'], env)
    run(['git', '-C', project, '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
         'commit', '-q', '-m', 'fixture baseline'], env)
    wt = h / 'work'
    run(['git', '-C', project, 'worktree', 'add', '-q', '-b', 'fm/task-x1', wt, 'main'], env)
    (wt / 'proof.bin').write_bytes(b'work that must survive')
    if variant == 'unpushed':
        run(['git', '-C', wt, 'add', 'proof.bin'], env)
        run(['git', '-C', wt, '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
             'commit', '-q', '-m', 'unpushed fixture work'], env)
    meta = h / 'state/task-x1.meta'
    meta.write_text(f'project={project}\nworktree={wt}\nkind=ship\nmode=local-only\n')
    scratch = h / 'data/task-x1/scratch.bin'
    scratch.write_bytes(b'task data must stay whole')
    (h / 'state/.last-watcher-beat').touch()
    before = (wt / 'proof.bin').read_bytes()
    head = run(['git', '-C', wt, 'rev-parse', 'HEAD'], env).stdout.strip()
    p = run([root / 'bin/fm-teardown.sh', 'task-x1'], env, expected=1)
    assert 'REFUSED:' in p.stderr and 'local-only worktree' in p.stderr, p.stderr
    assert ('uncommitted' in p.stderr if variant == 'dirty' else 'commits not yet on main' in p.stderr), p.stderr
    assert meta.exists() and scratch.read_bytes() == b'task data must stay whole'
    assert not (h / 'data/task-x1/.cleanup-hold').exists()
    assert (wt / 'proof.bin').read_bytes() == before
    assert run(['git', '-C', wt, 'rev-parse', 'HEAD'], env).stdout.strip() == head
    print(json.dumps({'variant': variant, 'refused': True, 'head': head,
                      'work_sha256': hashlib.sha256(before).hexdigest(),
                      'task_record_retained': True, 'scratch_unchanged': True,
                      'cleanup_hold_absent': True}), file=log, flush=True)
    results.append({'name': variant, 'result': 'pass', 'live': True})
(evidence / 'unlanded-guards-results.json').write_text(json.dumps(results, indent=2) + '\n')
