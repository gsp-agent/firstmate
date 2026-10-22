import importlib.util,os,shutil,subprocess as sp,time,json,signal
from pathlib import Path
spec=importlib.util.spec_from_file_location('live',Path('.test-phase/live-checks.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.log.close();m.log=(m.evidence/'live-more.log').open('w',buffering=1)
for mechanism in ('gtimeout','perl'):
    tools=m.scratch/('real-tools-'+mechanism);tools.mkdir()
    for name in ('bash sleep dirname basename date env mkdir mktemp chmod cat rm rmdir mv jq ps awk sed tr tail wc head cut sort shasum sha256sum cksum stat find uname touch python3 git readlink id grep mkfifo od cp ln cmp xargs hostname kill perl').split():
        binary=shutil.which(name)
        if binary:(tools/name).symlink_to(binary)
    if mechanism=='gtimeout':(tools/'gtimeout').symlink_to(shutil.which('timeout'))
    m.cancel_refresh('live-real-'+mechanism,True,path=str(tools))

home=m.new_home('live-signal-cancel',2000)
local=dict(m.env,FM_HOME=str(home),FM_HOME_SUMMARY_INTERVAL='9999999',FM_HOME_SUMMARY_TIMEOUT='900',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='9999999',FM_HEARTBEAT='9999999')
(home/'state/task.meta').write_text('kind=scout\nharness=codex\n')
outpath=m.evidence/'live-signal-cancel.out';errpath=m.evidence/'live-signal-cancel.err'
with outpath.open('w') as out,errpath.open('w') as err:
    parent=sp.Popen(['bash','bin/fm-watch.sh'],env=local,stdout=out,stderr=err)
    observed={};producer_observed=False
    try:
        end=time.monotonic()+40
        while not (home/'state/.last-watcher-beat').exists():
            assert parent.poll() is None,'signal watcher exited before first poll'
            assert time.monotonic()<end,'signal watcher failed to poll'
            time.sleep(.05)
        # The high interval must prevent a missing summary from starting a periodic refresh.
        assert not (home/'state/home-summary.json').exists()
        (home/'state/task.status').write_text('working: lab progress without positive execution proof\n')
        while parent.poll() is None:
            table=m.processes()
            for p in m.descendants(table,parent.pid):
                if p in table:
                    observed[p]=table[p]
                    if 'bin/fm-fleet-snapshot.sh' in table[p][3]:producer_observed=True
            assert time.monotonic()<end,'signal watcher did not surface unknown worker'
            time.sleep(.02)
        parent.wait(); after=m.processes()
        survivors={p:after[p] for p in observed if p in after and not after[p][2].startswith('Z')}
        groups={r[1] for r in observed.values() if r[1]!=os.getpgrp()}
        group_survivors={p:r for p,r in after.items() if r[1] in groups and not r[2].startswith('Z')}
        m.note('Signal-batch real process tree: '+json.dumps(observed,sort_keys=True))
        m.note('Signal-batch rc='+str(parent.returncode)+' producer_observed='+str(producer_observed)+' survivors='+json.dumps(survivors)+' group_survivors='+json.dumps(group_survivors))
        m.note('Watcher output: '+outpath.read_text());m.note('Durable wake: '+(home/'state/.wake-queue').read_text())
        assert parent.returncode==0 and 'signal:' in outpath.read_text()
        assert producer_observed,'real signal producer not observed; setup needs adjustment'
        assert not survivors and not group_survivors
    finally:
        if parent.poll() is None:parent.kill();parent.wait()
        for p in observed:
            try:os.kill(p,signal.SIGKILL)
            except ProcessLookupError:pass
