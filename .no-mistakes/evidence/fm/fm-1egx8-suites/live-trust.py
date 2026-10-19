from pathlib import Path
import hashlib,json,os,subprocess
r=Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M59Q21RQJTZ7ZCDK9K96MRAW')
e=Path('/Users/dalecarman/.no-mistakes/evidence/01M59Q21RQJTZ7ZCDK9K96MRAW')
d=r/'.gate-trust-live';d.mkdir()
for name in ('case-home','inherited-home','inherited-config','mate/bin','mate/data','mate/state','mate/config','mate/projects'):(d/name).mkdir(parents=True,exist_ok=True)
(d/'mate/.fm-secondmate-home').write_text('sm1\n');(d/'mate/AGENTS.md').write_text('# Disposable test home\n')
outer=[d/'inherited-home/.claude.json',d/'inherited-config/.claude.json']
for p in outer:p.write_text('{"fixture":"preserve me","projects":{}}\n')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p):digest(p) for p in outer}
env=os.environ.copy();env.update(HOME=str(d/'case-home'),CLAUDE_CONFIG_DIR='')
p=subprocess.run(['bash','bin/fm-claude-trust.sh','--secondmate-home',str(d/'mate'),'sm1'],cwd=r,env=env,text=True,capture_output=True)
print('$ HOME=<case-home> CLAUDE_CONFIG_DIR= bash bin/fm-claude-trust.sh --secondmate-home <disposable-mate> sm1')
print(p.stdout,end='');print(p.stderr,end='')
assert p.returncode==0
store=d/'case-home/.claude.json';config=json.loads(store.read_text())
assert config['projects'][str(d/'mate')]['hasTrustDialogAccepted'] is True
assert before=={str(p):digest(p) for p in outer}
result={'exit':p.returncode,'written_store':str(store),'registered_project':str(d/'mate'),'hasTrustDialogAccepted':True,'outer_store_hashes_before':before,'outer_store_hashes_after':{str(p):digest(p) for p in outer}}
print(json.dumps(result,indent=2))
(e/'live-trust-results.json').write_text(json.dumps(result,indent=2)+'\n')
