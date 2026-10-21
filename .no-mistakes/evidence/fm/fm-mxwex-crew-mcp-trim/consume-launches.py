from pathlib import Path
import subprocess,os,json,shlex,time
base=Path('.mcp-validation').absolute()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5FBH34GXXQDAYTMR1QJTR2R')
env=dict(os.environ,HOME=str(base/'user'),CLAUDE_CONFIG_DIR=str(base/'claude-config'),FM_HOME=str(base/'lab'),TMPDIR=str(base/'tmp'))
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:
    env.pop(key,None)
results=[]
for task in ['trim-default','trim-off','trim-scout','trim-secondmate']:
    launch=(evidence/f'{task}-generated-launch.sh').read_text()
    argv=shlex.split(launch[launch.index('claude '):])
    flags=[]
    if '--strict-mcp-config' in argv: flags+=['--strict-mcp-config']
    if '--mcp-config' in argv: flags+=['--mcp-config',argv[argv.index('--mcp-config')+1]]
    meta=dict(line.split('=',1) for line in (base/f'lab/state/{task}.meta').read_text().splitlines())
    probe=base/'probe.log'
    probe.write_text('')
    command=['claude',*flags,'--debug-file',str(base/f'{task}-consumer-debug.log'),'-p','Reply LAB_READY without tools.']
    run=subprocess.run(command,env=env,cwd=meta['worktree'],text=True,capture_output=True,timeout=40)
    log=probe.read_text()
    (evidence/f'{task}-mcp-lifecycle.log').write_text(log)
    (evidence/f'{task}-consumer-output.log').write_text(run.stdout+run.stderr)
    trimmed=task in ['trim-default','trim-scout']
    assert ('initialize\n' in log)==(not trimmed),(task,log)
    assert ('tools/list\n' in log)==(not trimmed),(task,log)
    results.append({'task':task,'consumer':'Claude Code native session startup','mcp_flags_from_live_launch':flags,'probe_started':bool(log),'initialize': 'initialize\n' in log,'tools_list':'tools/list\n' in log,'model_request':'not exercised: isolated config deliberately has no credentials','cli_exit':run.returncode})
(evidence/'mcp-consumer-observations.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
