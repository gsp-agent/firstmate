import json, os, pathlib, shlex, subprocess, sys
root=pathlib.Path.cwd()
lab=root/'.agent-state/holdprobe-validation-tmp/fm-lab.ntj_i07y'
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5988E2EDNGT1XV34F05X546')
env={k:os.environ[k] for k in ('PATH','LANG','NO_MISTAKES_GATE') if k in os.environ}
env.update(HOME=str(lab/'hosthome'), TMPDIR=str(root/'.agent-state/holdprobe-validation-tmp'), PYTHONDONTWRITEBYTECODE='1',
           XDG_CACHE_HOME=str(lab/'cache'), XDG_STATE_HOME=str(lab/'xdg-state'), XDG_CONFIG_HOME=str(lab/'xdg-config'),
           GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_HOME=str(lab/'regression'),
           REVIEW_PAGE_HOME=str(lab/'world/pages'),DALE_RECORDS_DIR=str(lab/'world/records'),
           FM_DALE_ASKS_RULE='/Users/dalecarman/.agent-config/configs/claude/hooks/dale-asks-rule.py')
with (evidence/'asks-rule-before-after.log').open('w') as transcript:
    def log(text):
        print(text,flush=True)
        transcript.write(text+'\n');transcript.flush()
    def run(args,expected=0):
        log('$ '+shlex.join([str(x) for x in args]))
        p=subprocess.run([str(x) for x in args],env=env,cwd=root,text=True,capture_output=True,timeout=45)
        log(p.stdout.rstrip())
        if p.stderr:log('stderr: '+p.stderr.rstrip())
        log('exit: '+str(p.returncode))
        assert p.returncode==expected,(p.stdout,p.stderr)
        return p
    home=lab/'regression'
    run([root/'bin/fm-lab-home.sh','create',home])
    (home/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=10\n')
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    oldbin=lab/'prior-bin';oldbin.mkdir()
    for entry in (root/'bin').iterdir():
        if entry.name!='fm-captain-hold.sh':(oldbin/entry.name).symlink_to(entry)
    prior=subprocess.run(['git','show','cddd6faa:bin/fm-captain-hold.sh'],cwd=root,env=env,capture_output=True,check=True).stdout
    old=oldbin/'fm-captain-hold.sh';old.write_bytes(prior);old.chmod(0o700)
    item=json.loads((lab/'world/review.json').read_text())['chapters'][0]['items'][0]
    args=['hold','answered-regression','--title',item['title'],'--reason',item['ask'],'--dale-step','sign-in','--probe','true']
    log('Before 9473977d: an answered matching ask incorrectly creates a hold.')
    run([old,*args])
    oldstate=run([root/'bin/fm-tasks-axi.sh','show','answered-regression','--full']).stdout
    assert '  held: yes' in oldstate
    before=(home/'data/backlog.md').read_bytes()
    args[1]='current-regression'
    log('At 9473977d: the same answered ask refuses before creating a task.')
    p=run([root/'bin/fm-captain-hold.sh',*args],expected=1)
    assert 'He decided it on review:lab-signin#signin.' in p.stderr and 'owner: dale' in p.stderr
    assert (home/'data/backlog.md').read_bytes()==before
    for title,question,prefix in [('Local work','Choose a local branch','Not one of his kinds'),('Account sign-in','Complete your sign-in','Not answerable in one read')]:
        p=run([sys.executable,env['FM_DALE_ASKS_RULE'],'ask','--title',title,'--question',question,'--recommend',question,'--text',question,'--if-no',question],expected=3)
        assert prefix in p.stdout
    log('Verified actual exit-3 category/form outcomes match the live fail-open hold cases.')
