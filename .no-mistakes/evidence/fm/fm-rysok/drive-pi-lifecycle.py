import os, pathlib, subprocess, json, time, signal, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5F5QFQD3801ZHQ2XDKPQEQ9')
scratch=root/'.test-rysok-live'/'lifecycle'
scratch.mkdir(parents=True,exist_ok=True)
source=(root/'tests/fm-pi-branch-extension.test.sh').read_text()
# Load the suite's executable definitions unchanged, leaving its invocation list
# to the normal complete-suite run. No assertion examines implementation text.
prefix=source.split('\ntest_outcomes_tool_call_headers_follow_the_loaded_pi_version\n')[0]+'\n'
original=subprocess.check_output(['git','show','fe60494c^:tests/fm-pi-branch-extension.test.sh'],text=True)
oldprefix=original.split('\ntest_outcomes_tool_call_headers_follow_the_loaded_pi_version\n')[0]+'\n'
js=r'''
import {spawn} from 'node:child_process';
import {mkdirSync,writeFileSync,existsSync} from 'node:fs';
const base=process.env.PROBE_HOME;
mkdirSync(`${base}/state`,{recursive:true});
mkdirSync(`${base}/config`,{recursive:true});
for(const lock of ['.wake-queue.lock','.branch-outcomes.lock']) {
  mkdirSync(`${base}/state/${lock}`);
  writeFileSync(`${base}/state/${lock}/pid`,`${process.env.CONTROLLER_PID}\n`);
}
const commands=[['fm-wake-grant.sh','publish','1','1'],['fm-wake-grant.sh','release','1'],['fm-branch-outcome.sh','mark-read','--through','4']];
const children=commands.map(args => spawn('bash',[`${process.env.PROBE_ROOT}/bin/${args[0]}`,...args.slice(1)],{env:{...process.env,FM_HOME:base},stdio:'ignore'}));
writeFileSync(process.env.PROBE_READY,JSON.stringify({driver:process.pid,home:base,children:children.map((p,i)=>({pid:p.pid,command:commands[i]}))}));
await new Promise(resolve=>{const t=setInterval(()=>{if(existsSync(process.env.PROBE_RELEASE)){clearInterval(t);resolve();}},20);});
if(process.env.PROBE_EXIT==='throw') throw new Error('intentional lifecycle assertion failure');
process.exit(Number(process.env.PROBE_EXIT||0));
'''
jsfile=scratch/'child-driver.mjs'
jsfile.write_text(js)
results=[]
def table():
    rows={}
    for line in subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,stat=,comm='],text=True).splitlines():
        p=line.strip().split(None,4)
        if len(p)==5:
            rows[int(p[0])]=dict(pid=int(p[0]),ppid=int(p[1]),pgid=int(p[2]),stat=p[3],executable=p[4])
    return rows

def await_condition(fn,seconds=15):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        result=fn()
        if result:return result
        time.sleep(.025)
    raise TimeoutError('condition not observed')

def run(name,mode='normal',sig=None,exit_mode='0',before=False):
    case=scratch/name
    case.mkdir()
    env=os.environ.copy()
    for key in list(env):
        if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(key)
    env.update(TMPDIR=str(case),CONTROLLER_PID=str(os.getpid()),PROBE_HOME=str(case/'blocked-home'),PROBE_ROOT=str(root),PROBE_READY=str(case/'ready.json'),PROBE_RELEASE=str(case/'release'),PROBE_EXIT=exit_mode,PROBE_JS=str(jsfile),FM_HOME=str(case/'unused-home'))
    driver=root/'tests'/('.rysok-live-'+name+'.sh')
    body='test_secondary_session_stays_inert\n' if mode=='holder' else 'node "$PROBE_JS"\nstatus=$?\nexit "$status"\n'
    driver.write_text((oldprefix if before else prefix)+body)
    groups=set()
    tracked=[]
    rec=dict(name=name,before_fix=before,signal=sig,signal_target='suite PID' if mode=='holder' else ('suite process group' if sig else None))
    start=time.monotonic()
    try:
        with (evidence/(name+'.log')).open('w') as out:
            proc=subprocess.Popen(['bash',str(driver)],cwd=root,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
            groups.add(proc.pid)
            rec['suite_pid']=proc.pid
            if mode=='holder':
                def find_holder():
                    rows=table()
                    return next((p for p in rows.values() if p['ppid']==proc.pid and p['executable']=='sleep'),None)
                holder=await_condition(find_holder)
                tracked=[holder['pid']]
                rec['active_holder']=holder
                os.kill(proc.pid,getattr(signal,'SIG'+sig))
            else:
                ready=await_condition(lambda: json.loads((case/'ready.json').read_text()) if (case/'ready.json').exists() else None)
                tracked=[ready['driver']]+[p['pid'] for p in ready['children']]
                time.sleep(.7)
                rows=table()
                rec['active_children']=[dict(command=c['command'],**rows[c['pid']]) for c in ready['children'] if c['pid'] in rows]
                if len(rec['active_children'])!=3:raise RuntimeError('real lock-wait children did not all remain active')
                groups.update(rows[p]['pgid'] for p in tracked if p in rows)
                # Reproduce the missing-home lock loop from the incident.
                shutil.rmtree(case/'blocked-home')
                time.sleep(.2)
                rec['children_after_home_removal']=[p for p in tracked[1:] if p in table()]
                if sig:
                    os.killpg(proc.pid,getattr(signal,'SIG'+sig))
                else:(case/'release').touch()
            try:rec['exit_code']=proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                rec['exit_timeout']=True
                raise
            time.sleep(.3)
            rows=table()
            rec['survivors']=[p for p in rows.values() if p['pgid'] in groups and 'Z' not in p['stat']]
            rec['fixture_registry_remaining']=[p.name for p in case.glob('.fm-test-*')]
            if before:
                rec['result']='reproduced' if len([p for p in rec['survivors'] if p['pid'] in tracked[1:]])==3 else 'not-reproduced'
            else:
                expected=(128+getattr(signal,'SIG'+sig)) if sig else (1 if exit_mode=='throw' else int(exit_mode))
                rec['expected_exit_code']=expected
                rec['result']='pass' if not rec['survivors'] and rec['exit_code']==expected and not rec['fixture_registry_remaining'] else 'fail'
    except Exception as exc:
        rec.update(result='error',error=repr(exc))
    finally:
        for group in groups:
            try:os.killpg(group,signal.SIGKILL)
            except ProcessLookupError:pass
        if 'proc' in locals():
            try:proc.wait(timeout=3)
            except subprocess.TimeoutExpired:pass
        driver.unlink(missing_ok=True)
        rec['elapsed_seconds']=round(time.monotonic()-start,2)
        results.append(rec)
        (evidence/'pi-lifecycle-results.json').write_text(json.dumps(results,indent=2)+'\n')
        print(json.dumps(rec),flush=True)
        shutil.rmtree(case)
run('before-fix-normal-exit',before=True)
run('normal-driver-exit')
run('nonzero-driver-exit',exit_mode='23')
run('failed-node-assertion',exit_mode='throw')
for sig in ('TERM','INT','HUP','QUIT'):
    run('active-children-'+sig.lower(),sig=sig)
for sig in ('TERM','INT','HUP','QUIT'):
    run('foreign-holder-'+sig.lower(),mode='holder',sig=sig)
jsfile.unlink()
scratch.rmdir()
