import os, pathlib, json, subprocess, shlex
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5KWW866PPTDFWE4PRBJYGC7'); L=R/'.local-owner-probe'; L.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','BEADS_','BR_','GIT_CONFIG_','XDG_'))}
env.update(HOME=str(L),FM_HOME=str(L),TMPDIR=str(L),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',DCG_HOOK_TIMEOUT_MS='2000')
wrapper=L/'prepare.sh'
wrapper.write_text('''#!/usr/bin/env bash
set -e
. "$1/bin/fm-wake-lib.sh"
lock=$(fm_meta_lock_path "$3/task-x1.meta")
fm_lock_try_acquire "$lock"
trap 'fm_lock_release "$lock"' EXIT
python3 "$1/bin/fm-task-data.py" prepare "$2" "$3" task-x1
''')
log=open(E/'live-owner-prepare.log','w',buffering=1)
def run(args,cwd):
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=env,text=True,capture_output=True,timeout=30)
    log.write('$ '+shlex.join(list(map(str,args)))+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    assert p.returncode==0,p.stderr
for kind in ('legacy','archived'):
    for name in ('path-text','other-checkout'):
        c=L/(kind+'-'+name); t=c/'data/task-x1'; (t/'record').mkdir(parents=True); (c/'state').mkdir(); (c/'history').mkdir()
        checkout=c/('dev/agent-config' if name=='path-text' else 'home/.agent-config')
        checkout.mkdir(parents=True)
        run(['git','init','-q',checkout],c);run(['git','-C',checkout,'remote','add','origin','https://github.com/gsp-agent/agent-config.git'],c)
        pr='https://github.com/gsp-agent/agent-config/pull/185'
        row=f'- [x] task-x1 - finished {pr} (repo: agent-config) (done 2026-10-20)\n  [capture](proof.png)\n'
        (c/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="history/completed.md"\n')
        (c/'data/backlog.md').write_text('# Backlog\n\n## Done\n');(c/'history/completed.md').write_text(row)
        (t/'proof.png').write_bytes(b'proof');(t/'scratch.bin').write_bytes(b'scratch')
        backlog={'data':str(c/'data'),'task':'task-x1'}
        if kind=='legacy':backlog.update(legacy=True,text=row)
        record={'version':1,'task':'task-x1','complete':False,'expired':False,'sources':[{'project':str(checkout),'pr':pr,'beads':[],'backlog':backlog}]}
        receipt=t/'record/data-cleanup.json';receipt.write_text(json.dumps(record))
        run(['bash',wrapper,R,c/'data',c/'state'],c)
        out=json.loads(receipt.read_text())
        assert out['sources'][0]['pr']==pr
        assert out['sources'][0]['unread']==[]
        assert (t/'proof.png').read_bytes()==b'proof' and (t/'scratch.bin').read_bytes()==b'scratch'
        log.write('PASS '+kind+' '+name+': same PR185 accepted as the same owner; no unread references\n'+json.dumps(out,sort_keys=True)+'\n')
log.close()
# Every disposable leaf is guarded; directories are removed only once empty.
files=[];dirs=[]
for parent,ds,fs in os.walk(L,topdown=False):
    files.extend(pathlib.Path(parent)/f for f in fs);dirs.append(pathlib.Path(parent))
for cmd,paths in [('rm',files),('rmdir',dirs)]:
    for offset in range(0,len(paths),16):
        args=[cmd, '-f','--'] if cmd=='rm' else [cmd,'--']
        args += list(map(str,paths[offset:offset+16]))
        guard=subprocess.run(['dcg'],input=json.dumps({'tool_name':'Bash','tool_input':{'command':shlex.join(args)}}),capture_output=True,text=True,env=env,check=True)
        if guard.stdout.strip():assert json.loads(guard.stdout)['hookSpecificOutput']['permissionDecision']=='allow',guard.stdout
        subprocess.run(args,check=True)
print('Four real same-PR preparation checks passed; disposable fixtures removed.')
