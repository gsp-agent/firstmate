#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import unicodedata

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
BASE = ROOT / '.validation-task-data/linux-runtime'
ENV = dict(os.environ, PATH=str(ROOT / '.validation-task-data/dcg-linux') + ':' + os.environ['PATH'])
ENV.update(XDG_DATA_HOME=str(BASE / 'xdg-data'), XDG_CONFIG_HOME=str(BASE / 'xdg-config'),
           XDG_CACHE_HOME=str(BASE / 'xdg-cache'), TMPDIR=str(BASE),
           FM_HOME=str(BASE), DCG_LOG_PATH=str(BASE / 'dcg.log'))
for key in list(ENV):
    if key.startswith('FM_') and key.endswith('_OVERRIDE'):
        del ENV[key]

def run(args, env=ENV):
    print('$ ' + shlex.join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str, args)), env=env, capture_output=True, text=True, timeout=60)
    print(result.stdout + result.stderr, flush=True)
    assert result.returncode == 0, result.returncode
    return result

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data) if isinstance(data, str) else path.write_bytes(data)

def home(name):
    lab = BASE / name
    (lab / 'state').mkdir(parents=True)
    (lab / 'data').mkdir()
    write(lab / '.tasks.toml', 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    return lab

def cleanup(action, lab, task_id, before=False):
    env = dict(ENV, FM_HOME=str(lab))
    if before:
        env['TASK_DATA_HELPER'] = str(ROOT / '.validation-task-data/before-bin/fm-task-data.py')
    args = ['bash', EVIDENCE / 'task-data-locked.sh', ROOT, action, lab, task_id]
    if action == 'stage':
        args += [lab, '']
    return run(args, env)

run(['dcg', '--version'])
probe = BASE / 'café'
write(probe, b'normalization probe')
nfd_probe = BASE / unicodedata.normalize('NFD', 'café')
assert not nfd_probe.exists(), 'Linux test filesystem must distinguish normalization forms'
print('Filesystem confirmed normalization-sensitive and case-sensitive.', flush=True)

lab = home('before')
root = lab / 'data/proof-owner'
write(root / 'café/frame.bin', b'NFC evidence\x00\xff')
write(root / 'report.md', '[NFC evidence](café/)\n')
write(root / 'scratch/blob.bin', b'unrelated scratch')
cleanup('stage', lab, 'proof-owner', before=True)
assert not (root / 'café/frame.bin').exists()
assert (root / '.cleanup-hold/café/frame.bin').read_bytes() == b'NFC evidence\x00\xff'
print('EXPECTED_BEFORE_FIX_FAILURE: cf0da8c3 staged an NFC directory that report.md links.', flush=True)
cleanup('expire', lab, 'proof-owner', before=True)
assert not (root / 'café/frame.bin').exists() and not (root / '.cleanup-hold').exists()
print('EXPECTED_BEFORE_FIX_DATA_LOSS: expiry deleted the linked NFC evidence.', flush=True)

lab = home('current')
root = lab / 'data/proof-owner'
nfc, nfd = 'café', unicodedata.normalize('NFD', 'café')
initial = {f'{nfc}/frame.bin': b'NFC original bytes\x00\xff',
           f'{nfd}/frame.bin': b'NFD original bytes\x00\xff',
           'proof(1).png': b'Markdown escape bytes\x00\xff',
           'nfc-backing.bin': b'NFC symlink target\x00\xff',
           'nfd-backing.bin': b'NFD symlink target\x00\xff'}
held = {f'later-{nfc}/frame.bin': b'held NFC bytes\x00\xff',
        f'later-{nfd}/frame.bin': b'held NFD bytes\x00\xff',
        'later(1).png': b'held Markdown escape\x00\xff',
        'later-backing.bin': b'held symlink target\x00\xff'}
for rel, data in (initial | held | {'scratch/blob.bin': b'unrelated scratch'}).items():
    write(root / rel, data)
(root / nfc / 'member.bin').symlink_to(root / 'nfc-backing.bin')
(root / nfd / 'member.bin').symlink_to(root / 'nfd-backing.bin')
(root / f'later-{nfc}/member.bin').symlink_to(root / 'later-backing.bin')
external = lab / 'outside/keep.bin'
write(external, b'external evidence\x00\xff')
(root / nfc / 'external.bin').symlink_to(external)
report = root / 'report.md'
write(report, f'[NFC]({nfc}/) [NFD]({nfd}/) ' + r'[image](proof\(1\).png)' + '\n')
cleanup('stage', lab, 'proof-owner')
for rel, data in initial.items():
    assert (root / rel).read_bytes() == data, rel
for rel, data in held.items():
    assert (root / '.cleanup-hold' / rel).read_bytes() == data, rel
report.write_text(report.read_text() + f'[new NFC](later-{nfc}/) [new NFD](later-{nfd}/) ' + r'[new image](later\(1\).png)' + '\n')
cleanup('expire', lab, 'proof-owner')
for rel, data in (initial | held).items():
    assert (root / rel).read_bytes() == data, rel
assert (root / nfc / 'member.bin').read_bytes() == initial['nfc-backing.bin']
assert (root / nfd / 'member.bin').read_bytes() == initial['nfd-backing.bin']
assert (root / f'later-{nfc}/member.bin').read_bytes() == held['later-backing.bin']
assert external.read_bytes() == b'external evidence\x00\xff'
assert not (root / '.cleanup-hold').exists() and not (root / 'scratch').exists()
print(json.dumps({'scenario': 'Normalization-sensitive Linux NFC/NFD and Markdown evidence survives staging and expiry',
                  'live': True, 'result': 'pass', 'before_fix_failure_reproduced': True,
                  'distinct_nfc_and_nfd_directories_preserved': True,
                  'new_held_references_restored': True, 'descendant_symlinks_valid': True,
                  'unrelated_scratch_reclaimed': True, 'external_target_untouched': True}, indent=2), flush=True)
print('LINUX_LIVE_SCENARIOS_COMPLETE', flush=True)
