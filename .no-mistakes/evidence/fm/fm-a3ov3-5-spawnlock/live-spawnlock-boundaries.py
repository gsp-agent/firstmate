#!/usr/bin/env python3
"""Opt-out, failed-reading and zero-cap guard checks through real fm-spawn."""
import importlib.util
import json
from pathlib import Path
import shlex
import sys

path=Path(__file__).with_name('live-spawnlock.py')
spec=importlib.util.spec_from_file_location('lab',path)
lab=importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
lab.tmux('-f','/dev/null','new-session','-d','-x','120','-y','40','-s',lab.SESSION,'/bin/bash','--noprofile','--norc')
lab.TMUX_ID=lab.tmux('display-message','-p','-t',lab.SESSION,'#{socket_path},#{pid},0').stdout.strip()
home=lab.BASE/'retake'
project=home/'projects/project'
control=home/'reading'

def check(task, name, expected, old_calls):
    lab.add_task(home,task)
    before=lab.snapshot(project)
    cp=lab.spawn(home,project,task,name=name)
    assert cp.returncode==75,cp.stdout
    assert expected in cp.stdout,cp.stdout
    lab.no_mutation(home,project,task,before)
    assert not lab.overshares(home)
    assert (control/'calls').read_text().count('reading')==old_calls

def opt_out():
    calls=(control/'calls').read_text().count('reading')
    (home/'config/project-capacity-headroom').write_text('\n')
    check('nms-off-b','headroom-disabled','already hold a place',calls)
    lab.log('Blank opt-in preserves capacity deferral; no additional reading was invoked.')

def failed_reading():
    calls=(control/'calls').read_text().count('reading')
    (control/'second-immediate').touch()
    (home/'config/project-capacity-headroom').write_text(shlex.join([sys.executable,str(path),'reading',str(control),'1'])+'\n')
    check('nms-denied-b','headroom-denied','headroom reading reported no room',calls+1)
    lab.log('A reading that prints a room line but exits 1 defers without consuming the window.')

def zero_cap():
    calls=(control/'calls').read_text().count('reading')
    (home/'config/project-capacity').write_text('project 0\n')
    (home/'config/project-capacity-headroom').write_text(shlex.join([sys.executable,str(path),'reading',str(control),'0'])+'\n')
    check('nms-zero-b','headroom-zero-cap','admits 0 worker(s)',calls)
    lab.log('Zero capacity is not raised, and its configured positive reading is not invoked.')

try:
    lab.scenario('Headroom opt-out preserves the existing capacity deferral',opt_out)
    lab.scenario('A failed reading defers without publishing or consuming a window',failed_reading)
    lab.scenario('Zero capacity admits no extra start and never invokes the reading',zero_cap)
finally:
    lab.tmux('kill-server',check=False)
    (lab.EVIDENCE/'live-spawnlock-boundary-results.json').write_text(json.dumps(lab.RESULTS,indent=2)+'\n')
raise SystemExit(0 if all(r['result']=='pass' for r in lab.RESULTS) else 1)
