from pathlib import Path
import os, subprocess, time, json, signal
base=Path(__file__).parent
lab=base/'idle-lab'
for d in ('home/state','home/data','home/config','home/projects','bin'):
    (lab/d).mkdir(parents=True,exist_ok=True)
(lab/'bin/tmux').write_text('#!/bin/sh\nexit 1\n')
(lab/'bin/tmux').chmod(0o755)
env=dict(os.environ,HOME=str(base/'home'),TMPDIR=str(base/'tmp'),FM_HOME=str(lab/'home'),
         FM_ROOT_OVERRIDE=str(Path.cwd()),FM_STATE_OVERRIDE=str(lab/'home/state'),
         FM_DATA_OVERRIDE=str(lab/'home/data'),FM_CONFIG_OVERRIDE=str(lab/'home/config'),
         FM_PROJECTS_OVERRIDE=str(lab/'home/projects'),FM_POLL='1',FM_CHECK_INTERVAL='9999999',
         FM_HEARTBEAT='9999999',FM_HOME_SUMMARY_INTERVAL='9999999',FM_HOME_SUMMARY_TIMEOUT='1',
         PATH=str(lab/'bin')+os.pathsep+os.environ['PATH'])
env.pop('TMUX',None)
state=lab/'home/state'; observations=[]; max_descendants=0; summary_started=False
with (base/'idle-watch.out').open('w') as out,(base/'idle-watch.err').open('w') as err:
    p=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=out,stderr=err,start_new_session=True)
    start=time.monotonic()
    try:
        while len(observations)<4 and time.monotonic()-start<30:
            assert p.poll() is None,'idle watcher exited unexpectedly'
            beat=state/'.last-watcher-beat'
            if beat.exists():
                stamp=beat.stat().st_mtime_ns
                if not observations or observations[-1]['mtime_ns']!=stamp:
                    observations.append({'elapsed':time.monotonic()-start,'mtime_ns':stamp})
            output=subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True)
            rows=[]
            for row in output.splitlines():
                parts=row.split(None,2)
                if len(parts)==3: rows.append((int(parts[0]),int(parts[1]),parts[2]))
            owned={p.pid}
            while True:
                found={pid for pid,parent,_ in rows if parent in owned}
                if found<=owned:break
                owned|=found
            max_descendants=max(max_descendants,len(owned)-1)
            summary_started|=any('fm-home-summary-refresh' in cmd or 'fm-fleet-snapshot' in cmd for pid,_,cmd in rows if pid in owned)
            time.sleep(.15)
        assert len(observations)>=4,'watcher did not advance through four polling cycles'
        assert not summary_started,'idle watcher started a summary refresh'
        assert not (state/'home-summary.json').exists(),'idle watcher published a summary'
    finally:
        p.terminate()
        try:p.wait(timeout=12)
        except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();raise
report={'command':'bash bin/fm-watch.sh','interval':9999999,'refresh_timeout':1,'poll_seconds':1,
        'heartbeat_observations':observations,'max_descendants_observed':max_descendants,
        'summary_process_seen':summary_started,'summary_file_exists':(state/'home-summary.json').exists(),'exit':p.returncode}
(base/'idle-watch-state.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
