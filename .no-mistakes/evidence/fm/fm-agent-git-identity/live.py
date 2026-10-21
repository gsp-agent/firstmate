import os, pathlib, subprocess, time, json, shlex
root=pathlib.Path.cwd(); lab=root/'.identity-validation/live'; lab.mkdir()
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5FWNE5V6ESXE85390HX5H69')
log=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'GIT_', 'TASKS_AXI')) or k in ('TMUX','TMUX_PANE','CLAUDE_CONFIG_DIR','CODEX_HOME'):
        env.pop(k)
env.update(HOME=str(lab/'user'), SHELL='/bin/bash', TREEHOUSE_ROOT=str(lab/'pool'), GIT_CONFIG_NOSYSTEM='1')
(lab/'user').mkdir(); (lab/'user/.gitconfig').write_text('[user]\n name = Dale Carman\n email = dale.carman@gmail.com\n')

def run(args, cwd=root, check=True):
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.append('$ '+shlex.join(list(map(str,args)))+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p
home=lab/'home'; run(['bin/fm-lab-home.sh','create',home]); env['FM_HOME']=str(home)
# The private socket is an incidental runtime file managed by the lab helper.
socket=run(['bin/fm-lab-home.sh','tmux-dir',home]).stdout.strip(); env['TMUX_TMPDIR']=socket
sockargs=['tmux','-L','fm-lab']
project=lab/'project'; project.mkdir(); origin=lab/'origin.git'
run(['git','init','-q','-b','main',project]); run(['git','init','-q','--bare',origin])
run(['git','commit','-q','--allow-empty','-m','fixture baseline'], project)
run(['git','remote','add','origin',origin],project); run(['git','push','-q','-u','origin','main'],project)
run(['git','--git-dir',origin,'symbolic-ref','HEAD','refs/heads/main'])
probe=lab/'probe.sh'; probe.write_text('''#!/bin/bash
set -eu
out=$1
{
printf 'cwd=%s\\n' "$PWD"
printf 'config_name=%s\\n' "$(git config user.name)"
printf 'config_email=%s\\n' "$(git config user.email)"
git commit -q --allow-empty -m 'live worker first commit'
git log -1 --format='author=%an <%ae>%ncommitter=%cn <%ce>'
} > "$out"
''')
before=(lab/'user/.gitconfig').read_bytes(); shared=(project/'.git/config').read_bytes()
results=[]
try:
    run(sockargs+['new-session','-d','-s','primary','-x','120','-y','40','-c',root,'/bin/bash --noprofile --norc'])
    env['TMUX']=run(sockargs+['display-message','-p','-t','primary','#{socket_path},#{pid},0']).stdout.strip()
    for name,identity,keep,override in [
        ('configured','gsp-agent <dale+gspagent@groovejones.com>',False,False),
        ('absent',None,False,False),
        ('keep-trailers','gsp-agent <dale+gspagent@groovejones.com>',True,False),
        ('inherited-author','gsp-agent <dale+gspagent@groovejones.com>',False,True),
        ('malformed','gsp-agent',False,False)]:
        setting=home/'config/worker-git-identity'
        # Keep each configuration experiment in its own home; never delete settings.
        if name!='configured':
            home=lab/('home-'+name); run(['bin/fm-lab-home.sh','create',home]); env['FM_HOME']=str(home)
        if identity is not None: (home/'config/worker-git-identity').write_text(identity+'\n')
        if keep: (home/'config/keep-ai-trailers').touch()
        id='ident-live-'+name
        (home/('data/'+id)).mkdir(); (home/('data/'+id+'/brief.md')).write_text("# Task\n## Captain's intent\nValidate first worker commit identity in an isolated fixture.\n\n## Firstmate spec\nRun only the identity probe.\n")
        (home/'state/.last-watcher-beat').touch()
        out=evidence/(name+'.txt')
        command='/bin/bash '+shlex.quote(str(probe))+' '+shlex.quote(str(out))
        if override: command='GIT_AUTHOR_NAME=\'Dale Carman\' GIT_AUTHOR_EMAIL=dale.carman@gmail.com '+command
        p=run(['bin/fm-spawn.sh',id,project,command,'--mode','local-only','--yolo','off'],check=False)
        if name!='malformed' and p.returncode==0:
            deadline=time.monotonic()+15
            while not out.exists() and time.monotonic()<deadline: time.sleep(.1)
        record={'case':name,'spawn_exit':p.returncode,'output':out.read_text() if out.exists() else ''}
        results.append(record)
        if p.returncode and name!='malformed':
            run(sockargs+['capture-pane','-p','-t','primary','-S','-200'],check=False)
            run(sockargs+['list-panes','-a','-F','#{pane_id} #{pane_current_path}'],check=False)
        if (lab/'user/.gitconfig').read_bytes()!=before: raise RuntimeError('global config changed')
        if (project/'.git/config').read_bytes()!=shared: raise RuntimeError('shared config changed')
    log.append('CAPTAIN SHELL IDENTITY: '+run(['git','config','user.email'], project).stdout.strip())
    log.append('Synthetic captain global and project shared config bytes unchanged: true')
finally:
    run(sockargs+['kill-server'],check=False)
    # Only this marked home's helper owns the private ephemeral socket cleanup.
    run(['bin/fm-lab-home.sh','teardown',lab/'home'],check=False)
    (evidence/'live-transcript.txt').write_text('\n\n'.join(log))
    (evidence/'live-results.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
