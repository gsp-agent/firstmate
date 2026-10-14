import json, os, plistlib, shlex, subprocess
from pathlib import Path
ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4XNE5RJ4SWE239K2J4FBE3K')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M4XNE5RJ4SWE239K2J4FBE3K')
WORK = ROOT / '.agent-state/live-drift-test-01M4XNE5'
repo = WORK/'recovery'
agents = WORK/'scheduler-agents'
env = os.environ.copy()
for key in ('GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE'):
    env.pop(key,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMPDIR=str(WORK/'tmp'),
           FM_DRIFT_AGENT_DIR=str(agents),FM_DRIFT_LAUNCHCTL='/usr/bin/false')
log = open(EVIDENCE/'generated-nightly-command.log','w',buffering=1)
log.write('launchctl is intentionally substituted with /usr/bin/false: no job loading or uninstallation is claimed live. The emitted ProgramArguments are executed with real bash, Git, and the canonical upstream remote.\n\n')

def run(args, expected):
    result = subprocess.run([str(a) for a in args],cwd=ROOT,env=env,text=True,capture_output=True)
    log.write('$ '+shlex.join([str(a) for a in args])+'\n'+result.stdout)
    if result.stderr:
        log.write('stderr:\n'+result.stderr)
    log.write(f'exit: {result.returncode}\n\n')
    assert result.returncode == expected, result.stdout+result.stderr
    return result
script = ROOT/'bin/fm-drift-nightly.sh'
run(['bash',script,'install','--repo',repo,'--hour','4','--minute','5'],2)
plist = agents/'dev.firstmate.drift-nightly.plist'
meaning = plistlib.loads(plist.read_bytes())
expected_args = ['/bin/bash',str(script),'check','--repo',str(repo)]
assert meaning == {'Label':'dev.firstmate.drift-nightly','ProgramArguments':expected_args,
                   'StartCalendarInterval':{'Hour':4,'Minute':5}},meaning
(EVIDENCE/'nightly-launchagent.plist').write_bytes(plist.read_bytes())
(EVIDENCE/'nightly-launchagent-semantic.json').write_text(json.dumps(meaning,indent=2)+'\n')
log.write('Typed plist meaning:\n'+json.dumps(meaning,indent=2)+'\n\n')
# Disposable clone only: configure the operator proof input for the emitted command.
(repo/'drift-proof.txt').write_bytes((WORK/'delivered-approved-patches.txt').read_bytes())
result = run(meaning['ProgramArguments'],0)
assert 'path-ok: bin/fm-drift-nightly.sh' in result.stdout
assert 'path-drift:' not in result.stdout
run(['bash',script,'uninstall'],0)
assert not plist.exists()
result = run(['bash',script,'uninstall'],0)
assert result.stdout.strip() == 'uninstalled: absent'
log.close()
print('Generated nightly command succeeded against the real delivered fork; plist fields and simulated file lifecycle verified. Actual launchd loading remains untested.')
