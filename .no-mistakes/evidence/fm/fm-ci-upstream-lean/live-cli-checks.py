import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
fixture = root / '.test-phase' / 'live-cli'
fixture.mkdir(exist_ok=True)
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M50V2BM2QVYA70JHTFYFVJEA')
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
env['TMPDIR'] = str(root / '.test-phase' / 'tmp')
home = fixture / 'home'
(home / 'config').mkdir(parents=True, exist_ok=True)
env['FM_HOME'] = str(home)

with (evidence / 'live-cli-protocols.log').open('w') as log:
    def record(label, value):
        log.write(label + '\n' + (value if isinstance(value, str) else json.dumps(value, indent=2)) + '\n')
        log.flush()

    for name, pct, age, code in [
        ('fractional-percent', 84.5, 26, 2),
        ('fractional-age', 85, 0.5, 2),
        ('minimum-integers', 1, 1, 0),
        ('maximum-percent', 100, 26, 0),
        ('percent-zero', 0, 26, 2),
        ('percent-over-limit', 101, 26, 2),
        ('age-zero', 85, 0, 2),
        ('string-percent', '85', 26, 2),
    ]:
        config = {'default': {'harness': 'codex'}, 'cursor_fallback': {'models_pct': pct, 'max_age_h': age}}
        (home / 'config' / 'crew-dispatch.json').write_text(json.dumps(config))
        run = subprocess.run(['bash', 'bin/fm-dispatch-resolve.sh', '--labels', ''], env=env, text=True, capture_output=True)
        record(f'fm-dispatch-resolve --labels "": {name}; config={json.dumps(config)}; exit={run.returncode}', run.stdout + run.stderr)
        assert run.returncode == code, (name, run.returncode, code)
        if code == 0:
            assert 'status: clear' in run.stdout and "profile: --harness 'codex'" in run.stdout, run.stdout
        else:
            assert 'integer models_pct' in run.stderr, run.stderr

    task = fixture / 'task'
    other = fixture / 'other'
    task.mkdir(exist_ok=True)
    other.mkdir(exist_ok=True)
    cases = [
        ('omitted-directory', {'command': 'pwd', 'timeout': 123, 'description': 'preserve fields'}, 'pin'),
        ('empty-directory', {'command': 'pwd', 'working_directory': ''}, 'pin'),
        ('explicit-directory', {'command': 'pwd', 'working_directory': str(other)}, 'unchanged'),
        ('deny-symbolic-ref', {'command': 'git symbolic-ref HEAD refs/heads/moved'}, 'deny'),
        ('deny-ref-wrapper', {'command': "env -S 'git -C /irrelevant update-ref HEAD abc123'"}, 'deny'),
        ('deny-compound-ref', {'command': 'if true; then git update-ref HEAD abc123; fi'}, 'deny'),
        ('allow-branch-read', {'command': 'git branch --show-current'}, 'pin'),
    ]
    for name, tool_input, expectation in cases:
        payload = {'tool_name': 'Shell', 'tool_input': tool_input}
        run = subprocess.run(['node', 'bin/fm-cursor-crew-guard.mjs', '--worktree', str(task)], input=json.dumps(payload), env=env, text=True, capture_output=True)
        record(f'Cursor preToolUse CLI: {name}; input={json.dumps(payload)}; exit={run.returncode}', run.stdout or '(no decision; explicit input retained)')
        assert run.returncode == 0 and not run.stderr, run.stderr
        if expectation == 'unchanged':
            assert not run.stdout
        else:
            response = json.loads(run.stdout)
            if expectation == 'pin':
                assert response == {'permission': 'allow', 'updated_input': {**tool_input, 'working_directory': str(task)}}
            else:
                assert response['permission'] == 'deny'
                assert 'git branch --show-current' in response['agent_message']

    config_path = fixture / 'cursor-cli-config.json'
    rules_path = fixture / 'pstack-models.mdc'
    config_path.write_text(json.dumps({'network': {'useHttp1ForAgent': False, 'retained': 'yes'}, 'modelParameters': {'grok-4.7': [{'id': 'fast', 'value': 'true'}]}, 'unrelated': 'keep'}))
    config_env = {**env, 'FM_CURSOR_CLI_CONFIG': str(config_path), 'FM_CURSOR_MODELS_RULE': str(rules_path)}
    for repetition in range(2):
        run = subprocess.run(['bash', 'bin/fm-cursor-assert.sh'], env=config_env, text=True, capture_output=True)
        assert run.returncode == 0, run.stderr
        config = json.loads(config_path.read_text())
        record(f'fm-cursor-assert invocation {repetition + 1}; generated configuration:', config)
        assert config['network']['useHttp1ForAgent'] is True
        assert config['network']['retained'] == 'yes' and config['unrelated'] == 'keep'
        assert {'id': 'fast', 'value': 'false'} in config['modelParameters']['grok-4.7']
    (evidence / 'generated-cursor-config.json').write_text(config_path.read_text())
    record('Result', 'All direct product CLI checks passed. These checks use no vendor or terminal stand-in; native Cursor consumption is a separate scenario.')

workflow = subprocess.run(['ruby', '-rjson', '-ryaml', '-e', 'd=YAML.load_file(ARGV[0]); e=d.fetch("on", d[true]); puts JSON.pretty_generate({name:d.fetch("name"),events:e,jobs:d.fetch("jobs").keys})', '.github/workflows/ci.yml'], text=True, capture_output=True, check=True)
model = json.loads(workflow.stdout)
for event in ['push', 'pull_request']:
    assert set(model['events'][event]['branches']) == {'main', 'upstream-lean'}, model
unchanged = subprocess.run(['git', 'diff', '--quiet', '20dcbf91520b1816663b81873ad67d0b93b3e4d6', 'f4b1b5588ab8bc6423ef5c58a5c53b59d104648b', '--', '.github/workflows/no-mistakes-required.yml'])
assert unchanged.returncode == 0
model['no_mistakes_required_workflow_unchanged'] = True
model['validation_limit'] = 'Parsed workflow semantics only; GitHub event delivery and no-mistakes checks-passed are owned by later gate phases.'
(evidence / 'workflow-semantics.json').write_text(json.dumps(model, indent=2) + '\n')
print('Direct CLI protocol/configuration checks and workflow semantic check passed; product outputs retained in evidence.')
