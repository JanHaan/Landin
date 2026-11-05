#!/usr/bin/env python3
"""Controls for environments/boards/gate.py, the physical gate's rig-side
entry, without a board, probe or hub: its board tools are small stand-in
scripts in a temporary checkout, run as real processes so that the lock,
the journal and signal forwarding are the gate's own, and the USB sysfs,
boot id, helper, probe-rs and bundles are fixed inputs."""
import fcntl
import hashlib
import io
import json
import os
import signal
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import gate as GATE  # noqa: E402

COMMON, RIGS = GATE.common, GATE.rigs
ARTY = '210319B3E738'
PATIENCE = 60

# A board tool's stand-in: what it does is named by GATE_FAKE_BOARD_MODE in
# its environment; it records its arguments and whether the rig lock was
# held while it ran, and writes the result a board tool writes.
FAKE = r'''
import fcntl, json, os, signal, sys, time
from pathlib import Path
board = Path(__file__).parent.name
values = dict(a.split('=', 1) for a in sys.argv[1:] if a.startswith('--') and '=' in a)
mode, out = values['--mode'], Path(values['--output'])
action = os.environ.get('GATE_FAKE_%s_%s' % (board.upper(), mode.upper()), 'pass')
out.mkdir(parents=True)
lock = open(os.environ['GATE_FAKE_LOCK'])
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    held = False
except BlockingIOError:
    held = True
(out / 'argv.json').write_text(json.dumps(dict(argv=sys.argv[1:], lock_held_by_gate=held,
                                               pgid=os.getpgid(0), pid=os.getpid())))
def write(status, outcome, **more):
    (out / 'result.json').write_text(json.dumps(dict(status=status, outcome=outcome, mode=mode, **more)))
if action == 'pass':
    write('passed', 'passed')
elif action == 'noresult':
    print('Traceback: the tool died'); sys.exit(1)
elif action == 'wait-signal':
    def stop(number, frame):
        write('failed', 'cancelled', failure='cancelled by ' + signal.Signals(number).name,
              cancelled=dict(signal=signal.Signals(number).name, phase=dict(command='flash')))
        sys.exit(130)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    (out / 'ready').write_text('')
    time.sleep(60)
    sys.exit(3)
else:
    write('failed', action, failure='fake ' + action); sys.exit(1)
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Rig:
    """A temporary checkout, bundles, probehive runtime, sysfs, state and
    rig description."""
    def __init__(self, tmp):
        self.tmp = Path(tmp)
        self.root = self.tmp / 'checkout'
        for board in GATE.BOARDS:
            tool = self.root / 'environments/boards' / board / 'board.py'
            tool.parent.mkdir(parents=True)
            tool.write_text(FAKE)
        self.bundles = self.tmp / 'bundles'
        for board in GATE.BOARDS:
            for mode in ('boot', 'ram'):
                directory = self.bundles / board / mode
                directory.mkdir(parents=True)
                (directory / 'bundle.json').write_text('{"board": "%s", "mode": "%s"}\n' % (board, mode))
        self.hive = self.tmp / 'probehive'
        files = {}
        for name in RIGS.PROBEHIVE_FILES:
            (self.hive / name).parent.mkdir(parents=True, exist_ok=True)
            (self.hive / name).write_text(name)
            files[name] = sha(name.encode())
        self.helper = self.tmp / 'landin-ram-run'
        self.helper.write_text('')
        self.sysfs = self.tmp / 'sys'
        self.device('1-1', '2109', '3431')
        self.device('1-1.2', '0bda', '5411')
        self.device('1-1.1', '0403', '6010', serial=ARTY)
        self.boot = self.tmp / 'boot_id'
        self.boot.write_text('boot-1\n')
        self.state = self.tmp / 'state'
        self.state.mkdir()
        self.lock = self.state / 'rig.lock'
        self.lock.write_text('')
        description = json.loads((ROOT / 'environments/boards/rig.json').read_text())
        description['probehive'].update(files=files)
        description['ports']['configured'] = dict(
            location=dict(hub='1-1', port=2),
            steps=[dict(board='rp2350', mode='ram', arguments=['--hub={hub}', '--port', '{port}'])])
        self.rig = self.tmp / 'rig.json'
        self.rig.write_text(json.dumps(description))
        self.record_bitstream(description)
        self.summary = self.tmp / 'summary.md'
        self.environ = dict(os.environ, GATE_FAKE_LOCK=str(self.lock), GITHUB_SHA='a' * 40,
                            GITHUB_RUN_ID='41', GITHUB_RUN_ATTEMPT='2', GITHUB_EVENT_NAME='push',
                            GITHUB_STEP_SUMMARY=str(self.summary))
        self.validated = []

    def device(self, location, vendor, product, serial=None):
        device = self.sysfs / location
        device.mkdir(parents=True)
        (device / 'idVendor').write_text(vendor + '\n')
        (device / 'idProduct').write_text(product + '\n')
        (device / 'busnum').write_text('1\n')
        (device / 'devnum').write_text('5\n')
        if serial:
            (device / 'serial').write_text(serial + '\n')

    def record_bitstream(self, description):
        kept = dict(format_version=1, sha256=description['probehive']['bitstream']['sha256'],
                    boot_id='boot-1', arty=RIGS.arty(ARTY, self.sysfs))
        (self.state / RIGS.LOADED).write_text(json.dumps(kept))

    def validate(self, directory, *, board, mode, source_root):
        self.validated.append((board, mode))
        assert source_root == self.root
        return dict(compiler_identity=dict(sha256='c' * 64), source_identity=dict(sha256='s' * 64))

    def args(self, port, **more):
        values = dict(port=port, bundles=self.bundles, output=self.tmp / ('out-%s' % port),
                      rig=self.rig, lock_wait=0.0, probehive=self.hive, ram_loader=self.helper)
        values.update(more)
        return SimpleNamespace(**values)

    def gate(self, port, environ=None, **options):
        arguments = dict(root=self.root, environ=self.environ if environ is None else environ,
                         state=self.state, lock_path=self.lock, sysfs=self.sysfs, boot_id_path=self.boot,
                         validate_bundle=self.validate,
                         verify_helper=lambda args: dict(protocol_version=1, source_sha256='h' * 64),
                         probe_rs=lambda: dict(path='/bin/probe-rs', version='probe-rs 0.32.0 6f9946fe'),
                         which=lambda tool: '/bin/' + tool, report=lambda _: None)
        arguments.update(options)
        args = arguments.pop('args', None) or self.args(port)
        with redirect_stdout(io.StringIO()), mock.patch.object(GATE.sys.stdout, 'buffer', io.BytesIO(),
                                                               create=True):
            document = GATE.run_gate(args, **arguments)
        written = json.loads((Path(args.output) / 'outcome.json').read_text())
        assert written == json.loads(json.dumps(document)), 'outcome.json differs from the document'
        return written, Path(args.output)

    def free(self):
        """Whether the rig lock is free now."""
        with self.lock.open() as contender:
            try:
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            fcntl.flock(contender, fcntl.LOCK_UN)
            return True


class Sequence(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.rig = Rig(self.temporary.name)

    def test_a_port_runs_its_ram_run_then_its_boot_check_under_one_lock(self):
        # The boot check comes last, so the board rests on its verified fixed image.
        document, output = self.rig.gate('rp2040')
        self.assertEqual(document['format_version'], 1)
        self.assertEqual(document['outcome'], 'passed')
        self.assertEqual([(s['board'], s['mode'], s['outcome'], s['status']) for s in document['steps']],
                         [('rp2040', 'ram', 'passed', 'passed'), ('rp2040', 'boot', 'passed', 'passed')])
        for step in document['steps']:
            self.assertEqual(step['result'], 'rp2040-%s/result.json' % step['mode'])
            self.assertIsNone(step['failure'])
            self.assertGreaterEqual(step['elapsed_seconds'], 0)
            ran = json.loads((output / step['output'] / 'argv.json').read_text())
            self.assertEqual(ran['argv'], [
                '--mode=' + step['mode'], '--bundle=%s' % (self.rig.bundles / 'rp2040' / step['mode']),
                '--output=%s' % (output / ('rp2040-' + step['mode'])), '--probehive', str(self.rig.hive),
                '--indicator-pin', 'IO32', '--ram-loader', str(self.rig.helper)])
            self.assertTrue(ran['lock_held_by_gate'])
            self.assertEqual(ran['pgid'], ran['pid'], 'each step leads its own process group')
            self.assertTrue((output / ('rp2040-%s.log' % step['mode'])).is_file())
        self.assertTrue(self.rig.free())
        self.assertFalse((self.rig.state / 'runs/rp2040.json').exists())
        self.assertNotIn('previous_interrupted', document)
        provenance = document['provenance']
        self.assertEqual(provenance['commit'], 'a' * 40)
        self.assertEqual((provenance['github']['run_id'], provenance['github']['run_attempt'],
                          provenance['github']['event']), ('41', '2', 'push'))
        self.assertEqual([(b['board'], b['mode'], b['compiler_identity']['sha256'], b['source_identity'])
                          for b in provenance['bundles']],
                         [('rp2040', 'ram', 'c' * 64, 's' * 64), ('rp2040', 'boot', 'c' * 64, 's' * 64)])
        self.assertEqual(provenance['bundles'][0]['manifest_sha256'],
                         sha((self.rig.bundles / 'rp2040/ram/bundle.json').read_bytes()))
        self.assertEqual(provenance['rig']['sha256'], sha(self.rig.rig.read_bytes()))
        self.assertEqual(provenance['helper']['source_sha256'], 'h' * 64)
        self.assertIn('6f9946fe', provenance['probe_rs']['version'])
        self.assertEqual(sorted(provenance['probehive']['files']), sorted(RIGS.PROBEHIVE_FILES))
        self.assertEqual(provenance['bitstream']['boot_id'], 'boot-1')
        self.assertEqual(provenance['topology'], dict(cascade='1-1.2', arty='1-1.1'))
        self.assertEqual(provenance['boot_id'], 'boot-1')
        self.assertIn('host', provenance)
        for key in ('started', 'finished', 'elapsed_seconds'):
            self.assertIn(key, document)
        summary = self.rig.summary.read_text()
        self.assertIn('### Boards: rp2040, passed', summary)
        self.assertIn('| rp2040 ram | passed |', summary)

    def test_the_sequence_stops_at_the_first_step_that_does_not_pass(self):
        self.rig.environ['GATE_FAKE_RP2040_RAM'] = 'unavailable'
        document, output = self.rig.gate('rp2040')
        self.assertEqual(document['outcome'], 'unavailable')
        self.assertEqual([s['mode'] for s in document['steps']], ['ram'])
        self.assertEqual(document['steps'][0]['failure'], 'fake unavailable')
        self.assertFalse((output / 'rp2040-boot').exists())
        self.assertFalse((self.rig.state / 'runs/rp2040.json').exists(),
                         'a step that ended with its own result completed the sequence')
        self.assertIn('| rp2040 ram | unavailable |', self.rig.summary.read_text())

    def test_a_step_without_a_result_is_incomplete_and_its_journal_stays(self):
        self.rig.environ['GATE_FAKE_RP2040_RAM'] = 'noresult'
        document, _ = self.rig.gate('rp2040')
        self.assertEqual(document['outcome'], 'incomplete')
        step = document['steps'][0]
        self.assertEqual((step['outcome'], step['result'], step['exit_status']), ('incomplete', None, 1))
        self.assertIn('Traceback: the tool died', step['failure'])
        journal = json.loads((self.rig.state / 'runs/rp2040.json').read_text())
        self.assertEqual((journal['port'], journal['step'], journal['board'], journal['mode']),
                         ('rp2040', 0, 'rp2040', 'ram'))
        self.assertEqual(journal['github']['run_id'], '41')
        self.assertEqual((self.rig.state / 'runs/rp2040.json').stat().st_mode & 0o7777, 0o660)
        del self.rig.environ['GATE_FAKE_RP2040_RAM']
        again, _ = self.rig.gate('rp2040', args=self.rig.args('rp2040', output=self.rig.tmp / 'again'))
        self.assertEqual(again['outcome'], 'passed', (again.get('failure'), again['steps']))
        self.assertEqual(again['previous_interrupted'], journal)
        # The board's state is unknown, so a boot check restores it first.
        self.assertEqual([s['mode'] for s in again['steps']], ['boot', 'ram', 'boot'])
        self.assertEqual([s['output'] for s in again['steps']], ['rp2040-boot', 'rp2040-ram', 'rp2040-boot-2'])
        self.assertFalse((self.rig.state / 'runs/rp2040.json').exists())

    def test_a_port_without_probehive_skips_its_pins(self):
        (self.rig.state / RIGS.LOADED).unlink()
        (self.rig.hive / 'flake.nix').unlink()
        document, output = self.rig.gate('esp32c5')
        self.assertEqual(document['outcome'], 'passed')
        self.assertEqual(document['provenance']['bitstream'], 'not used by this port')
        self.assertNotIn('probehive', document['provenance'])
        self.assertEqual(json.loads((output / 'esp32c5-boot/argv.json').read_text())['argv'][3:], [])
        self.assertEqual(json.loads((output / 'esp32c5-ram/argv.json').read_text())['argv'][3:],
                         ['--ram-loader', str(self.rig.helper)])

    def test_a_location_is_put_in_its_placeholders(self):
        document, output = self.rig.gate('configured')
        self.assertEqual(document['outcome'], 'passed')
        self.assertEqual(json.loads((output / 'rp2350-ram/argv.json').read_text())['argv'][3:],
                         ['--hub=1-1', '--port', '2'])


class Refusals(unittest.TestCase):
    """Each refusal before the lock ends the port with its outcome, runs no
    step and leaves the lock untaken."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.rig = Rig(self.temporary.name)
        self.rig.lock.unlink()

    def refused(self, port, outcome, text, **options):
        document, output = self.rig.gate(port, **options)
        self.assertEqual(document['outcome'], outcome, document.get('failure'))
        self.assertIn(text, document['failure'])
        self.assertEqual(document['steps'], [])
        self.assertFalse(self.rig.lock.exists(), 'the lock was taken')
        self.assertEqual([p.name for p in output.iterdir()], ['outcome.json'])
        return document

    def test_the_pico_2_without_a_boot_path_needs_setup_before_anything_else(self):
        description = json.loads(self.rig.rig.read_text())
        description['ports']['pico2']['location'] = dict(hub=None, port=None)
        self.rig.rig.write_text(json.dumps(description))
        self.refused('pico2', 'needs-setup', 'leaves its hub, port null')
        self.assertEqual(self.rig.validated, [])

    def test_a_host_tool_the_steps_run_is_found_before_the_lock(self):
        # The first Pico 2 leg on the rig flashed its board and then met a
        # missing ping, leaving the fixed image unrestored.
        document = self.refused('pico2', 'needs-setup', 'lacks uhubctl on PATH',
                                which=lambda tool: None if tool == 'uhubctl' else '/bin/' + tool)
        self.assertIn('rp2350, rp2350_hazard3', document['failure'])
        # The probe's echo after a cycle is common.py's own, never ping.
        self.assertNotIn('ping', GATE.HOST_TOOLS['rp2350'] + GATE.HOST_TOOLS['rp2350_hazard3'])
        document = self.refused('rp2040', 'needs-setup', 'lacks nix, uhubctl on PATH',
                                which=lambda tool: None if tool in ('nix', 'uhubctl') else '/bin/' + tool)
        self.assertNotIn('ping', document['failure'])

    def test_a_bundle_from_other_source_fails(self):
        def stale(directory, **_):
            raise GATE.bundle.Invalid('bundle source identity does not match these tool and firmware sources')
        self.refused('rp2040', 'failed', 'source identity', validate_bundle=stale)

    def test_a_stale_helper_or_probe_rs_is_a_tool_mismatch(self):
        def stale(args):
            raise COMMON.ToolMismatch('stale or incompatible SRAM helper')
        self.refused('rp2040', 'rig-tool-mismatch', 'SRAM helper', verify_helper=stale)

        def other():
            raise COMMON.ToolMismatch('probe-rs reports another revision')
        self.refused('stm32h753', 'rig-tool-mismatch', 'probe-rs',
                     args=self.rig.args('stm32h753', output=self.rig.tmp / 'probe'), probe_rs=other)

    def test_a_missing_helper_needs_setup(self):
        self.rig.helper.unlink()
        self.refused('rp2040', 'needs-setup', 'no SRAM helper')

    def test_a_probehive_runtime_that_is_not_the_pin_is_a_tool_mismatch(self):
        (self.rig.hive / 'scripts/dap_udp.py').write_text('newer')
        self.refused('esp32c3', 'rig-tool-mismatch', 'scripts/dap_udp.py')

    def test_an_absent_cascade_or_arty_is_unavailable(self):
        for name in ('idVendor', 'idProduct', 'busnum', 'devnum'):
            (self.rig.sysfs / '1-1.2' / name).unlink()
        self.refused('stm32h753', 'unavailable', 'no hub cascade')

    def test_an_unrecorded_or_reenumerated_bitstream_needs_the_operator(self):
        (self.rig.sysfs / '1-1.1/devnum').write_text('9\n')
        self.refused('rp2040', 'needs-operator', 'enumerated again')

    def test_a_held_lock_ends_rig_busy_after_the_bounded_wait(self):
        holder = COMMON.RigLock('esp32 board.py', self.rig.lock, report=lambda _: None).acquire()
        self.addCleanup(holder.release)
        (self.rig.tmp / 'no-locks').write_text('')
        document, _ = self.rig.gate('rp2040', locks=self.rig.tmp / 'no-locks')
        self.assertEqual(document['outcome'], 'rig-busy')
        self.assertIn('held by esp32 board.py', document['failure'])
        self.assertEqual(document['steps'], [])

    def test_an_interrupted_pico_2_needs_the_operator_before_hardware(self):
        (self.rig.state / 'runs').mkdir()
        (self.rig.state / 'runs/pico2.json').write_text('{"port": "pico2", "step": 2}')
        description = json.loads(self.rig.rig.read_text())
        description['ports']['pico2']['location'] = dict(hub='1-1', port=2)
        self.rig.rig.write_text(json.dumps(description))
        document, output = self.rig.gate('pico2')
        self.assertEqual(document['outcome'], 'needs-operator')
        self.assertEqual(document['previous_interrupted'], dict(port='pico2', step=2))
        self.assertEqual(document['steps'], [])
        self.assertTrue((self.rig.state / 'runs/pico2.json').exists())
        self.assertTrue(self.rig.free())

    def test_the_steps_are_checked_before_they_run(self):
        rig = json.loads(self.rig.rig.read_text())
        values = dict(probehive='P', ram_loader='L')
        steps, used = GATE.port_steps(rig, 'esp32c3', values)
        self.assertEqual(steps, [('esp32c3', 'ram', ['--probehive', 'P', '--ram-loader', 'L']),
                                 ('esp32c3', 'boot', ['--probehive', 'P'])])
        self.assertEqual(used, {'probehive', 'ram_loader'})
        for change, text in (([dict(board='rp2040', mode='ram', arguments=['{unknown}'])], 'unknown'),
                             ([dict(board='rp2040', mode='ram', arguments=['--output=x'])], 'controls'),
                             ([dict(board='nucleo', mode='ram', arguments=[])], 'invalid step'),
                             ([], 'no steps')):
            rig['ports']['bad'] = dict(steps=change)
            with self.assertRaisesRegex(COMMON.Failed, text):
                GATE.port_steps(rig, 'bad', values)
        with self.assertRaisesRegex(COMMON.Failed, 'no port'):
            GATE.port_steps(rig, 'absent', values)

    def test_probe_rs_must_be_the_pinned_revision(self):
        with self.assertRaises(COMMON.NeedsSetup):
            GATE.probe_rs_identity(which=lambda _: None)
        answer = SimpleNamespace(returncode=0, stdout='probe-rs 0.31.0 (git commit: 0123abcd)\n', stderr='')
        with self.assertRaises(COMMON.ToolMismatch):
            GATE.probe_rs_identity(which=lambda _: '/bin/probe-rs', run=lambda *a, **k: answer)
        answer.stdout = 'v0.32.0-344-g6f9946fe\n'
        self.assertEqual(GATE.probe_rs_identity(which=lambda _: '/bin/probe-rs', run=lambda *a, **k: answer),
                         dict(path='/bin/probe-rs', version='v0.32.0-344-g6f9946fe'))


class Cancellation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.rig = Rig(self.temporary.name)
        handlers = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
        for number, handler in handlers.items():
            self.addCleanup(signal.signal, number, handler)

    def test_a_signal_reaches_the_running_step_which_records_its_cancellation(self):
        self.rig.environ['GATE_FAKE_RP2040_RAM'] = 'wait-signal'
        ready = self.rig.tmp / 'out-rp2040/rp2040-ram/ready'
        errors = []

        def cancel():
            deadline = time.monotonic() + PATIENCE
            while not ready.exists():
                if time.monotonic() > deadline:
                    errors.append('the step never started')
                    return
                time.sleep(0.05)
            os.kill(os.getpid(), signal.SIGTERM)
        sender = threading.Thread(target=cancel, daemon=True)
        sender.start()
        document, output = self.rig.gate('rp2040')
        sender.join(PATIENCE)
        self.assertEqual(errors, [])
        self.assertEqual(document['outcome'], 'cancelled')
        self.assertEqual(document['signals'], ['SIGTERM'])
        step, = document['steps']
        self.assertEqual((step['outcome'], step['exit_status'], step['phase']),
                         ('cancelled', 130, dict(command='flash')))
        self.assertFalse((output / 'rp2040-boot').exists())
        self.assertTrue((self.rig.state / 'runs/rp2040.json').exists(), 'an interrupted run stays journaled')
        self.assertTrue(self.rig.free())
        self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)

    def test_a_signal_between_steps_ends_the_port_cancelled(self):
        forwarder = GATE.Forwarder()
        with self.assertRaises(COMMON.Cancelled):
            forwarder(signal.SIGINT, None)
        forwarder(signal.SIGTERM, None)
        self.assertEqual(forwarder.signals, ['SIGINT', 'SIGTERM'])


if __name__ == '__main__':
    unittest.main()
