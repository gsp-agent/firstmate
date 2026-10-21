import os, pathlib, subprocess, time, json, shlex
root=pathlib.Path.cwd()
lab=root/'.identity-validation-r2'
lab.mkdir()
code=lab/'runtime';code.mkdir()
tmp=lab/'tmp';tmp.mkdir()
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5FWNE5V6ESXE85390HX5H69')
logs=[];results=[]
env=os.environ.copy()
for key in list(env):
    if key.startswith(('FM_','GIT_','TASKS_AXI')) or key in ('TMUX','TMUX_PANE','CLAUDE_CONFIG_DIR','CODEX_HOME'):
        env.pop(key)
env.update(HOME=str(lab/'user'),SHELL='/bin/bash',TREEHOUSE_ROOT=str(lab/'pool'),GIT_CONFIG_NOSYSTEM='1',TMPDIR=str(tmp))
(lab/'user').mkdir()
global_config=lab/'user/.gitconfig'
global_config.write_text('[user]\n name = Dale Carman\n email = dale.carman@gmail.com\n')
def run(args,cwd=root,check=True):
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    logs.append('$ '+shlex.join(list(map(str,args)))+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
    if check and p.returncode:raise RuntimeError(p.stdout)
    return p
archive=subprocess.run(['git','archive','HEAD'],stdout=subprocess.PIPE,check=True).stdout
subprocess.run(['tar','-x','-C',str(code)],input=archive,check=True)
# All product code is an unchanged HEAD export, allowing sibling secondmate homes.
run(['bash',code/'tests/fm-spawn-worker-git-identity.test.sh'])
(evidence/'round2-targeted-test.txt').write_text(logs[-1])
project=lab/'project';project.mkdir();origin=lab/'origin.git'
run(['git','init','-q','-b','main',project]);run(['git','init','-q','--bare',origin])
run(['git','commit','-q','--allow-empty','-m','fixture baseline'],project)
run(['git','remote','add','origin',origin],project);run(['git','push','-q','-u','origin','main'],project)
run(['git','--git-dir',origin,'symbolic-ref','HEAD','refs/heads/main'])
probe=lab/'probe.sh'
probe.write_text('''#!/bin/bash
set -eu
out=$1
{
printf 'cwd=%s\\n' "$PWD"
printf 'config_name=%s\\n' "$(git config user.name)"
printf 'config_email=%s\\n' "$(git config user.email)"
printf 'hooks=%s\\n' "$(git config core.hooksPath || true)"
git commit -q --allow-empty -m 'live worker first commit'
git log -1 --format='author=%an <%ae>%ncommitter=%cn <%ce>'
} > "$out"
''')
firsthome=lab/'home-socket';run([code/'bin/fm-lab-home.sh','create',firsthome])
socket=run([code/'bin/fm-lab-home.sh','tmux-dir',firsthome]).stdout.strip()
env['TMUX_TMPDIR']=socket
sock=['tmux','-L','fm-lab']
global_before=global_config.read_bytes();shared_before=(project/'.git/config').read_bytes()
def home_for(name,identity=None,keep=False):
    home=lab/('home-'+name);run([code/'bin/fm-lab-home.sh','create',home])
    if identity is not None:(home/'config/worker-git-identity').write_text(identity+'\n')
    if keep:(home/'config/keep-ai-trailers').touch()
    return home
def brief(home,id):
    (home/('data/'+id)).mkdir()
    (home/('data/'+id+'/brief.md')).write_text("# Task\n## Captain's intent\nValidate first worker commit identity in an isolated fixture.\n\n## Firstmate spec\nRun only the identity probe; no network operations.\n")
    (home/'state/.last-watcher-beat').touch()
def spawn(name,home,proj=project,raw=None,flags=None,expected='gsp-agent <dale+gspagent@groovejones.com>',refuse=False,relaunch=False):
    id='ident-r2-'+name;env['FM_HOME']=str(home)
    if not relaunch:brief(home,id)
    out=evidence/('round2-'+name+('-relaunch' if relaunch else '')+'.txt')
    command='/bin/bash '+shlex.quote(str(probe))+' '+shlex.quote(str(out))
    if raw:command=raw+' '+command
    if relaunch:
        # Relaunch reuses the original command and evidence destination.
        prior=evidence/('round2-'+name+'.txt')
        if prior.exists(): prior.rename(evidence/('round2-'+name+'-first.txt'))
        out=prior
        args=[code/'bin/fm-spawn.sh',id,'--relaunch']
    else:args=[code/'bin/fm-spawn.sh',id,proj,command]+(flags if flags is not None else ['--mode','local-only','--yolo','off'])
    p=run(args,check=False)
    if refuse:
        assert p.returncode!=0,(name,p.stdout)
        assert 'identity' in p.stdout,(name,p.stdout)
        assert not (home/('state/'+id+'.meta')).exists(),name+' created worker metadata'
        assert not out.exists(),name+' ran a worker'
        text=p.stdout
    else:
        assert p.returncode==0,(name,p.stdout)
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            if out.exists() and 'committer=' in out.read_text():break
            time.sleep(.1)
        text=out.read_text() if out.exists() else ''
        assert 'author='+expected in text,(name,text)
        assert 'committer='+expected in text,(name,text)
        assert 'config_email='+expected.split('<')[1][:-1] in text,(name,text)
        wt=pathlib.Path(next(line[4:] for line in text.splitlines() if line.startswith('cwd=')))
        outside=run(['git','config','user.email'],wt).stdout.strip()
        assert outside=='dale.carman@gmail.com',(name,outside)
    assert global_config.read_bytes()==global_before,'global config changed'
    assert (project/'.git/config').read_bytes()==shared_before,'shared project config changed'
    results.append({'case':name+('-relaunch' if relaunch else ''),'result':'pass','spawn_exit':p.returncode,'observable':text})
    (evidence/'round2-results.json').write_text(json.dumps(results,indent=2))
    print(name+('-relaunch' if relaunch else '')+': pass',flush=True)
    return out
try:
    run(sock+['new-session','-d','-s','primary','-x','120','-y','40','-c',root,'/bin/bash --noprofile --norc'])
    env['TMUX']=run(sock+['display-message','-p','-t','primary','#{socket_path},#{pid},0']).stdout.strip()
    home=home_for('default');spawn('default',home)
    spawn('default',home,relaunch=True)
    home=home_for('configured','Fleet Agent <fleet-agent@example.invalid>');spawn('configured',home,expected='Fleet Agent <fleet-agent@example.invalid>')
    spawn('keep-trailers',home_for('keep-trailers',keep=True))
    # The real pane server inherited Dale's variables before launch, too.
    for k,v in [('GIT_AUTHOR_NAME','Dale Carman'),('GIT_AUTHOR_EMAIL','dale.carman@gmail.com'),('GIT_COMMITTER_NAME','Dale Carman'),('GIT_COMMITTER_EMAIL','dale.carman@gmail.com')]:
        run(sock+['set-environment','-g',k,v]);env[k]=v
    spawn('inherited-author',home_for('inherited-author',keep=True))
    for k in ('GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL'):
        run(sock+['set-environment','-gu',k]);env.pop(k,None)
    for n,raw in enumerate(["GIT_AUTHOR_NAME='Dale Carman' GIT_AUTHOR_EMAIL=dale.carman@gmail.com",'env GIT_AUTHOR_EMAIL=dale.carman@gmail.com',"GIT_COMMITTER_NAME='Dale Carman'",'export GIT_COMMITTER_EMAIL=dale.carman@gmail.com;']):
        spawn('explicit-'+str(n),home_for('explicit-'+str(n)),raw=raw,refuse=True)
    spawn('malformed',home_for('malformed','gsp-agent'),refuse=True)
    spawn('scout',home_for('scout'),flags=['--scout'])
    allow=home_for('allowlist');(allow/'config/launch-env-allowlist').write_text('PATH\nHOME\nSHELL\n')
    spawn('allowlist',allow)
    # Secondmate and its crew use the real inheritance path and real panes.
    primary=home_for('mate-primary','gsp-agent <dale+gspagent@groovejones.com>')
    mate=home_for('mate')
    subprocess.run(['tar','-x','-C',str(mate)],input=archive,check=True)
    (mate/'.fm-secondmate-home').write_text('ident-r2-secondmate\n');(mate/'data/charter.md').write_text('Isolated identity validation only.\n')
    run(['git','init','-q','-b','main',mate]);run(['git','commit','-q','--allow-empty','-m','mate fixture baseline'],mate)
    spawn('secondmate',primary,proj=mate,flags=['--secondmate'])
    assert (mate/'config/worker-git-identity').read_text()=='gsp-agent <dale+gspagent@groovejones.com>\n'
    spawn('secondmate-crew',mate)
    logs.append('Synthetic captain global and shared repository configuration unchanged in every case; outside-worker git config user.email stayed dale.carman@gmail.com.')
finally:
    run(sock+['kill-server'],check=False)
    run([code/'bin/fm-lab-home.sh','teardown',firsthome],check=False)
    (evidence/'round2-transcript.txt').write_text('\n\n'.join(logs))
    (evidence/'round2-results.json').write_text(json.dumps(results,indent=2))
print('All live scenarios passed. Lab tmux server stopped and socket removed.',flush=True)
