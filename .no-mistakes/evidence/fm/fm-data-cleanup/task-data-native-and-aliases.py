#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('live', Path(__file__).with_name('task-data-live.py'))
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
run, write, home, cleanup = live.run, live.write, live.home, live.cleanup
ROOT, EVIDENCE = live.ROOT, live.EVIDENCE
live.RESULTS = json.loads((EVIDENCE / 'task-data-live-results.json').read_text())

# The installed consumer and the latest public source both lack a Beads
# adapter. Still exercise actual safe refusal with a real isolated br row.
lab, env, project = home('beads-references')
graph = lab / 'graph/.beads'
graph.mkdir(parents=True)
run(['br', 'init', '--db', graph / 'beads.db', '--prefix', 'proof'], env, lab / 'graph')
write(lab / '.tasks.toml', 'backend = "beads"\n[beads]\npath = "graph/.beads"\nprefix = "proof"\n')
created = run(['br', 'create', 'Real isolated evidence source', '--description',
               r'[image](proof\(1\).png) [directory](café/)', '--db', graph / 'beads.db', '--json'], env, lab / 'graph')
row = json.loads(created.stdout)
task_id = row['id']
unsupported = run(['tasks-axi', 'show', task_id, '--full'], env, lab, expected=None)
assert unsupported.returncode != 0 and 'Unsupported backend' in unsupported.stdout
root = lab / 'data' / task_id
files = {'proof(1).png': b'actual bead linked image\x00\xff',
         'café/frame.bin': b'actual bead linked directory\x00\xff',
         'scratch/blob.bin': b'actual bead scratch\x00\xff'}
for rel, data in files.items():
    write(root / rel, data)
refused = cleanup('stage', lab, env, task_id, lab / 'projects/example', expected=None)
assert refused.returncode != 0
for rel, data in files.items():
    assert (root / rel).read_bytes() == data
assert not (root / '.cleanup-hold').exists()
limitation = {
    'scenario': 'Successful cleanup from a native Beads-backed home',
    'result': 'untested',
    'installed_tasks_axi': '0.2.6',
    'attempts': ['Created a disposable real br database and owning issue',
                 'Tried the installed tasks-axi with an explicit isolated Beads config',
                 'Queried the published package and cloned its official default branch into the workspace'],
    'public_source_head': '9401ff899c0d1d8ae6b4fd8727b9025abda2032c',
    'reason': 'Installed and latest published/default-branch tasks-axi 0.2.6 support Markdown only. A real Beads-capable tasks-axi build on the disposable PATH is required; fabricating its adapter would not prove integration.',
    'observed_safety': 'Actual cleanup refused while the Beads source was unreadable and every original byte stayed in place.'
}
(EVIDENCE / 'task-data-native-beads-limitation.json').write_text(json.dumps(limitation, indent=2) + '\n')
print(json.dumps(limitation, indent=2), flush=True)

lab, env, project = home('named-references')
run(['tasks-axi', 'add', 'proof-owner', 'Owning task'], env, lab)
body = r'[named bead image](proof\(1\).png) [named directory](café/)'
run(['tasks-axi', 'add', 'proof-related', 'Named reference source', '--body', body], env, lab)
root = lab / 'data/proof-owner'
write(root / 'brief.md', 'Bead proof-related\n')
files = {'proof(1).png': b'named reference image\x00\xff',
         'café/frame.bin': b'named reference directory\x00\xff',
         'later(1).png': b'named held image\x00\xff'}
for rel, data in (files | {'scratch/blob.bin': b'unlinked scratch'}).items():
    write(root / rel, data)
cleanup('stage', lab, env, 'proof-owner', project)
assert (root / 'proof(1).png').read_bytes() == files['proof(1).png']
assert (root / 'café/frame.bin').read_bytes() == files['café/frame.bin']
assert (root / '.cleanup-hold/later(1).png').read_bytes() == files['later(1).png']
run(['tasks-axi', 'update', 'proof-related', '--body', body + r' [late capture](later\(1\).png)'], env, lab)
cleanup('expire', lab, env, 'proof-owner')
for rel, data in files.items():
    assert (root / rel).read_bytes() == data
assert not (root / '.cleanup-hold').exists() and not (root / 'scratch').exists()
live.record('Named Bead references resolve through the real task CLI and restore newly linked recovery',
            {'consumer': 'Installed tasks-axi Markdown adapter', 'all_linked_bytes_preserved': True,
             'held_link_restored': True, 'unrelated_scratch_reclaimed': True})

lab, env, project = home('filesystem-aliases')
root = lab / 'data/alias-owner'
write(root / 'Captures/frame.bin', b'case alias capture\x00\xff')
write(root / 'Captures/proof.bin', b'component ordered capture\x00\xff')
write(root / 'Captures/later.bin', b'held alias capture\x00\xff')
write(root / 'café/member.bin', b'normalization alias capture\x00\xff')
(root / 'Captures/subdir').mkdir()
(root / 'bridge').symlink_to('Captures/subdir')
(lab / 'ancestor').symlink_to(lab / 'data', target_is_directory=True)
case_alias = (root / 'captures/frame.bin').exists()
normalization_alias = (root / 'cafe\u0301/member.bin').exists()
assert case_alias and normalization_alias, 'This live check expects the current macOS alias capabilities'
(root / 'latest.png').symlink_to(lab / 'ancestor/ALIAS-OWNER/captures/frame.bin')
(root / 'ordered.png').symlink_to('bridge/../proof.bin')
(root / 'later.png').symlink_to(lab / 'ancestor/ALIAS-OWNER/captures/later.bin')
write(root / 'report.md', '[case alias](latest.png) [ordered path](ordered.png) [normalization alias](cafe\u0301/)\n')
write(root / 'discard.bin', b'unrelated alias scratch')
cleanup('stage', lab, env, 'alias-owner', project)
assert (root / 'latest.png').read_bytes() == b'case alias capture\x00\xff'
assert (root / 'ordered.png').read_bytes() == b'component ordered capture\x00\xff'
assert (root / 'café/member.bin').read_bytes() == b'normalization alias capture\x00\xff'
assert (root / '.cleanup-hold/Captures/later.bin').read_bytes() == b'held alias capture\x00\xff'
report = root / 'report.md'
report.write_text(report.read_text() + '[new alias](later.png)\n')
cleanup('expire', lab, env, 'alias-owner')
assert (root / 'latest.png').read_bytes() == b'case alias capture\x00\xff'
assert (root / 'ordered.png').read_bytes() == b'component ordered capture\x00\xff'
assert (root / 'later.png').read_bytes() == b'held alias capture\x00\xff'
assert (root / 'café/member.bin').read_bytes() == b'normalization alias capture\x00\xff'
assert not (root / '.cleanup-hold').exists() and not (root / 'discard.bin').exists()
live.record('Actual macOS case, normalization and ancestor aliases preserve linked targets through expiry',
            {'case_insensitive_filesystem': case_alias, 'normalization_insensitive_filesystem': normalization_alias,
             'symlink_dotdot_component_order_preserved': True, 'held_alias_restored': True,
             'unrelated_scratch_reclaimed': True})
print('NATIVE_CAPABILITY_AND_LIVE_ALIAS_SCENARIOS_COMPLETE', flush=True)
