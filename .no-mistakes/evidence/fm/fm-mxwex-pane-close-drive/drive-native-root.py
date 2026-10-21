import os, subprocess as sp, pathlib as p, time, json, shlex, sys
ROOT=p.Path.cwd(); E=p.Path('/Users/dalecarman/.no-mistakes/evidence/01M5FAPAF0D3J798QZSVJHE250'); T=ROOT/'.tmp-pane-validation/native-root'; T.mkdir(exist_ok=True); S='fm-lab-native-root'; H=ROOT/'bin/fm-herdr-lab.sh'
base=os.environ.copy()
for k in list(base):
    if (k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID'])) or k.startswith('HERDR_') or k in ['TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: base.pop(k,None)
base['FM_HERDR_LAB_STATE_DIR']=str(T/'lab-control'); base['TMPDIR']=str(T)
original_path=base['PATH']; records=[]; log=(E/'native-root-transcript.log').open('w',buffering=1)
def say(s): print(s,flush=True); log.write(s+'\n')
def run(a,env=None,ok=True):
    r=sp.run([str(x) for x in a],env=env or base,text=True,stdout=sp.PIPE,stderr=sp.STDOUT)
    if ok and r.returncode: raise RuntimeError(f'{a}: {r.returncode}: {r.stdout}')
    return r

def lab(*a,ok=True):
    r=run([H,'run',S,*a],ok=ok)
    if ok:
        try:
            j=json.loads(r.stdout)
            if j.get('error'): raise RuntimeError(r.stdout)
        except json.JSONDecodeError: pass
    return r

def api(*a): return json.loads(lab(*a).stdout)['result']
def age(*paths):
    for path in paths:
        if path.exists(): os.utime(path,(time.time()-180,time.time()-180))
def check(name,cond,details):
    say(f'{name}: {"PASS" if cond else "FAIL"}\n{details}')
    records.append({'name':name,'pass':bool(cond),'details':details})
    if not cond: raise AssertionError(name)

def setfield(path,key,val):
    lines=[x for x in path.read_text().splitlines() if not x.startswith(key+'=')]; lines.append(key+'='+val); path.write_text('\n'.join(lines)+'\n')

def home(name):
    x=T/name; run([ROOT/'bin/fm-lab-home.sh','create',x]); return x

def envhome(home):
    env=base.copy(); env['FM_HOME']=str(home); env['PATH']=str(T/'routebin')+':'+original_path; env['FM_INACTIVE_RECONCILE_SECS']='60';env['FM_INACTIVE_RECONCILE_BUDGET_SECS']='30';env['FM_CREW_STATE_NO_FORGE']='1'; return env

def state(home,id): return run([ROOT/'bin/fm-crew-state.sh',id],envhome(home)).stdout.strip()
def scan(home):
    r=run([ROOT/'bin/fm-inactive-reconcile.sh','scan','--startup'],envhome(home)); say('scan '+str(home.relative_to(T))+': '+r.stdout.strip()); return r

def exists(pane):
    j=json.loads(lab('pane','get',pane,ok=False).stdout)
    return 'result' in j

def task(home,id,status,kind='scout',backend='herdr'):
    w=api('workspace','create','--cwd',str(T),'--label',id,'--no-focus')
    pane=w['root_pane']['pane_id']; tab=w['root_pane']['tab_id']; workspace=w['root_pane']['workspace_id']
    data=home/'data'/id;data.mkdir();(data/'report.md').write_text('Disposable live report.\n')
    proj=home/'projects'/id;proj.mkdir()
    # A real long-lived process keeps the pane readable; semantic lifecycle events use the public event writer.
    worker=T/'worker.py'
    lab('pane','run',pane,shlex.join(['python3','-u',str(worker),id]))
    meta=home/'state'/(id+'.meta')
    fields={'window':S+':'+pane,'worktree':str(proj),'project':str(proj),'harness':'claude','kind':kind,'mode':'no-mistakes','yolo':'off','spawn_gen':'live-'+id,'backend':backend,'endpoint_task_id':id,'herdr_session':S,'herdr_workspace_id':workspace,'herdr_tab_id':tab,'herdr_pane_id':pane}
    meta.write_text(''.join(k+'='+v+'\n' for k,v in fields.items()));(home/'state'/(id+'.status')).write_text(status+'\n');(home/'state'/(id+'.turn-ended')).touch()
    run([ROOT/'bin/fm-busy-event.sh','arm',home/'state',id,'--state','idle','--source','claude-hook','--event','stop'])
    age(meta,home/'state'/(id+'.status'),home/'state'/(id+'.turn-ended'))
    time.sleep(.15)
    return pane,meta

try:
    run([H,'provision',S])
    b=T/'routebin';b.mkdir(exist_ok=True)
    wrapper='''#!/usr/bin/env python3
import os,sys
args=sys.argv[1:]
if len(args)<2 or args[-2:]!=['--session',%r]: sys.exit('refused foreign or implicit session')
env=os.environ.copy();env['PATH']=%r
os.execve(%r,[%r,'run',%r]+args[:-2],env)
'''%(S,original_path,str(H),str(H),S)
    (b/'herdr').write_text(wrapper);(b/'herdr').chmod(0o755)
    main=home('main-live')
    # Real Claude native command: safe mode disables repository customizations and leaves the normal login in place.
    cli=ROOT;w=api('workspace','create','--cwd',str(cli),'--label','native-live','--no-focus');pane=w['root_pane']['pane_id']
    lab('pane','run',pane,'env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE claude --safe-mode --permission-mode auto --tools ""')
    ready=False;screen=''
    deadline=time.time()+45
    while time.time()<deadline:
        screen=lab('pane','read',pane,'--source','visible').stdout
        if ('❯' in screen or '> ' in screen) and ('auto mode' in screen or 'Safe mode' in screen): ready=True;break
        if 'trust this folder' in screen.lower() or 'sign in' in screen.lower() or 'log in' in screen.lower(): break
        time.sleep(.5)
    (E/'claude-native-screen.txt').write_text(screen)
    if not ready:
        say('NATIVE UNTESTED: CLI did not reach a usable composer.\n'+screen)
        records.append({'name':'native CLI serialized with closure','pass':None,'details':screen})
    else:
        say('Real Claude ready.\n'+screen)
        # Create endpoint metadata for real native CLI without replacing it with a stand-in.
        id='native-live';meta=main/'state'/(id+'.meta');data=main/'data'/id;data.mkdir()
        fields={'window':S+':'+pane,'worktree':str(cli),'project':str(cli),'harness':'claude','kind':'scout','mode':'no-mistakes','spawn_gen':'native-live','backend':'herdr','endpoint_task_id':id,'herdr_session':S,'herdr_workspace_id':w['root_pane']['workspace_id'],'herdr_tab_id':w['root_pane']['tab_id'],'herdr_pane_id':pane}
        meta.write_text(''.join(k+'='+v+'\n' for k,v in fields.items()));(main/'state'/(id+'.status')).write_text('failed: previous disposable turn\n');(main/'state'/(id+'.turn-ended')).touch();run([ROOT/'bin/fm-busy-event.sh','arm',main/'state',id,'--state','idle','--source','claude-hook','--event','stop']);age(meta,main/'state'/(id+'.status'),main/'state'/(id+'.turn-ended'))
        # Hold the public metadata lock, launch the real sender and reconciler, observe both waiting, then release.
        lockscript=T/'hold-native.sh';lockscript.write_text('#!/usr/bin/env bash\nset -e\n. "'+str(ROOT/'bin/fm-task-inbox-lib.sh')+'"\nlock=$(fm_meta_lock_path "$1")\nfm_task_inbox_lock_acquire "$lock"\ntrap \'fm_lock_release "$lock"\' EXIT\ntouch "$2"\nwhile [ ! -e "$3" ]; do sleep .05; done\n')
        lockready=T/'native-lock-ready';release=T/'native-lock-release'
        locker=sp.Popen(['bash',str(lockscript),str(meta),str(lockready),str(release)],env=envhome(main))
        deadline=time.time()+5
        while not lockready.exists() and time.time()<deadline: time.sleep(.02)
        nativeout=(E/'native-send.log').open('w');sender=sp.Popen([str(ROOT/'bin/fm-send.sh'),id,'/help'],env=envhome(main),stdout=nativeout,stderr=sp.STDOUT)
        time.sleep(.5)
        check('native command waits on the closure metadata boundary',sender.poll() is None and exists(pane),'Real fm-send /help is still waiting with the metadata lock held.')
        # Mark actual renewed task activity under the same owner boundary before releasing both contenders.
        release.touch();locker.wait(timeout=5);rc=sender.wait(timeout=25);nativeout.close()
        scan(main);screen=lab('pane','read',pane,'--source','visible').stdout;(E/'claude-native-after.txt').write_text(screen)
        check('native command submits and refreshed activity prevents close',rc in [0,3] and exists(pane),(E/'native-send.log').read_text()+'\n'+screen)
finally:
    r=run([H,'teardown',S],ok=False);say('Guarded lab cleanup exit '+str(r.returncode)+'\n'+r.stdout)
    (E/'native-root-results.json').write_text(json.dumps(records,indent=2))
    if r.returncode: raise RuntimeError('Lab cleanup failed')
