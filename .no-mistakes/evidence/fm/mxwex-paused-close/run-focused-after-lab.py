import pathlib,time,subprocess,os
p=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5G3MH318E8QVNSE345AGS9W')
deadline=time.monotonic()+1500
while not (p/'live-rotation-results.json').exists():
 if time.monotonic()>deadline:raise SystemExit('Rotation did not complete before deadline; focused rerun not started.')
 time.sleep(1)
e=os.environ.copy();e['FM_INACTIVE_RECONCILE_BUDGET_SECS']='30'
with (p/'focused-reconcile.log').open('w') as log:
 r=subprocess.run(['bash',str(p/'focused-reconcile.sh')],env=e,stdout=log,stderr=subprocess.STDOUT)
print('Focused regression exit:',r.returncode,flush=True)
raise SystemExit(r.returncode)
