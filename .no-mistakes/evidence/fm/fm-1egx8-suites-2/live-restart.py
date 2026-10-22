import importlib.util,subprocess as sp,os,time,json,signal
from pathlib import Path
spec=importlib.util.spec_from_file_location('live',Path('.test-phase/live-checks.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);m.log.close();m.log=(m.evidence/'live-restart.log').open('w',buffering=1)
home=m.new_home('live-lock-restart');state=home/'state';local=dict(m.env,FM_HOME=str(home),FM_POLL='1',FM_HOME_SUMMARY_INTERVAL='999999',FM_HOME_SUMMARY_TIMEOUT='2',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='9999999',FM_HEARTBEAT='9999999')
locker=m.scratch/'hold-summary-lock.sh';locker.write_text('#!/bin/bash\n. "$1/bin/fm-wake-lib.sh"\nfm_lock_acquire_wait "$FM_HOME/state/.home-summary-refresh.lock"\ntouch "$FM_HOME/held"\nsleep 30\n')
lock=sp.Popen(['bash',str(locker),str(m.root)],env=local);watchers=[]
def wait(fn,message,seconds=15):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if fn():return
        time.sleep(.05)
    raise AssertionError(message)
try:
    wait(lambda:(home/'held').exists(),'lock holder did not acquire')
    for i in range(1,4):
        beat=state/'.last-watcher-beat'
        if beat.exists():beat.unlink()
        outpath=m.evidence/('live-restart-watch-%d.out'%i);errpath=m.evidence/('live-restart-watch-%d.err'%i)
        out=outpath.open('w');err=errpath.open('w');p=sp.Popen(['bash','bin/fm-watch.sh'],env=local,stdout=out,stderr=err);watchers.append(p)
        wait(lambda:beat.exists() or p.poll() is not None,'replacement did not poll')
        if i==1:
            (state/'task.status').write_text('done: disposable completion\n');p.wait(timeout=20)
        elif i==2:time.sleep(4)
        m.note('Watcher %d pid=%d rc=%s output=%s'%(i,p.pid,p.poll(),outpath.read_text().strip()))
        out.close();err.close()
    lock.kill();lock.wait()
    refresh=sp.run(['bash','bin/fm-home-summary-refresh.sh','--best-effort'],env=dict(local,FM_HOME_SUMMARY_IF_IDLE='1',FM_HOME_SUMMARY_TIMEOUT='60'),capture_output=True,text=True,timeout=70)
    end=time.monotonic()+10
    while not (state/'home-summary.json').exists() and time.monotonic()<end:time.sleep(.05)
    m.note('After holder killed: direct best-effort refresh rc=%d; ledger_exists=%s; stderr=%s'%(refresh.returncode,(state/'home-summary.json').exists(),refresh.stderr))
    for record in state.iterdir():
        if record.name in ('.home-summary-refresh.log','.wake-queue','.watcher-down'):
            m.note(record.name+': '+record.read_text())
    if not (state/'home-summary.json').exists():
        lockpath=state/'.home-summary-refresh.lock'
        m.note('Publication lock symlink='+str(lockpath.is_symlink())+' owner_pid='+((lockpath/'pid').read_text() if (lockpath/'pid').exists() else 'absent'))
        raise AssertionError('real publication did not recover after lock-holder death')
    m.note('Real lock-holder-death publication recovered.')
finally:
    if lock.poll() is None:lock.kill();lock.wait()
    for p in watchers:
        if p.poll() is None:p.terminate()
        try:p.wait(timeout=10)
        except sp.TimeoutExpired:p.kill();p.wait()
