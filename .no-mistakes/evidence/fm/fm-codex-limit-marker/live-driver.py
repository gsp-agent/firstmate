import os, subprocess as sp, pathlib as P, json, http.server, threading, time, sys, shlex
root=P.Path.cwd(); ev=P.Path('/Users/dalecarman/.no-mistakes/evidence/01M5JHQCG4FESCSQGZDRMVAJQS'); lab=root/'.live-limit-lab3'; lab.mkdir()
log=(ev/'live-product.log').open('w', buffering=1)
def note(s): print(s,flush=True); log.write(s+'\n')
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'CLAUDE', 'TASKS_AXI', 'CODEX')) or k in ['NO_MISTAKES_GATE','TMUX','TMUX_PANE']: env.pop(k,None)
user=lab/'user'; user.mkdir(exist_ok=True); (user/'.claude').mkdir(exist_ok=True)
(user/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True,'theme':'dark'}))
(env_home:=lab/'home').mkdir(exist_ok=True)
socket=ev/'t'; socket.mkdir(exist_ok=True)
(lab/'codex').mkdir()
env.update(HOME=str(user), CLAUDE_CONFIG_DIR=str(user/'.claude'), CODEX_HOME=str(lab/'codex'), FM_HOME=str(env_home), FM_BACKEND='tmux', TMUX_TMPDIR=str(socket), FM_SPAWN_NO_GUARD='1', FM_LIVE_SESSION_CHECK='', DISABLE_AUTOUPDATER='1', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
def run(args, check=True, timeout=120):
    p=sp.run(list(map(str,args)),env=env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=timeout)
    note('$ '+shlex.join(list(map(str,args)))+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
    if check and p.returncode: raise RuntimeError('command failed')
    return p

def tm(*args,check=True): return run(['tmux','-L','fm-lab',*args],check=check)
run(['bash','bin/fm-lab-home.sh','create',env_home])
for name,value in [('backend','tmux'),('claude-permission-mode','auto')]: (env_home/'config'/name).write_text(value+'\n')
proj=lab/'project'; wt=lab/'wt'; proj.mkdir(exist_ok=True)
run(['git','-C',proj,'init','-q']); (proj/'README.md').write_text('Disposable live routing verification.\n')
run(['git','-C',proj,'add','README.md']); run(['git','-C',proj,'-c','user.name=Routing Test','-c','user.email=test@example.invalid','commit','-qm','initial'])
run(['git','-C',proj,'worktree','add','-q','-b','proof',wt])
id='limitproof'+str(os.getpid()); (ev/'live-task-id.txt').write_text(id)
data=env_home/'data'/id; data.mkdir(); (data/'brief.md').write_text('# Task\n## Captain\'s intent\nReply with LIMIT_ROUTE_OK, then stop. Do not edit files, start supervision or call any tools except reading your launch brief if needed. This is a disposable routing verification.\n## Firstmate spec\nOnly reply LIMIT_ROUTE_OK.\n')
tm('-f','/dev/null','new-session','-d','-s','primary','-n','fm-'+id,'-x','120','-y','40','-c',wt)
# The socket is exclusively lab-owned; all production operations inherit this same endpoint.
info=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip(); env['TMUX']=info
env['TMUX_PANE']=tm('display-message','-p','-t','primary','#{pane_id}').stdout.strip()
meta=env_home/'state'/(id+'.meta')
base={'window':'primary:fm-'+id,'endpoint_task_id':id,'worktree':str(wt),'project':str(proj),'harness':'codex','kind':'ship','mode':'local-only','yolo':'off','model':'gpt-5','effort':'high','backend':'tmux','spawn_gen':'s'+str(int(time.time())-10)+'.1.1'}
def write_meta(d): meta.write_text(''.join(k+'='+v+'\n' for k,v in d.items()))
write_meta(base)
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        b=json.dumps({'error':{'type':'usage_limit_reached','message':'The usage limit has been reached','plan_type':'pro','resets_at':int(time.time())+86400}}).encode()
        self.send_response(429); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET=do_POST
    def log_message(self,*a): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),H); threading.Thread(target=server.serve_forever,daemon=True).start()
env['MOCK_KEY']='dummy'
try:
    p=run(['codex','exec','--skip-git-repo-check','-C',wt,'-c','model_provider="mock"','-c','model_providers.mock={name="mock",base_url="http://127.0.0.1:'+str(server.server_port)+'/v1",wire_api="responses",env_key="MOCK_KEY"}','-m','gpt-5','say hi'],check=False)
    assert p.returncode!=0
    files=list((lab/'codex'/'sessions').rglob('rollout-*.jsonl')); assert files
    for f in files:
        for l in f.read_text().splitlines():
            o=json.loads(l)
            if o.get('type')=='session_meta' or o.get('payload',{}).get('type')=='task_complete': note('Codex persisted: '+json.dumps({'type':o['type'],'payload':({k:v for k,v in o['payload'].items() if k in ['cwd','cli_version']} if o['type']=='session_meta' else o['payload'])}))
    # Raw executable identity must route by its canonical family, and never launch when redirected.
    usage=lab/'usage'; usage.mkdir(); (usage/'current-spending.txt').write_text('cursor_models_pct=90\n'); env['FM_CURSOR_USAGE_DIR']=str(usage)
    base['harness']='cursor-agent'; base['worktree']=str(proj); write_meta(base); before=meta.read_bytes()
    p=run(['bash','bin/fm-spawn.sh',id,'--relaunch','--harness','cursor-agent --trust'],check=False)
    assert p.returncode==1 and 'route to codex' in p.stdout and meta.read_bytes()==before
    note('Observed refusal: Cursor raw command left task record and generation unchanged.')
    base['harness']='codex-client'; base['worktree']=str(wt); write_meta(base); before=meta.read_bytes()
    p=run(['bash','bin/fm-spawn.sh',id,'--relaunch','--harness','codex --no-alt-screen'],check=False)
    assert p.returncode==1 and 'route to claude' in p.stdout and meta.read_bytes()==before
    marker=env_home/'state'/(id+'.codex-limit'); assert marker.stat().st_size
    note('Persisted marker: '+marker.read_text())
    # Override must scan a retiring prefixed Codex record before a healthy Cursor early return.
    # Separate task ids avoid manufacturing a marker deletion/reset on the live task.
    for target in ['claude','cursor-agent']:
        oid=id+'-'+target; om=env_home/'state'/(oid+'.meta'); om.write_bytes(meta.read_bytes())
        (usage/'current-spending.txt').write_text('cursor_models_pct=10\n')
        p=run(['bash','bin/fm-cursor-guard.sh','route',oid,target,'codex-client'])
        assert p.stdout.strip()==('cursor' if target=='cursor-agent' else 'claude')
        assert (env_home/'state'/(oid+'.codex-limit')).stat().st_size
        new=base.copy(); new['harness']='claude'; new['spawn_gen']='s'+str(int(time.time())+300)+'.1.2'; om.write_text(''.join(k+'='+v+'\n' for k,v in new.items()))
        p=run(['bash','bin/fm-cursor-guard.sh','route',oid,'codex']); assert p.stdout.startswith('claude ')
    note('Healthy Cursor and Claude overrides preserved retiring Codex limits across generation replacement.')
    # Same-family direct relaunch must preserve omitted axes, without touching a real CLI.
    # The marked task now takes the canonical live Claude replacement.
    p=run(['bash','bin/fm-spawn.sh',id,'--relaunch','--harness','codex'])
    assert 'harness=claude' in p.stdout
    note('Task record after real relaunch:\n'+meta.read_text())
    assert 'harness=claude\n' in meta.read_text() and 'effort=xhigh\n' in meta.read_text()
    # Bounded readiness observation of the real CLI in a 120x40 terminal.
    for i in range(12):
        time.sleep(2)
        pane=tm('capture-pane','-p','-S','-160','-t','primary').stdout
        if 'LIMIT_ROUTE_OK' in pane or 'Welcome to Claude' in pane or 'login' in pane.lower() or 'select the text style' in pane.lower(): break
    (ev/'claude-live-pane.txt').write_text(pane)
    note('Live CLI process tree:\n'+tm('list-panes','-t','primary','-F','#{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height}').stdout)
    (ev/'live-results.json').write_text(json.dumps({'raw_cursor_refused':True,'raw_codex_refused':True,'retiring_override_marker':True,'relaunch_harness':'claude','pane':pane},indent=2))
finally:
    server.shutdown(); server.server_close()
    tm('kill-server',check=False)
    note('Stopped the private fm-lab tmux server and local usage-limit provider.')
