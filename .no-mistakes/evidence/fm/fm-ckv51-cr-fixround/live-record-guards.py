import os, pathlib, shlex, subprocess
root = pathlib.Path.cwd()
evidence = pathlib.Path(__file__).parent
lab = root/'.agent-state/live-cr-validation-5/home'
state = lab/'state'
record = state/'changes-requested-sweep.seen'
lines = record.read_text().splitlines()
url, head, rounds, stamp, escalated = lines[1].split()
assert rounds == '1'
env = os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
    env.pop(key, None)
env['FM_HOME'] = str(lab)
env['FM_BACKLOG_ROW_TIMEOUT_SECS'] = '45'
log = (evidence/'live-record-guards.log').open('w', buffering=1)
def run(args, expected=0):
    args = [str(x) for x in args]
    log.write('$ ' + shlex.join(args) + chr(10))
    r = subprocess.run(args, env=env, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    log.write(r.stdout + 'exit=' + str(r.returncode) + chr(10))
    print(r.stdout, 'exit=', r.returncode, flush=True)
    assert r.returncode == expected, (args,r.returncode)
    return r
before = record.read_bytes()
base = [root/'bin/fm-pr-queue-sweep.sh','--cr-dispatch',state,url,head]
missing = [root/'bin/fm-control.sh','missing-task','relaunch','--note','Disposable duplicate guard validation.']
run(base + ['round1','--'] + missing)
assert record.read_bytes() == before
log.write('Duplicate round 1 skipped the real failing callback and preserved the record.' + chr(10))
run(base + ['round2','--'] + missing, expected=1)
assert record.read_bytes() == before
log.write('The real failed second-round launch did not consume round 2.' + chr(10))
run(base + ['round3','--'] + missing, expected=1)
assert record.read_bytes() == before
run([root/'bin/fm-pr-queue-sweep.sh','--cr-record',state,url,head,'escalated'],expected=1)
assert record.read_bytes() == before
log.write('Round 3 and premature escalation were refused with no state change.' + chr(10))
reason = url + ' has no new head after two fix rounds; requesting reviewer carmanchip23-dev. Synthetic hold fixture, not an automatic sweep result.'
run([root/'bin/fm-captain-hold.sh','hold','cr-review-hold','--title','Decide unchanged PR after two fix rounds','--repo','lab-project','--reason',reason])
r = run([root/'bin/fm-tasks-axi.sh','show','cr-review-hold'])
(evidence/'captain-hold.txt').write_text(r.stdout)
(evidence/'round-one-record.txt').write_bytes(record.read_bytes())
log.close()
