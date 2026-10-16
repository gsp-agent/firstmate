#!/usr/bin/env python3
"""Exercise persisted registration recovery through the real running watcher."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode=True
out=Path('/Users/dalecarman/.no-mistakes/evidence/01M52M4YB15FC8H82PA7T22SFS')
spec=importlib.util.spec_from_file_location('queue_live',out/'live-queue-validation.py')
live=importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
old=live.LAB/'shipped-old-poll.sh'
old.write_bytes(subprocess.check_output(['git','show','38fa6f7bde25e4cd64235581ceb16ca92a8453bc:bin/fm-pr-poll.sh']))
old.chmod(0o600)
try:
    for variant in ('shipped-template-recovery','tampered-template-refused','unshipped-hash-refused'):
        data=live.Dataset(variant,[[]],{1:live.node(1,'recovery-drop')})
        ctx=live.setup(data,[])
        state=ctx[0]/'state'
        url='https://github.com/o/r/pull/1'
        meta=state/'task-a.meta'
        meta.write_text('pr='+url+'\n');meta.chmod(0o600)
        template=live.ROOT/'bin/fm-pr-poll.sh' if variant=='unshipped-hash-refused' else old
        live.call(['bash',out/'seed-watch.sh',live.ROOT,ctx[0],'task-a',url,template],ctx[1])
        registration=state/'task-a.pr-poll-registration'
        record=registration.read_text().splitlines()
        # Serialized registration contract: recorded device:inode bindings.
        for index in (9,10):
            device,inode=record[index].split(':')
            record[index]=f'{int(device)+1}:{inode}'
        if variant=='unshipped-hash-refused':
            record[8]=hashlib.sha256(b'unshipped-template').hexdigest()
        registration.write_text('\n'.join(record)+'\n')
        registration.chmod(0o600)
        if variant=='tampered-template-refused':
            check=state/'task-a.check.sh'
            with check.open('a') as stream:
                stream.write('\nprintf "tampered execution\\n" > "${FM_HOME:?}/state/tampered-executed"\n')
        before=hashlib.sha256(registration.read_bytes()).hexdigest()
        drain,snapshot=live.cycle(data,ctx)
        polls=[r for r in live.REQUESTS if r['scenario']==variant and r['kind']=='poll']
        if variant=='shipped-template-recovery':
            live.once(drain,'o/r',1,'failed_checks')
            assert len(polls)==1
            assert before!=hashlib.sha256(registration.read_bytes()).hexdigest()
            title='A shipped historical poll with stale recorded device numbers is re-registered and reports the queue drop'
        else:
            assert 'rejected unauthenticated state checks' in drain
            assert not polls and not (state/'tampered-executed').exists()
            assert before==hashlib.sha256(registration.read_bytes()).hexdigest()
            title='A '+('tampered historical check' if variant=='tampered-template-refused' else 'registration carrying an unshipped template hash')+' remains refused after a recorded device-number shift'
        live.finish(data,title)
finally:
    live.SERVER.shutdown();live.SERVER.server_close()
    (out/'registration-live-scenarios.json').write_text(json.dumps(live.RESULTS,indent=2)+'\n')
