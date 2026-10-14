import json, os, shlex, subprocess
from pathlib import Path
ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4XNE5RJ4SWE239K2J4FBE3K')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M4XNE5RJ4SWE239K2J4FBE3K')
WORK = ROOT / '.agent-state/live-drift-test-01M4XNE5'
ENV = os.environ.copy()
for key in ('GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE'):
    ENV.pop(key,None)
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(WORK/'tmp'))
SCRIPT = ROOT/'bin/fm-drift-nightly.sh'
log = open(EVIDENCE/'counterfactual-and-delivered-fork.log','w',buffering=1)

def run(args, expected=None, record=True):
    result = subprocess.run([str(a) for a in args],cwd=ROOT,env=ENV,text=True,capture_output=True)
    if record:
        log.write('$ '+shlex.join([str(a) for a in args])+'\n'+result.stdout)
        if result.stderr:
            log.write('stderr:\n'+result.stderr)
        log.write(f'exit: {result.returncode}\n\n')
    if expected is not None:
        assert result.returncode == expected, result.stdout+result.stderr
    return result

old = WORK/'prior-guard.sh'
old.write_text(run(['git','show','9f1504c9:bin/fm-drift-nightly.sh'],expected=0,record=False).stdout)
repo = WORK/'rename'
args = ['check','--repo',repo,'--upstream','upstream','--no-fetch','--proof',WORK/'rename-proof.txt']
before = run(['bash',old,*args],expected=0)
after = run(['bash',SCRIPT,*args],expected=1)
assert 'path-drift: original.txt' not in before.stdout
assert 'path-drift: original.txt' in after.stdout
log.write('The same real repository deletion is missed by the parent guard and rejected by the target guard.\n\n')
repo = WORK/'recovery'
run(['git','-C',repo,'remote','add','kunchenguid','https://github.com/kunchenguid/firstmate.git'],expected=0)
result = run(['bash',SCRIPT,'check','--repo',repo],expected=1)
assert 'path-drift: bin/fm-drift-nightly.sh' in result.stdout
assert 'path-drift: drift-proof.txt' in result.stdout
accepted = WORK/'delivered-approved-patches.txt'
shas = [run(['git','rev-parse',ref],expected=0,record=False).stdout.strip()
        for ref in ('0efb72c1','ce08ec29','9f1504c9','23b309bf')]
accepted.write_text('\n'.join(shas)+'\n')
log.write('Test-only approval input contains the commits needed to replay the delivered guard artifacts; it grants no main-home or publication authority.\n')
result = run(['bash',SCRIPT,'check','--repo',repo,'--proof',accepted],expected=None)
print('DELIVERED_APPROVED_EXIT='+str(result.returncode))
print(result.stdout)
print(result.stderr)
log.close()
