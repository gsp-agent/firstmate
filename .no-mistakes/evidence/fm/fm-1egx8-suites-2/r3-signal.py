import os, sys, json, shutil, subprocess as sp, signal, time
from pathlib import Path
root=Path.cwd(); scratch=root/'.test-phase-r3'; evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ')
log=(evidence/'r3-signal-product.log').open('w', buffering=1)
def note(x): print(x,flush=True); print(x,file=log,flush=True)
env=dict(os.environ)
for key in list(env):
    if key.startswith(('FM_','TASKS_AXI_','GIT_CONFIG_')) or key in ('TMUX','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE'): env.pop(key,None)
env.update(HOME=str(scratch/'home'),TMPDIR=str(scratch/'tmp'),TMP=str(scratch/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMUX=str(scratch/'no-default-tmux-socket')+',1,0',TMUX_TMPDIR=str(scratch/'tmp'),CLAUDE_CONFIG_DIR=str(scratch/'home/.claude'),XDG_CONFIG_HOME=str(scratch/'home/.config'),XDG_CACHE_HOME=str(scratch/'home/.cache'))
def run(args,**kw): return sp.run(args,check=True,env=kw.pop('env',env),text=True,**kw)
def new_home(name, count=0):
    home=scratch/name
    if not home.exists(): run(['bin/fm-lab-home.sh','create',str(home)],stdout=sp.DEVNULL)
    rows='## In flight\n\n## Queued\n'+''.join('- [ ] queued-%d - Disposable queued task (repo: lab) (kind: scout)\n'%i for i in range(count))+'\n## Done\n'
    (home/'data/backlog.md').write_text(rows)
    return home
def processes():
    out=sp.run(['ps','-axo','pid=,ppid=,pgid=,stat=,command='],capture_output=True,text=True,check=True).stdout
    result={}
    for row in out.splitlines():
        fields=row.split(None,4)
        if len(fields)==5: result[int(fields[0])]=(int(fields[1]),int(fields[2]),fields[3],fields[4][:220])
    return result
def descendants(table,pid):
    found={pid}
    for _ in range(20):
        more={p for p,row in table.items() if row[0] in found}
        if more<=found: break
        found|=more
    return found

def cancel_refresh(name,watcher=False,mechanism=None,path=None):
    home=new_home(name,2000); local=dict(env,FM_HOME=str(home),FM_HOME_SUMMARY_TIMEOUT='900',FM_HOME_SUMMARY_INTERVAL='1',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='9999999',FM_HEARTBEAT='9999999')
    if path: local['PATH']=path
    if mechanism: local['FM_TIMEOUT_MECHANISM_OVERRIDE']=mechanism
    out=(evidence/("r3-"+name+'.out')).open('w'); err=(evidence/("r3-"+name+'.err')).open('w')
    cmd=['bash','bin/fm-watch.sh' if watcher else 'bin/fm-home-summary-refresh.sh']
    parent=sp.Popen(cmd,env=local,stdout=out,stderr=err); captured={}; active=set()
    try:
        deadline=time.monotonic()+45
        while time.monotonic()<deadline:
            table=processes(); owned=descendants(table,parent.pid)
            producers=[p for p in owned if p in table and 'bin/fm-fleet-snapshot.sh' in table[p][3]]
            if producers:
                active={p for p in owned if p in table and not table[p][2].startswith('Z')}; captured={p:table[p] for p in active}; break
            if parent.poll() is not None: raise AssertionError(name+' exited before producer observed: '+str(parent.returncode))
            time.sleep(.02)
        assert active,name+' real producer not observed'
        note(name+' before cancellation: '+json.dumps(captured,sort_keys=True))
        start=time.monotonic(); parent.terminate(); parent.wait(timeout=15)
        after=processes(); survivors={p:after[p] for p in active if p in after and not after[p][2].startswith('Z')}
        note(name+' parent_rc='+str(parent.returncode)+' cancellation_seconds=%.3f'%(time.monotonic()-start)+' survivors='+json.dumps(survivors))
        groups={row[1] for row in captured.values() if row[1]!=os.getpgrp()}
        group_survivors={p:row for p,row in after.items() if row[1] in groups and not row[2].startswith('Z')}
        note(name+' owned_process_groups='+json.dumps(sorted(groups))+' group_survivors='+json.dumps(group_survivors))
        assert not group_survivors,name+' left an owned process group alive'
        assert not survivors,name+' left real producer descendants alive'
        assert parent.returncode in (-15,143),name+' wrong cancellation status'
    finally:
        if parent.poll() is None: parent.kill(); parent.wait()
        for p,row in captured.items():
            try: os.kill(p,signal.SIGKILL)
            except ProcessLookupError: pass
        out.close();err.close()



home=new_home('r3-signal-cancel',2000)
local=dict(env,FM_HOME=str(home),FM_HOME_SUMMARY_INTERVAL='9999999',FM_HOME_SUMMARY_TIMEOUT='900',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='9999999',FM_HEARTBEAT='9999999')
(home/'state/task.meta').write_text('kind=scout\nharness=codex\n')
opath=evidence/'r3-signal-watch.out';epath=evidence/'r3-signal-watch.err'
with opath.open('w') as out,epath.open('w') as err:
    parent=sp.Popen(['bash','bin/fm-watch.sh'],env=local,stdout=out,stderr=err)
    observed={};groups=set()
    try:
        end=time.monotonic()+60
        beats=set()
        while len(beats)<3:
            assert parent.poll() is None,'watcher stopped before idle cadence proof'
            assert time.monotonic()<end,'watcher did not advance three beacons'
            beat=home/'state/.last-watcher-beat'
            if beat.exists():beats.add(beat.stat().st_mtime_ns)
            t=processes();owned=descendants(t,parent.pid)
            assert not any('bin/fm-fleet-snapshot.sh' in t[p][3] for p in owned if p in t),'missing ledger started periodic snapshot despite suppressed interval'
            time.sleep(.05)
        assert not (home/'state/home-summary.json').exists()
        note('Three real watcher beacons advanced with missing summary; periodic producer count=0; interval=9999999.')
        (home/'state/task.status').write_text('blocked [key=disposable]: cancellation check\n')
        producer=False
        while time.monotonic()<end and parent.poll() is None:
            t=processes()
            for p in descendants(t,parent.pid):
                if p in t:
                    observed[p]=t[p]
                    producer=producer or 'bin/fm-fleet-snapshot.sh' in t[p][3]
            if producer and 'signal:' in opath.read_text():break
            time.sleep(.01)
        assert producer,'real signal-triggered summary producer was not observed'
        assert 'signal:' in opath.read_text(),'blocked signal was not delivered during publication'
        note('Blocked signal delivered while real producer was running: '+opath.read_text())
        parent.terminate();parent.wait(timeout=30)
        t=processes();groups={r[1] for r in observed.values() if r[1]!=os.getpgrp()}
        survivors={p:r for p,r in t.items() if (p in observed or r[1] in groups) and not r[2].startswith('Z')}
        note('Signal cancellation process tree: '+json.dumps(observed,sort_keys=True))
        note('Delivered close exit='+str(parent.returncode)+'; producer-group survivors='+json.dumps(survivors))
        assert parent.returncode==0 and not survivors
        shutil.copy2(home/'state/.wake-queue',evidence/'r3-signal-wake-queue.tsv')
    finally:
        if parent.poll() is None:parent.kill();parent.wait()
        for p in observed:
            try:os.kill(p,signal.SIGKILL)
            except ProcessLookupError:pass
