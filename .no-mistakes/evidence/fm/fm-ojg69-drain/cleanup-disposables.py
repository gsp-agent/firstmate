import json
import os
from pathlib import Path
import shlex
import subprocess
import time
ROOT=Path.cwd()
EVID=Path('/Users/dalecarman/.no-mistakes/evidence/01M5BV5GQB0KD20X4J2BKKMYVX')
metadata=json.loads((EVID/'verified-live-scenarios.json').read_text())
targets=[Path(path) for path in metadata['disposable_workdirs']]+[ROOT/'.agent-state']
records=[]
with (EVID/'disposable-cleanup.log').open('w') as log:
    for target in targets:
        assert target.parent==ROOT and (target.name.startswith('.phase-') or target.name=='.agent-state')
        assert not target.is_symlink()
        if not target.exists():continue
        files=[]
        directories=[]
        for current,dirs,names in os.walk(target,topdown=False,followlinks=False):
            base=Path(current)
            for name in names:
                files.append(base/name)
            for name in dirs:
                child=base/name
                if child.is_symlink():files.append(child)
                else:directories.append(child)
        # Inspect all temporary files before guarded removal, keeping evidence outside.
        size=sum(path.lstat().st_size for path in files)
        row={'target':str(target),'files':len(files),'directories':len(directories),'bytes':size}
        log.write(json.dumps(row)+'\n');log.flush()
        # Every runtime lock belongs to a now-finished disposable scenario.
        for path in files:
            if path.name=='pid' and path.parent.name.endswith('.lock'):
                text=path.read_text().strip()
                if text.isdigit():
                    status=subprocess.run(['ps','-p',text,'-o','command='],text=True,capture_output=True).stdout.strip()
                    assert not status, f'cannot remove active fixture lock {path}: {status}'
        for group in (files, sorted(directories,key=lambda path:len(path.parts),reverse=True)+[target]):
            command='rm' if group is files else 'rmdir'
            for offset in range(0,len(group),128):
                batch=group[offset:offset+128]
                args=[command,*(['-f'] if command=='rm' else []),'--',*[str(path) for path in batch]]
                hook={'tool_name':'Bash','tool_input':{'command':shlex.join(args)}}
                guard=subprocess.run(['dcg'],input=json.dumps(hook),capture_output=True,text=True,timeout=30,check=True)
                if guard.stdout.strip():
                    response=json.loads(guard.stdout)
                    assert response.get('hookSpecificOutput',{}).get('permissionDecision')=='allow', f'dcg refused cleanup: {guard.stdout}'
                subprocess.run(args,check=True)
        row['removed']=not target.exists()
        records.append(row)
        log.write('removed=true\n');log.flush()
(EVID/'disposable-cleanup.json').write_text(json.dumps(records,indent=2)+'\n')
print(json.dumps({'removed_roots':len(records),'files':sum(row['files'] for row in records)}),flush=True)
