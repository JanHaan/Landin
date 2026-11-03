#!/usr/bin/env python3
"""Controls for the RP2350 Hazard3 board tool's oracle, without a board
(D711): the RISC-V IMAGE_DEF block it expects, its reading of the entry
word and the trap table, the amoadd.w it requires, which chip name it
attaches as, the corrupted copy of its negative control, the hub's guard,
and the boot frame and the AMO's results as the scenario reads them."""
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


BOARD = load('board_rp2350_hazard3', 'environments/boards/rp2350_hazard3/board.py')
ELF = load('test_board_common', 'scripts/tests/test_board_common.py').elf32

GUARD = '  Port 4: 0503 power highspeed enable connect [0403:6010 Digilent Digilent USB Device 210319B3E738]\n'
QUIET = ('Current status for hub 7-2.3.3 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]\n'
         '  Port 1: 0100 power\n  Port 2: 0100 power\n  Port 3: 0100 power\n' + GUARD)
BOOTSEL = QUIET.replace('  Port 2: 0100 power\n',
                        '  Port 2: 0103 power enable connect [2e8a:000f]\n')

RESET, EXTERNAL, UNHANDLED = 0x10000390, 0x10000324, 0x10000434
HANDLER_AT = {'timer_irq': 0x10000674, 'dma_irq': 0x10000928, 'usb_irq': 0x100007cc}
NAMES = dict(HANDLER_AT, _landin_firmware_reset=RESET, _landin_firmware_external=EXTERNAL,
             _landin_firmware_unhandled=UNHANDLED, reports=0x20000520)
FIRMWARE = dict(vector_address=BOARD.TABLE, vector_words=BOARD.VECTOR_WORDS,
                image_block=dict(address=BOARD.TABLE + 4 * BOARD.VECTOR_WORDS))


class Paced:
    """A pace that records each action it spaces."""
    def __init__(self, calls=None):
        self.calls = calls if calls is not None else []

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
        answer = self.answers.get(name, '')
        if isinstance(answer, list):
            return answer.pop(0) if len(answer) > 1 else answer[0]
        return answer


def jal(at, target):
    """`jal x0, TARGET` placed at AT, as the assembler encodes it."""
    offset = (target - at) & 0x1fffff
    return (((offset >> 20) & 1) << 31 | ((offset >> 1) & 0x3ff) << 21
            | ((offset >> 11) & 1) << 20 | ((offset >> 12) & 0xff) << 12 | 0x6f)


def table(slots=None):
    slots = slots or {}
    words = []
    for slot in range(BOARD.VECTOR_WORDS):
        target = slots.get(slot, EXTERNAL if slot == 11 else
                           HANDLER_AT.get(BOARD.HANDLERS.get(slot), UNHANDLED))
        words.append(jal(BOARD.TABLE + 4 * slot, target))
    return struct.pack('<%dI' % len(words), *words)


def image(block=BOARD.IMAGE_DEF, entry=None, vectors=None, machine=243):
    entry = struct.pack('<I', jal(BOARD.FLASH, RESET) if entry is None else entry)
    vectors = table() if vectors is None else vectors
    at = BOARD.TABLE + len(vectors)
    data = bytearray(ELF([('.landin_entry', BOARD.FLASH, entry),
                          ('.isr_vector', BOARD.TABLE, vectors),
                          ('.embedded_block', at, struct.pack('<5I', *block))],
                         [(BOARD.FLASH, '.landin_entry'), (BOARD.TABLE, '.isr_vector'),
                          (at, '.embedded_block')]))
    struct.pack_into('<H', data, 0x12, machine)
    return bytes(data)


class Block(unittest.TestCase):
    def test_the_expected_block_is_the_datasheet_s_minimum_risc_v_image_def(self):
        # 5.9.5.1, Table 503: IMAGE_TYPE is item type 0x42, one word, its
        # flags 0x1101: EXE, RISC-V in CPU bits 10:8, RP2350 in 14:12; LAST
        # is type 0x7f with the size flag, 0xff, then the other items' one
        # word; the link to itself is zero.
        flags = 1 | 1 << 8 | 1 << 12
        self.assertEqual(flags, 0x1101)
        image_type = 0x42 | 1 << 8 | flags << 16
        last = 0xff | 1 << 8
        self.assertEqual(BOARD.IMAGE_DEF, (0xffffded3, image_type, last, 0, 0xab123579))

    def test_the_corrupted_copy_differs_in_its_end_marker_alone(self):
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(image())
            bad = BOARD.corrupted(SimpleNamespace(out=Path(out)), path)
            differ = [i for i, (a, b) in enumerate(zip(path.read_bytes(), bad.read_bytes()))
                      if a != b]
            self.assertEqual(len(differ), 4)
            data, sections = BOARD.elf_sections(bad)
            self.assertEqual(BOARD.block_of(data, sections)[2][-1], 0xab123579 ^ 0xffffffff)


class Layout(unittest.TestCase):
    def check(self, data, names=NAMES, firmware=FIRMWARE):
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(data)
            return BOARD.check_layout(path, names, firmware)

    def test_jumps_are_decoded_as_the_assembler_encodes_them(self):
        for at, target in ((0x10000000, 0x10000390), (0x10000240, 0x10000674),
                           (0x10000278, 0x10000200), (0x10000000, 0x100ffffe)):
            self.assertEqual(BOARD.jal_target(jal(at, target), at), target)
        # The linked image's own words: j to reset, slot 11 and slot 30.
        self.assertEqual(BOARD.jal_target(0x3900006f, 0x10000000), 0x10000390)
        self.assertEqual(BOARD.jal_target(0x0f80006f, 0x1000022c), 0x10000324)
        self.assertEqual(BOARD.jal_target(0x5540006f, 0x10000278), 0x100007cc)
        self.assertIsNone(BOARD.jal_target(0x00000013, 0x10000000))
        self.assertIsNone(BOARD.jal_target(0x000000ef, 0x10000000))

    def test_the_head_is_the_entry_word_the_table_and_the_block_in_4_kib(self):
        self.assertEqual(self.check(image()), BOARD.TABLE + 4 * BOARD.VECTOR_WORDS)
        self.assertLessEqual(BOARD.TABLE + 4 * BOARD.VECTOR_WORDS + 20, BOARD.FIRST_4K)

    def test_each_departure_is_refused(self):
        cases = [
            (image(machine=40), 'EM_RISCV'),
            (image(entry=jal(BOARD.FLASH, UNHANDLED)), 'jump to reset'),
            (image(entry=0x00000013), 'jump to reset'),
            (image(vectors=table({11: UNHANDLED})), 'slot 11'),
            (image(vectors=table({30: UNHANDLED})), 'slot 30 does not jump to usb_irq'),
            (image(vectors=table({31: HANDLER_AT['usb_irq']})), 'slot 31'),
            (image(vectors=table()[:-4]), 'the table is'),
            (image(block=(0xffffded3, 0x10210142, 0x1ff, 0, 0xab123579)), 'RISC-V IMAGE_DEF'),
        ]
        for data, message in cases:
            with self.assertRaisesRegex(BOARD.Failed, message):
                self.check(data)
        with self.assertRaisesRegex(BOARD.Failed, 'report puts'):
            self.check(image(), firmware=dict(FIRMWARE, vector_address=BOARD.TABLE + 0x100))
        with self.assertRaisesRegex(BOARD.Failed, 'SRAM'):
            self.check(image(), names=dict(NAMES, reports=0x10002000))

    def test_the_amoadd_is_found_in_objdump_s_listing(self):
        listing = ('10002740 <add_u32>:\n'
                   '10002754:\tfd442383          \tlw\tt2,-44(s0)\n'
                   '10002758:\t067322af          \tamoadd.w.aqrl\tt0,t2,(t1)\n'
                   '10002760 <telemetry>:\n'
                   '10002764:\t1b592f2f          \tsc.w.rl\tt5,s5,(s2)\n')
        self.assertEqual(BOARD.amo_adds(listing), [('10002758', 'add_u32')])
        self.assertEqual(BOARD.amo_adds('10002760 <telemetry>:\n'), [])


ARGS = dict(hub='7-2.3.3', port=2, guard_serial='210319B3E738', cascade='7-2', off_seconds=0,
            pico_serial=None, hub_group=None, enumerate_seconds=1.0, boot_seconds=0,
            guard_seconds=0, bootsel_attach=False, probe_host='10.42.0.50',
            probe_rs='probe-rs', probe='0000:0001:127.0.0.1:4442')
PING = '1 packets transmitted, 1 received, 0% packet loss, time 0ms\n'
LOST = '1 packets transmitted, 0 received, 100% packet loss, time 0ms\n'


def paced_args(run, **more):
    """ARGS with a pace that records into RUN's calls."""
    return SimpleNamespace(**dict(ARGS, pace=Paced(run.calls), **more))


def cycling(**more):
    """The answers a clean guarded cycle gets."""
    answers = {'hub-status': QUIET, 'hub-after-cycle': QUIET, 'hub-wait': QUIET,
               'probe-ping': PING, 'hub-before-attach': QUIET}
    answers.update(more)
    return answers


class Attach(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_chip_name_follows_the_architecture_that_answers(self):
        args = SimpleNamespace(**ARGS)
        run = Recorded()
        self.assertEqual(BOARD.attached(run, args, 'attach').chip, 'RP235x')
        run = Recorded(statuses={'attach-RP235x': 1})
        self.assertEqual(BOARD.attached(run, args, 'attach').chip, 'RP235x_riscv')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'attach-RP235x_riscv'])
        run = Recorded(statuses={'attach-RP235x': 1, 'attach-RP235x_riscv': 1})
        with self.assertRaisesRegex(BOARD.Failed, 'neither'):
            BOARD.attached(run, args, 'attach')

    def test_a_flash_through_the_arm_side_boots_the_image_before_reading_back(self):
        head = struct.pack('<2I', 0x3900006f, 0)
        run = Recorded(statuses={'reattach-RP235x': 1}, **cycling(**{
            'flash-readback': '0x10000000: 3900006f 00000000'}))
        args = paced_args(run)
        with mock.patch.object(BOARD.time, 'sleep'):
            self.assertEqual(BOARD.flash(run, args, 'board.elf', head), 'RP235x')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'before download',
                                     'flash', 'after download', 'hub-status', 'power-cycle',
                                     'after power cycle at once', 'hub-wait', 'probe-ping',
                                     'hub-before-attach', 'reattach-RP235x',
                                     'reattach-RP235x_riscv', 'flash-readback'])

    def test_a_flash_from_bootsel_cycles_the_power_at_once(self):
        # D712: the attach halted the boot ROM, so the cycle is not paced,
        # only recorded, and the head is not read back while BOOTSEL shows.
        head = struct.pack('<2I', 0x3900006f, 0)
        run = Recorded(statuses={'reattach-RP235x': 1}, **cycling(**{
            'hub-before-attach': [BOOTSEL, QUIET],
            'flash-readback': '0x10000000: 3900006f 00000000'}))
        args = paced_args(run, bootsel_attach=True)
        with mock.patch.object(BOARD.time, 'sleep'):
            self.assertEqual(BOARD.flash(run, args, 'board.elf', head), 'RP235x')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'before download',
                                     'flash', 'after download', 'hub-status', 'power-cycle',
                                     'after power cycle at once', 'hub-wait', 'probe-ping',
                                     'hub-before-attach', 'reattach-RP235x',
                                     'reattach-RP235x_riscv', 'flash-readback'])
        run = Recorded(**cycling(**{'hub-before-attach': BOOTSEL}))
        with mock.patch.object(BOARD.time, 'sleep'), \
                self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.flash(run, paced_args(run, bootsel_attach=True), 'board.elf', head)
        self.assertNotIn('reattach-RP235x', run.calls)

    def test_a_flash_through_the_risc_v_side_reads_back_at_once(self):
        head = struct.pack('<2I', 0x3900006f, 0)
        run = Recorded(statuses={'attach-RP235x': 1},
                       **cycling(**{'flash-readback': '0x10000000: 3900006f 00000001'}))
        args = paced_args(run)
        with self.assertRaisesRegex(BOARD.Failed, 'flash does not hold'):
            BOARD.flash(run, args, 'board.elf', head)
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'attach-RP235x_riscv',
                                     'before download', 'flash', 'after download',
                                     'hub-wait', 'flash-readback'])

    def test_nothing_attaches_while_the_pico_2_is_in_bootsel(self):
        args = SimpleNamespace(**ARGS)
        run = Recorded(**cycling(**{'hub-before-attach': BOOTSEL}))
        with self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.attached(run, args, 'attach')
        self.assertEqual(run.calls, ['hub-before-attach'])
        args = SimpleNamespace(**dict(ARGS, bootsel_attach=True))
        self.assertEqual(BOARD.attached(Recorded(**cycling(**{'hub-before-attach': BOOTSEL})),
                                        args, 'attach').chip, 'RP235x')

    def block_control(self, **statuses):
        head = struct.pack('<2I', 0x3900006f, 0)
        bad = head[:-4] + struct.pack('<I', BOARD.IMAGE_DEF[-1] ^ 0xffffffff)
        run = Recorded(statuses=statuses, **cycling(**{
            'flash-readback': '0x10000000: ' + ' '.join(
                '%08x' % w for w in struct.unpack('<2I', bad)),
            'hub-after-corrupt': [QUIET, BOOTSEL]}))
        args = paced_args(run, bootsel_attach=True)
        with mock.patch.object(BOARD, 'corrupted', return_value='bad.elf'), \
                mock.patch.object(BOARD.time, 'sleep'):
            return run, BOARD.block_control(run, args, 'board.elf', head)

    def test_a_block_control_flashed_as_rp235x_is_cycled_at_once_and_never_read(self):
        # D832: the download's RP235x reset leaves BOOTSEL halted on the bus.
        run, verdict = self.block_control()
        self.assertEqual(verdict['flashed_as'], 'RP235x')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'before download',
                                     'flash', 'after download', 'hub-status', 'power-cycle',
                                     'after power cycle at once', 'hub-wait', 'probe-ping',
                                     'hub-after-corrupt', 'hub-after-corrupt'])

    def test_a_block_control_flashed_as_rp235x_riscv_is_read_back_before_a_paced_cycle(self):
        run, verdict = self.block_control(**{'attach-RP235x': 1})
        self.assertEqual(verdict['flashed_as'], 'RP235x_riscv')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'attach-RP235x_riscv',
                                     'before download', 'flash', 'after download', 'hub-wait',
                                     'flash-readback', 'before power cycle', 'hub-status',
                                     'power-cycle', 'after power cycle', 'hub-wait',
                                     'probe-ping', 'hub-after-corrupt', 'hub-after-corrupt'])

    def test_the_block_control_needs_leave_to_attach_in_bootsel(self):
        run = Recorded(**cycling())
        with self.assertRaisesRegex(BOARD.Failed, '--bootsel-attach'):
            BOARD.block_control(run, SimpleNamespace(**ARGS), 'board.elf', b'')
        self.assertEqual(run.calls, [])


class Hub(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_only_a_hub_the_arty_is_off_is_switched(self):
        hub = Recorded(**cycling())
        BOARD.power_cycle(hub, paced_args(hub))
        self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'power-cycle',
                                     'after power cycle', 'hub-wait', 'probe-ping'])
        for where in ('7-2.3.3.4', None):
            hub = Recorded(**cycling())
            with mock.patch.object(BOARD.common, 'device_location', return_value=where), \
                    self.assertRaises(BOARD.Failed):
                BOARD.power_cycle(hub, paced_args(hub))
            self.assertEqual(hub.calls, [])

    def test_a_listing_that_meets_the_tree_gone_is_asked_again(self):
        class Flaky(Recorded):
            def command(self, name, argv, **kw):
                answer = super().command(name, argv, **kw)
                if name == 'hub-status' and self.calls.count('hub-status') < 3:
                    raise BOARD.Failed('hub-status failed (1)')
                return answer
        hub = Flaky(**cycling())
        with mock.patch.object(BOARD.time, 'sleep'):
            BOARD.power_cycle(hub, paced_args(hub, guard_seconds=5))
        self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'hub-status',
                                     'hub-status', 'power-cycle', 'after power cycle',
                                     'hub-wait', 'probe-ping'])
        hub = Flaky(**cycling())
        with self.assertRaisesRegex(BOARD.Failed, 'hub-status failed'):
            BOARD.power_cycle(hub, paced_args(hub))

    def test_a_pace_that_refuses_stops_the_cycle_before_the_hub_is_read(self):
        class Refusing(Paced):
            def before(self, what):
                raise BOARD.Failed('the kernel logged USB trouble since the last action')
        hub = Recorded(**cycling())
        with self.assertRaisesRegex(BOARD.Failed, 'USB trouble'):
            BOARD.power_cycle(hub, SimpleNamespace(**dict(ARGS, pace=Refusing())))
        self.assertEqual(hub.calls, [])

    def test_a_cycle_that_loses_the_arty_or_the_probe_stops_the_run(self):
        with mock.patch.object(BOARD.time, 'sleep'), \
                mock.patch.object(BOARD.common, 'device_location', side_effect=['7-1.4', None]):
            hub = Recorded(**cycling())
            with self.assertRaisesRegex(BOARD.Failed, 'after the cycle: no USB device'):
                BOARD.power_cycle(hub, paced_args(hub))
        hub = Recorded(**cycling(**{'probe-ping': LOST}))
        with self.assertRaisesRegex(BOARD.Failed, 'does not answer ping'):
            BOARD.power_cycle(hub, paced_args(hub))


class Console:
    """A console whose board answers each REPORT with the next frame."""
    def __init__(self, boot, replies):
        self.received = bytearray(boot)
        self.sent = bytearray()
        self.replies = list(replies)

    def send(self, data, pace=64):
        self.sent += data
        self.received += data
        if bytes([BOARD.REPORT]) in data:
            self.received += self.replies.pop(0)

    def wait(self, predicate, seconds, what):
        if predicate(bytes(self.received)):
            return bytes(self.received)
        raise BOARD.Failed('waited for ' + what)


def frame(tag, **fields):
    return (b'\x02' + tag.encode() + b''.join(b' %s=%08x' % (k.encode(), v)
                                              for k, v in fields.items()) + b'\x03\n')


BOOT = frame('b', r=BOARD.CHIP_RESET_HAD_POR, v=BOARD.MTVEC, a=BOARD.MARCHID_HAZARD3,
             k=BOARD.CLK_REF_XOSC)


class Scenario(unittest.TestCase):
    def run_scenario(self, boot, replies):
        with mock.patch.object(BOARD.time, 'sleep'):
            return BOARD.scenario(Console(boot, replies), None, 1240)

    def test_the_boot_frame_is_held_to_the_datasheet(self):
        for wrong, message in ((dict(r=0x00010004), 'power-on'), (dict(a=0x1c), 'Hazard3'),
                               (dict(v=BOARD.TABLE), 'vectored'), (dict(k=1), 'crystal')):
            fields = dict(r=BOARD.CHIP_RESET_HAD_POR, v=BOARD.MTVEC, a=BOARD.MARCHID_HAZARD3,
                          k=BOARD.CLK_REF_XOSC)
            fields.update(wrong)
            with self.assertRaisesRegex(BOARD.Failed, message):
                self.run_scenario(frame('b', **fields), [])

    def test_each_frame_carries_the_amoadd_result_that_numbers_it(self):
        good = frame('t', h=1, c=0, d=0, m=1, u=0, p=0, n=0, e=1, g=8, s=2, q=0)
        bad = frame('t', h=1, c=0, d=0, m=1, u=0, p=0, n=0, e=1, g=8, s=2, q=1)
        with self.assertRaisesRegex(BOARD.Failed, 'amoadd.w result 1'):
            self.run_scenario(BOOT, [bad])
        with self.assertRaisesRegex(BOARD.Failed, 'amoadd.w result 0'):
            self.run_scenario(BOOT, [good, good])

    def test_the_forced_irq_arrives_as_a_machine_external_interrupt(self):
        self.assertEqual(BOARD.MCAUSE_EXTERNAL, 1 << 31 | 11)
        self.assertEqual(BOARD.HANDLERS[30], 'usb_irq')
        replies = [frame('t', h=1, c=0, d=0, m=1, u=0, p=0, n=0, e=1, g=8, s=2, q=0),
                   frame('t', h=3, c=0, d=0, m=2, u=0, p=0, n=0, e=3, g=0, s=2, q=1),
                   frame('t', h=5, c=0, d=0, m=3, u=1, p=0x80000007, n=0, e=5, g=0, s=2, q=2)]
        with self.assertRaisesRegex(BOARD.Failed, 'mcause 80000007'):
            self.run_scenario(BOOT, replies)


class Constants(unittest.TestCase):
    def test_the_table_is_where_d662_aligns_it(self):
        size = 4 * BOARD.VECTOR_WORDS
        alignment = max(64, 1 << (size - 1).bit_length())
        self.assertEqual(alignment, 512)
        self.assertEqual(BOARD.TABLE, (BOARD.FLASH + 4 + alignment - 1) // alignment * alignment)
        self.assertEqual(BOARD.MTVEC & 3, 1)


if __name__ == '__main__':
    unittest.main()
