import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
fixture = root / '.test-phase/live-state-recheck'
home = fixture / 'home'
(home / 'state').mkdir(parents=True)
(home / 'config').mkdir()
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(home), TMPDIR=str(root / '.test-phase/tmp'), NODE_NO_WARNINGS='1')
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M50V2BM2QVYA70JHTFYFVJEA')
with (evidence / 'live-state-cli.log').open('w') as log:
    def run(label, command, stdin=None, code=0, expected=()):
        p = subprocess.run(command, input=stdin, env=env, text=True, capture_output=True)
        log.write(label + '\n$ ' + ' '.join(command) + f'\nexit={p.returncode}\n' + p.stdout + p.stderr + '\n')
        log.flush()
        assert p.returncode == code, (label, p.stdout, p.stderr)
        for text in expected:
            assert text in p.stdout + p.stderr, (label, text)
        return p.stdout

    # Persisted queue is the public input contract of the real dispatcher.
    state = home / 'state'
    (state / 'demo.meta').write_text('project=demo\nwindow=fm-demo\n')
    queue = state / '.wake-queue'
    queue.write_text('1\t1\tsignal\tdemo.status\tsignal: demo.status\n')
    run('An attended recovery containing only routine task rows goes to the branch.', ['node', 'bin/fm-branch-dispatch.mjs', 'offer'], 'check: rearm-resurface\n', expected=('eligible=1', 'rows=1', 'tasks=demo'))
    run('Other attended check triggers stay on main over the same queue.', ['node', 'bin/fm-branch-dispatch.mjs', 'offer'], 'check: merge landed: fixture\n', expected=('eligible=0',))
    queue.write_text(queue.read_text() + '2\t2\tcheck\tmerge\tcheck: merge landed: fixture\n')
    run('Adversarial mixed routine/check resurface stays on main.', ['node', 'bin/fm-branch-dispatch.mjs', 'offer'], 'check: rearm-resurface\n', expected=('eligible=0',))
    run('Away posture accepts the same mixed rows.', ['node', 'bin/fm-branch-dispatch.mjs', 'offer', '--afk'], 'check: rearm-resurface\n', expected=('eligible=1', 'rows=1 2'))
    queue.write_text('')
    run('An empty recovery queue cannot manufacture branch work.', ['node', 'bin/fm-branch-dispatch.mjs', 'offer'], 'check: rearm-resurface\n', expected=('eligible=0',))

    run('A new isolated home defaults to user.', ['bash', 'bin/fm-role.sh', 'report'], expected=('fm-role: user (default)',))
    run('Owning the repository does not authorize self-publication.', ['bash', 'bin/fm-role.sh', 'check', str(root)], code=1, expected=('refused:',))
    (home / 'config/firstmate-role').write_text('maintainer github.com/example/elsewhere\n')
    run('A grant for another repository cannot authorize this one.', ['bash', 'bin/fm-role.sh', 'check', str(root)], code=1, expected=('refused:',))
    (home / 'config/firstmate-role').write_text('maintainer github.com/example/elsewhere\nuser\n')
    run('A second directive fails closed.', ['bash', 'bin/fm-role.sh', 'report'], expected=('fm-role: user',))

    # Cursor's public fallback/counting protocol consumes only disposable files.
    usage = fixture / 'usage'
    plugin = fixture / 'pstack/.cursor-plugin'
    usage.mkdir()
    plugin.mkdir(parents=True)
    (plugin / 'plugin.json').write_text('{"version":"0.15.21"}')
    env.update(FM_CURSOR_USAGE_DIR=str(usage), FM_PSTACK_DIR=str(plugin.parent))
    (usage / 'older-spending.txt').write_text('cursor_models_pct=89\n')
    os.utime(usage / 'older-spending.txt', (946684800, 946684800))
    (usage / 'newest-spending.txt').write_text('cursor_models_pct=10\n')
    run('The newest fresh low-usage file wins over a stale high-usage file.', ['bash', 'bin/fm-cursor-guard.sh', 'fallback', 'lab-worker'], expected=('cursor\n',))
    (usage / 'newest-spending.txt').write_text('cursor_models_pct=89\n')
    run('High shared-pool usage selects Codex.', ['bash', 'bin/fm-cursor-guard.sh', 'fallback', 'lab-worker'], expected=('codex Cursor Models at 89%',))
    for count in (1, 2):
        run(f'Cursor launch allowance {count} is accepted.', ['bash', 'bin/fm-cursor-guard.sh', 'take', 'lab-worker'])
    before = (state / 'cursor-dispatch.json').read_text()
    run('A third launch is refused.', ['bash', 'bin/fm-cursor-guard.sh', 'take', 'lab-worker'], code=1)
    assert (state / 'cursor-dispatch.json').read_text() == before
    log.write('Persisted launch allowance: ' + (state / 'cursor-dispatch.json').read_text() + '\n')
print('Live dispatcher, role and Cursor guard CLI scenarios passed.')
