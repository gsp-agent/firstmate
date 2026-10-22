import json, os, signal, subprocess, time
from pathlib import Path
root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ')
home=root/'.test-phase/publication-lab'
subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True)
(home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
env=dict(os.environ,HOME=str(root/'.test-phase/home'),TMPDIR=str(root/'.test-phase/tmp'),FM_HOME=str(home),FM_HOME_SUMMARY_TIMEOUT='60')
for key in ('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_ROOT_OVERRIDE','FM_HOME_SUMMARY_IF_IDLE'):
    env.pop(key,None)
holder_script=root/'.test-phase/lock-holder.sh'
holder_script.write_text('. "$1/bin/fm-wake-lib.sh"\nfm_lock_acquire_wait "$FM_HOME/state/.home-summary-refresh.lock"\n: > "$FM_HOME/state/lock-held"\nexec sleep 120\n')
holder=subprocess.Popen(['bash',str(holder_script),str(root)],env=env)
writer=None
try:
    deadline=time.monotonic()+30
    while not (home/'state/lock-held').exists():
        assert holder.poll() is None, 'holder exited'
        assert time.monotonic()<deadline, 'holder did not acquire lock'
        time.sleep(.1)
    idle=subprocess.run(['bin/fm-home-summary-refresh.sh','--best-effort'],env=dict(env,FM_HOME_SUMMARY_IF_IDLE='1'),capture_output=True,text=True,timeout=30)
    assert idle.returncode==0 and not (home/'state/home-summary.json').exists(), idle.stderr
    print('Idle-only refresh while lock held: rc=0, no ledger, correctly skips busy publisher',flush=True)
    writer=subprocess.Popen(['bin/fm-home-summary-refresh.sh','--best-effort'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    time.sleep(1)
    assert writer.poll() is None and not (home/'state/home-summary.json').exists(), 'required refresh did not wait'
    print('Required refresh while lock held: running, ledger absent; waiting for publication lock',flush=True)
    holder.kill(); holder.wait()
    output,error=writer.communicate(timeout=65)
    ledger=home/'state/home-summary.json'
    assert writer.returncode==0 and ledger.exists(), error
    data=json.loads(ledger.read_text())
    assert data['schema']=='fm-secondmate-home-summary.v1' and data['home']==str(home) and data['valid']
    assert ledger.stat().st_mode & 0o777 == 0o600
    (evidence/'recovered-home-summary.json').write_text(ledger.read_text())
    print('Killed publication-lock holder: required refresh rc=0; real snapshot published valid mode-0600 ledger',flush=True)
    print(json.dumps({key:data[key] for key in ('schema','home','generated','valid','state','counts')},indent=2),flush=True)
finally:
    for process in (writer,holder):
        if process is not None:
            if process.poll() is None: process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
