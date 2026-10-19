from pathlib import Path
import json, os, sqlite3, subprocess, time

root = Path.cwd()
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round3')
scratch = root / '.nm-live-yeldv-r3'
assert not scratch.exists(), 'fresh fixture only'
scratch.mkdir()
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'TASKS_AXI_', 'NM_'))}
isolated = { 'NM_HOME': str(scratch/'nm-home'), 'FM_HOME': str(scratch/'fm-home'),
    'TMPDIR': str(scratch/'tmp'), 'XDG_CONFIG_HOME': str(scratch/'xdg-config'),
    'XDG_CACHE_HOME': str(scratch/'xdg-cache'), 'GIT_CONFIG_GLOBAL': '/dev/null',
    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_TERMINAL_PROMPT': '0',
    'GIT_AUTHOR_NAME':'gsp-agent', 'GIT_COMMITTER_NAME':'gsp-agent',
    'GIT_AUTHOR_EMAIL':'gsp-agent@users.noreply.github.com',
    'GIT_COMMITTER_EMAIL':'gsp-agent@users.noreply.github.com'}
for key in ['NM_HOME', 'TMPDIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME']:
    Path(isolated[key]).mkdir(parents=True)
env.update(isolated)
def run(args, cwd=root, extra=None, check=True):
    p = subprocess.run(list(map(str,args)), cwd=cwd, env=env|dict(extra or {}), text=True, capture_output=True, timeout=45)
    if check and p.returncode:
        raise RuntimeError(str(args)+'\n'+p.stdout+p.stderr)
    return p.stdout.strip()
seed=scratch/'seed'; remote=scratch/'origin.git'; slot=scratch/'slot'
run(['git','init','-q','-b','main',seed])
(seed/'payload.txt').write_text('initial payload\n')
run(['git','-C',seed,'add','payload.txt'])
run(['git','-C',seed,'commit','-qm','initial disposable payload'])
run(['git','clone','-q','--bare',seed,remote])
run(['git','-C',remote,'config','uploadpack.allowFilter','true'])
run(['git','clone','-q','--filter=blob:none',remote.as_uri(),slot])
run(['git','-C',slot,'switch','-qc','fm/lab-yeldv'])
submitted=run(['git','-C',slot,'rev-parse','HEAD'])
run(['git','-C',seed,'switch','-qc','fm/lab-yeldv'])
(seed/'pipeline-only.txt').write_text('private pipeline commit absent from origin\n')
run(['git','-C',seed,'add','pipeline-only.txt'])
run(['git','-C',seed,'commit','-qm','pipeline-only fix'])
head=run(['git','-C',seed,'rev-parse','HEAD'])
repo_id='f3ab00000001'; run_id='01M5APP0000000000000000021'
nmrepo=scratch/'nm-home'/'repos'/(repo_id+'.git')
nmrepo.parent.mkdir(parents=True)
run(['git','clone','-q','--bare',seed,nmrepo])
run(['git','-C',slot,'remote','add','no-mistakes',nmrepo])
# A read-only CLI inspection creates its own schema in the disposable NM_HOME.
run(['no-mistakes','axi','status'],cwd=slot,check=False)
now=int(time.time()*1000)
finding={'findings':[{'id':'LAB21','severity':'warning','description':'Disposable review decision retained for missing-head proof','action':'ask-user'}]}
with sqlite3.connect(scratch/'nm-home'/'state.sqlite') as db:
    db.execute('INSERT INTO repos(id,working_path,upstream_url,default_branch,created_at) VALUES (?,?,?,?,?)',(repo_id,str(slot),remote.as_uri(),'main',now))
    db.execute('INSERT INTO runs(id,repo_id,branch,head_sha,base_sha,submitted_head_sha,worktree_dir,status,awaiting_agent_since,created_at,updated_at,intent) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
        (run_id,repo_id,'fm/lab-yeldv',head,submitted,submitted,str(seed),'running',now,now,now,'Disposable live validation record; no pipeline was started'))
    db.execute('INSERT INTO step_results(id,run_id,step_name,step_order,status,findings_json,started_at) VALUES (?,?,?,?,?,?,?)',('lab-review21',run_id,'review',1,'awaiting_approval',json.dumps(finding),now))
run([root/'bin/fm-lab-home.sh','create',env['FM_HOME']])
(Path(env['FM_HOME'])/'state/lab-yeldv.meta').write_text('worktree='+str(slot)+'\nproject='+str(slot)+'\nkind=ship\nbranch=fm/lab-yeldv\nmode=no-mistakes\n')
fixture={'scratch':str(scratch),'slot':str(slot),'seed':str(seed),'remote':str(remote),'head':head,'submitted':submitted,'run_id':run_id,'repo_id':repo_id}
(evidence/'env.json').write_text(json.dumps(isolated,indent=2))
(evidence/'fixture.json').write_text(json.dumps(fixture,indent=2))
print(json.dumps(fixture),flush=True)
p=subprocess.run(['no-mistakes','axi','status'],cwd=slot,env=env|{'GIT_NO_LAZY_FETCH':'1'},text=True,capture_output=True,timeout=30)
(evidence/'initial-status.toon').write_text(p.stdout+p.stderr)
print('initial status exit='+str(p.returncode)+'\n'+p.stdout+p.stderr,flush=True)
