import os, json, signal, shutil, subprocess as sp, time
from pathlib import Path
root=Path.cwd(); scratch=root/'.test-phase'; evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ'); gate=scratch/'machine-gate.sh'
shutil.copy2('/Users/dalecarman/.agent-state/machine-gate.sh',gate)
env=dict(os.environ)
for key in list(env):
    if key.startswith(('FM_','MACHINE_','GIT_CONFIG_','TASKS_AXI_')) or key in ('TMUX','GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE'): env.pop(key,None)
env.update(HOME=str(scratch/'home'),TMPDIR=str(scratch/'tmp'),TMP=str(scratch/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_TEST_MACHINE_GATE=str(gate),MACHINE_GATE_READ="printf 'SLOT FREE = YES\\n'")
def table():
    out=sp.run(['ps','-axo','pid=,ppid=,pgid=,stat=,command='],capture_output=True,text=True,check=True).stdout
    return {int(f[0]):(int(f[1]),int(f[2]),f[3],f[4][:220]) for row in out.splitlines() if len(f:=row.split(None,4))==5}
def descendants(t,p):
    found={p}
    for _ in range(30):
        more={i for i,row in t.items() if row[0] in found}
        if more<=found: return found
        found|=more
    return found

def wait(predicate,message,limit=40):
    end=time.monotonic()+limit
    while time.monotonic()<end:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError(message)

for name,defer in [('before-launch',True),('serial-slot',False)]:
    case=scratch/('proof-'+name); case.mkdir(); local=dict(env,MACHINE_LINE_DIR=str(case/'line'))
    if defer:
        waiter=case/'before-admit.sh'; waiter.write_text('#!/bin/bash\ntouch "$PROOF_LAB/ready"\nwhile [ ! -e "$PROOF_LAB/enter" ]; do sleep 0.1; done\n');waiter.chmod(0o755)
        local.update(PROOF_LAB=str(case),MACHINE_GATE_BEFORE_ADMIT=str(waiter))
    out_path=evidence/('live-proof-'+name+'.log'); err_path=evidence/('live-proof-'+name+'.err')
    with out_path.open('w') as out,err_path.open('w') as err:
        parent=sp.Popen(['bin/fm-test-isolation-proof.sh','--pool','pure-contract-unit','--jobs','1'],env=local,stdout=out,stderr=err)
        owned={}; before_candidates=0
        try:
            if defer: wait(lambda:(case/'ready').exists(),'real machine admission did not reach before-launch barrier')
            else: wait(lambda:'FM_ISOLATION_CANDIDATE_BEGIN ' in out_path.read_text(),'real proof did not launch first candidate')
            current=table(); owned={p:current[p] for p in descendants(current,parent.pid) if p in current}
            before_candidates=out_path.read_text().count('FM_ISOLATION_CANDIDATE_BEGIN ')
            parent.kill();parent.wait()
            if defer:(case/'enter').touch()
            wait(lambda:(case/'line/log.tsv').exists() and '\tend\t' in (case/'line/log.tsv').read_text(),'machine line did not record release',60)
            wait(lambda:not {p for p in owned if p in (t:=table()) and not t[p][2].startswith('Z')},'proof or gate process survived release',20)
            after_candidates=out_path.read_text().count('FM_ISOLATION_CANDIDATE_BEGIN ')
            assert after_candidates==before_candidates,(name,'launched a further candidate',before_candidates,after_candidates)
            holder=case/'line/holder';assert not holder.exists() or not holder.read_text().strip(),'machine holder retained'
            with out_path.open('a') as report:
                report.write('\nObserved real process tree before owner SIGKILL: '+json.dumps(owned,sort_keys=True)+'\n')
                report.write('Machine-line lifecycle:\n'+(case/'line/log.tsv').read_text())
                report.write('Owner killed; candidates before=%d after=%d; owned survivors=[]; machine holder empty.\n'%(before_candidates,after_candidates))
            print(name+': no later candidates; no surviving proof, candidate, or gate processes; machine line released.',flush=True)
        finally:
            if parent.poll() is None:parent.kill();parent.wait()
            for p in owned:
                try:os.kill(p,signal.SIGKILL)
                except ProcessLookupError:pass
