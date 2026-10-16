import os,pathlib,subprocess,time,json
root=pathlib.Path.cwd();h=root/'.test-phase/interrupted-device-home'; ev=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M51C1DWAJZ71NFCZJ46PQH92')
log=root/'.test-phase/continued-api.jsonl'; env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM']:env.pop(k,None)
env.update(FM_HOME=str(h),FM_LIVE_API_LOG=str(log),PATH=str(root/'.test-phase/live-bin')+':'+env['PATH'],FM_CHECK_INTERVAL='0',FM_HEARTBEAT='999999')
f=h/'state/.last-check';before=f.stat().st_mtime_ns
p=subprocess.Popen(['bin/fm-watch.sh'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
    deadline=time.monotonic()+60
    while f.stat().st_mtime_ns<=before and p.poll() is None and time.monotonic()<deadline:time.sleep(.1)
    completed=f.stat().st_mtime_ns>before
    if p.poll() is None:p.terminate()
    out,err=p.communicate(timeout=10)
finally:
    if p.poll() is None:p.kill();p.wait()
reads=[json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []
matched=[x for x in reads if 'number=4017' in x['args']]
assert completed and matched and matched[-1]['rc']==0,(completed,matched,out,err)
assert 'rejected unauthenticated' not in out and 'dequeued ' not in out,out
(ev/'live-continued-poll-after-recovery.json').write_text(json.dumps({'completed_new_sweep':completed,'stdout':out,'stderr':err,'authenticated_poll_api_reads':matched,'registration':(h/'state/legacy.pr-poll-registration').read_text()},indent=2))
print('Recovered watch completed another authenticated real GitHub poll and suppressed its handled event')
