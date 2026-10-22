import json, os, subprocess, sys
from pathlib import Path
def git(*args):
 return subprocess.check_output(['git', *args], text=True).strip()
report = {'name': git('config', 'user.name'), 'email': git('config', 'user.email'), 'hooks': git('config', 'core.hooksPath') if os.environ.get('GIT_CONFIG_COUNT') == '3' else '', 'cwd': os.getcwd(), 'primary': git('worktree', 'list', '--porcelain').splitlines()[0][9:]}
subprocess.run(['git', 'commit', '-q', '--allow-empty', '-m', 'live: first worker identity'], check=True)
report.update(author=git('log', '-1', '--format=%an <%ae>'), committer=git('log', '-1', '--format=%cn <%ce>'), commit=git('rev-parse', 'HEAD'))
Path(sys.argv[1]).write_text(json.dumps(report))
print(json.dumps(report), flush=True)
