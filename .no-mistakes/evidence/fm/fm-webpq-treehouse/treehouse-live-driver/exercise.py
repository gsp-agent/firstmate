import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

from prepare import EVIDENCE, ENV, LAB, WORKTREE, run

REPORT = EVIDENCE / 'treehouse-cap-results.json'
TRANSCRIPT = EVIDENCE / 'treehouse-cap-cli.txt'
CHECKS = {}

def note(label, value):
    with TRANSCRIPT.open('a') as out:
        out.write('\n' + label + '\n' + value + '\n')

def cli(args, cwd=None, check=True, record=False):
    result = run(['treehouse', *args], cwd=cwd, check=check)
    if record:
        note('$ treehouse ' + ' '.join(args), result.stdout + result.stderr + f'\nexit={result.returncode}')
    return result

def state(record=False, cwd=None):
    return json.loads(cli(['status', '--json'], record=record, cwd=cwd).stdout)

def lease(index):
    result = cli(['get', '--lease', '--json', '--no-fetch', '--lease-holder', f'nm-cap-{index:02d}'])
    return json.loads(result.stdout)

def checkpoint(name, details):
    CHECKS[name] = {'result': 'pass', **details}
    REPORT.write_text(json.dumps(CHECKS, indent=2) + '\n')
    print(name + ': ' + json.dumps(details), flush=True)

def interactive_get():
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 180, 0, 0))
    env = dict(ENV, SHELL='/bin/sh')
    def tty_setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    proc = subprocess.Popen(['treehouse', 'get', '--no-fetch'], cwd=LAB / 'primary', env=env,
                            stdin=slave, stdout=slave, stderr=slave, preexec_fn=tty_setup)
    os.close(slave)
    output = bytearray()
    def drain_until(marker, timeout=60):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            if marker and marker in output:
                return
            ready, _, _ = select.select([master], [], [], max(0, until - time.monotonic()))
            if not ready:
                break
            try:
                data = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            output.extend(data)
        if marker and marker not in output:
            raise AssertionError('Real Treehouse shell did not become ready: ' + output.decode(errors='replace'))
    try:
        os.write(master, b"printf '%s%s %s\\n' NM_POOL_ SHELL_READY \"$PWD\"\n")
        drain_until(b'NM_POOL_SHELL_READY ')
        current = state(record=True)
        live = [slot for slot in current if slot['status'] != 'leased']
        assert len(current) == 17, current
        assert len(live) == 1, current
        assert live[0]['status'] == 'in-use', live
        assert any(p.get('pid') for p in live[0]['processes']), live
        marker = next(line for line in output.decode(errors='replace').splitlines()
                      if line.startswith('NM_POOL_SHELL_READY '))
        actual_path = marker.split(' ', 1)[1].strip()
        assert Path(actual_path) == Path(live[0]['path']), (marker, live)
        os.write(master, b'exit\n')
        drain_until(None, timeout=10)
        assert proc.wait(timeout=10) == 0
        checkpoint('ordinary_get_enters_17th_slot', {'path': actual_path, 'pty_grid': '40x180',
                   'slots': len(current), 'running_shell_seen_by_status': True})
    finally:
        if proc.poll() is None:
            os.write(master, b'exit\n')
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=5)
        os.close(master)
        note('$ treehouse get --no-fetch [real /bin/sh; PTY 40x180]', output.decode(errors='replace'))
    return Path(actual_path)

def release(slot):
    result = cli(['return', slot['path'], '--if-lease-id', slot['lease_id'],
                  '--if-lease-holder', slot['lease_holder']], record=True)
    assert result.returncode == 0

def main():
    current = state()
    assert len(current) == 1 and current[0]['lease_holder'] == 'nm-cap-01', current
    for i in range(2, 17):
        lease(i)
    baseline = state(record=True)
    assert len(baseline) == 16 and all(s['status'] == 'leased' for s in baseline), baseline
    denied = cli(['get', '--lease', '--json', '--no-fetch', '--lease-holder', 'baseline-17'], check=False, record=True)
    assert denied.returncode != 0, denied.stdout
    assert len(state()) == 16
    checkpoint('baseline_full_at_16', {'occupied': 16, '17th_request_exit': denied.returncode,
               'refusal': denied.stderr.strip()})

    primary = LAB / 'primary'
    (primary / 'treehouse.toml').write_bytes((WORKTREE / 'treehouse.toml').read_bytes())
    run(['git', 'add', 'treehouse.toml'])
    run(['git', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'apply tracked pool configuration'])
    run(['git', 'fetch', '--quiet', str(primary), 'main:main'], cwd=LAB / 'origin.git')
    run(['git', 'fetch', '--quiet', 'origin'])
    primary.joinpath('nested').mkdir()
    after = state(cwd=primary / 'nested', record=True)
    assert [(s['path'], s['lease_id']) for s in after] == [(s['path'], s['lease_id']) for s in baseline]
    checkpoint('config_does_not_spawn_or_relocate_workers', {'unchanged_busy_slots': 16,
               'extra_workers_started_automatically': 0, 'existing_pool_unchanged': True})

    interactive_path = interactive_get()
    post_shell = state(record=True)
    assert len(post_shell) == 17
    shell_slot = next(s for s in post_shell if Path(s['path']) == interactive_path)
    assert shell_slot['status'] == 'available', shell_slot
    for i in range(17, 25):
        lease(i)
    finish()

def finish():
    primary = LAB / 'primary'
    filled = state(record=True)
    assert len(filled) == 24 and all(s['status'] == 'leased' for s in filled), filled
    assert len({s['path'] for s in filled}) == 24
    checkpoint('tracked_config_allows_24_distinct_slots', {'leased': len(filled),
               'same_pool_directory': all(Path(s['path']).is_relative_to(LAB / 'pool') for s in filled)})

    nested = cli(['get', '--lease', '--json', '--no-fetch', '--lease-holder', 'denied-25'],
                 cwd=primary / 'nested', check=False, record=True)
    assert nested.returncode != 0
    assert [(s['path'], s['lease_id']) for s in state()] == [(s['path'], s['lease_id']) for s in filled]
    checkpoint('25th_slot_refused_without_disturbing_workers', {'occupied': 24,
               '25th_request_exit': nested.returncode, 'refusal': nested.stderr.strip()})

    release(filled[-1])
    release(filled[-2])
    spare = state(record=True)
    available = [s for s in spare if s['status'] == 'available']
    busy = [s for s in spare if s['status'] == 'leased']
    assert len(available) == 2 and len(busy) == 22, spare
    cli(['status'], record=True)
    checkpoint('status_shows_two_available_with_22_occupied', {'available': 2, 'leased': 22,
               'pool_size': len(spare), 'production_peak_claim': False})

    # Run from a newly allocated linked worktree, with the tracked config present.
    linked = Path(next(s['path'] for s in busy if s['lease_holder'] == 'nm-cap-18'))
    linked_nested = linked / 'nested'
    linked_nested.mkdir()
    linked_status = state(cwd=linked_nested, record=True)
    assert {s['path'] for s in linked_status} == {s['path'] for s in spare}, linked_status
    reused = json.loads(cli(['get', '--lease', '--json', '--no-fetch', '--lease-holder', 'nm-linked-reuse'],
                            cwd=linked_nested, record=True).stdout)
    assert reused['path'] in {s['path'] for s in available}, reused
    assert len(state()) == 24
    checkpoint('linked_worktree_reuses_same_pool', {'reused_path': reused['path'],
               'new_slot_created': False, 'pool_size': 24})
    release(reused)

    # Release our exact lease identities, preserving unrelated/changed ownership.
    for slot in state():
        if slot['status'] == 'leased':
            release(slot)
    final = state(record=True)
    assert len(final) == 24 and all(s['status'] == 'available' for s in final), final
    checkpoint('test_leases_released', {'available': len(final), 'leased': 0})

if __name__ == '__main__':
    try:
        if '--resume' in sys.argv:
            previous = json.loads(REPORT.read_text())
            if 'failure' in previous:
                (EVIDENCE / 'treehouse-driver-timeout.json').write_text(json.dumps(previous['failure'], indent=2) + '\n')
            CHECKS.update({key: value for key, value in previous.items() if key != 'failure'})
            note('Test-driver setup adjustment', 'The 60-second per-command driver deadline was too short for a 24-slot Treehouse status scan. Retrying that real command with a 240-second deadline; no product code or configuration was changed.')
            finish()
        else:
            main()
    except Exception as exc:
        CHECKS['failure'] = {'result': 'fail', 'type': type(exc).__name__, 'details': str(exc)}
        REPORT.write_text(json.dumps(CHECKS, indent=2) + '\n')
        raise
