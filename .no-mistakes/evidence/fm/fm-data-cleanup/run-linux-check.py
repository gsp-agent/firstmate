#!/usr/bin/env python3
from pathlib import Path
import shlex
import subprocess

root = Path.cwd()
evidence = Path(__file__).parent
runtime = root / '.validation-task-data/linux-runtime'
runtime.mkdir(exist_ok=True)
args = ['docker', '--config', str(root / '.validation-task-data/docker-config'), 'run', '--rm',
        '--name', 'fm-task-data-linux-01m51z', '--label', 'no-mistakes.run=01M51ZCPG0KSDTE3D3JEJ57XBH',
        '--read-only', '--network', 'none',
        '--mount', f'type=bind,source={root},target={root},readonly',
        '--mount', f'type=bind,source={evidence},target={evidence},readonly',
        '--tmpfs', f'{runtime}:rw,exec,size=64m', '--workdir', str(root),
        'python:3.13-slim', 'python3', str(evidence / 'task-data-linux.py')]
print('$ ' + shlex.join(args), flush=True)
result = subprocess.run(args, timeout=240)
raise SystemExit(result.returncode)
