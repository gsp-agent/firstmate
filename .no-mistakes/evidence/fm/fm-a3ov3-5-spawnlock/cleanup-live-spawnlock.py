#!/usr/bin/env python3
"""Retire only the marked lab homes created by live-spawnlock.py."""
import importlib.util
from pathlib import Path
import json
import shlex
import subprocess

path=Path(__file__).with_name('live-spawnlock.py')
spec=importlib.util.spec_from_file_location('lab',path)
lab=importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
lab.TMUX_ID='.nm-test-tmp/s,0,0'
assert lab.tmux('list-sessions',check=False).returncode != 0, 'private server still running'
meta_paths=sorted(lab.BASE.glob('*/state/nms-*.meta'))+sorted(lab.BASE.glob('*/mate/state/nms-*.meta'))
retired=[]
for meta in meta_paths:
    home=meta.parent.parent
    task=meta.stem
    assert (home/'.fm-lab-home').read_text().splitlines()[0]=='fm-lab-home v1'
    values=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
    assert str(values.get('worktree','')).startswith(str(lab.BASE/'pool'))
    args=[str(lab.ROOT/'bin/fm-teardown.sh'),task]
    guard=subprocess.run(['dcg'],input=json.dumps(dict(tool_name='Bash',tool_input=dict(command=shlex.join(args)))),text=True,capture_output=True,env=lab.ENV)
    if guard.stdout.strip():
        decision=json.loads(guard.stdout)
        assert decision.get('hookSpecificOutput',{}).get('permissionDecision')!='deny',guard.stdout
    assert guard.returncode==0,guard.stderr
    cp=lab.run(args,env=lab.home_env(home),check=False,timeout=150,name=f'cleanup-{task}')
    assert cp.returncode==0,cp.stdout
    assert not meta.exists()
    retired.append(dict(home=str(home.relative_to(lab.ROOT)),task=task))
assert lab.tmux('list-sessions',check=False).returncode != 0
(lab.EVIDENCE/'live-cleanup.json').write_text(json.dumps(dict(retired=retired,private_tmux_stopped=True),indent=2)+'\n')
print('Every launched lab task retired through fm-teardown; the private tmux server is stopped.',flush=True)
