import os, pathlib, subprocess, json, time, shlex, traceback
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5G3MH318E8QVNSE345AGS9W')
SCR=ROOT/'.gate-live-rotation'
SCR.mkdir()
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_PANE_ID','HERDR_WORKSPACE_ID','HERDR_TAB_ID','TMUX','TMUX_PANE'):
        ENV.pop(k,None)
ENV['FM_HERDR_LAB_STATE_DIR']=str(SCR/'tripwire')
BASE_PATH=ENV['PATH']
LOG=(EVID/'live-rotation.log').open('w')
def say(x):
    LOG.write(x+'\n'); LOG.flush(); print(x,flush=True)
def run(args,env=None,check=True,cwd=None,timeout=65):
    p=subprocess.run([str(x) for x in args],env=env or ENV,cwd=cwd or ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if check and p.returncode:
        raise RuntimeError(f'{args}: rc={p.returncode}\n{p.stdout}\n{p.stderr}')
    return p
HELPER=ROOT/'bin/fm-herdr-lab.sh'
SESSION=run(['bash',HELPER,'name','rotation']).stdout.strip()
def lab(*args,check=True): return run(['bash',HELPER,*args],check=check)
def hd(*args,check=True): return lab('run',SESSION,*args,check=check)
def jhd(*args): return json.loads(hd(*args).stdout)['result']
RESULT=[]
made=False
try:
    say('Named lab: '+SESSION)
    lab('provision',SESSION); made=True
    say('Lab provisioned with default-fleet tripwire.')
    ws=jhd('workspace','create','--label','inactive-reconcile-lab','--cwd',str(SCR))['workspace']['workspace_id']
    (SCR/'tools').mkdir()
    wrapper=SCR/'tools/herdr'
    wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\na=sys.argv[1:]\nif "--session" not in a: raise SystemExit("lab requires explicit session")\ni=a.index("--session"); s=a[i+1]; del a[i:i+2]\nif s != '+repr(SESSION)+': raise SystemExit("wrong lab session")\nos.environ["PATH"]='+repr(BASE_PATH)+'\nos.execv("/bin/bash",["bash",'+repr(str(HELPER))+',"run",s]+a)\n')
    wrapper.chmod(0o755)
    PE=ENV.copy(); PE['PATH']=str(SCR/'tools')+':'+BASE_PATH
    def home(label):
        h=SCR/label
        run(['bash',ROOT/'bin/fm-lab-home.sh','create',h])
        (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
        return h
    def penv(h,more=None):
        e=PE.copy(); e['FM_HOME']=str(h)
        if more: e.update(more)
        return e
    def product(h,script,*args,check=True,more=None):
        return run(['bash',ROOT/'bin'/script,*args],env=penv(h,more),cwd=h,check=check)
    def task(h,id,note,guard='',age=1000):
        t=jhd('tab','create','--workspace',ws,'--label','fm-'+id,'--cwd',str(h),'--no-focus')
        pane=t['root_pane']['pane_id']; tab=t['tab']['tab_id']
        proj=h/'projects'/id; proj.mkdir()
        (h/'data'/id).mkdir(); (h/'data'/id/'transcript.txt').write_text('disposable transcript retained\n')
        fields={'backend':'herdr','window':SESSION+':'+pane,'herdr_session':SESSION,'herdr_workspace_id':ws,'herdr_tab_id':tab,'herdr_pane_id':pane,'endpoint_task_id':id,'harness':'claude','kind':'ship','mode':'no-mistakes','yolo':'off','spawn_gen':'lab-'+id,'worktree':str(proj),'project':str(proj)}
        if guard=='identity': fields['endpoint_task_id']='other-task'
        if guard=='secondmate': fields['kind']='secondmate'
        if guard=='backend': fields.update(backend='zellij',window='isolated:0',zellij_session='isolated',zellij_tab_id='0',zellij_pane_id='0')
        meta=h/'state'/(id+'.meta'); meta.write_text(''.join(f'{k}={v}\n' for k,v in fields.items()))
        status=h/'state'/(id+'.status'); status.write_text('paused: '+note+'\n')
        turn=h/'state'/(id+'.turn-ended'); turn.touch()
        product(h,'fm-busy-event.sh','arm',h/'state',id,'--state','busy' if guard=='busy' else 'idle','--source','claude-hook','--event','user-prompt-submit' if guard=='busy' else 'stop')
        if guard=='unknown': product(h,'fm-busy-event.sh','apply',h/'state',id,'unknown','--current-gen','--source','claude-hook','--event','test')
        if guard=='inbox':
            inbox=h/'state'/(id+'.inbox'); inbox.mkdir(); (inbox/'000001.msg').write_text('unhandled instruction\n')
        if guard=='held':
            product(h,'fm-captain-hold.sh','hold',id,'--title','Isolated held task','--reason','awaiting lab decision')
        if guard=='held-verb': status.write_text('captain-held: awaiting lab decision\n')
        for p in (meta,status,turn): os.utime(p,(time.time()-age,time.time()-age))
        return pane,proj,meta,status,turn
    h=home('rotation')
    ids={}
    for i in range(104):
        id=f'load{i:03d}'
        pane,*_=task(h,id,'context limit reached; awaiting a fresh session and then continue')
        ids[pane]=id
    say('Created 104 actual Herdr panes with aged context-pause task records.')
    initial=jhd('pane','list','--workspace',ws)
    say('Initial pane-list keys: '+str(list(initial)))
    closed=set(); cycles=[]
    for i in range(24):
        marker=h/'state'/'.inactive-outcome-reconcile'
        if marker.exists():os.utime(marker,(time.time()-1000,time.time()-1000))
        started=time.monotonic()
        scan=product(h,'fm-inactive-reconcile.sh','scan',more={'FM_INACTIVE_RECONCILE_SECS':'300','FM_INACTIVE_RECONCILE_BUDGET_SECS':'30'})
        elapsed=time.monotonic()-started
        panes=jhd('pane','list','--workspace',ws)['panes']
        present={x['pane_id'] for x in panes}
        now_closed=set(ids)-present
        newly=now_closed-closed;closed=now_closed
        row={'cycle':i+1,'scan_seconds':round(elapsed,3),'newly_closed':len(newly),'total_closed':len(closed),'cursor_record':marker.read_text(),'stdout':scan.stdout,'stderr':scan.stderr}
        cycles.append(row);say(json.dumps(row))
        if len(closed)==104:break
    result={'task_count':104,'closed':len(closed),'cycles':cycles,'clock_compression':'Between scans only the disposable cadence marker mtime was aged; the durable cursor and all product code were retained. Actual scan time plus 300 seconds per skipped cadence gives a schedule estimate, not a real-time hour observation.','conservative_schedule_seconds':round(sum(x['scan_seconds'] for x in cycles)+300*len(cycles),3),'result':'pass' if len(closed)==104 else 'fail'}
    RESULT.append(result)
    say(json.dumps(result))
except Exception:
    say(traceback.format_exc())
finally:
    if made:
        r=lab('teardown',SESSION,check=False);say('Lab teardown rc='+str(r.returncode)+' '+r.stderr)
    (EVID/'live-rotation-results.json').write_text(json.dumps(RESULT,indent=2)+'\n')
    LOG.close()
