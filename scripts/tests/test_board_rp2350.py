#!/usr/bin/env python3
"""Controls for the RP2350 board tool's oracle, without a board (D655): the
IMAGE_DEF block it expects, the corrupted copy of its negative control and
that control's reading of the hub, the hub's guard while the Pico 2 does
not enumerate, the pace and the wait for the hub around each download and
cycle, every download as RP235x followed at once by a cycle (D712,
D832), and the
framing and accounting it shares with the RP2040's."""
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BOARD = load('board_rp2350', 'environments/boards/rp2350/board.py')
ELF = load('test_board_common', 'scripts/tests/test_board_common.py').elf32
HANDSHAKE = load('test_rp_startup', 'scripts/tests/test_board_rp2040.py')

SERIAL = 'E661A4D4171B5D2E'
GUARD = '  Port 4: 0503 power highspeed enable connect [0403:6010 Digilent Digilent USB Device 210319B3E738]\n'
QUIET = ('Current status for hub 7-2.3.3 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]\n'
         '  Port 1: 0100 power\n  Port 2: 0101 power connect\n  Port 3: 0100 power\n' + GUARD)
BOOTSEL = QUIET.replace('  Port 2: 0101 power connect\n',
                        '  Port 2: 0103 power enable connect [2e8a:000f Raspberry Pi RP2350 %s]\n' % SERIAL)


class Startup(unittest.TestCase):
    def test_uart_opens_after_ram_loading_and_before_boot_power(self):
        for mode in ('ram', 'boot'):
            with self.subTest(mode=mode):
                HANDSHAKE.console_order(self, BOARD, (b'', {}), mode=mode)

    def test_startup_ack_precedes_boot_frame_and_application_traffic(self):
        HANDSHAKE.startup_order(self, BOARD)

    def test_startup_retries_a_lost_ack_with_a_bounded_wait(self):
        HANDSHAKE.startup_retry(self, BOARD)


class Paced:
    """A pace that records each action it spaces."""
    def __init__(self, calls):
        self.calls = calls

    def before(self, what):
        self.calls.append('before ' + what)

    def after(self, what):
        self.calls.append('after ' + what)


class Recorded:
    """A tool's commands: every call kept, each name answered, and each
    status recorded as Run records it."""
    def __init__(self, statuses=None, **answers):
        self.answers, self.statuses, self.calls, self.commands = answers, statuses or {}, [], []

    def command(self, name, argv, **_):
        self.calls.append(name)
        self.commands.append(dict(name=name, status=self.statuses.get(name, 0)))
        answer = self.answers.get(name, bytes(4) if name.startswith(('attach-', 'reattach-')) else '')
        if isinstance(answer, list):
            answer = answer.pop(0) if len(answer) > 1 else answer[0]
        return HANDSHAKE.helper_fixture_command(self, name, argv, answer,
            board='rp2350', probe=ARGS['probe'])


def image(block):
    vectors = struct.pack('<%dI' % BOARD.VECTOR_WORDS, *([0x20082000] + [0x10000201] * 67))
    words = struct.pack('<5I', *block)
    return ELF([('.isr_vector', BOARD.VECTORS, vectors),
                ('.embedded_block', BOARD.VECTORS + len(vectors), words)],
               [(BOARD.VECTORS, '.isr_vector'), (BOARD.VECTORS + len(vectors), '.embedded_block')])


class Block(unittest.TestCase):
    def test_the_expected_block_is_the_datasheet_s_minimum_arm_image_def(self):
        # 5.9.5.1, Table 503: IMAGE_TYPE is item type 0x42, one word, its
        # flags 0x1021 above; LAST is type 0x7f with the size flag, 0xff,
        # then the other items' one word; the link to itself is zero.
        image_type = 0x42 | 1 << 8 | 0x1021 << 16
        last = 0xff | 1 << 8
        self.assertEqual(BOARD.IMAGE_DEF, (0xffffded3, image_type, last, 0, 0xab123579))

    def test_the_corrupted_copy_differs_in_its_end_marker_alone(self):
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(image(BOARD.IMAGE_DEF))
            run = SimpleNamespace(out=Path(out))
            bad = BOARD.corrupted(run, path)
            good_bytes, bad_bytes = path.read_bytes(), bad.read_bytes()
            self.assertEqual(len(good_bytes), len(bad_bytes))
            differ = [i for i, (a, b) in enumerate(zip(good_bytes, bad_bytes)) if a != b]
            self.assertEqual(len(differ), 4)
            data, sections = BOARD.elf_sections(bad)
            self.assertEqual(BOARD.block_of(data, sections)[2][-1], 0xab123579 ^ 0xffffffff)
            self.assertEqual(BOARD.block_of(data, sections)[2][:-1], BOARD.IMAGE_DEF[:-1])

    def test_a_block_of_another_size_is_refused(self):
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(ELF([('.embedded_block', 0x10000110, bytes(16))],
                                 [(0x10000110, '.embedded_block')]))
            data, sections = BOARD.elf_sections(path)
            with self.assertRaises(BOARD.Failed):
                BOARD.block_of(data, sections)


ARGS = dict(hub='7-2.3.3', port=2, guard_serial='210319B3E738', cascade='7-2', off_seconds=0,
            pico_serial=SERIAL, hub_group=None, enumerate_seconds=1.0, probe_rs='probe-rs',
            probe='0000:0002:10.42.0.50/1', guard_seconds=0, boot_seconds=0,
            bootsel_attach=False, probe_host='10.42.0.50', ram_loader='ram-loader')
PING = '1 packets transmitted, 1 received, 0% packet loss, time 0ms\n'


def paced_args(run, **more):
    """ARGS with a pace that records into RUN's calls."""
    return SimpleNamespace(**dict(ARGS, pace=Paced(run.calls), **more))


def answers(**more):
    """The answers a clean guarded cycle gets."""
    found = {'hub-status': QUIET, 'hub-wait': QUIET, 'probe-ping': PING,
             'hub-before-attach': QUIET}
    found.update(more)
    return found


class Hub(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_port_holding_no_device_or_the_pico_2_is_switched(self):
        for status in (QUIET, BOOTSEL):
            hub = Recorded(**answers(**{'hub-status': status}))
            BOARD.power_cycle(hub, paced_args(hub))
            self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'power-cycle',
                                         'after power cycle', 'hub-wait', 'probe-ping'])

    def test_a_port_holding_another_device_is_not(self):
        hub = Recorded(**answers(**{'hub-status': BOOTSEL.replace(SERIAL, 'SOMEONE-ELSE')}))
        with self.assertRaises(BOARD.Failed):
            BOARD.power_cycle(hub, paced_args(hub))
        self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'after power cycle'])

    def test_nothing_is_switched_while_the_arty_is_on_the_cascade_or_absent(self):
        for where in ('7-2.3.3.4', None):
            hub = Recorded(**answers())
            with mock.patch.object(BOARD.common, 'device_location', return_value=where), \
                    self.assertRaises(BOARD.Failed):
                BOARD.power_cycle(hub, paced_args(hub))
            self.assertEqual(hub.calls, [])

    def test_the_cycle_waits_for_the_hub_to_list_again(self):
        hub = Recorded(**answers(**{'hub-wait': ['', QUIET]}))
        with mock.patch.object(BOARD.common.time, 'sleep'):
            BOARD.power_cycle(hub, paced_args(hub, guard_seconds=5))
        self.assertEqual(hub.calls.count('hub-wait'), 2)


class Control(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.output = Path(directory.name)
        output = mock.patch.object(Recorded, 'out', self.output, create=True)
        output.start()
        self.addCleanup(output.stop)
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def head(self):
        return struct.pack('<%dI' % (BOARD.VECTOR_WORDS + 5),
                           *([0x20082000] + [0x10000201] * 67 + list(BOARD.IMAGE_DEF)))

    def readback(self, head):
        return head

    def control(self, after, bootsel_attach=True):
        head = self.head()
        bad = head[:-4] + struct.pack('<I', 0xab123579 ^ 0xffffffff)
        run = Recorded(**answers(**{'flash-readback': self.readback(bad),
                                    'hub-after-corrupt': after}))
        args = paced_args(run, bootsel_attach=bootsel_attach)
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(image(BOARD.IMAGE_DEF))
            run.out = Path(out)
            with mock.patch.object(BOARD.time, 'sleep'):
                return run, BOARD.block_control(run, args, path, head)

    def test_a_refused_block_leaves_the_board_in_bootsel(self):
        run, verdict = self.control([QUIET, BOOTSEL])
        self.assertEqual(verdict['enumerated'], '2e8a:000f Raspberry Pi RP2350 ' + SERIAL)
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'before download',
                                     'flash', 'after download', 'hub-status', 'power-cycle',
                                     'after power cycle at once', 'hub-wait', 'probe-ping',
                                     'hub-after-corrupt', 'hub-after-corrupt'])

    def test_the_corrupted_image_s_download_is_cycled_before_anything_reaches_the_chip(self):
        # D832: probe-rs's RP235x reset leaves BOOTSEL's USB on the bus with
        # its core halted, so the cycle comes straight after the download,
        # unpaced but recorded, and no probe-rs attaches or reads the chip
        # from the download to the end of the control.
        run, _ = self.control([QUIET, BOOTSEL])
        after = run.calls[run.calls.index('after download') + 1:]
        self.assertEqual(after[:3], ['hub-status', 'power-cycle', 'after power cycle at once'])
        self.assertNotIn('before power cycle', run.calls)
        self.assertFalse([c for c in after if 'attach' in c or 'read' in c or c == 'flash'])

    def test_a_board_that_boots_the_corrupted_image_fails_the_control(self):
        with self.assertRaisesRegex(BOARD.Failed, 'did not enumerate as BOOTSEL'):
            self.control([QUIET])

    def test_the_control_needs_leave_to_attach_in_bootsel(self):
        # D712: the good image is flashed again from BOOTSEL.
        with self.assertRaisesRegex(BOARD.Failed, '--bootsel-attach'):
            self.control([BOOTSEL], bootsel_attach=False)

    def test_even_explicit_bootsel_attach_is_refused_before_any_probe_command(self):
        run = Recorded(**answers(**{'hub-before-attach': BOOTSEL}))
        with self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.flash(run, paced_args(run, bootsel_attach=True), 'board.elf', b'')
        self.assertEqual(run.calls, ['hub-before-attach'])

    def test_every_download_as_rp235x_is_cycled_at_once_before_the_head_is_read(self):
        # D832: the download's own reset left BOOTSEL's USB device halted on
        # the bus; the cycle precedes any wait for the hub and any attach,
        # and the head is read back from the booted image.
        head = self.head()
        run = Recorded(**answers(**{'flash-readback': self.readback(head)}))
        run.out = self.output
        with mock.patch.object(BOARD.time, 'sleep'):
            self.assertEqual(BOARD.flash(run, paced_args(run), 'board.elf', head), 'RP235x')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'before download',
                                     'flash', 'after download', 'hub-status', 'power-cycle',
                                     'after power cycle at once', 'hub-wait', 'probe-ping',
                                     'hub-before-attach', 'reattach-RP235x', 'flash-readback'])

    def test_a_board_left_running_a_risc_v_image_is_flashed_through_its_side(self):
        # D712: a RISC-V image gates the Arm access ports, so RP235x meets a
        # FAULT; the Arm image is flashed as RP235x_riscv, booted by a paced
        # cycle and read back from the Arm cores.
        head = self.head()
        run = Recorded(statuses={'attach-RP235x': 1},
                       **answers(**{'flash-readback': self.readback(head)}))
        run.out = self.output
        with mock.patch.object(BOARD.time, 'sleep'):
            self.assertEqual(BOARD.flash(run, paced_args(run), 'board.elf', head),
                             'RP235x_riscv')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'attach-RP235x_riscv',
                                     'before download', 'flash', 'after download',
                                     'before power cycle', 'hub-status', 'power-cycle',
                                     'after power cycle', 'hub-wait', 'probe-ping',
                                     'hub-before-attach', 'reattach-RP235x', 'flash-readback'])

    def test_nothing_attaches_while_the_pico_2_is_in_bootsel(self):
        run = Recorded(**answers(**{'hub-before-attach': BOOTSEL}))
        with self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.flash(run, paced_args(run), 'board.elf', self.head())
        self.assertEqual(run.calls, ['hub-before-attach'])
        # Allowed to attach, it never reads back while BOOTSEL still shows.
        run = Recorded(**answers(**{'hub-before-attach': BOOTSEL}))
        with mock.patch.object(BOARD.time, 'sleep'), \
                self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.flash(run, paced_args(run, bootsel_attach=True), 'board.elf', self.head())
        self.assertNotIn('flash-readback', run.calls)


class Framing(unittest.TestCase):
    def test_frames_and_echo_are_the_shared_reading(self):
        stream = b'1\x02t h=00000001 p=0000001e\x03\n'
        self.assertEqual(BOARD.frames_safe(stream), [('t', {'h': 1, 'p': 30})])
        self.assertEqual(BOARD.echo_of(stream), b'1')
        self.assertEqual(BOARD.USBCTRL_SLOT, 30)
        self.assertEqual(BOARD.CHIP_RESET_HAD_POR, 1 << 16)


if __name__ == '__main__':
    unittest.main()
