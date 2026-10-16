import json
import os
from pathlib import Path
import shlex
import subprocess

root=Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M52RE89MCRBDJ3XPJ4P07HTS/.test-task-data-live')
assert root.is_dir() and not root.is_symlink() and root.resolve()==root
files=[]
directories=[]
for parent, dirs, names in os.walk(root,followlinks=False):
    for name in dirs+names:
        path=Path(parent)/name
        if path.is_symlink() or path.is_file():
            files.append(path)
        elif path.is_dir():
            directories.append(path)
        else:
            raise RuntimeError('Unexpected disposable entry: '+str(path))

def guarded(args):
    command=shlex.join([str(arg) for arg in args])
    payload=json.dumps(dict(tool_name='Bash',tool_input=dict(command=command)))
    result=subprocess.run(['dcg'],input=payload,text=True,capture_output=True,check=True,timeout=30)
    if result.stdout.strip():
        output=json.loads(result.stdout)
        assert output.get('hookSpecificOutput',{}).get('permissionDecision')=='allow',result.stdout
    subprocess.run([str(arg) for arg in args],check=True,timeout=30)

for offset in range(0,len(files),64):
    guarded(['rm','-f','--',*files[offset:offset+64]])
directories=sorted(directories,key=lambda path:len(path.parts),reverse=True)+[root]
for offset in range(0,len(directories),64):
    guarded(['rmdir','--',*directories[offset:offset+64]])
assert not root.exists()
print('Removed only inspected workspace-local disposable files, symlinks and empty directories through dcg.')
