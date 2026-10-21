from pathlib import Path
import subprocess,os,re,json,shlex
base=Path('.mcp-validation').absolute()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5FBH34GXXQDAYTMR1QJTR2R')
env=dict(os.environ,TMUX_TMPDIR=(base/'socket-dir').read_text().strip())
results=[]
for task in ['trim-default','trim-off','trim-scout','trim-secondmate']:
    text=subprocess.check_output(['tmux','-L','fm-lab','capture-pane','-J','-p','-t',f'primary:fm-{task}','-S','-200'],env=env,text=True)
    (evidence/f'{task}-terminal.txt').write_text(text)
    paths=re.findall(r"(/tmp/fm-[^'\s]+/launch\.[^'\s]+\.sh)",text)
    assert paths,(task,'No generated launch record in live terminal')
    launch=Path(paths[-1]).read_text()
    (evidence/f'{task}-generated-launch.sh').write_text(launch)
    argv=shlex.split(launch[launch.index('claude '):])
    trimmed=task in ['trim-default','trim-scout']
    assert ('--strict-mcp-config' in argv)==trimmed
    assert ('--mcp-config' in argv)==trimmed
    item={'task':task,'generated_launch':str(evidence/f'{task}-generated-launch.sh'),'strict':trimmed}
    if trimmed:
        file=Path(argv[argv.index('--mcp-config')+1])
        assert file.parent == base/'lab/state'
        assert json.loads(file.read_text())=={'mcpServers':{}}
        (evidence/f'{task}.mcp-crew.json').write_text(file.read_text())
        item.update(config_path=str(file),config=json.loads(file.read_text()))
    else:
        assert not (base/f'lab/state/{task}.mcp-crew.json').exists()
    results.append(item)
(evidence/'launch-observations.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
