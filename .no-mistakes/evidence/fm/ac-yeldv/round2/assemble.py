from pathlib import Path
import json, os, subprocess

root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round2')
f=json.loads((evidence/'fixture.json').read_text())
def data(name): return json.loads((evidence/name).read_text())
sample=data('ten-minute-summary.json')
observations=[json.loads(s) for s in (evidence/'ten-minute-orphan-samples.jsonl').read_text().splitlines()]
sample['first_sample_seconds']=observations[0]['at_seconds']
sample['last_sample_seconds']=observations[-1]['at_seconds']
reads=[json.loads(s) for s in (evidence/'ten-minute-crew-reads.jsonl').read_text().splitlines()]
sample['review_gate_reads']=sum('parked at review: 1 finding(s)' in r.get('stdout','') for r in reads)
sample['missed_gate_reads']=[r for r in reads if 'parked at review: 1 finding(s)' not in r.get('stdout','')]
events=[]
for file in evidence.glob('sample-crew-*.trace.jsonl'):
    events.extend(json.loads(s) for s in file.read_text().splitlines())
sample['implicit_lazy_fetches']=[v['argv'] for v in events if v.get('event')=='start' and 'fetch' in v.get('argv',[]) and '--stdin' in v.get('argv',[])]
sample['slow_origin_started']=(root/'.nm-live-yeldv-r2/sample-remote-pids').exists()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(data('env.json'))
p=subprocess.run(['git','-C',f['slot'],'cat-file','-e',f['head']+'^{commit}'],env=env|{'GIT_NO_LAZY_FETCH':'1'},text=True,capture_output=True)
sample['pipeline_head_remains_absent']=p.returncode!=0
(evidence/'ten-minute-summary.json').write_text(json.dumps(sample,indent=2))
status=data('status-counterfactual-proof.json')
paired=data('paired-latency.json')
process=data('process-tree-proof.json')
contracts=data('bounded-contract-proof.json')
review=data('review-proof.json')
cleanup=data('teardown-proof.json')
postfetch=data('teardown-postfetch-proof.json')
tests=data('targeted-tests.json')
checks={
    'status_under_one_second':all(r['exit']==0 and r['returns_gate_and_finding'] and r['elapsed_seconds']<1 and not r['implicit_lazy_fetches'] for r in status['runs'] if r['version'].startswith('after')) and all(r['exit']==0 and r['has_gate_and_finding'] and r['elapsed_seconds']<1 for r in paired if r['interface']=='bounded-product'),
    'head_still_absent':status['head_remains_absent'] and sample['pipeline_head_remains_absent'],
    'timeout_reaps_subtree':process[-1]['all_descendants_gone'],
    'contracts':all(r['expected_surface'] for r in contracts),
    'review':all(r['expected_surface'] for r in review),
    'cleanup_missing':cleanup['expected_surface'],
    'cleanup_postfetch':postfetch['expected_surface'],
    'sustained_gate':sample['all_reads_show_review_gate'] and not sample['missed_gate_reads'],
    'ten_minute_orphan_sample':sample['elapsed_seconds']>=600 and sample['orphan_cat_file_instances']==0 and not sample['implicit_lazy_fetches'] and not sample['slow_origin_started'],
    'targeted_checks':all(r['exit']==0 for r in tests),
}
result={'checks':checks,'all_exercised_pass':all(checks.values()),'sample':sample}
(evidence/'result.json').write_text(json.dumps(result,indent=2))
lines=[
    'Live validation round 2: 0bcfe6bb84688bf4792db33c28550f62de27085e',
    'Real Firstmate, no-mistakes, Git, and gh ran against disposable partial clones, seeded pipeline records, a marked Firstmate lab home, and a local forge API.',
    'Only read-only no-mistakes commands were used. No pipeline, delivery, shared fleet, real account, or production configuration was changed.',
    'The initial three bounded status reads met the one-second threshold. Subsequent timing controls did not meet it reliably, so this is not a clean performance pass.',
    '',
    'MISSING PIPELINE HEAD: BEFORE AND AFTER',
    json.dumps(status,indent=2),
    'PAIRED TIMING CONTROLS',
    json.dumps(paired,indent=2),
    'The direct CLI with lazy fetching disabled also exceeded one second. Host load was 125.53 / 116.67 / 131.49 during the comparison. These observations do not establish a code regression and do not satisfy the required latency acceptance.',
    '',
    'ACTUAL STATUS SURFACE',
    (evidence/'after-1-status.txt').read_text(),
    '',
    'REAL GIT FETCH SUBTREE: BEFORE AND AFTER',
    json.dumps(process,indent=2),
    'The old runner left a recorded remote descendant under launchd (ppid 1). The changed runner left neither recorded descendant alive. Baseline descendants were explicitly stopped.',
    '',
    'STDIN, OUTPUT, EXIT STATUS AND BASH FALLBACK',
    json.dumps(contracts,indent=2),
    '',
    'TEN-MINUTE CREW-STATE AND ORPHAN SAMPLE',
    json.dumps(sample,indent=2),
    'Crew-state reads:',
    json.dumps(reads,indent=2),
    '',
    'REVIEW DIFF: MISSING HEAD, AVAILABLE LOCAL HEAD, FRESH PULL REF',
]
for row in review:
    lines.extend([row['scenario'],row['stdout'],'Missing-head fallback warning: '+str('PR head unavailable' in row['stderr'])])
lines.extend([
    'A fresh PR diff may fetch an omitted blob when rendering content. That does not fetch a missing commit during the changed existence probe.',
    '',
    'CLEANUP REFUSES TO DISCARD UNLANDED WORK',
    (evidence/'teardown-refusal.txt').read_text(),
    json.dumps({k:cleanup[k] for k in ['exit','cat_file_probes','implicit_lazy_fetches','metadata_preserved','local_work_preserved','expected_surface']},indent=2),
    '',
    'SUCCESSFUL PR FETCH WITH DISAGREEING RECORDED HEAD',
    json.dumps(postfetch,indent=2),
    '',
    'TARGETED CHECKS',
    json.dumps(tests,indent=2),
    'No full repository suite, lint, formatter, static analysis, push, PR, CI, or pipeline-control command was run.',
    '',
    'REQUIRED DELIVERY FOLLOW-UP NOT EXERCISED HERE',
    'Production cutover and the following-morning ten-minute sample require the outer delivery owner to deploy the approved change and repeat the process sampling after that cutover. This phase cannot deploy or advance the date, and it did not access the live fleet.',
    '',
    'RESULT',json.dumps(checks,indent=2),
])
(evidence/'live-validation-report.txt').write_text('\n'.join(lines)+'\n')
print(json.dumps(result,indent=2))
