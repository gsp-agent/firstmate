import json
import os
from pathlib import Path
import subprocess

WORKTREE = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5AP49DMP3YQHK647NXQF5WB')
LAB = WORKTREE / '.nm-treehouse-live'
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP49DMP3YQHK647NXQF5WB')
ENV = os.environ.copy()
for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'TREEHOUSE_LEASE_HOLDER', 'ENV', 'BASH_ENV'):
    ENV.pop(key, None)
ENV.update({
    'TREEHOUSE_ROOT': str(LAB / 'pool'),
    'XDG_CONFIG_HOME': str(LAB / 'xdg-config'),
    'XDG_STATE_HOME': str(LAB / 'xdg-state'),
    'XDG_CACHE_HOME': str(LAB / 'xdg-cache'),
    'XDG_DATA_HOME': str(LAB / 'xdg-data'),
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_GLOBAL': '/dev/null',
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_AUTHOR_NAME': 'gsp-agent',
    'GIT_AUTHOR_EMAIL': 'gsp-agent@users.noreply.github.com',
    'GIT_COMMITTER_NAME': 'gsp-agent',
    'GIT_COMMITTER_EMAIL': 'gsp-agent@users.noreply.github.com',
    'TERM': 'xterm-256color',
    'NO_COLOR': '1',
})
EVIDENCE.mkdir(parents=True, exist_ok=True)

def run(args, cwd=None, check=True):
    proc = subprocess.run(args, cwd=cwd or LAB / 'primary', env=ENV, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=240 if args[0] == 'treehouse' else 60)
    entry = {'cwd': str(cwd or LAB / 'primary'), 'argv': args,
             'returncode': proc.returncode, 'stdout': proc.stdout, 'stderr': proc.stderr}
    with (EVIDENCE / 'treehouse-live-transcript.jsonl').open('a') as out:
        out.write(json.dumps(entry) + '\n')
    if check and proc.returncode:
        raise AssertionError(json.dumps(entry, indent=2))
    return proc

if __name__ == '__main__':
    seed = LAB / 'seed'
    seed.mkdir()
    run(['git', 'init', '--quiet', '--initial-branch=main'], seed)
    (seed / 'README.md').write_text('Disposable Treehouse pool consumer fixture.\n')
    run(['git', 'add', 'README.md'], seed)
    run(['git', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'baseline fixture'], seed)
    run(['git', 'clone', '--quiet', '--bare', str(seed), str(LAB / 'origin.git')], LAB)
    run(['git', 'clone', '--quiet', str(LAB / 'origin.git'), str(LAB / 'primary')], LAB)
    print(run(['treehouse', '--version']).stdout.strip())
    print(run(['treehouse', 'status', '--json']).stdout)
    result = run(['treehouse', 'get', '--lease', '--json', '--no-fetch', '--lease-holder', 'nm-cap-01'])
    print(result.stdout)
    print(result.stderr)
    print(run(['treehouse', 'status', '--json']).stdout)
