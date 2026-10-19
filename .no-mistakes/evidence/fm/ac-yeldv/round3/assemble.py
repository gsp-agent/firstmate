from pathlib import Path
import json, os, subprocess
root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round3')
def read(name): return json.loads((evidence/name).read_text())
f=read('fixture.json')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(read('env.json'))
probe=subprocess.run(['git','-C',f['slot'],'cat-file','-e',f['head']+'^{commit}'],env=env|{'GIT_NO_LAZY_FETCH':'1'},text=True,capture_output=True,timeout=20)
summary=read('ten-minute-summary.json')
crew=[json.loads(v) for v in (evidence/'ten-minute-crew-reads.jsonl').read_text().splitlines()]
trace_probes=[]; trace_fetches=[]
for path in sorted(evidence.glob('sample-crew-*.trace.jsonl')):
 for v in map(json.loads,path.read_text().splitlines()):
  if v.get('event')!='start': continue
  argv=v['argv']
  if 'cat-file' in argv: trace_probes.append({'trace':path.name,'argv':argv})
  if 'fetch' in argv and '--stdin' in argv: trace_fetches.append({'trace':path.name,'argv':argv})
final={'head_remains_absent':probe.returncode!=0,'missing_head_probe_exit':probe.returncode,'sample':summary,'attributable_git_cat_file_starts':len(trace_probes),'implicit_lazy_fetches':trace_fetches,'slow_promisor_started':(Path(f['scratch'])/'sample-remote-pids').exists(),'host_load_at_completion':os.getloadavg()}
(evidence/'final-sample-proof.json').write_text(json.dumps(final,indent=2))
status=read('status-counterfactual-proof.json')
function=read('function-latency-proof.json')
spread=read('spread-latency-proof.json')
lines=['Real no-mistakes v1.84.0 and Firstmate at 0bcfe6bb84688bf4792db33c28550f62de27085e.','A disposable file-protocol blob:none clone has a pipeline head present only in its disposable gate repository.','No pipeline was initialized or controlled. The CLI reads an isolated SQLite run and gate record.','Acceptance baseline from bead .agent-config-yeldv: bounded status timed out at 10 seconds; 6 cat-file probes orphaned in 10 minutes.','','Counterfactual on a deliberately slow promisor:']
for v in status['runs']:
 lines.append(str(v))
lines+=['','Untraced function timing uses Bash built-in time after sourcing the library.','The function-only measurements exclude shell startup, library loading and Git trace writes; all earlier end-to-end wall timings remain below.']
for v in function['reads']+spread['reads']: lines.append(str(v))
lines+=['','Earlier whole-shell untraced timings:',json.dumps(read('paired-latency.json'),indent=2),'','Representative actual product response:','$ fm_nm_run_bounded <disposable-slot> 10 axi status',(evidence/'spread-1.toon').read_text()]
(evidence/'status-performance.txt').write_text('\n'.join(lines))
lines=['Actual process tables from real Git cat-file -> Git fetch -> slow upload-pack -> TERM-resistant sleep.','Before the fix:',json.dumps(read('process-tree-proof.json'),indent=2),'','Full Git process tree before and after the changed runner returns, under native timeout and Bash fallback:',json.dumps(read('git-descendants-proof.json'),indent=2)]
(evidence/'process-tree-evidence.txt').write_text('\n'.join(lines))
lines=['Ten-minute live sample scoped to the unique disposable pipeline head.',json.dumps(final,indent=2),'','Actual crew-state responses:']
for v in crew:
 lines.extend(['at '+str(v['at_seconds'])+'s; duration '+str(v.get('elapsed_seconds'))+'s; exit '+str(v.get('exit')),'$ bash bin/fm-crew-state.sh lab-yeldv',v.get('stdout',str(v)),v.get('stderr','')])
(evidence/'crew-sample-evidence.txt').write_text('\n'.join(lines))
lines=[]
for v in read('review-proof.json'):
 lines.extend([v['scenario'],(evidence/('review-'+v['scenario']+'.txt')).read_text(),'Implicit lazy fetches: '+str(v['implicit_lazy_fetches']),''])
(evidence/'review-evidence.txt').write_text('\n'.join(lines))
lines=[]
for name in ['teardown-proof.json','teardown-postfetch-proof.json']:
 v=read(name)
 lines.extend(['$ FM_HOME=<disposable-marked-home> bash bin/fm-teardown.sh lab-teardown',v['stdout']+v['stderr'],'Probe commands: '+str(v['cat_file_probes']),'Implicit lazy fetches: '+str(v['implicit_lazy_fetches']),'Metadata preserved: '+str(v['metadata_preserved']),'Unlanded work preserved: '+str(v['local_work_preserved']),'Explicit PR fetch retrieved head: '+str(v.get('explicit_pr_fetch_retrieved_head','PR ref intentionally absent')),''])
(evidence/'teardown-evidence.txt').write_text('\n'.join(lines))
lines=['Bounded runner stdin, stdout, stderr and exit behavior:',json.dumps(read('bounded-contract-proof.json'),indent=2),'','No-fetch policy stays inside the no-mistakes child; caller environment and shell settings remain intact:',json.dumps(read('scope-proof.json'),indent=2)]
(evidence/'runner-contract-evidence.txt').write_text('\n'.join(lines))
accepted=function['reads']+[v|{'interface':'bounded-function'} for v in spread['reads']]
accepted=[v for v in accepted if v['interface']=='bounded-function']
checks={'missing_head_no_lazy_fetch':status['head_remains_absent'] and all(v['returns_gate_and_finding'] and v['exit']==0 and not v['implicit_lazy_fetches'] for v in status['runs'] if v['version'].startswith('after')),'function_latency_under_one_second':all(v['exit']==0 and v['elapsed_seconds']<1 and v['has_gate_and_finding'] for v in accepted),'crew_gate_reliable':bool(crew) and summary['all_reads_show_review_gate'],'ten_minute_no_orphans':summary['elapsed_seconds']>=600 and summary['orphan_cat_file_instances']==0 and len(trace_probes)>0 and not trace_fetches and probe.returncode!=0,'real_git_tree_reaped':all(v['expected_surface'] for v in read('git-descendants-proof.json')),'runner_contract':all(v['expected_surface'] for v in read('bounded-contract-proof.json')) and all(v['expected_surface'] for v in read('scope-proof.json')),'review_heads':all(v['expected_surface'] for v in read('review-proof.json')),'teardown_preserves_work':read('teardown-proof.json')['expected_surface'] and read('teardown-postfetch-proof.json')['expected_surface']}
result={'checks':checks,'function_latency_min':min(v['elapsed_seconds'] for v in accepted),'function_latency_max':max(v['elapsed_seconds'] for v in accepted),'failed_latency_reads':[v for v in accepted if v['exit']!=0 or v['elapsed_seconds']>=1 or not v['has_gate_and_finding']],'final_sample':final,'targeted_tests':read('targeted-tests.json')}
(evidence/'result.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
