#!/usr/bin/env python3
"""Controls for the RP2040 board tool's oracle, without a board (D595)."""
import importlib.util
import contextlib
import json
import struct
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('board', ROOT / 'environments/boards/rp2040/board.py')
BOARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOARD)


class Hub:
    """uhubctl as the tool sees it: a status listing, and every call kept."""
    def __init__(self, status):
        self.status, self.calls = status, []

    def command(self, name, argv, **_):
        self.calls.append(name)
        return self.status if name in ('hub-status', 'hub-wait') else ''


class Paced:
    """A pace that records each action it spaces into CALLS."""
    def __init__(self, calls):
        self.calls = calls

    def before(self, what):
        self.calls.append('before ' + what)

    def after(self, what):
        self.calls.append('after ' + what)


STATUS = """Current status for hub 7-2.3.3 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]
  Port 1: 0100 power
  Port 2: 0103 power enable connect [2e8a:000f]
  Port 3: 0100 power
  Port 4: 0503 power highspeed enable connect [0403:6010 Digilent Digilent USB Device 210319B3E738]
"""


def helper_readback(argv, data, *, board, probe):
    """Answer the real read plan with fixture bytes, checking the request."""
    assert len(argv) == 5 and str(argv[0]) == 'ram-loader', argv
    assert argv[1] == '--plan' and argv[3] == '--output', argv
    plan = json.loads(Path(argv[2]).read_text())
    assert plan == dict(format_version=1, board=board, mode='read', probe=probe,
                        address=0x10000000, count=len(data) // 4), plan
    words = list(struct.unpack('<%dI' % (len(data) // 4), data))
    Path(argv[4]).write_text(json.dumps(dict(format_version=1, status='passed',
        mode='read', board=board, address=0x10000000, count=len(words),
        flash_written=False, words=words, helper_source_sha256=BOARD.common.helper_source_hash())))


def helper_fixture_command(run, name, argv, answer, *, board, probe):
    """Mock only the helper process; Probe still validates the JSON evidence."""
    if '--plan' not in argv:
        return answer
    if run.commands[-1]['status']:
        raise BOARD.Failed('helper read failed')
    if name.endswith('-RP235x_riscv'):
        board = 'rp2350_hazard3'
    elif name.endswith('-RP235x'):
        board = 'rp2350'
    helper_readback(argv, answer, board=board, probe=probe)
    return ''


def console_order(test, board, built, *, mode='ram', hazard=False):
    """Run a simulated board entry point; debug and UART may never overlap."""
    with tempfile.TemporaryDirectory() as tmp:
        elf = Path(tmp) / 'image.elf'
        elf.write_bytes(b'image')
        events = []
        lock = mock.Mock(file=True)
        lock.acquire.return_value = lock
        console = mock.Mock(received=b'', sent=b'')
        console.close.side_effect = lambda: events.append('close')
        pace = board.common.Pace(state=Path(tmp) / 'pace', kernel=lambda _: [])
        argv = ['board.py', '--mode=' + mode, '--refine=refine', '--ram-loader=loader',
                '--probe-rs=probe', '--nm=nm', '--objdump=objdump',
                '--probehive=' + tmp, '--output=' + tmp + '/run', '--cascade=1-1']
        if not hazard and board.__file__.endswith('/rp2040/board.py'):
            argv.remove('--objdump=objdump')
        if not hazard and board.__file__.endswith('/rp2350/board.py'):
            argv.remove('--objdump=objdump')
        with contextlib.ExitStack() as stack:
            def patch(owner, name, **kwargs):
                return stack.enter_context(mock.patch.object(owner, name, **kwargs))
            patch(board.sys, 'argv', new=argv)
            patch(board.common, 'board_preflight')
            patch(board.common, 'place_hubs')
            patch(board.common, 'Pace', return_value=pace)
            patch(board.common, 'rig_lock', return_value=lock)
            patch(board.common, 'shared_bridge', return_value=(None, {}))
            patch(board.common, 'TcpConsole', side_effect=lambda *_:
                  events.append('console') or console)
            patch(board.common, 'ram_load', side_effect=lambda *_:
                  events.append('load') or {'mode': 'warm'})
            patch(board.common, 'elf_sections', return_value=(b'', {'.isr_vector': (0x20000000, 0, 8)}))
            patch(board, 'build', return_value=(elf,) + built)
            patch(board, 'flash', return_value='RP235x')
            patch(board, 'power_cycle', side_effect=lambda *_: events.append('power'))
            patch(board, 'scenario', return_value=({}, {}, 0) if hazard else ({}, {}))
            patch(board, 'cross_check', side_effect=lambda *_:
                  events.append('check') or {})
            if hasattr(board, 'restore_fixed'):
                patch(board, 'restore_fixed')
            patch(board.common, 'finish_boot')
            if hasattr(board, 'pico2'):
                patch(board.pico2, 'boot_location')
                patch(board.pico2, 'refuse_bootsel')
            test.assertEqual(board.main(), 0)
            evidence = json.loads((Path(tmp) / 'run/result.json').read_text())['kernel_usb']
            test.assertEqual(evidence['status'], 'captured')
            test.assertEqual(evidence['lines'], [])
            test.assertGreaterEqual(evidence['until'], evidence['since'])
        if mode == 'ram':
            test.assertLess(events.index('load'), events.index('console'))
            test.assertNotIn('power', events)
        else:
            test.assertLess(events.index('console'), events.index('power'))
            test.assertNotIn('load', events)
        test.assertLess(events.index('close'), events.index('check'))


def startup_order(test, board, *, hazard=False):
    """A boot frame is unavailable until ACK; normal traffic follows it."""
    fields = dict(r=board.CHIP_RESET_HAD_POR, v=board.MTVEC if hazard else board.VECTORS,
                  k=board.CLK_REF_XOSC)
    if hazard:
        fields['a'] = board.MARCHID_HAZARD3
    boot = b'\x02b' + b''.join(b' %s=%08x' % (key.encode(), value)
                                    for key, value in fields.items()) + b'\x03\n'
    class Console:
        def __init__(self):
            self.sent = bytearray()
            self.received = bytearray()
        def send(self, data):
            self.sent += data
            if data == board.STARTUP:
                self.received += boot
            if data == board.GO:
                self.received += b'\x02r\x03\n'
        def wait(self, predicate, *_):
            test.assertTrue(predicate(self.received))
            return bytes(self.received)
    console = Console()
    with mock.patch.object(board, 'report', side_effect=RuntimeError('ready for traffic')):
        with test.assertRaisesRegex(RuntimeError, 'ready for traffic'):
            board.scenario(console, None, 1)
    test.assertEqual(bytes(console.sent), board.STARTUP + board.GO + board.SHARED[:1])
    test.assertEqual(board.echo_of(console.received), b'')


def startup_retry(test, board):
    """The first ACK is lost before UART setup; retries stay out of payload."""
    class Console:
        def __init__(self):
            self.sent = bytearray()
            self.received = bytearray()
        def send(self, data):
            self.sent += data
            if data == board.STARTUP and len(self.sent) > 1:
                self.received += b'\x02b r=00000001\x03\n'
            if data == board.GO:
                self.received += b'\x02r\x03\n'
        def wait(self, predicate, *_):
            if predicate(self.received):
                return bytes(self.received)
            raise board.Failed('waiting for frame')
    console = Console()
    _, prefix = board.startup(console)
    test.assertEqual(console.sent, board.STARTUP * 2 + board.GO)
    test.assertEqual(prefix, 3)
    test.assertEqual(board.echo_of(console.received), b'')
    with mock.patch.object(console, 'wait', side_effect=board.Failed('no board')):
        with test.assertRaisesRegex(board.Failed, 'no board'):
            board.startup(console)
    test.assertEqual(console.sent.count(board.STARTUP), 12)


class Oracle(unittest.TestCase):
    def test_ordinary_stream_waits_for_each_complete_echo_between_frames(self):
        test = self
        class Console:
            def __init__(self):
                self.received = bytearray(b'old\x02t h=00000003\x03\n')
                self.pieces = []
                self.pending = None
            def send(self, piece):
                test.assertIsNone(self.pending, 'another piece overtook its echo')
                test.assertLessEqual(len(piece), 64)
                self.pieces.append(piece)
                self.pending = piece
            def wait(self, predicate, *_):
                test.assertFalse(predicate(bytes(self.received)))
                self.received += self.pending[:-1]
                test.assertFalse(predicate(bytes(self.received)))
                self.received += b'\x02t h=00000003\x03\n' + self.pending[-1:]
                self.pending = None
                test.assertTrue(predicate(bytes(self.received)))
                return bytes(self.received)
        console = Console()
        data = b'abcdefghijklmnopqrstuvwxyz' * 5 + bytes([BOARD.STALL])
        BOARD.send_stream(console, data)
        self.assertEqual(b''.join(console.pieces), data)
        self.assertEqual(list(map(len, console.pieces)), [64, 64, 3])
        self.assertEqual(BOARD.echo_of(console.received), b'old' + data)

    def test_ordinary_stream_stops_on_missing_or_corrupt_echo(self):
        for corrupt in (False, True):
            with self.subTest(corrupt=corrupt):
                console = mock.Mock(received=b'')
                def wait(predicate, *_):
                    if corrupt:
                        answer = b'X' + b'a' * 63
                        self.assertTrue(predicate(answer))
                        return answer
                    self.assertFalse(predicate(b'a' * 63))
                    raise BOARD.Failed('missing final echo byte')
                console.wait.side_effect = wait
                with self.assertRaisesRegex(BOARD.Failed,
                        'echo differs|missing final echo byte'):
                    BOARD.send_stream(console, b'a' * 129)
                console.send.assert_called_once_with(b'a' * 64)

    def test_second_stage_readback_compares_helper_bytes(self):
        stage = bytes(range(256))
        for actual in (stage, stage[:-1] + b'\x00'):
            with self.subTest(matches=actual == stage), tempfile.TemporaryDirectory() as tmp:
                class Run:
                    out = Path(tmp)
                    def command(self, name, argv, **_):
                        if name == 'flash-readback':
                            helper_readback(argv, actual, board='rp2040', probe='slot0')
                        else:
                            self.assert_download = argv
                        return ''
                run = Run()
                args = SimpleNamespace(probe_rs='probe-rs', probe='slot0', ram_loader='ram-loader',
                    pace=mock.Mock(), guard_serial='arty', cascade='1-1',
                    hub_group=None, hub='1-1.3.3', hub_seconds=0)
                with mock.patch.object(BOARD.common, 'paced', side_effect=lambda pace, what, action, *rest: action()), \
                        mock.patch.object(BOARD.common, 'wait_for_hub'):
                    if actual == stage:
                        self.assertEqual(BOARD.flash(run, args, 'image.elf', stage), stage)
                    else:
                        with self.assertRaisesRegex(BOARD.Failed, 'second stage'):
                            BOARD.flash(run, args, 'image.elf', stage)
                self.assertIn('download', run.assert_download)

    def test_uart_opens_after_ram_loading_and_before_boot_power(self):
        for mode in ('ram', 'boot'):
            with self.subTest(mode=mode):
                console_order(self, BOARD, (b'', 0, {}), mode=mode)

    def test_startup_ack_precedes_boot_frame_and_application_traffic(self):
        startup_order(self, BOARD)

    def test_startup_retries_a_lost_ack_with_a_bounded_wait(self):
        startup_retry(self, BOARD)
    def test_default_ram_run_builds_before_lock_and_never_flashes_or_cycles_power(self):
        with tempfile.TemporaryDirectory() as tmp:
            elf = Path(tmp) / 'image.elf'
            elf.write_bytes(b'image')
            events = []
            lock = mock.Mock(file=True)
            lock.acquire.side_effect = lambda: events.append('lock') or lock
            def build(*_):
                events.append('build')
                return elf, b'', 0, {}
            console = mock.Mock(received=b'', sent=b'')
            pace = BOARD.common.Pace(state=Path(tmp) / 'pace', kernel=lambda _: [])
            description = SimpleNamespace(returncode=0, stderr='', stdout=json.dumps(dict(
                protocol_version=1, probe_rs_revision=BOARD.common.HELPER_PROBE_REVISION,
                source_sha256=BOARD.common.sha(ROOT / 'environments/boards/ram-run/main.rs'))))
            argv = ['board.py', '--refine=refine', '--ram-loader=loader', '--probe-rs=probe',
                    '--nm=nm', '--probehive=' + tmp, '--output=' + tmp + '/run', '--cascade=1-1']
            with mock.patch.object(BOARD.sys, 'argv', argv), \
                    mock.patch.object(BOARD.common.subprocess, 'run', return_value=description), \
                    mock.patch.object(BOARD.common, 'place_hubs'), \
                    mock.patch.object(BOARD.common, 'Pace', return_value=pace), \
                    mock.patch.object(BOARD.common, 'rig_lock', return_value=lock), \
                    mock.patch.object(BOARD, 'build', side_effect=build), \
                    mock.patch.object(BOARD, 'flash') as flash, \
                    mock.patch.object(BOARD, 'power_cycle') as cycle, \
                    mock.patch.object(BOARD.common, 'shared_bridge', return_value=(None, {})), \
                    mock.patch.object(BOARD.common, 'TcpConsole', return_value=console), \
                    mock.patch.object(BOARD.common, 'ram_load', return_value={'mode': 'warm'}) as load, \
                    mock.patch.object(BOARD.common, 'elf_sections', return_value=(b'', {'.isr_vector': (0x20000000, 0, 8)})), \
                    mock.patch.object(BOARD, 'scenario', return_value=({}, {})), \
                    mock.patch.object(BOARD, 'cross_check', return_value={}):
                self.assertEqual(BOARD.main(), 0)
            self.assertEqual(events, ['build', 'lock'])
            flash.assert_not_called()
            cycle.assert_not_called()
            load.assert_called_once()

    def test_the_checksum_is_the_boot_rom_s(self):
        # CRC-32/MPEG-2's check value, the parameters RP2040's datasheet
        # gives in 2.8.1.3.1.
        self.assertEqual(BOARD.crc32_mpeg2(b'123456789'), 0x0376E6E7)
        self.assertEqual(BOARD.crc32_mpeg2(b''), 0xFFFFFFFF)

    def test_frames_are_found_between_echoed_bytes(self):
        stream = b'ab\x02t h=0000000a g=00000004\x03\ncd\x02b r=00000100\x03\n'
        found, echo = BOARD.frames(stream)
        self.assertEqual(found, [('t', {'h': 10, 'g': 4}), ('b', {'r': 0x100})])
        self.assertEqual(echo, b'abcd')

    def test_a_frame_still_arriving_is_left_out(self):
        stream = b'ab\x02t h=0000000a\x03\ncd\x02t h=000'
        self.assertEqual(BOARD.frames_safe(stream), [('t', {'h': 10})])
        self.assertEqual(BOARD.echo_of(stream), b'abcd')

    def args(self, hub):
        return SimpleNamespace(hub='7-2.3.3', port=1, guard_serial='210319B3E738',
                               cascade='7-2', off_seconds=0, hub_seconds=0,
                               pace=Paced(hub.calls))

    def test_the_hub_is_switched_only_while_the_arty_is_off_the_cascade(self):
        for where in ('7-2.3.3.4', None):
            hub = Hub(STATUS)
            with mock.patch.object(BOARD.common, 'device_location', return_value=where), \
                    self.assertRaises(BOARD.Failed):
                BOARD.power_cycle(hub, self.args(hub))
            self.assertEqual(hub.calls, [])
        hub = Hub(STATUS)
        with mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4'):
            BOARD.power_cycle(hub, self.args(hub))
        # D725: paced, and the hub listing again before anything else.
        self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'power-cycle',
                                     'after power cycle', 'hub-wait'])

    def test_a_hub_that_does_not_list_again_stops_the_run(self):
        hub = Hub(STATUS)
        hub.status = ''
        with mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4'), \
                self.assertRaisesRegex(BOARD.Failed, 'did not list within'):
            BOARD.power_cycle(hub, self.args(hub))


class LockLifecycle(unittest.TestCase):
    def run_boot(self, *, borrowed=False, failure=None, acquire_fails=False):
        """Exercise cleanup through the entry point and the real restoration guard."""
        with tempfile.TemporaryDirectory() as tmp:
            elf = Path(tmp) / 'image.elf'
            elf.write_bytes(b'image')
            fixed = Path(tmp) / 'fixed.elf'
            fixed.write_bytes(b'resident')
            events, hardware = [], []
            lock = mock.Mock(file=None)
            def acquire():
                events.append('acquire')
                if acquire_fails:
                    raise BOARD.Failed('rig is busy')
                if not borrowed:
                    lock.file = object()
                return lock
            lock.acquire.side_effect = acquire
            lock.release.side_effect = lambda: events.append('release')
            pace = BOARD.common.Pace(state=Path(tmp) / 'pace', kernel=lambda _: [])
            console = mock.Mock(received=b'', sent=b'')
            argv = ['board.py', '--mode=boot', '--refine=refine', '--probe-rs=probe',
                    '--nm=nm', '--output=' + tmp + '/run', '--fixed-image=' + str(fixed),
                    '--cascade=1-1']
            argv += ['--probehive=' + tmp]
            built = (elf, b'', 0, {})
            def scenario(*_):
                if failure == 'cancel':
                    # What the handler records before it raises.
                    BOARD.common.CANCELLATION = dict(signal='SIGTERM', received=1.0)
                    pace.last_action = 'power cycle'
                    raise BOARD.common.Cancelled('SIGTERM')
                if failure == 'usb':
                    pace.blocked = 'xhci_hcd: HC died'
                    raise BOARD.common.USBGuardError(pace.blocked)
                if failure:
                    raise BOARD.Failed('application did not answer')
                return ({}, {})
            with contextlib.ExitStack() as stack:
                def patch(owner, name, **kwargs):
                    return stack.enter_context(mock.patch.object(owner, name, **kwargs))
                patch(BOARD.sys, 'argv', new=argv)
                patch(BOARD.common, 'board_preflight')
                patch(BOARD.common, 'place_hubs')
                patch(BOARD.common, 'Pace', return_value=pace)
                patch(BOARD.common, 'rig_lock', return_value=lock)
                patch(BOARD.common, 'elf_sections', return_value=(b'', {'.isr_vector': (0x20000000, 0, 8)}))
                patch(BOARD, 'build', return_value=built)
                hardware.append(patch(BOARD, 'flash'))
                hardware.append(patch(BOARD, 'power_cycle'))
                hardware.append(patch(BOARD, 'cross_check', return_value={}))
                hardware.append(patch(BOARD.common, 'shared_bridge', return_value=(None, {})))
                hardware.append(patch(BOARD.common, 'TcpConsole', return_value=console))
                hardware.append(patch(BOARD, 'scenario', side_effect=scenario))
                restore = patch(BOARD, 'restore_fixed', side_effect=lambda *_:
                    events.append('restore') or {'value': BOARD.common.FIXED_READY_MAGIC})
                patch(BOARD.common, 'CANCELLATION', new=None)
                try:
                    status = BOARD.main()
                except KeyboardInterrupt:
                    status = 'cancelled'
                result = json.loads((Path(tmp) / 'run/result.json').read_text())
            return status, result, events, restore, hardware

    def test_boot_cleanup_uses_successful_acquisition_for_owned_and_borrowed_locks(self):
        for borrowed, failure, acquire_fails in (
                (False, None, False), (True, None, False), (True, 'app', False),
                (True, 'usb', False), (True, None, True)):
            with self.subTest(borrowed=borrowed, failure=failure, acquire_fails=acquire_fails):
                status, result, events, restore, hardware = self.run_boot(
                    borrowed=borrowed, failure=failure, acquire_fails=acquire_fails)
                self.assertEqual(status, int(bool(failure or acquire_fails)))
                if acquire_fails:
                    for action in hardware:
                        action.assert_not_called()
                    restore.assert_not_called()
                    self.assertNotIn('fixed_restore', result)
                elif failure == 'usb':
                    restore.assert_not_called()
                    self.assertEqual(result['fixed_restore']['status'], 'pending')
                    self.assertIn('HC died', result['fixed_restore']['reason'])
                else:
                    restore.assert_called_once()
                    self.assertEqual(result['fixed_restore']['status'], 'passed')
                    self.assertLess(events.index('restore'), events.index('release'))
                self.assertEqual(result['outcome'], {None: 'passed', 'app': 'failed', 'usb': 'usb-stopped'}[
                    failure] if not acquire_fails else 'failed')

    def test_a_cancelled_boot_check_releases_the_lock_and_records_where_it_stopped(self):
        status, result, events, restore, hardware = self.run_boot(failure='cancel')
        self.assertEqual(status, 'cancelled')
        restore.assert_not_called()
        self.assertEqual(events, ['acquire', 'release'])
        self.assertEqual((result['status'], result['outcome']), ('failed', 'cancelled'))
        self.assertEqual(result['cancelled']['signal'], 'SIGTERM')
        self.assertEqual(result['cancelled']['phase'], dict(action='power cycle'))
        self.assertEqual(result['fixed_restore'], dict(
            status='pending', reason='cancelled before resident image restoration'))
        self.assertIn('cancelled by SIGTERM', result['failure'])
        self.assertIn('kernel_usb', result)


if __name__ == '__main__':
    unittest.main()
