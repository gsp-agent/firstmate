from pathlib import Path
import json

evidence = Path(__file__).parent

def read(name):
    return json.loads((evidence/name).read_text())

def block(title, text):
    return title + "\n" + "=" * len(title) + "\n" + text.rstrip() + "\n\n"

initial=read('function-latency-proof.json')
spread=read('spread-latency-proof.json')
peak=read('peak-function-latency-proof.json')
sample=read('ten-minute-summary.json')
process=read('process-tree-proof.json')
descendants=read('git-descendants-proof.json')
perl=read('perl-retry-descendants-proof.json')
contract=read('bounded-contract-proof.json')
scope=read('scope-proof.json')
review=read('review-proof.json')
teardown=read('teardown-proof.json')
post=read('teardown-postfetch-proof.json')
counter=read('status-counterfactual-proof.json')
tests=read('targeted-tests.json')
all_calls=initial['reads']+spread['reads']+peak['reads']
bounded=[r for r in all_calls if r.get('interface','bounded-function')=='bounded-function']
direct=[r for r in all_calls if r.get('interface')=='direct-cli-no-fetch']
result={
    'bounded_latency_seconds': [r['elapsed_seconds'] for r in bounded],
    'direct_control_latency_seconds': [r['elapsed_seconds'] for r in direct],
    'bounded_all_under_one_second':all(r['elapsed_seconds']<1 for r in bounded),
    'bounded_all_keep_gate':all(r['exit']==0 and r['has_gate_and_finding'] for r in bounded),
    'sample':sample,
    'timeout_baseline_and_changed':process,
    'all_real_git_descendants_gone':all(r['expected_surface'] for r in descendants+perl),
    'stdin_and_output_preserved':all(r['expected_surface'] for r in contract),
    'caller_environment_preserved':all(r['expected_surface'] for r in scope),
    'review_cases':all(r['expected_surface'] for r in review),
    'teardown_missing_head_safe':teardown['expected_surface'],
    'teardown_postfetch_safe':post['expected_surface'],
    'focused_tests':tests
}
(evidence/'results.json').write_text(json.dumps(result,indent=2))

txt=block('Live missing-head review gate', '$ fm_nm_run_bounded <disposable-partial-clone> 10 axi status\n'+(evidence/'function-1-bounded-function.toon').read_text())
txt+=block('Untraced latency checks, after loading the runner',json.dumps({'initial':initial,'spaced':spread,'contemporaneous_controls':peak},indent=2))
txt+=block('Same missing-head scenario before and after the change',json.dumps(counter,indent=2))
(evidence/'status-performance.txt').write_text(txt)

rows=[json.loads(line) for line in (evidence/'ten-minute-crew-reads.jsonl').read_text().splitlines()]
txt=block('Ten-minute disposable crew-state and orphan sample',json.dumps(sample,indent=2))
for row in rows:
    txt+=f"at {row['at_seconds']} seconds; elapsed {row.get('elapsed_seconds','?')} seconds; exit {row.get('exit','?')}\n$ FM_HOME=<marked-lab-home> bin/fm-crew-state.sh lab-yeldv\n{row.get('stdout','')}\n{row.get('stderr','')}\n"
(evidence/'crew-sample-evidence.txt').write_text(txt)

(evidence/'process-tree-evidence.txt').write_text(block('Real Git lazy-fetch process trees at the timeout', json.dumps({'baseline':process,'native_and_bash':descendants,'perl':perl},indent=2)))
(evidence/'runner-contract-evidence.txt').write_text(block('Bounded command streams and exit statuses',json.dumps(contract,indent=2))+block('No-fetch setting stays scoped to status reads',json.dumps(scope,indent=2)))
txt=''
for label in ['missing-recorded-head','available-recorded-head','fresh-pull-ref']:
    txt+=block('PR review: '+label,(evidence/('review-'+label+'.txt')).read_text())
(evidence/'review-evidence.txt').write_text(txt)
(evidence/'teardown-evidence.txt').write_text(block('Absent PR commit preserves unlanded work',(evidence/'teardown-refusal.txt').read_text())+block('Explicit PR-head fetch does not enable lazy probes',json.dumps(post,indent=2)))
print(json.dumps(result,indent=2))
