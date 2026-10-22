import json, os, shutil, subprocess, time
from pathlib import Path
root=Path.cwd()
b=Path(__file__).parent
lab=b/'validation-lab'
for d in ('bin','shim','home/state','home/data','home/config','home/projects'):
    (lab/d).mkdir(parents=True,exist_ok=True)
for helper in ('fm-home-summary-refresh.sh','fm-timeout-lib.sh','fm-wake-lib.sh','fm-path-lib.sh'):
    (lab/'bin'/helper).symlink_to(root/'bin'/helper)
(lab/'bin/fm-fleet-snapshot.sh').write_text('#!/bin/sh\nexec cat "$FM_TEST_VALIDATION_DOCUMENT"\n')
(lab/'bin/fm-fleet-snapshot.sh').chmod(0o755)
(lab/'shim/jq').write_text('''#!/bin/sh
for arg in "$@"; do
  case "$arg" in */.home-summary.json.*)
    printf '%s\\n' "$$" > "$FM_TEST_VALIDATION_MARKER"
    sleep 30;;
  esac
done
exec "$FM_TEST_REAL_JQ" "$@"
''')
(lab/'shim/jq').chmod(0o755)
(lab/'trace-init.sh').write_text("PS4='+${EPOCHREALTIME} ${BASHPID} '\nset -x\n")
document=next(iter(json.loads((b/'published-summary-observed.json').read_text()).values()))
document['home']=str(lab/'home')
(lab/'summary.json').write_text(json.dumps(document))
env=dict(os.environ,HOME=str(b/'home'),TMPDIR=str(b/'tmp'),PATH=str(lab/'shim')+os.pathsep+os.environ['PATH'],
         FM_ROOT_OVERRIDE=str(root),FM_HOME=str(lab/'home'),FM_HOME_SUMMARY_TIMEOUT='1',
         FM_TEST_REAL_JQ=shutil.which('jq'),FM_TEST_VALIDATION_DOCUMENT=str(lab/'summary.json'),
         FM_TEST_VALIDATION_MARKER=str(lab/'validation-started'),BASH_ENV=str(lab/'trace-init.sh'))
for key in ('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_HOME_SUMMARY_IF_IDLE','FM_TIMEOUT_MECHANISM_OVERRIDE'):
    env.pop(key,None)
results=[]
for mechanism in ('native','bash'):
    if mechanism=='bash': env['FM_TIMEOUT_MECHANISM_OVERRIDE']='bash'
    env['FM_TEST_VALIDATION_MARKER']=str(lab/('marker-'+mechanism))
    started=time.monotonic(); events=[]
    with (b/('validation-'+mechanism+'.out')).open('w') as out,(b/('validation-'+mechanism+'.trace')).open('w') as err:
        p=subprocess.Popen([str(lab/'bin/fm-home-summary-refresh.sh'),'--best-effort'],env=env,stdout=out,stderr=err)
        while p.poll() is None:
            if Path(env['FM_TEST_VALIDATION_MARKER']).exists() and not events:
                events.append({'validation_seen_seconds':time.monotonic()-started})
            if time.monotonic()-started>20:
                p.terminate(); events.append({'exceeded_diagnostic_bound':True}); break
            time.sleep(.05)
        p.wait(timeout=10)
    results.append({'mechanism':mechanism,'elapsed':time.monotonic()-started,'returncode':p.returncode,'events':events})
    (b/'validation-timings.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
