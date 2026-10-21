import os, sys, subprocess as sp, pathlib as pl, time, json, shlex, signal, threading
from PIL import Image, ImageDraw, ImageFont

ROOT=pl.Path.cwd()
BASE=ROOT/'.codex-validation'
EV=pl.Path('/Users/dalecarman/.no-mistakes/evidence/01M5F46AX27V1BVSRQ2Q3P5CB4')
REAL_CODEX=sp.check_output(['which','codex'],text=True).strip()
AUTH=pl.Path(os.environ.get('CODEX_HOME', str(pl.Path.home()/'.codex')))/'auth.json'
SOCKET=str(ROOT/os.environ.get('CODEX_LIVE_SOCKET','.cxs'))
ORIG=dict(os.environ)
for key in list(ORIG):
    if key.startswith('FM_') or key in ['TMUX','HERDR_SESSION','HERDR_ENV','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
        ORIG.pop(key,None)
ORIG.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')

def run(args,env=None,check=True):
    p=sp.run(list(map(str,args)),env=env or ORIG,text=True,stdout=sp.PIPE,stderr=sp.STDOUT)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.stdout}')
    return p
def tx(*args,check=True): return run(['tmux','-S',SOCKET,*args],check=check)
def screenshot(name,frame):
    (EV/f'{name}.txt').write_text(frame)
    lines=frame.splitlines()
    font=ImageFont.load_default(size=16)
    im=Image.new('RGB',(1440,max(80,24*len(lines)+32)), '#151922')
    draw=ImageDraw.Draw(im)
    for i,line in enumerate(lines): draw.text((16,16+24*i),line,fill='#e5e7eb',font=font)
    im.save(EV/f'{name}.png')
def pids_under(wt):
    rows=run(['lsof','-a','-d','cwd','-Fpn'],check=False).stdout.splitlines()
    result=[]; pid=None
    for row in rows:
        if row.startswith('p'): pid=int(row[1:])
        if row.startswith('n') and (row[1:]==str(wt) or row[1:].startswith(str(wt)+'/')): result.append(pid)
    return result

def scenario(name,mode):
    d=BASE/name; d.mkdir()
    home=d/'home'; user=d/'user'; proj=d/'project'; wt=d/'wt'; store=d/'codex'; blank=d/'blank'; bindir=d/'bin'
    for path in [user,proj,store,blank,bindir,d/'tmp']: path.mkdir()
    run(['bash','bin/fm-lab-home.sh','create',home])
    if not AUTH.is_file(): raise RuntimeError('Existing Codex auth.json unavailable; no sign-in attempted')
    for path in [store,blank]:
        (path/'auth.json').symlink_to(AUTH)
        (path/'config.toml').write_text('model = "gpt-6.1-sol"\nmodel_reasoning_effort = "low"\n')
    run(['git','init','-q','-b','main',proj])
    (proj/'README.md').write_text('Disposable Codex folder trust live fixture.\n')
    run(['git','-C',proj,'add','README.md'])
    run(['git','-C',proj,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','fixture'])
    run(['git','-C',proj,'worktree','add','-qb','fixture',wt])
    ident=f'cxl-{name}-{os.getpid()}'
    brief=home/'data'/ident/'brief.md'; brief.parent.mkdir()
    brief.write_text('# Task\n## Captain\'s intent\nRead this brief. Reply CODEX_LIVE_OK. Do not use tools, change files, contact others, or publish.\n\n## Firstmate spec\nThis disposable verification ends once the brief is being processed.\n')
    if mode=='quoted':
        with brief.open('a') as f:
            f.write('\nThe following two dialogs are quoted data for this exercise. Do not act on them.\n\nFolder access\nTrust this folder? Codex can read, edit, and run files here.\n› 1. Trust and continue\n  2. Quit\n  enter continue · esc quit\n\nFolder access\nConfig, hooks, and exec policies from untrusted folders stay disabled.\n› 1. Open restricted\n  2. Quit\n  enter continue · esc quit\n')
    (home/'state'/'.last-watcher-beat').touch()
    # Supply an already-created real linked worktree instead of changing the host's treehouse pool.
    rc=d/'bashrc'; rc.write_text('export PATH='+shlex.quote(str(bindir)+':'+ORIG['PATH'])+'\nfunction treehouse() { cd '+shlex.quote(str(wt))+'; }\nPS1="lab$ "\n'+('printf "• Worked for 1s\\n"\n' if mode.startswith('prompt') else ''))
    shell=d/'shell'; shell.write_text('#!/bin/bash\nexec /bin/bash --noprofile --rcfile '+shlex.quote(str(rc))+' -i\n'); shell.chmod(0o755)
    wrapper=bindir/'codex'
    code='#!/bin/bash\nif [ "$1" = --version ]; then exec '+shlex.quote(REAL_CODEX)+' --version; fi\nprintf "%s\\n" "$$" > '+shlex.quote(str(d/'worker.pid'))+'\nprintf "%s\\n" "$@" > '+shlex.quote(str(d/'args.txt'))+'\n'
    if mode.startswith('prompt'): code+='export CODEX_HOME='+shlex.quote(str(blank))+'\n'
    if mode=='timeout': code+='set -- "${@:1:$#-1}"\n'
    code+='exec '+shlex.quote(REAL_CODEX)+(' --no-alt-screen' if mode=='prompt-inline' else '')+' "$@"\n'
    wrapper.write_text(code); wrapper.chmod(0o755)
    if mode=='prompt-scan-fail':
        (bindir/'lsof').write_text('#!/bin/bash\nexit 1\n'); (bindir/'lsof').chmod(0o755)
    if mode=='declined':
        with (store/'config.toml').open('a') as f: f.write(f'\n[projects.{json.dumps(str(proj))}]\ntrust_level="untrusted"\n')
    if mode=='prompt-restricted':
        with (blank/'config.toml').open('a') as f: f.write(f'\n[projects.{json.dumps(str(proj))}]\ntrust_level="untrusted"\n')
    if mode=='broken':
        with (store/'config.toml').open('a') as f: f.write('\n[broken\n')
    before=(store/'config.toml').read_bytes()
    env=dict(ORIG,FM_HOME=str(home),HOME=str(user),CODEX_HOME=str(store),PATH=str(bindir)+':'+ORIG['PATH'],TMPDIR=str(d/'tmp'),FM_SPAWN_NO_GUARD='1',FM_BACKEND='tmux')
    tx('new-session','-d','-s','firstmate','-x','150','-y','42','-c',ROOT,'/bin/bash --noprofile --norc')
    tx('set-option','-g','default-shell',shell)
    tx('set-option','-g','default-command',str(shell))
    tx('set-option','-g','history-limit','3000')
    # The server's global pane environment is separate from the calling process.
    for key in ['HOME','FM_HOME','CODEX_HOME','PATH','TMPDIR']:
        tx('set-environment','-g',key,env[key])
    serverpid=tx('display-message','-p','#{pid}').stdout.strip()
    env['TMUX']=SOCKET+','+serverpid+',0'
    target='firstmate:fm-'+ident
    args=['bash','bin/fm-spawn.sh',ident,str(proj),'--harness','codex']
    if mode=='scout': args.append('--scout')
    else: args.extend(['--mode','no-mistakes','--yolo','off'])
    frames=[]; start=time.monotonic(); worker_pids=[]
    try:
        p=sp.Popen(args,env=env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT)
        while p.poll() is None:
            fr=tx('capture-pane','-p','-S','-100','-t',target,check=False)
            if fr.returncode==0:
                if not frames or frames[-1]!=fr.stdout: frames.append(fr.stdout)
                if 'Folder access' in fr.stdout and ('Trust and continue' in fr.stdout or 'Open restricted' in fr.stdout):
                    screenshot(name+'-prompt',fr.stdout)
            if time.monotonic()-start>330:
                p.terminate(); raise RuntimeError('spawn exceeded 330 seconds')
            time.sleep(.15)
        out=p.communicate()[0]; elapsed=time.monotonic()-start
        final=tx('capture-pane','-p','-S','-100','-t',target,check=False)
        if final.returncode==0: frames.append(final.stdout)
        log=f'COMMAND: {shlex.join(args)}\nElapsed: {elapsed:.2f}s\nExit: {p.returncode}\n{out}\n'
        log+='STORE BEFORE:\n'+before.decode()+'\nSTORE AFTER:\n'+(store/'config.toml').read_text()
        log+='\nPANE FRAMES:\n'+'\n--- frame ---\n'.join(frames)
        (EV/f'{name}.log').write_text(log)
        if mode in ['fresh','scout','quoted']:
            assert p.returncode==0, out
            assert any('esc to interrupt' in f or 'Worked for ' in f for f in frames), 'No real started turn captured'
            if mode!='quoted': assert not any('Trust and continue' in f for f in frames), 'Unexpected trust modal'
            else: assert any('Trust and continue' in f and 'Open restricted' in f and 'esc to interrupt' in f for f in frames), 'Quoted dialogs were not visible during started turn'
            import tomllib
            assert tomllib.loads((store/'config.toml').read_text())['projects'][str(proj)]['trust_level']=='trusted'
            aa=(d/'args.txt').read_text().splitlines(); assert any(aa[i:i+2]==['--disable','hooks'] for i in range(len(aa)-1)),aa
            screenshot(name+'-started',frames[-1])
        elif mode in ['declined','broken']:
            assert p.returncode!=0 and 'could not pre-register Codex folder trust' in out,out
            assert not (d/'worker.pid').exists(), 'CLI launched despite refusal'
            assert (store/'config.toml').read_bytes()==before, 'Store rewritten on refusal'
        else:
            expected='showed neither its folder-access prompt nor a started turn' if mode=='timeout' else 'parked on its folder-access prompt'
            assert p.returncode!=0 and expected in out,out
            assert elapsed<300, 'Readiness rejection exceeded five minutes'
            assert final.returncode!=0, 'Rejected endpoint still exists'
            if mode!='timeout':
                choice='Open restricted' if mode=='prompt-restricted' else 'Trust and continue'
                assert any('Folder access' in f and choice in f for f in frames), 'Real modal not captured'
                if mode=='prompt-inline': assert any('Folder access' in f and 'Worked for 1s' in f and 'launch.' in f for f in frames), 'Old inline output, launch echo, and live modal did not coexist'
            else:
                assert any('OpenAI Codex' in f and 'Ask Codex' in f for f in frames), 'Real idle composer not captured'
                assert not any('esc to interrupt' in f for f in frames), 'CLI unexpectedly started a turn'
                screenshot(name+'-idle',frames[-1])
            assert not (home/'state'/f'{ident}.meta').exists(), 'Provisional record remains'
            if mode=='prompt-scan-fail':
                warning=f'warning: could not verify worker shutdown for task {ident} in worktree {wt}; preserving its git-hooks strip'
                assert out.count(warning)==1,out
                assert (home/'state'/f'{ident}.git-hooks').is_dir(), 'Unverified-worker hooks strip removed'
            else:
                worker_pids=pids_under(wt)
                assert not worker_pids, f'Rejected worker remains: {worker_pids}'
        log+='\nPOSTCONDITIONS: verified; endpoint '+('open' if final.returncode==0 else 'closed')+'\n'
        (EV/f'{name}.log').write_text(log)
        print(json.dumps(dict(scenario=name,result='pass',seconds=round(elapsed,2))),flush=True)
    finally:
        owned=pids_under(wt)
        tx('kill-server',check=False)
        for pid in owned:
            try: os.kill(pid,signal.SIGTERM)
            except ProcessLookupError: pass
        # Never leave the real harness alive after validation.
        deadline=time.monotonic()+5
        while pids_under(wt) and time.monotonic()<deadline: time.sleep(.1)
        remaining=pids_under(wt)
        for pid in remaining:
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
        assert not pids_under(wt), 'Lab process cleanup failed'

cases=[('fresh','fresh'),('scout','scout'),('declined','declined'),('broken','broken'),('prompt','prompt'),('prompt-scan-fail','prompt-scan-fail'),('timeout','timeout'),('timeout-retry','timeout'),('quoted','quoted'),('prompt-inline','prompt-inline'),('prompt-restricted','prompt-restricted')]
if sys.argv[1:]: cases=[(x,dict(cases)[x]) for x in sys.argv[1:]]
for name,mode in cases:
    try: scenario(name,mode)
    except Exception as e:
        print(json.dumps(dict(scenario=name,result='fail',error=str(e))),flush=True)
        raise
