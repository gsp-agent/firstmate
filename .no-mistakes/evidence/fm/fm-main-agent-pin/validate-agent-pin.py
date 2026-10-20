from dataclasses import dataclass
from pathlib import Path
import json
import subprocess
import yaml

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5DT93DY3040KMZCSPKJ9MNY')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5DT93DY3040KMZCSPKJ9MNY')
BASE = '7dd35426d7d089d1d090cc65d9eb84dfc18175c0'
TARGET = 'd0eb47d88a43b3891d3dde7ed53b41dae63423e5'

class UniqueMappingLoader(yaml.SafeLoader):
    pass

def unique_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ValueError(f'Duplicate configuration key: {key}')
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping

UniqueMappingLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping
)

@dataclass(frozen=True)
class GateConfiguration:
    disable_project_settings: bool
    agents: tuple[str, ...] | None
    other_settings: dict
    ordered_keys: tuple[str, ...]

    @classmethod
    def parse(cls, text):
        data = yaml.load(text, Loader=UniqueMappingLoader)
        assert type(data) is dict, 'Configuration must be a mapping'
        assert all(type(key) is str for key in data), 'Keys must be strings'
        disabled = data['disable_project_settings']
        assert type(disabled) is bool, 'Instruction suppression must be a boolean'
        agents = data.get('agent')
        if agents is not None:
            assert type(agents) is list, 'Agent selection must be a list'
            assert agents and all(type(item) is str for item in agents)
            assert len(set(agents)) == len(agents), 'Agent list must be unique'
            agents = tuple(agents)
        return cls(disabled, agents,
                   {key: value for key, value in data.items()
                    if key not in ('disable_project_settings', 'agent')},
                   tuple(data))

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True)

base_text = git('show', BASE + ':.no-mistakes.yaml')
target_text = git('show', TARGET + ':.no-mistakes.yaml')
assert (ROOT / '.no-mistakes.yaml').read_text() == target_text
base = GateConfiguration.parse(base_text)
target = GateConfiguration.parse(target_text)
changed_paths = git('diff', '--name-only', BASE, TARGET).splitlines()
assert changed_paths == ['.no-mistakes.yaml'], changed_paths
assert base.agents is None, 'Unexpected baseline agent pin'
assert target.agents == ('codex',), 'Selection must permit only Codex'
assert base.disable_project_settings is True
assert target.disable_project_settings is True
assert target.ordered_keys.index('agent') == (
    target.ordered_keys.index('disable_project_settings') + 1
), 'Agent pin must follow instruction suppression'
assert target.other_settings == base.other_settings, 'Unrelated configuration changed'

report = {
    'contract': 'Typed semantics of the project no-mistakes YAML configuration',
    'base_commit': BASE,
    'target_commit': TARGET,
    'changed_paths': changed_paths,
    'baseline': {
        'agent': None,
        'disable_project_settings': base.disable_project_settings,
    },
    'target': {
        'agent': list(target.agents),
        'disable_project_settings': target.disable_project_settings,
        'ordered_top_level_keys': list(target.ordered_keys),
    },
    'unrelated_settings': {
        'equal_to_baseline': target.other_settings == base.other_settings,
        'keys': list(target.other_settings),
    },
    'live': False,
    'limitation': (
        'This configuration-only change has no Firstmate runtime surface. '
        'Parsing proves the declarative selection and scope, not agent launches '
        'or interpretation of AGENTS.md. A future trusted pipeline run and '
        'publication of the existing PR signature/attestation belong to the '
        'outer executor, outside this test phase.'
    ),
}
output = json.dumps(report, indent=2) + '\n'
(EVIDENCE / 'agent-pin-semantics.json').write_text(output)
print(output, end='')
