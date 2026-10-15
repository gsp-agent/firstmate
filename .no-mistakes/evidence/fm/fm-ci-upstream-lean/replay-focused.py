import os
from pathlib import Path
import re
import subprocess

root = Path.cwd()
scratch = root / '.test-phase'
product = scratch / 'product'
product.mkdir(exist_ok=True)
archive = subprocess.Popen(['git', 'archive', 'f4b1b5588ab8bc6423ef5c58a5c53b59d104648b'], stdout=subprocess.PIPE)
subprocess.run(['tar', '-x', '-C', str(product)], stdin=archive.stdout, check=True)
archive.stdout.close()
assert archive.wait() == 0
subprocess.run(['git', 'init', '-q', '-b', 'main', str(product)], check=True)
subprocess.run(['git', '-C', str(product), '-c', 'user.name=Validation Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Isolated product runtime'], check=True)
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
env['TMPDIR'] = str(scratch / 'tmp')
env['FM_TEST_EVIDENCE'] = '1'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M50V2BM2QVYA70JHTFYFVJEA')
selections = {
    'fm-spawn-dispatch-profile': [
        'test_cursor_threads_model_workspace_and_omits_effort_axis',
        'test_cursor_crew_guard_pins_working_directory_and_refuses_ref_plumbing',
        'test_cursor_secondmate_stays_interactive',
        'test_cursor_allowlist_launch_executes_and_preserves_exit',
    ],
    'fm-pi-branch-extension': [
        'test_away_record_parks_main_and_presents_after_archive',
        'test_branch_mirror_filters_order_and_cursor',
    ],
    'fm-pi-watch-extension': [
        'test_pi_streaming_followup_is_replayed_after_replacement',
        'test_pi_streaming_time_delivery_keeps_the_successor_chain',
    ],
}
results = []
for subject, selectors in selections.items():
    original = product / 'tests' / (subject + '.test.sh')
    # Preserve existing behavioral test bodies, suppress only their top-level
    # invocation list, then run the named cases. No product source is changed.
    lines = original.read_text().splitlines(keepends=True)
    selected = ''.join(line for line in lines if not re.fullmatch(r'test_[A-Za-z0-9_]+\s*\n?', line))
    selected += '\n' + '\n'.join(selectors) + '\n'
    driver = original.with_name(subject + '.selected.test.sh')
    driver.write_text(selected)
    log_path = evidence / (subject + '-focused-replay.log')
    with log_path.open('w') as log:
        log.write('Fixture: exact target-commit product snapshot inside the gate worktree; fixture homes outside that code root.\n')
        log.write('Existing behavioral test selectors: ' + ', '.join(selectors) + '\n')
        log.flush()
        run = subprocess.run(['bash', str(driver)], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        log.write(f'focused replay exit={run.returncode}\n')
    results.append({'subject': subject, 'selectors': selectors, 'exit': run.returncode})
(evidence / 'focused-replay-results.json').write_text(__import__('json').dumps(results, indent=2) + '\n')
print(results)
assert all(result['exit'] == 0 for result in results), results
