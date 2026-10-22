import json, os, subprocess, time
from pathlib import Path
R=Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5HEFVZ2ZGARFBBBDTE72WAN')
E=Path('/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN')
F=E/'version-inputs-round2'
F.mkdir(exist_ok=True)
sc=F/'shellcheck'
sc.write_text('''#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\\n' "$$" > "$VERSION_PID"
  printf 'ShellCheck - controlled adversarial version workload\\nversion: 0.11.0\\n'
  case "$VERSION_MODE" in
    memory) exec perl -e 'my $s = "x" x (128 * 1048576); sleep 5' ;;
    time) exec sleep 5 ;;
  esac
fi
printf 'analysis-started\\n' >> "$ANALYSIS_LOG"
''')
sc.chmod(0o755)
fixture=F/'clean.sh'
fixture.write_text('#!/usr/bin/env bash\nexit 0\n')
results=[]
with (E/'version-cap-product-round2.txt').open('w') as log:
    log.write('Real fm-lint.sh with controlled external ShellCheck version workloads; synthetic dependency tests, not real ShellCheck workloads.\n')
    for mode,seconds,cap,expected in [('memory','10','65536',123),('time','1','262144',124)]:
        pid=F/(mode+'.pid')
        analysis=F/(mode+'.analysis')
        env=os.environ.copy()
        env.update(PATH=str(F)+os.pathsep+os.environ['PATH'],VERSION_MODE=mode,VERSION_PID=str(pid),ANALYSIS_LOG=str(analysis),TMPDIR=str(E/'test-round2-tmp'),FM_LINT_ROOT_SECONDS=seconds,FM_LINT_ROOT_GRACE='1',FM_LINT_ROOT_MEMORY_KIB=cap)
        command=[str(R/'bin/fm-lint.sh'),str(fixture)]
        start=time.monotonic()
        process=subprocess.Popen(command,cwd=R,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        out,_=process.communicate(timeout=35)
        alive=False
        if pid.exists():
            try: os.kill(int(pid.read_text().strip()),0); alive=True
            except ProcessLookupError: pass
        result=dict(mode=mode,exit=process.returncode,expected=expected,elapsed_seconds=round(time.monotonic()-start,3),analysis_started=analysis.exists(),version_process_alive=alive)
        result['passed']=process.returncode==expected and not alive and not analysis.exists()
        results.append(result)
        log.write('\n$ FM_LINT_ROOT_SECONDS='+seconds+' FM_LINT_ROOT_MEMORY_KIB='+cap+' bin/fm-lint.sh clean.sh\n'+out+json.dumps(result)+'\n')
        log.flush()
(E/'version-cap-results-round2.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
