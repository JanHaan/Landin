#!/usr/bin/env python3
"""Controls for the RP2350 board tool's oracle, without a board (D655): the
IMAGE_DEF block it expects, the corrupted copy of its negative control and
that control's reading of the hub, the hub's guard while the Pico 2 does
not enumerate, and the framing and accounting it shares with the RP2040's."""
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

SERIAL = 'E661A4D4171B5D2E'
GUARD = '  Port 4: 0503 power highspeed enable connect [0403:6010 Digilent Digilent USB Device 210319B3E738]\n'
QUIET = ('Current status for hub 7-2.3.3 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]\n'
         '  Port 1: 0100 power\n  Port 2: 0101 power connect\n  Port 3: 0100 power\n' + GUARD)
BOOTSEL = QUIET.replace('  Port 2: 0101 power connect\n',
                        '  Port 2: 0103 power enable connect [2e8a:000f Raspberry Pi RP2350 %s]\n' % SERIAL)


class Recorded:
    """A tool's commands: every call kept, each name answered."""
    def __init__(self, **answers):
        self.answers, self.calls = answers, []

    def command(self, name, argv, **_):
        self.calls.append(name)
        answer = self.answers.get(name, '')
        if isinstance(answer, list):
            return answer.pop(0) if len(answer) > 1 else answer[0]
        return answer


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
            probe='0000:0002:10.42.0.50/1')


class Hub(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_port_holding_no_device_or_the_pico_2_is_switched(self):
        args = SimpleNamespace(**ARGS)
        for status in (QUIET, BOOTSEL):
            hub = Recorded(**{'hub-status': status})
            BOARD.power_cycle(hub, args)
            self.assertEqual(hub.calls, ['hub-status', 'power-cycle'])

    def test_a_port_holding_another_device_is_not(self):
        args = SimpleNamespace(**ARGS)
        hub = Recorded(**{'hub-status': BOOTSEL.replace(SERIAL, 'SOMEONE-ELSE')})
        with self.assertRaises(BOARD.Failed):
            BOARD.power_cycle(hub, args)
        self.assertEqual(hub.calls, ['hub-status'])

    def test_nothing_is_switched_while_the_arty_is_on_the_cascade_or_absent(self):
        args = SimpleNamespace(**ARGS)
        for where in ('7-2.3.3.4', None):
            hub = Recorded(**{'hub-status': QUIET})
            with mock.patch.object(BOARD.common, 'device_location', return_value=where), \
                    self.assertRaises(BOARD.Failed):
                BOARD.power_cycle(hub, args)
            self.assertEqual(hub.calls, [])


class Control(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def control(self, after):
        args = SimpleNamespace(**ARGS)
        head = struct.pack('<%dI' % (BOARD.VECTOR_WORDS + 5),
                           *([0x20082000] + [0x10000201] * 67 + list(BOARD.IMAGE_DEF)))
        bad = head[:-4] + struct.pack('<I', 0xab123579 ^ 0xffffffff)
        line = ' '.join('%08x' % w for w in struct.unpack('<%dI' % (len(bad) // 4), bad))
        run = Recorded(**{'hub-status': QUIET, 'flash-readback': '0x10000000: ' + line,
                          'hub-after-corrupt': after})
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(image(BOARD.IMAGE_DEF))
            run.out = Path(out)
            with mock.patch.object(BOARD.time, 'sleep'):
                return run, BOARD.block_control(run, args, path, head)

    def test_a_refused_block_leaves_the_board_in_bootsel(self):
        run, verdict = self.control([QUIET, BOOTSEL])
        self.assertEqual(verdict['enumerated'], '2e8a:000f Raspberry Pi RP2350 ' + SERIAL)
        self.assertEqual(run.calls, ['flash', 'flash-readback', 'hub-status', 'power-cycle',
                                     'hub-after-corrupt', 'hub-after-corrupt'])

    def test_a_board_that_boots_the_corrupted_image_fails_the_control(self):
        with self.assertRaisesRegex(BOARD.Failed, 'did not enumerate as BOOTSEL'):
            self.control([QUIET])


class Framing(unittest.TestCase):
    def test_frames_and_echo_are_the_shared_reading(self):
        stream = b'1\x02t h=00000001 p=0000001e\x03\n'
        self.assertEqual(BOARD.frames_safe(stream), [('t', {'h': 1, 'p': 30})])
        self.assertEqual(BOARD.echo_of(stream), b'1')
        self.assertEqual(BOARD.USBCTRL_SLOT, 30)
        self.assertEqual(BOARD.CHIP_RESET_HAD_POR, 1 << 16)


if __name__ == '__main__':
    unittest.main()
