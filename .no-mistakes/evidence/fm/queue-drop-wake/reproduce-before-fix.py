#!/usr/bin/env python3
"""Run the same page race through the immediately preceding product code."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
out=Path('/Users/dalecarman/.no-mistakes/evidence/01M52M4YB15FC8H82PA7T22SFS')
spec=importlib.util.spec_from_file_location('queue_live',out/'live-queue-validation.py')
live=importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
original=Path.cwd()
baseline=original/'.queue-live-lab/before-fix-code'
(baseline/'bin').mkdir(parents=True)
changed={'fm-pr-lib.sh','fm-pr-queue-sweep.sh','fm-watch.sh'}
for path in (original/'bin').iterdir():
    if path.name not in changed:
        (baseline/'bin'/path.name).symlink_to(path)
for name in changed:
    data=subprocess.check_output(['git','show',f'74ca4598^:bin/{name}'],cwd=original)
    target=baseline/'bin'/name
    target.write_bytes(data)
    target.chmod(0o700)
live.ROOT=baseline
try:
    data=live.Dataset('before-fix-interpage',[[live.node(9,'queued-nine',queued=True,kind='AddedToMergeQueueEvent')],[live.node(10)]],{1:live.node(1,state='MERGED')})
    data.on_page_two=lambda: data.pages[0].__setitem__(0,live.node(9,'drop-nine',reason='manual removal'))
    ctx=live.setup(data,[('task-a','o/r',1)])
    first,state=live.cycle(data,ctx)
    assert '/pull/9' not in first
    assert state['watched_repositories']==[], 'Expected the pre-fix product to lose discovery'
    second,state=live.cycle(data,ctx)
    assert '/pull/9' not in second, 'Expected the pre-fix product to miss the removal'
    assert not any(r['kind']=='sweep' and r['cycle']==2 for r in live.REQUESTS), 'Pre-fix product unexpectedly rescanned the lost repository'
    (out/data.name/'api-requests.json').write_text(json.dumps(live.REQUESTS,indent=2)+'\n')
    print('Reproduced: preceding commit retired o/r after the queued sighting and never reported its removal on the next cycle.',flush=True)
finally:
    live.SERVER.shutdown();live.SERVER.server_close()
