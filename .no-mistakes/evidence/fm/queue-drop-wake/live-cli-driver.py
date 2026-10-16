import os,pathlib,subprocess,json,time
root=pathlib.Path.cwd(); p=root/'.test-phase/local-cli';p.mkdir()
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M51C1DWAJZ71NFCZJ46PQH92')
for n in ['state','config','usage','pstack/.cursor-plugin']: (p/n).mkdir(parents=True,exist_ok=True)
(p/'pstack/.cursor-plugin/plugin.json').write_text('{"version":"0.15.21"}')
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM']:env.pop(k,None)
env.update(FM_HOME=str(p),FM_CURSOR_USAGE_DIR=str(p/'usage'),FM_PSTACK_DIR=str(p/'pstack'))
log=[]
def run(args,expect=0,stdin=None,extra=None):
    r=subprocess.run(args,env=dict(env,**(extra or {})),input=stdin,capture_output=True,text=True,timeout=30)
    log.append({'command':args,'stdin':stdin,'stdout':r.stdout,'stderr':r.stderr,'exit':r.returncode})
    assert r.returncode==expect,(args,r.stdout,r.stderr,r.returncode)
    return r.stdout
rules={'label_routes':{'docs-only':{'harness':'codex','model':'gpt-6.1-sol','effort':'max'},'ep-opus':{'harness':'claude','model':'opus','effort':'xhigh'}},'default':{'harness':'cursor','model':'cursor-grok-4.6-high'}}
(p/'config/crew-dispatch.json').write_text(json.dumps(rules))
s=run(['bin/fm-dispatch-resolve.sh','--labels','docs-only']);assert '--harness \'codex\'' in s and '--effort \'max\'' in s,s
s=run(['bin/fm-dispatch-resolve.sh','--labels','ep-opus']);assert '--harness \'claude\'' in s,s
s=run(['bin/fm-dispatch-resolve.sh','--labels','unmatched']);assert '--harness \'cursor\'' in s,s
s=run(['bin/fm-dispatch-resolve.sh','--labels','docs-only,ep-opus'],1);assert 'status: refused' in s
s=run(['bin/fm-role.sh','report']);assert s.strip()=='fm-role: user (default)'
s=run(['bin/fm-role.sh','check',str(root)],1);assert 'no publication authority' in s
s=run(['bin/fm-role.sh','check',str(root),'upstream-consent','github.com/example/wrong'],1);assert 'refused' in s
(p/'usage/current-spending.txt').write_text('cursor_models_pct=26\n')
s=run(['bin/fm-cursor-guard.sh','fallback','demo']);assert s.strip()=='cursor'
(p/'usage/current-spending.txt').write_text('cursor_models_pct=89\n')
s=run(['bin/fm-cursor-guard.sh','fallback','demo']);assert s.startswith('codex Cursor Models at 89%')
(p/'state/demo.codex-limit').write_text('Codex usage exhausted\n')
s=run(['bin/fm-cursor-guard.sh','fallback','demo']);assert s.startswith('claude Cursor Models at 89%')
(p/'usage/current-spending.txt').write_text('cursor_models_pct=26\n')
(p/'pstack/.cursor-plugin/plugin.json').write_text('{"version":"0.15.22"}')
s=run(['bin/fm-cursor-guard.sh','fallback','demo']);assert s.startswith('grok pstack plugin version')
run(['bin/fm-cursor-guard.sh','take','demo']);run(['bin/fm-cursor-guard.sh','take','demo']);run(['bin/fm-cursor-guard.sh','take','demo'],1)
run(['bin/fm-cursor-guard.sh','give','demo']);run(['bin/fm-cursor-guard.sh','take','demo'])
lock=p/'state/cursor-dispatch.lock';lock.mkdir();os.utime(lock,(1,1))
run(['bin/fm-cursor-guard.sh','take','another'])
assert not lock.exists()
run(['bin/fm-cursor-assert.sh'],extra={'FM_CURSOR_CLI_CONFIG':str(p/'cursor/cli-config.json'),'FM_CURSOR_MODELS_RULE':str(p/'cursor/pstack-models.mdc')})
cfg=json.loads((p/'cursor/cli-config.json').read_text());assert cfg['network']['useHttp1ForAgent'] is True
params={x['id']:x['value'] for x in cfg['modelParameters']['grok-4.7']};assert params=={'context':'256k','reasoning_effort':'xhigh','fast':'false'}
(evidence/'live-cursor-generated-config.json').write_text(json.dumps(cfg,indent=2))
for cmd,permission in [('git status','allow'),('if true; then env git update-ref refs/heads/a HEAD; fi','deny'),('git branch --show-current','allow'),('git switch -c test','allow')]:
    s=run(['node','bin/fm-cursor-crew-guard.mjs','--worktree',str(p)],stdin=json.dumps({'tool_name':'Shell','tool_input':{'command':cmd}}))
    got=json.loads(s);assert got['permission']==permission,(cmd,got)
    if permission=='allow':assert got['updated_input']['cwd']==str(p)
(evidence/'live-local-cli-transcript.json').write_text(json.dumps(log,indent=2))
print('Public routing, publication, Cursor fallback, launch cap, stale-lock recovery, generated settings, and hook protocols passed')
