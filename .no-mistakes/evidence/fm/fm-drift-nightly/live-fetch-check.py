#!/usr/bin/env python3
"""Exercise the default nightly fetch using a real, disposable local upstream."""
from pathlib import Path
import os
import shlex
import subprocess

root = Path.cwd()
lab = root/'.test-live'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M4ZEKNC14QM3J3ZZ3Q1TTCJA')
env = dict(os.environ, TMPDIR=str(lab/'tmp'), GIT_CONFIG_GLOBAL='/dev/null',
           GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
source = lab/'fetch-upstream'
fork = lab/'fetch-fork'
log = (evidence/'live-default-fetch.log').open('w')

def run(args, cwd=root):
    args = [str(x) for x in args]
    proc = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    log.write('$ '+shlex.join(args)+'\n'+proc.stdout+proc.stderr+f'exit: {proc.returncode}\n\n')
    log.flush()
    assert proc.returncode == 0, proc.stderr
    return proc.stdout

def git(repo, *args):
    return run(['git','-C',repo,*args])

def commit(repo, title):
    git(repo,'add','-A')
    git(repo,'-c','user.name=Validation','-c','user.email=validation@example.invalid',
        '-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','commit','-qm',title)
    return git(repo,'rev-parse','HEAD').strip()

source.mkdir()
git(source,'init','-q','-b','main')
(source/'baseline.txt').write_text('Shared upstream baseline\n')
commit(source,'Upstream baseline')
run(['git','clone','-q',source,fork])
git(fork,'remote','rename','origin','kunchenguid')
(fork/'retained.txt').write_text('Proven fork change\n')
kept = commit(fork,'Retained proven change')
proof = lab/'fetch-proof.txt'
proof.write_text(kept+'\n')
(source/'upstream-only.txt').write_text('New upstream commit\n')
new_upstream = commit(source,'Upstream advanced after the fork')
out = run(['bash',root/'bin/fm-drift-nightly.sh','check','--repo',fork,'--proof',proof])
assert 'behind: 1\nahead: 1\npath-ok: retained.txt' in out
assert 'path-drift:' not in out
assert git(fork,'rev-parse','kunchenguid/main').strip() == new_upstream
log.write('The real fetch advanced kunchenguid/main, then the nightly command reported the new upstream snapshot and accepted only the proven fork patch.\n')
log.close()
print('Real default fetch, updated upstream snapshot and proven fork acceptance completed.')
