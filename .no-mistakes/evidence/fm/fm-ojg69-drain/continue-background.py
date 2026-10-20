import importlib.util
import json
from pathlib import Path
import traceback
EVID=Path('/Users/dalecarman/.no-mistakes/evidence/01M5BV5GQB0KD20X4J2BKKMYVX')
spec=importlib.util.spec_from_file_location('live_cleanup',EVID/'live-cleanup.py')
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
setup=json.loads((EVID/'live-results-rerun.json').read_text())
lab=Path(setup['work'])/'background'
assert lab.is_relative_to(Path.cwd())
result={'name':'background cleanup and recovery','live':True,'evidence':str(EVID/'background-continuation.log')}
started=False
with (EVID/'background-continuation.log').open('w') as log:
    m.LOG=log
    try:
        m.say('Continuing the same real lab after the earlier 90s observation deadline. The background sweep itself has no expiry deadline.')
        for task in ('old-slow1','old-large1','old-stage1'):
            assert m.load(lab,task).get('expired')
            assert not (lab/'data'/task/'.cleanup-hold').exists()
            m.snapshot(lab,task,f'background-final-{task}')
        directory=lab/'data/task-a1'
        assert (directory/'.cleanup-hold/clone').is_dir()
        assert not m.load(lab,'task-a1').get('expired')
        m.snapshot(lab,'task-a1','background-final-fresh-a')
        socket_dir=m.run([m.ROOT/'bin/fm-lab-home.sh','tmux-dir',lab],lab).stdout.strip()
        m.run(['tmux','-L','fm-lab','new-session','-d','-s','fm-lab','-x','120','-y','40','-c',m.ROOT,'/bin/sh'],lab,extra={'TMUX_TMPDIR':socket_dir})
        started=True
        socket=m.run(['tmux','-L','fm-lab','display-message','-p','-t','fm-lab','#{socket_path},#{pid},0'],lab,extra={'TMUX_TMPDIR':socket_dir}).stdout.strip()
        m.SOCKETS[str(lab)]=(socket_dir,socket)
        m.begin_task(lab,'task-b1')
        m.teardown(lab,'task-b1')
        m.wait_for(lambda:m.load(lab,'task-a1').get('expired'),'subsequent completion did not expire A',300)
        assert not (directory/'.cleanup-hold').exists()
        assert not (directory/'clone').exists()
        for path in ('brief.md','review.md','findings.txt','status','proof.png'):
            assert (directory/path).is_file(),f'lost retained evidence {path}'
        assert (lab/'data/task-b1/.cleanup-hold/scratch.bin').is_file()
        m.snapshot(lab,'task-a1','background-final-expired-a')
        m.snapshot(lab,'task-b1','background-final-fresh-b')
        m.run(['du','-sk',lab/'data'],lab)
        result['result']='pass'
    except Exception as error:
        m.say(traceback.format_exc())
        result.update(result='fail',error=str(error))
    finally:
        if started:
            m.run(['tmux','-L','fm-lab','kill-server'],lab,expected=None)
            m.run([m.ROOT/'bin/fm-lab-home.sh','teardown',lab],lab,expected=None)
(EVID/'background-final-results.json').write_text(json.dumps({'work':str(lab.parent),'aux_work':str(m.WORK),'results':[result]},indent=2)+'\n')
print(json.dumps(result),flush=True)
