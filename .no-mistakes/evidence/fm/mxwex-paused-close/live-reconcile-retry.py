import os, pathlib, subprocess, json, time, shlex, traceback
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5G3MH318E8QVNSE345AGS9W')
SCR=ROOT/'.gate-live-reconcile3'
SCR.mkdir()
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_PANE_ID','HERDR_WORKSPACE_ID','HERDR_TAB_ID','TMUX','TMUX_PANE'):
        ENV.pop(k,None)
ENV['FM_HERDR_LAB_STATE_DIR']=str(SCR/'tripwire')
BASE_PATH=ENV['PATH']
LOG=(EVID/'live-reconcile-retry.log').open('w')
def say(x):
    LOG.write(x+'\n'); LOG.flush(); print(x,flush=True)
def run(args,env=None,check=True,cwd=None,timeout=65):
    p=subprocess.run([str(x) for x in args],env=env or ENV,cwd=cwd or ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if check and p.returncode:
        raise RuntimeError(f'{args}: rc={p.returncode}\n{p.stdout}\n{p.stderr}')
    return p
HELPER=ROOT/'bin/fm-herdr-lab.sh'
SESSION=run(['bash',HELPER,'name','pause-close']).stdout.strip()
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
        run(['git','init','-q',proj])
        run(['git','-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','core.hooksPath=/dev/null','-C',proj,'commit','-q','--allow-empty','-m','fixture'])
        run(['git','-C',proj,'branch','task-retained'])
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
    CLOSE=["session reached Dale's 300K context line; work in progress committed",'context passed 300k tokens; stowed','session context limit reached; fix committed','session context limit, a fresh session resumes','context limit reached mid-diagnosis, fresh session needed','context limit reached; awaiting a fresh session to resume','context limit reached; awaiting a fresh session to continue','context limit reached; awaiting a fresh session and then continue']
    KEEP=['waiting for the PM call on the context limit question, until 2026-10-22T15:00Z','context limit reached; waiting for a replacement session to take over and for PM approval','context limit reached; waiting for a replacement session to take over and PM approval','context limit reached; awaiting a fresh session to resume. Waiting for the PM call','context limit reached; awaiting a new session and then continue; awaiting Firstmate','context limit reached; awaiting a fresh session and then continue until 2026-10-22T15:00Z']
    cases=[('close7retry',CLOSE[-1],'',True,1000)]
    for id,note,guard,close,age in cases:
        h=home(id)
        pane,proj,meta,status,turn=task(h,id,note,guard,age)
        before={str(p):p.read_bytes() for p in (meta,status,h/'data'/id/'transcript.txt')}
        start=time.monotonic(); scan=product(h,'fm-inactive-reconcile.sh','scan','--startup',more={'FM_INACTIVE_RECONCILE_BUDGET_SECS':'30'}); elapsed=time.monotonic()-start
        exists=hd('pane','get',pane,check=False).returncode==0
        state=product(h,'fm-crew-state.sh',id,check=False,more={'FM_CREW_STATE_NO_FORGE':'1'}).stdout.strip() if close else ''
        retained=all(p.exists() and p.read_bytes()==v for s,v in before.items() for p in [pathlib.Path(s)]) and proj.is_dir() and run(['git','-C',proj,'show-ref','--verify','refs/heads/task-retained'],check=False).returncode==0
        outcomes=list((h/'state'/'terminal-outcomes').glob('*')) if (h/'state'/'terminal-outcomes').exists() else []
        wake=h/'state'/'.wake-queue'; silent=not wake.exists() or wake.stat().st_size==0
        ok=(exists != close and retained and not outcomes and silent and (not close or 'state: paused' in state))
        item={'id':id,'note':note,'guard':guard,'expected_close':close,'pane_exists_after':exists,'retained':retained,'terminal_outcomes':len(outcomes),'silent':silent,'crew_state':state,'seconds':round(elapsed,3),'result':'pass' if ok else 'fail','stderr':scan.stderr}
        RESULT.append(item); say(json.dumps(item))
    # Run the actual watcher with no inactive overrides: aged 400 closes, aged 200 stays.
    for label,overrides,ages,expect in [('watch-default-retry',{},[400,200],[True,False]),('watch-override-retry',{'FM_INACTIVE_RECONCILE_SECS':'900','FM_INACTIVE_RECONCILE_BUDGET_SECS':'30'},[400,1000],[False,True]),('watch-budget',{},[1000]*16,[None]*16),('watch-budget-one',{'FM_INACTIVE_RECONCILE_BUDGET_SECS':'1'},[1000]*4,[None]*4)]:
        h=home(label); items=[]
        for i,age in enumerate(ages):
            id=label+str(i); items.append((id,task(h,id,CLOSE[-1],age=age),expect[i]))
        prime=SCR/'prime.sh'
        prime.write_text('. "$1/bin/fm-wake-lib.sh"\nfor status in "$2"/*.status; do fm_wake_status_mark_current "$2" "$status"; done\n')
        run(['bash',prime,ROOT,h/'state'],env=penv(h))
        # Prime the normal heartbeat/check cadence without bypassing reconciliation.
        for name in ['.last-check','.last-heartbeat']:(h/'state'/name).touch()
        we=penv(h,{'FM_POLL':'1','FM_SIGNAL_GRACE':'1','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999',**overrides})
        with (EVID/(label+'.log')).open('w') as output:
            p=subprocess.Popen(['bash',str(ROOT/'bin/fm-watch.sh')],env=we,cwd=h,stdout=output,stderr=subprocess.STDOUT)
            start=time.monotonic()
            try:
                deadline=start+45
                while time.monotonic()<deadline:
                    marker=h/'state'/'.inactive-outcome-reconcile'
                    if marker.exists() and marker.stat().st_size and not (h/'state'/'.inactive-outcome-reconcile.lock').exists() and time.monotonic()-start>4: break
                    if p.poll() is not None: break
                    time.sleep(.2)
            finally:
                if p.poll() is None:p.terminate()
                try:p.wait(timeout=10)
                except subprocess.TimeoutExpired:p.kill();p.wait()
        marker=h/'state'/'.inactive-outcome-reconcile'
        say('Budget scan duration='+str(round(time.monotonic()-start,3))+' marker='+marker.read_text())
        for id,(_,proj,meta,status,turn),expected in items:
            fields=dict(line.split('=',1) for line in meta.read_text().splitlines()); pane=fields['herdr_pane_id']
            exists=hd('pane','get',pane,check=False).returncode==0
            item={'id':id,'expected_close':expected,'pane_exists_after':exists,'seconds':round(time.monotonic()-start,3),'result':('observed' if expected is None else 'pass' if exists!=expected else 'fail'),'overrides':overrides}
            RESULT.append(item);say(json.dumps(item))
    say('All real-product scenarios finished.')
except Exception:
    say(traceback.format_exc())
finally:
    if made:
        r=lab('teardown',SESSION,check=False);say('Lab teardown rc='+str(r.returncode)+' '+r.stderr)
    (EVID/'live-reconcile-retry-results.json').write_text(json.dumps(RESULT,indent=2)+'\n')
    LOG.close()
