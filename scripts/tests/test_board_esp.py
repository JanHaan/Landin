#!/usr/bin/env python3
"""Controls for the ESP32-C3's and ESP32-C5's board tools, without a board
(D723): the application image read apart from refine, the ROM's boot log
and the two image controls, the instructions each level allows, the
scenario's oracle against a board simulated from what the ports are
written to do, the tty found by its hub port with its modem lines held,
and the hub's guard when two ports are switched together."""
import hashlib
import importlib.util
import os
import random
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


COMMON = load('common', 'environments/boards/common.py')
ESP = load('esp', 'environments/boards/esp.py')
C3 = load('board_esp32c3', 'environments/boards/esp32c3/board.py').C3()
C5_BOARD = load('board_esp32c5', 'environments/boards/esp32c5/board.py')
C5 = C5_BOARD.C5()


def elf32(entry, segments):
    """A little-endian ELF32 with ENTRY and program headers for SEGMENTS,
    [(physical address, bytes, writable)], each its bytes in the file."""
    at = 52 + 32 * len(segments)
    body, headers = bytearray(), bytearray()
    for address, data, writable in segments:
        headers += struct.pack('<8I', 1, at + len(body), address, address, len(data),
                               len(data), 6 if writable else 5, 4)
        body += data
    header = bytearray(b'\x7fELF\x01\x01\x01' + bytes(9))
    header += struct.pack('<HHIIIIIHHHHHH', 2, 243, 1, entry, 52, 0, 0, 52, 32,
                          len(segments), 40, 0, 0)
    return bytes(header) + bytes(headers) + bytes(body)


def esp_image(entry, chip, revisions, segments, checksum=None, digest=None, extra=b''):
    """The application image ESP-IDF's esp_app_format.h lays out, written
    here apart from the tool's reader."""
    out = bytearray(struct.pack('<BBBBI', 0xE9, len(segments), 2, 0x20, entry))
    out += struct.pack('<B3sHBHH4sB', 0xEE, bytes(3), chip, 0, revisions[0], revisions[1],
                       bytes(4), 1)
    value = 0xEF
    for address, data in segments:
        out += struct.pack('<II', address, len(data)) + data
        for byte in data:
            value ^= byte
    while len(out) % 16 != 15:
        out.append(0)
    out.append(value if checksum is None else checksum)
    out += hashlib.sha256(bytes(out)).digest() if digest is None else digest
    return bytes(out) + extra


TEXT = bytes(range(256)) * 4
DATA = b'\x11\x22\x33\x44' * 5


def c3_build(tmp):
    segments = [(0x40380000, TEXT, False), (0x4038a400, DATA, True)]
    elf = Path(tmp) / 'board.elf'
    elf.write_bytes(elf32(0x40380000, segments))
    data = esp_image(0x40380000, 5, (3, 199), [(a, b) for a, b, _ in segments])
    parsed = COMMON.esp_image(data)
    report = {'firmware': {'esp_image': dict(
        offset=0, entry=0x40380000, chip=5, min_revision=3, max_revision=199,
        segments=[dict(address=a, bytes=len(b)) for a, b, _ in segments],
        checksum=parsed['checksum'], sha256=parsed['sha256'], bytes=len(data))}}
    return elf, data, report


# The Espressif QEMU esp32c3 machine's ROM, the chip's own, booting images
# refine wrote: a good one, one whose checksum byte was flipped and one
# whose SHA-256 was.
GOOD_LOG = """ESP-ROM:esp32c3-api1-20210207\r
Build:Feb  7 2021\r
rst:0x1 (POWERON),boot:0xc (SPI_FAST_FLASH_BOOT)\r
SPIWP:0xee\r
mode:DIO, clock div:2\r
load:0x40380000,len:0x400\r
load:0x4038a400,len:0x14\r
entry 0x40380000\r
"""
CHECKSUM_LOG = GOOD_LOG.replace('entry 0x40380000\r\n',
                                'Checksum failure. Calculated 0x%02x stored 0x%02x\r\nets_main.c 333 \r\n')
SHA_LOG = GOOD_LOG.replace('entry 0x40380000', 'SHA-256 comparison failed:\r\nCalculated: %s\r\n'
                           'Expected: %s\r\nAttempting to boot anyway...\r\nentry 0x40380000')


class Image(unittest.TestCase):
    def test_an_image_is_read_from_its_bytes(self):
        data = esp_image(0x40800000, 23, (100, 199), [(0x40800000, TEXT)])
        image = COMMON.esp_image(data)
        self.assertEqual((image['entry'], image['chip'], image['min_revision'],
                          image['max_revision']), (0x40800000, 23, 100, 199))
        self.assertEqual(image['segments'], [(0x40800000, TEXT)])
        self.assertEqual(image['sha256'], hashlib.sha256(data[:-32]).hexdigest())
        self.assertEqual(len(data[:-32]) % 16, 0)

    def test_every_part_that_is_not_as_made_is_refused(self):
        good = esp_image(0x40380000, 5, (3, 199), [(0x40380000, TEXT)])
        checksum = good[-33]
        bad = {
            'magic': b'\xe8' + good[1:],
            'reserved': good[:19] + b'\x01' + good[20:],
            'padding': None,
            'checksum': esp_image(0x40380000, 5, (3, 199), [(0x40380000, TEXT)],
                                  checksum=checksum ^ 1),
            'sha256': good[:-1] + bytes([good[-1] ^ 1]),
            'trailing': good + b'\0',
            'segment': good[:24] + struct.pack('<II', 0x40380000, 0x10000) + good[32:],
        }
        odd = esp_image(0x40380000, 5, (3, 199), [(0x40380000, b'\x01\x02\x03')])
        at = 24 + 8 + 3
        broken = bytearray(odd[:-32])
        broken[at] = 0x55
        bad['padding'] = bytes(broken) + hashlib.sha256(bytes(broken)).digest()
        for name, data in bad.items():
            with self.subTest(name):
                with self.assertRaises(COMMON.Failed):
                    COMMON.esp_image(data)

    def test_the_checksum_is_every_segment_byte_into_0xef(self):
        self.assertEqual(COMMON.esp_checksum([(0, b'\x01\x02'), (4, b'\x04')]), 0xEF ^ 1 ^ 2 ^ 4)


class Check(unittest.TestCase):
    def test_the_c3_image_matches_its_elf_chip_and_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            elf, data, report = c3_build(tmp)
            image = ESP.check_image(C3, data, elf, report)
            self.assertEqual([a for a, _ in image['segments']], [0x40380000, 0x4038a400])

    def test_another_chip_segment_entry_or_report_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            elf, data, report = c3_build(tmp)
            with self.assertRaises(COMMON.Failed):
                ESP.check_image(C5, data, elf, report)
            other = esp_image(0x40380000, 5, (3, 199), [(0x40380000, TEXT)])
            with self.assertRaises(COMMON.Failed):
                ESP.check_image(C3, other, elf, report)
            report['firmware']['esp_image']['checksum'] ^= 1
            with self.assertRaises(COMMON.Failed):
                ESP.check_image(C3, data, elf, report)


class Instructions(unittest.TestCase):
    PLAIN = '40380000:\taddi\tsp,sp,-16\n40380004:\tlw\ta0,0(a1)\n'
    AMO = '40380008:\tamoadd.w.aqrl\ta0,a1,(a2)\n'
    LRSC = '4038000c:\tlr.w.aq\ta0,(a2)\n40380010:\tsc.w.rl\ta3,a1,(a2)\n'

    def test_rv32imc_holds_no_a_instruction(self):
        self.assertEqual(ESP.instructions(C3, self.PLAIN), [])
        for extra in (self.AMO, self.LRSC):
            with self.assertRaises(COMMON.Failed):
                ESP.instructions(C3, self.PLAIN + extra)

    def test_rv32imac_holds_an_amo_and_an_lr_sc_pair(self):
        self.assertEqual(ESP.instructions(C5, self.PLAIN + self.AMO + self.LRSC),
                         ['amoadd.w.aqrl', 'lr.w.aq', 'sc.w.rl'])
        for listing in (self.PLAIN + self.AMO, self.PLAIN + self.LRSC):
            with self.assertRaises(COMMON.Failed):
                ESP.instructions(C5, listing)


class Rom(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.elf, self.data, _ = c3_build(self.tmp.name)
        self.image = COMMON.esp_image(self.data)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_power_on_boot_of_the_image_passes(self):
        self.assertEqual(ESP.boot_log(GOOD_LOG, self.image)['entry'], '0x40380000')

    def test_each_departure_from_the_image_s_boot_is_refused(self):
        for bad in (GOOD_LOG.replace('rst:0x1 (POWERON)', 'rst:0x15 (USB_UART_HPSYS)'),
                    GOOD_LOG.replace('SPI_FAST_FLASH_BOOT', 'DOWNLOAD(USB/UART0)'),
                    GOOD_LOG.replace('len:0x14', 'len:0x18'),
                    GOOD_LOG.replace('load:0x4038a400,len:0x14\r\n', ''),
                    GOOD_LOG.replace('entry 0x40380000', 'entry 0x40380004'),
                    GOOD_LOG.replace('entry 0x40380000\r\n', '')):
            with self.subTest(bad), self.assertRaises(COMMON.Failed):
                ESP.boot_log(bad, self.image)

    def test_only_the_first_boot_is_read(self):
        twice = GOOD_LOG + GOOD_LOG.replace('rst:0x1 (POWERON)', 'rst:0xc (RTC_SW_CPU_RST)')
        self.assertEqual(ESP.boot_log(twice, self.image)['reset'], 'POWERON')

    def test_the_checksum_control_requires_refusal_of_the_image_s_own_checksum(self):
        checksum = self.image['checksum']
        refused = CHECKSUM_LOG % (checksum, checksum ^ 0xff)
        self.assertEqual(ESP.refused_checksum(refused, self.image),
                         dict(calculated='%#04x' % checksum, stored='%#04x' % (checksum ^ 0xff)))
        for bad in (CHECKSUM_LOG % (checksum ^ 1, checksum ^ 0xff),
                    refused + 'entry 0x40380000\r\n',
                    refused + '\x02b r=00000001 v=40380101\x03\n',
                    GOOD_LOG):
            with self.subTest(bad), self.assertRaises(COMMON.Failed):
                ESP.refused_checksum(bad, self.image)

    def test_the_sha_control_requires_the_image_s_own_hash(self):
        sha = self.image['sha256']
        flipped = sha[:-2] + '%02x' % (int(sha[-2:], 16) ^ 0xff)
        self.assertEqual(ESP.warned_sha(SHA_LOG % (sha, flipped), self.image),
                         dict(calculated=sha, expected=flipped, entered=True))
        with self.assertRaises(COMMON.Failed):
            ESP.warned_sha(SHA_LOG % (flipped, sha), self.image)

    def test_the_corrupted_copies_differ_in_one_byte(self):
        for where, at in (('checksum', len(self.data) - 33), ('sha256', len(self.data) - 1)):
            bad = ESP.corrupted(self.data, where)
            self.assertEqual([i for i in range(len(bad)) if bad[i] != self.data[i]], [at])


class Board:
    """A console onto a board simulated from what compiler/tests/board's
    ports are written to do: every byte echoed, 1 and 0 driving the
    indicator, the `a`, `t` and `b` frames, a ring of 256 bytes that drops
    the rest while STALL holds the reader off, and a FIFO of 128 that
    flags an overflow once while MASK holds the interrupt off."""
    def __init__(self, chip, fault=None):
        self.chip, self.fault = chip, fault
        self.received, self.sent = bytearray(), bytearray()
        self.indicator = self.handled = self.restarts = self.dropped = self.overflows = 0
        self.entries, self.ticks, self.masked_ticks, self.mode = 0, 5, 0, None
        self.previous = [0, 0]
        self.received += b'ESP-ROM:esp32c5-eco2-20250121\r\nentry 0x40800000\r\n'
        self.frame('b', r=1, v=chip.expected_mtvec)

    def frame(self, tag, **fields):
        self.received += b'\x02' + tag.encode() + b''.join(
            b' %s=%08x' % (k.encode(), v & 0xffffffff) for k, v in fields.items()) + b'\x03\n'

    def send(self, data, pace=64):
        self.sent += data
        if self.mode:
            ring, self.mode = self.mode, None
            if ring == 'stall':
                self.dropped += max(0, len(data) - 256)
            else:
                self.overflows += 1 if len(data) > 128 else 0
                self.masked_ticks = 100 if self.fault != 'masked timer' else 0
            self.entries += 1
            self.restarts += 1
            return
        for byte in data:
            self.entries += 1
            self.handled += 1
            if byte == 0x31:
                self.indicator = self.chip.indicator
            if byte == 0x30:
                self.indicator = 0
            self.received.append(byte)
            if byte == ESP.ATOMICS:
                x, y = self.previous
                atomics = self.chip.atomics(x, y)
                if self.fault == 'atomics':
                    atomics[next(iter(atomics))] ^= 1
                self.frame('a', **atomics)
            if byte == ESP.REPORT:
                self.ticks += 50
                cause = self.chip.uart_cause | (0x08000000 if self.chip is C5 else 0)
                self.frame('t', h=self.handled, c=self.restarts, i=self.entries, m=self.ticks,
                           p=cause, q=self.chip.timer_cause, k=self.masked_ticks,
                           l=self.dropped, o=self.overflows, e=0,
                           g=self.indicator if self.fault != 'indicator' else 0, s=2)
            if byte == ESP.STALL:
                self.mode = 'stall'
            if byte == ESP.MASK:
                self.mode = 'mask'
            self.previous = [self.previous[1], byte]

    def wait(self, predicate, seconds, what):
        if predicate(bytes(self.received)):
            return bytes(self.received)
        raise COMMON.Failed('waited for %s' % what)


class Scenario(unittest.TestCase):
    def setUp(self):
        C3.expected_mtvec, C5.expected_mtvec = 0x40380101, 0x40800203
        self.sleep = mock.patch.object(ESP.time, 'sleep')
        self.sleep.start()

    def tearDown(self):
        self.sleep.stop()

    def test_both_boards_pass_as_the_ports_are_written(self):
        for chip in (C3, C5):
            with self.subTest(chip.name):
                board = Board(chip)
                verdicts, final, atomics = ESP.scenario(board, chip, 1240)
                self.assertEqual(verdicts['ring_overrun']['dropped'], ESP.BURST - ESP.RING)
                self.assertEqual(verdicts['threshold']['fifo_overflows'], 1)
                self.assertEqual(final['h'], len(ESP.echo_of(board.received)) - len(b'ESP-ROM:esp32c5-eco2-20250121\r\nentry 0x40800000\r\n'))
                self.assertEqual(atomics, chip.atomics(verdicts['atomics']['x'],
                                                       verdicts['atomics']['y']))

    def test_each_departure_is_refused(self):
        for fault in ('atomics', 'indicator', 'masked timer'):
            for chip in (C3, C5):
                with self.subTest(fault=fault, chip=chip.name), self.assertRaises(COMMON.Failed):
                    ESP.scenario(Board(chip, fault), chip, 1240)

    def test_the_atomics_oracles_are_the_arithmetic(self):
        self.assertEqual(C3.atomics(0x41, 0x7e), dict(b=0x41, h=0x417e, w=0x417e7e41))
        self.assertEqual(C5.atomics(0x7e, 0x7d),
                         dict(p=0x7e, q=0xfb, r=0x03, d=0x03, e=0x7e, f=0xfb))

    def test_the_operands_are_neither_commands_nor_the_indicator_s(self):
        rng = random.Random(1)
        for _ in range(500):
            for byte in ESP.operands(rng):
                self.assertTrue(0x20 <= byte < 0x7f and byte not in (0x30, 0x31))

    def test_the_echo_loses_the_two_bursts(self):
        self.assertEqual(ESP.expected_stream(b'ab' + b'X' * 3 + b'cd' + b'Y' * 2 + b'e',
                                             [b'XXX', b'YY']), b'abcde')


class Probe(unittest.TestCase):
    def test_counters_and_cells_are_read_from_their_words(self):
        counters = dict(handled=9, recoveries=2, dropped=44, overflows=1, entries=7, boot_reason=1)
        words = {0x3fca04c0: 0x417e0041, 0x3fca04e4: 0x417e7e41}

        class Fake:
            def read_words(self, name, address, count):
                return [counters.get(name[len('jtag-'):], words.get(address, 0))]
        trap = dict(('_landin_firmware_trap_' + c, 0x3fca0100 + 4 * i)
                    for i, c in enumerate(ESP.TRAP_CELLS))
        names = dict(counters, byte_cell=0x3fca04c0, half_cell=0x3fca04c2, word_cell=0x3fca04e4,
                     **trap)
        final = dict(h=9, c=2, l=44, o=1, i=7, r=1)
        atomics = dict(b=0x41, h=0x417e, w=0x417e7e41)
        read = ESP.cross_check(Fake(), C3, names, final, atomics)
        self.assertEqual((read['byte_cell'], read['half_cell'], read['word_cell']),
                         (0x41, 0x417e, 0x417e7e41))
        with self.assertRaises(COMMON.Failed):
            ESP.cross_check(Fake(), C3, names, dict(final, i=8), atomics)
        words[0x3fca0110], words[0x3fca0100], words[0x3fca0104] = 1, 2, 0x40380294
        with self.assertRaises(COMMON.Failed) as refused:
            ESP.cross_check(Fake(), C3, names, final, atomics)
        self.assertIn('mcause 0x2 at 0x40380294', str(refused.exception))


class PowerOn(unittest.TestCase):
    NAMES = dict(boot_reason=0x10, app_state=0x14, timer_events=0x18,
                 **{'_landin_firmware_trap_' + c: 0x20 + 4 * i
                    for i, c in enumerate(('cause', 'pc', 'value', 'sp', 'count'))})

    class Fake:
        def __init__(self, words):
            self.words = words

        def read_words(self, name, address, count):
            value = self.words[address]
            return [value.pop(0) if isinstance(value, list) else value]

    def board(self, cause=1, reason=1, state=2, timer=(5, 9)):
        words = {C5_BOARD.RESET_CAUSE: 0x20 | cause, 0x10: reason, 0x14: state,
                 0x18: list(timer)}
        words.update({0x20 + 4 * i: 0 for i in range(5)})
        return self.Fake(words)

    def test_a_running_application_after_a_power_on_passes(self):
        with mock.patch.object(C5_BOARD.time, 'sleep'):
            found = C5_BOARD.power_on_boot(self.board(), self.NAMES)
        self.assertEqual((found['reset_cause'], found['boot_reason']), (1, 1))

    def test_another_cause_a_halted_application_or_a_stopped_timer_fails(self):
        for board in (self.board(cause=0x0c), self.board(reason=0x0c), self.board(state=1),
                      self.board(timer=(9, 9))):
            with mock.patch.object(C5_BOARD.time, 'sleep'), self.assertRaises(COMMON.Failed):
                C5_BOARD.power_on_boot(board, self.NAMES)

    def test_the_chip_enable_reset_is_rts_alone(self):
        calls = []
        with mock.patch.object(COMMON.fcntl, 'ioctl', side_effect=lambda fd, request, arg:
                               calls.append((request, arg)) or struct.pack('I', 0)), \
                mock.patch.object(C5_BOARD.time, 'sleep'):
            C5_BOARD.chip_enable_reset(3, 0.1)
        rts = struct.pack('I', COMMON.termios.TIOCM_RTS)
        self.assertEqual(calls[1:], [(COMMON.termios.TIOCMBIS, rts), (COMMON.termios.TIOCMBIC, rts)])

    def test_no_reset_while_dtr_is_active(self):
        dtr = struct.pack('I', COMMON.termios.TIOCM_DTR)
        with mock.patch.object(COMMON.fcntl, 'ioctl', return_value=dtr), \
                self.assertRaises(COMMON.Failed):
            C5_BOARD.chip_enable_reset(3, 0.1)


class Restore(unittest.TestCase):
    def test_a_download_that_finds_no_probe_is_tried_again(self):
        tries = []

        class Fake:
            def download_bin(self, image, offset):
                tries.append(offset)
                if len(tries) < 3:
                    raise COMMON.Failed('flash failed (1)')
        with mock.patch.object(ESP.time, 'sleep'):
            ESP.restore(Fake(), 'board.elf.bin', 0x2000)
        self.assertEqual(tries, [0x2000] * 3)

    def test_it_gives_up_in_the_end(self):
        class Fake:
            def download_bin(self, image, offset):
                raise COMMON.Failed('flash failed (1)')
        with mock.patch.object(ESP.time, 'sleep'), self.assertRaises(COMMON.Failed):
            ESP.restore(Fake(), 'board.elf.bin', 0x2000, tries=4)


class Recover(unittest.TestCase):
    def test_download_mode_is_esptool_s_usb_jtag_serial_sequence(self):
        calls = []

        class Line:
            fd = 5

            def close(self):
                calls.append('close')
        with mock.patch.object(COMMON, 'wait_for_tty', return_value='/dev/ttyACM4'), \
                mock.patch.object(COMMON, 'TtyConsole', return_value=Line()), \
                mock.patch.object(COMMON, 'set_lines', side_effect=lambda fd, **lines:
                                  calls.append(tuple(sorted(lines.items())))), \
                mock.patch.object(ESP.time, 'sleep'):
            ESP.download_mode('A0:76:4E:42:57:F8')
        self.assertEqual(calls, [(('dtr', False), ('rts', False)), (('dtr', True),),
                                 (('rts', False),), (('rts', True),), (('dtr', False),),
                                 (('rts', True),), (('dtr', False),), (('rts', False),), 'close'])


class Tty(unittest.TestCase):
    def tree(self, tmp, layouts):
        sysfs, dev = Path(tmp) / 'class', Path(tmp) / 'dev'
        sysfs.mkdir()
        dev.mkdir()
        for name, path in layouts.items():
            target = Path(tmp) / 'devices' / path
            target.mkdir(parents=True)
            (sysfs / name).mkdir()
            os.symlink(target, sysfs / name / 'device')
        return sysfs, dev

    def test_a_tty_is_found_by_its_hub_port(self):
        with tempfile.TemporaryDirectory() as tmp:
            sysfs, dev = self.tree(tmp, {
                'ttyACM5': '7-2.3.4/7-2.3.4.3/7-2.3.4.3:1.0',
                'ttyUSB2': '7-2.3.4/7-2.3.4.4/7-2.3.4.4:1.0/ttyUSB2',
                'ttyUSB0': '7-2.3.3/7-2.3.3.4/7-2.3.3.4:1.0/ttyUSB0',
                'ttyUSB1': '7-2.3.3/7-2.3.3.4/7-2.3.3.4:1.1/ttyUSB1'})
            self.assertEqual(COMMON.tty_at('7-2.3.4.4', sysfs, dev), dev / 'ttyUSB2')
            self.assertEqual(COMMON.tty_at('7-2.3.4.3', sysfs, dev), dev / 'ttyACM5')
            self.assertEqual(COMMON.tty_at('7-2.3.3.4', sysfs, dev), dev / 'ttyUSB0')
            self.assertIsNone(COMMON.tty_at('7-2.3.4', sysfs, dev))
            self.assertIsNone(COMMON.tty_at('7-2.3.4.1', sysfs, dev))

    def test_a_quiet_tty_drops_dtr_and_rts_together(self):
        calls = []
        with mock.patch.object(COMMON.fcntl, 'ioctl',
                               side_effect=lambda fd, request, arg: calls.append((request, arg))):
            COMMON.quiet_lines(7)
        self.assertEqual(calls, [(COMMON.termios.TIOCMBIC, struct.pack(
            'I', COMMON.termios.TIOCM_DTR | COMMON.termios.TIOCM_RTS))])


HUB = ('Current status for hub 7-2.3.4 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]\n'
       '  Port 1: 0103 power enable connect [1366:0105]\n'
       '  Port 2: 0103 power enable connect [303a:1001 Espressif USB JTAG/serial debug unit'
       ' A0:76:4E:42:57:F8]\n'
       '  Port 3: 0103 power enable connect [303a:1001 Espressif USB JTAG/serial debug unit'
       ' D0:CF:13:E0:87:F0]\n'
       '  Port 4: 0103 power enable connect [1a86:7523 USB Serial]\n')


class Recorded:
    def __init__(self, status, switched=None):
        self.status, self.calls = status, []
        self.switched = switched if switched is not None else [
            'Sent power off request\nNew status for hub 7-2.3.4 [0bda:5411]\n']

    def command(self, name, argv, **_):
        self.calls.append((name, argv))
        if name.startswith('power-'):
            return self.switched.pop(0) if len(self.switched) > 1 else self.switched[0]
        return self.status


class Hub(unittest.TestCase):
    HOLDS = [(3, 'D0:CF:13:E0:87:F0'), (4, '1a86:7523')]

    def test_both_ports_are_switched_in_one_call(self):
        hub = Recorded(HUB)
        COMMON.switch_ports(hub, '7-2.3.4', [4, 3], 'off', holds=self.HOLDS, keeps=(1, '1366:0105'))
        self.assertEqual(hub.calls[-1], ('power-off', ['uhubctl', '-l', '7-2.3.4', '-p', '4,3',
                                                       '-a', 'off']))

    def test_a_port_without_its_device_or_a_hub_without_its_guard_is_not_switched(self):
        for status in (HUB.replace('1a86:7523', '0403:6001'),
                       HUB.replace('D0:CF:13:E0:87:F0', 'A0:76:4E:42:57:F8'),
                       HUB.replace('[1366:0105]', '[]')):
            hub = Recorded(status)
            with self.subTest(status), self.assertRaises(COMMON.Failed):
                COMMON.switch_ports(hub, '7-2.3.4', [4, 3], 'off', holds=self.HOLDS,
                                    keeps=(1, '1366:0105'))
            self.assertEqual([n for n, _ in hub.calls], ['hub-status'])

    def test_a_switch_that_finds_no_hub_waits_and_switches_again(self):
        hub = Recorded(HUB, switched=['', 'New status for hub 7-2.3.4 [0bda:5411]\n'])
        with mock.patch.object(COMMON.time, 'sleep'):
            COMMON.switch_ports(hub, '7-2.3.4', [3], 'on', keeps=(1, '1366:0105'))
        self.assertEqual([n for n, _ in hub.calls],
                         ['hub-status', 'power-on', 'hub-wait', 'power-on'])

    def test_a_status_read_that_finds_no_hub_is_read_again(self):
        class Hidden(Recorded):
            def command(self, name, argv, **kw):
                if name == 'hub-status' and not any(n == 'hub-status' for n, _ in self.calls):
                    self.calls.append((name, argv))
                    return ''
                return Recorded.command(self, name, argv, **kw)
        hub = Hidden(HUB)
        with mock.patch.object(COMMON.time, 'sleep'):
            COMMON.switch_ports(hub, '7-2.3.4', [3], 'off', holds=self.HOLDS[:1],
                                keeps=(1, '1366:0105'))
        self.assertEqual([n for n, _ in hub.calls], ['hub-status', 'hub-status', 'power-off'])

    def test_a_switch_that_never_takes_fails(self):
        hub = Recorded(HUB, switched=[''])
        with mock.patch.object(COMMON.time, 'sleep'), self.assertRaises(COMMON.Failed):
            COMMON.switch_ports(hub, '7-2.3.4', [3], 'on', keeps=(1, '1366:0105'))

    def test_the_guarded_port_is_never_switched(self):
        with self.assertRaises(COMMON.Failed):
            COMMON.switch_ports(Recorded(HUB), '7-2.3.4', [1, 3], 'on', keeps=(1, '1366:0105'))

    def test_ports_coming_back_need_no_device_but_the_guard(self):
        hub = Recorded(HUB.replace('[1a86:7523 USB Serial]', '').replace(
            'connect [303a:1001 Espressif USB JTAG/serial debug unit D0:CF:13:E0:87:F0]', 'off'))
        COMMON.switch_ports(hub, '7-2.3.4', [4], 'on', holds=self.HOLDS[1:],
                            keeps=(1, '1366:0105'))
        self.assertEqual(hub.calls[-1][1][-2:], ['-a', 'on'])


if __name__ == '__main__':
    unittest.main()
