import json, subprocess, time
from pathlib import Path
E=Path('/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN')
D=E/'round3-tmp'
O=E/'round3-runtime-evidence'
O.mkdir(exist_ok=True)
def snapshot():
    return subprocess.check_output(['sysctl','vm.swapusage'],text=True)+subprocess.check_output(['vm_stat'],text=True)
(E/'round3-memory-before.txt').write_text(snapshot())
roots=list(D.glob('fm-lint-default-caps.*/lint.roots.tsv'))
if len(roots)!=1: raise SystemExit('Expected one active default-cap test; got '+str(roots))
root=roots[0]
f=root.open()
start=time.monotonic()
latest=''
while time.monotonic()-start<360:
    for src in D.rglob('*.tsv'):
        if src.is_file():
            dest=O/src.relative_to(D)
            dest.parent.mkdir(parents=True,exist_ok=True)
            try: dest.write_bytes(src.read_bytes())
            except FileNotFoundError: pass
    f.seek(0)
    latest=f.read()
    (E/'round3-default-caps.roots.tsv').write_text(latest)
    if 'meta\tresult_exit\t' in latest or not root.exists(): break
    time.sleep(0.2)
(E/'round3-memory-after.txt').write_text(snapshot())
print(latest,flush=True)
print('Captured runtime evidence; observation_seconds='+str(round(time.monotonic()-start,3)),flush=True)
