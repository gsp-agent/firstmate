from pathlib import Path
import json

evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH')

def data(name):
    return json.loads((evidence / name).read_text())

counterfactual = data('status-counterfactual-proof.json')
sample = data('ten-minute-summary.json')
paired = data('paired-latency-control.json')
process = data('process-tree-proof.json')
review = data('review-proof.json')
teardown = data('teardown-proof.json')
postfetch = data('teardown-postfetch-proof.json')
lines = [
    'Live validation of 0bcfe6bb84688bf4792db33c28550f62de27085e',
    'No production checkout, fleet session, credential store, or upstream pipeline was changed.',
    'Real Firstmate scripts, Git 2.56.0, no-mistakes v1.84.0, and gh were exercised against disposable local Git repositories, no-mistakes records, and a local forge API.',
    '',
    'RESULT: functional no-fetch and descendant-cleanup proofs passed; strict latency and reliable crew-state acceptance failed on this loaded host.',
    'Host load observation during the run: 135.66 / 181.40 / 195.68.',
    '',
    'MISSING-HEAD STATUS: BEFORE AND AFTER',
    json.dumps(counterfactual, indent=2),
    '',
    'The pipeline commit remained absent in the partial clone after the checks.',
    'The old runner lazy-fetched and timed out at 10.105324 seconds. The changed runner returned the real review gate and finding without a lazy fetch, including a 0.824324-second call.',
    'Other changed-runner calls exceeded the required one second. Paired control timings show the installed CLI with GIT_NO_LAZY_FETCH=1 also slowed independently of the wrapper:',
    json.dumps(paired, indent=2),
    '',
    'ACTUAL PRODUCT STATUS OUTPUT',
    (evidence / 'after-1-status.txt').read_text(),
    '',
    'PROCESS TREE: REAL GIT FETCH WITH TERM-IGNORING REMOTE DESCENDANTS',
    json.dumps(process, indent=2),
    'The before case left a remote descendant with ppid 1; the after case returned 124 and left both recorded descendants absent. Baseline survivors were explicitly stopped.',
    '',
    'TEN-MINUTE LAB OBSERVATION',
    json.dumps(sample, indent=2),
    'Samples span 0.017 through 599.910 seconds. Of 20 actual crew-state reads, 17 showed the review approval with one finding and 3 fell back to unknown. No lab-head cat-file process was observed under launchd.',
    '',
    'REVIEW DIFF OUTPUTS',
]
for row in review:
    lines.extend([row['scenario'], 'expected_surface=' + str(row['expected_surface']), row['stdout'], 'Missing-head fallback warning=' + str('PR head unavailable' in row['stderr'])])
lines.extend([
    'The fresh-PR diff fetched an omitted blob while rendering content. Trace2 attributes that fetch to git diff, outside the changed commit-probe boundary.',
    '',
    'CLEANUP SAFETY WITH MISSING PR HEAD',
    json.dumps({key: teardown[key] for key in ['exit', 'cat_file_probes', 'implicit_lazy_fetches', 'metadata_preserved', 'local_work_preserved', 'expected_surface']}, indent=2),
    teardown['stderr'].split('REFUSED:')[-1],
    '',
    'CLEANUP SAFETY AFTER A SUCCESSFUL BUT DISAGREEING PR-REF FETCH',
    json.dumps({key: postfetch[key] for key in ['exit', 'cat_file_probes', 'implicit_lazy_fetches', 'explicit_pr_fetch_retrieved_head', 'metadata_preserved', 'local_work_preserved', 'expected_surface']}, indent=2),
    '',
    'FOCUSED AUTOMATED CHECKS',
    'Passed: tests/fm-nm-run-lib.test.sh (default timeout and forced Bash fallback), tests/fm-timeout-lib.test.sh, tests/fm-review-diff.test.sh.',
    'No complete suite, lint, formatting, static analysis, push, PR, CI, or pipeline-control phase was run.',
    '',
    'UNTESTED REQUIRED FOLLOW-UP',
    'Production rollout and the following-morning ten-minute sample require the outer delivery owner to deploy the change and remeasure the real fleet after cutover. This phase is confined to the isolated worktree and disposable lab.',
    '',
    'CLEANUP',
    'All disposable repositories, homes, databases, subprocesses, API servers, and sockets were removed. git status --short returned no output. Evidence files remain in this evidence directory.',
])
(evidence / 'live-validation-report.txt').write_text('\n'.join(lines) + '\n')
print('Wrote live-validation-report.txt')
