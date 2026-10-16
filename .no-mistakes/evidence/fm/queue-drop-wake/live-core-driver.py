import os, pathlib, subprocess, time, re, json, signal
root=pathlib.Path.cwd(); evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M51C1DWAJZ71NFCZJ46PQH92')
base=os.environ.copy()
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
    base.pop(k,None)
base.update(PATH=str(root/'.test-phase/live-bin')+':'+base['PATH'],FM_LIVE_API_LOG=str(root/'.test-phase/live-extra-api.jsonl'),FM_CHECK_INTERVAL='0',FM_HEARTBEAT='999999',FM_POLL='0.1',FM_SIGNAL_GRACE='0')
def env(home): return dict(base,FM_HOME=str(home))
def call(args,home,label,ok=(0,),timeout=90):
    r=subprocess.run(args,env=env(home),capture_output=True,text=True,timeout=timeout)
    (evidence/(label+'.txt')).write_text('$ '+' '.join(args)+'\n'+r.stdout+'\nSTDERR:\n'+r.stderr+'\nexit='+str(r.returncode)+'\n')
    assert r.returncode in ok,(label,r.returncode,r.stdout,r.stderr)
    return r

def newlab(name):
    h=root/'.test-phase'/name
    call(['bin/fm-lab-home.sh','create',str(h)],h,name+'-create')
    return h

def meta(h,id,number):
    url=f'https://github.com/groovejones/groove-sight-platform/pull/{number}'
    p=h/'state'/(id+'.meta'); p.write_text('window=fm-lab-'+id+'\nkind=ship\nmode=no-mistakes\nworktree='+str(root)+'\npr='+url+'\n'); p.chmod(0o600)
    return url

def arm(h,id,number):
    url=meta(h,id,number)
    call(['bin/fm-pr-check.sh',id,url],h,h.name+'-arm-'+id)
    return url

def drain(h,label,ack=False):
    r=call(['bin/fm-wake-drain.sh'],h,label)
    if ack:
        m=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',r.stderr)
        assert m,(label,r.stderr)
        call(['bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2]],h,label+'-ack')
    return r.stdout

def watch(h,label):return call(['bin/fm-watch.sh'],h,label)

def quiet_cycle(h,label):
    path=h/'state'/'.last-check'; before=path.stat().st_mtime_ns if path.exists() else 0
    p=subprocess.Popen(['bin/fm-watch.sh'],env=env(h),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    deadline=time.monotonic()+60
    try:
        while time.monotonic()<deadline:
            if path.exists() and path.stat().st_mtime_ns>before: break
            if p.poll() is not None: break
            time.sleep(0.1)
        completed=path.exists() and path.stat().st_mtime_ns>before
        if p.poll() is None: p.terminate()
        out,err=p.communicate(timeout=10)
    finally:
        if p.poll() is None: p.kill();p.wait()
    (evidence/(label+'.txt')).write_text('Completed a new sweep: '+str(completed)+'\nSTDOUT:\n'+out+'\nSTDERR:\n'+err+'\nexit='+str(p.returncode)+' (TERM after completed quiet sweep)\n')
    assert completed,(label,out,err)
    assert 'dequeued ' not in out,(label,out)

h=root/'.test-phase/live-home'
call(['bin/fm-check-unregister.sh','contributions'],h,'live-unregister-contribution-observer')
quiet_cycle(h,'live-repeat-silent')
s=drain(h,'live-repeat-drain');assert 'dequeued ' not in s,s
print('Repeated real GitHub sweep: no duplicate removal notifications',flush=True)

h=newlab('earlier-check-home')
arm(h,'later-pr',4017)
c=h/'state'/'a-notice.check.sh';c.write_text('#!/usr/bin/env bash\nprintf \'local-notice-before-PR\\n\'\n');c.chmod(0o700)
call(['bin/fm-check-register.sh','a-notice'],h,'live-earlier-register')
r=watch(h,'live-earlier-check-and-drops')
assert 'local-notice-before-PR' in r.stdout and 'pull/4017 reason=failed_checks' in r.stdout,r.stdout
s=drain(h,'live-earlier-drain',True);assert 'local-notice-before-PR' in s and 'pull/4017 reason=failed_checks' in s
print('Earlier custom-check notification did not suppress later real queue drops',flush=True)

for recovery in (False,True):
    h=newlab('receipt-home' if recovery else 'merged-home')
    arm(h,'merged',4308)
    if recovery:call(['.test-phase/crash-receipt.sh'],h,'live-create-crash-receipt')
    r=watch(h,'live-startup-recovery' if recovery else 'live-only-watch-merged')
    if recovery:
        assert 'rearm-resurface' in r.stdout,r.stdout
        assert (h/'state'/'merged.pr-poll').exists() and (h/'state'/'merged.pr-poll-retirement').exists()
        assert not (h/'state'/'merged.check.sh').exists()
        (evidence/'live-deferred-retirement.json').write_text(json.dumps({'after_recovery':{'repository_sidecar_retained':True,'receipt_retained':True,'runnable_merged_poll_removed':True}},indent=2))
        drain(h,'live-recovered-merge-drain',True)
        watch(h,'live-after-recovery-first-sweep')
    s=drain(h,'live-recovery-final-drain' if recovery else 'live-merged-final-drain',True)
    assert 'pull/4017 reason=failed_checks' in s,s
    assert not (h/'state'/'merged.pr-poll').exists() and not (h/'state'/'merged.pr-poll-retirement').exists()
    print(('Crash receipt recovery' if recovery else 'Last armed PR merged')+': real repository drops delivered before final retirement',flush=True)

historical=root/'.test-phase/historical-poll.sh'
historical.write_bytes(subprocess.check_output(['git','show','20dcbf91520b1816663b81873ad67d0b93b3e4d6:bin/fm-pr-poll.sh']))
for kind in ('legacy-device','interrupted-device','tampered-device'):
    h=newlab(kind+'-home');url=meta(h,'legacy',4017)
    call(['.test-phase/seed-poll.sh',str(h/'state'),'legacy',url,str(historical)],h,'live-'+kind+'-seed')
    reg=h/'state'/'legacy.pr-poll-registration';lines=reg.read_text().splitlines()
    lines[9]='1:'+lines[9].split(':')[1];lines[10]='1:'+lines[10].split(':')[1]
    reg.write_text('\n'.join(lines)+'\n');reg.chmod(0o600)
    check=h/'state'/'legacy.check.sh';before=check.stat().st_ino
    if kind=='interrupted-device':check.write_bytes((root/'bin/fm-pr-poll.sh').read_bytes())
    if kind=='tampered-device':
        with check.open('a') as f:f.write('\nprintf tampered-ran > "$FM_HOME/tampered-ran"\n')
    (evidence/('live-'+kind+'-registration-before.txt')).write_text(reg.read_text())
    r=watch(h,'live-'+kind+'-watch')
    if kind=='tampered-device':
        assert 'rejected unauthenticated state checks' in r.stdout,r.stdout
        assert not (h/'tampered-ran').exists()
        assert reg.read_text()=='\n'.join(lines)+'\n'
        print('Tampered legacy poll rejected and never executed',flush=True)
    else:
        assert 'legacy.check.sh: dequeued '+url+' reason=failed_checks' in r.stdout,r.stdout
        after=reg.read_text().splitlines()
        assert after[9].split(':')[0]!='1' and after[10].split(':')[0]!='1'
        assert check.stat().st_ino==before
        (evidence/('live-'+kind+'-registration-after.txt')).write_text(reg.read_text())
        drain(h,'live-'+kind+'-drain',True)
        call(['bin/fm-pr-poll.sh','--validated','github',url,'github.com','groovejones/groove-sight-platform','4017'],h,'live-'+kind+'-continued-read')
        print(kind+': recovered device/hash registration in place and delivered real failed_checks removal',flush=True)
print('Live core scenarios complete',flush=True)
