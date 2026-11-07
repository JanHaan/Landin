#!/usr/bin/env python3
"""Controls for the STM32H753 cached profile's board tool, without a board
(D975): its oracle against a scripted board that behaves as a write-back
data cache predicts, and against boards that do not, each refused for the
reason it is not; and its check of the image's cache registers (D976)."""
import importlib.util
import struct
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('board_stm32h753_cached',
                                              ROOT / 'environments/boards/stm32h753_cached/board.py')
BOARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOARD)
common = BOARD.common

# The level 1 data cache's CCSIDR on the STM32H753: write-through, write-back,
# read- and write-allocate, 128 sets, four ways, 32-byte lines.
CCSIDR = 0xF00FE019
VECTOR = 0x24000000


def frame(tag, **fields):
    return (bytes([common.STX]) + tag.encode() + b''.join(b' %s=%08x' % (k.encode(), v) for k, v in fields.items())
            + bytes([common.ETX, common.LF]))


class Board:
    """The cached application as the host sees it, each phase answering
    what the host sends; BEHAVE changes what a phase reports."""
    def __init__(self, **behave):
        self.behave = dict(ccr=0x00070200, stale_mask=3, lost=BOARD.LINE,
                           unclean=bytes([BOARD.TRANSMIT_MEMORY]) * BOARD.TRANSMIT,
                           end_ccr=0x00070200, prefix=b'', halt=None, transmitted=None)
        self.behave.update(behave)
        self.received = bytearray(self.behave['prefix'])
        self.sent = bytearray()
        self.phase = 0

    def send(self, data):
        self.sent += data
        b = self.behave
        if self.phase == 0:
            self.received += frame('b', c=b['ccr'], g=CCSIDR, l=32, v=VECTOR, s=data[0])
            if b['halt'] == 5:
                self.received += frame('h', s=5)
                return
            self.received += frame('c', n=BOARD.CONTROL)
        elif self.phase == 1:
            mask = b['stale_mask']
            seen = b''.join(bytes([BOARD.RING_FILL]) * 32 if mask >> i & 1 else bytes(data[i * 32:i * 32 + 32])
                            for i in range(len(data) // 32))
            stale = seen.count(BOARD.RING_FILL)
            self.received += frame('C', n=len(data), s=stale, k=mask, a=BOARD.fnv(seen),
                                   m=BOARD.fnv(data))
        elif self.phase == 2:
            self.received += frame('E', n=len(data), x=BOARD.fnv(data), w=4)
            self.received += frame('d', l=b['lost'], r=BOARD.REFUSED, k=BOARD.LINE, w=BOARD.LINE)
            sent = (frame('x', n=64) + b['unclean'] + frame('X', t=1, f=1, r=0)
                    + frame('y', n=64) + BOARD.message() + frame('Y', t=1, f=0, r=0))
            # A transmit racing the CPU's frames for the FIFO drops what
            # the board says it drops.
            self.received += b['transmitted'](sent) if b['transmitted'] else sent
            self.received += frame('e', c=b['end_ccr'])
        self.phase += 1

    def wait(self, predicate, seconds, what):
        if not predicate(bytes(self.received)):
            raise common.Failed('waited %g s for %s' % (seconds, what))
        return bytes(self.received)


class Swd:
    def __init__(self, running=0x00070200, returned=0x00040200):
        self.values = {'swd-ccr-running': running, 'swd-ccr-returned': returned}
        self.reads = []

    def read_words(self, name, address, count):
        self.reads.append((name, address, count))
        return [self.values[name]]


def run(board=None, swd=None):
    with mock.patch.object(BOARD.time, 'sleep'):
        return BOARD.scenario(board or Board(), swd or Swd(), 1230, VECTOR)


class Oracle(unittest.TestCase):
    def test_a_board_whose_cache_behaves_as_predicted_passes(self):
        swd = Swd()
        verdicts = run(swd=swd)
        self.assertEqual(verdicts['stale_read']['stale'], 64)
        self.assertEqual(verdicts['lost_dirty']['lost'], 32)
        self.assertEqual(verdicts['transmit'], dict(unclean_stale=64, unclean_lines=3, cleaned=64,
                                                    flags=[1, 0]))
        self.assertEqual(verdicts['returned']['ccr'] & BOARD.CCR_CACHES, 0)
        self.assertEqual([r[1] for r in swd.reads], [BOARD.CCR, BOARD.CCR])

    def test_the_last_application_s_output_before_the_load_is_not_this_run_s(self):
        verdicts = run(Board(prefix=b'\x02t h=00000001\x03\nzz'))
        self.assertEqual(verdicts['receive']['bytes'], BOARD.STREAM)

    def test_caches_left_off_by_reset_are_refused(self):
        with self.assertRaisesRegex(common.Failed, 'did not enable both caches'):
            run(Board(ccr=0x00040200))

    def test_a_cache_off_while_the_run_goes_on_is_refused(self):
        with self.assertRaisesRegex(common.Failed, 'while the run goes on'):
            run(swd=Swd(running=0x00050200))

    def test_a_line_evicted_before_the_read_still_shows_the_other_stale(self):
        verdicts = run(Board(stale_mask=2,
                             unclean=bytes([BOARD.TRANSMIT_MEMORY]) * 32 + BOARD.message()[32:]))
        self.assertEqual(verdicts['stale_read']['stale_lines'], 2)
        self.assertEqual(verdicts['transmit']['unclean_lines'], 1)

    def test_a_read_that_is_not_stale_is_refused_as_an_unconfirmed_control(self):
        # A cacheless core, or an emulator, reads what the stream wrote.
        with self.assertRaisesRegex(common.Failed, '0 of 64 bytes stale'):
            run(Board(stale_mask=0))

    def test_an_invalidate_that_keeps_the_dirty_bytes_is_refused(self):
        with self.assertRaisesRegex(common.Failed, 'did not discard them'):
            run(Board(lost=0))

    def test_a_transmit_without_a_clean_that_carries_the_message_is_refused(self):
        with self.assertRaisesRegex(common.Failed, 'without a clean carried'):
            run(Board(unclean=BOARD.message()))
        # Part of a line stale is no line's mix.
        with self.assertRaisesRegex(common.Failed, 'without a clean carried'):
            run(Board(unclean=bytes([BOARD.TRANSMIT_MEMORY]) * 16 + BOARD.message()[16:]))

    def test_bytes_lost_at_each_transmit_s_edges_are_refused(self):
        # The first chip run: the wait ended on an underrun's FEIF with the
        # stream still feeding the FIFO, and five bytes were lost at each
        # transmit's edge, the last `o` and `\x02X t`, then the first `A`
        # and `\x02Y t`.
        def collided(sent):
            x_end = sent.index(b'\x02X')
            sent = sent[:x_end - 1] + sent[x_end + 4:]
            y_start = sent.index(b'\x02y n=00000040\x03\n') + 15
            sent = sent[:y_start] + sent[y_start + 1:]
            y_end = sent.index(b'\x02Y')
            return sent[:y_end] + sent[y_end + 4:]
        with self.assertRaisesRegex(common.Failed, 'frames around the transmits are x, y, e'):
            run(Board(transmitted=collided))

    def test_one_byte_lost_from_either_transmit_is_refused(self):
        def short_unclean(sent):
            at = sent.index(b'\x02X')
            return sent[:at - 1] + sent[at:]
        with self.assertRaisesRegex(common.Failed, 'without a clean carried 63 bytes'):
            run(Board(transmitted=short_unclean))
        def short_message(sent):
            at = sent.index(b'\x02y n=00000040\x03\n') + 15
            return sent[:at] + sent[at + 1:]
        with self.assertRaisesRegex(common.Failed, 'cleaned transmit carried 63 bytes'):
            run(Board(transmitted=short_message))

    def test_a_transmit_missing_its_first_byte_is_refused(self):
        # The second chip run: each transmit's stream ended with its count
        # at zero and FEIF set, and its first byte never reached the line.
        def first_lost(sent):
            for opening in (b'\x02x n=00000040\x03\n', b'\x02y n=00000040\x03\n'):
                at = sent.index(opening) + len(opening)
                sent = sent[:at] + sent[at + 1:]
            return sent.replace(b'f=00000001', b'f=00000031').replace(b'f=00000000', b'f=00000031')
        with self.assertRaisesRegex(common.Failed, 'without a clean carried 63 bytes'):
            run(Board(transmitted=first_lost))
        def first_of_message_lost(sent):
            at = sent.index(b'\x02y n=00000040\x03\n') + 15
            return sent[:at] + sent[at + 1:]
        with self.assertRaisesRegex(common.Failed, "cleaned transmit carried 63 bytes, b'BCD"):
            run(Board(transmitted=first_of_message_lost))

    def test_a_transmit_that_did_not_complete_is_refused(self):
        def incomplete(sent):
            return sent.replace(b'\x02Y t=00000001', b'\x02Y t=00000000')
        with self.assertRaisesRegex(common.Failed, 'a transmit did not complete'):
            run(Board(transmitted=incomplete))

    def test_caches_still_on_once_the_entry_returned_are_refused(self):
        with self.assertRaisesRegex(common.Failed, 'still on'):
            run(swd=Swd(returned=0x00070200))

    def test_a_halt_names_its_step(self):
        with self.assertRaisesRegex(common.Failed, 'halted at step 5'):
            run(Board(halt=5))


class Image(unittest.TestCase):
    @staticmethod
    def elf(words):
        """An ELF32 with one PT_LOAD segment holding WORDS."""
        body = struct.pack('<%dI' % len(words), *words)
        header = bytearray(52)
        header[:4] = b'\x7fELF'
        struct.pack_into('<I', header, 0x1c, 52)
        struct.pack_into('<HH', header, 0x2a, 32, 1)
        program = struct.pack('<IIIIIIII', 1, 84, VECTOR, VECTOR, len(body), len(body), 7, 4)
        return bytes(header) + program + body

    def test_the_declared_registers_pass(self):
        found = BOARD.cache_registers(self.elf([0xE000ED14, 0xE000EF60, 0xE000EF74, 7]))
        self.assertEqual(found, ['0xe000ed14', '0xe000ef60', '0xe000ef74'])

    def test_an_undeclared_maintenance_register_is_refused(self):
        with self.assertRaisesRegex(common.Failed, '0xe000ef64'):
            BOARD.cache_registers(self.elf([0xE000ED14, 0xE000EF64]))

    def test_an_image_that_never_reaches_ccr_is_refused(self):
        with self.assertRaisesRegex(common.Failed, 'not cached'):
            BOARD.cache_registers(self.elf([0xE000EF60]))


class Stream(unittest.TestCase):
    def test_raw_bytes_lie_between_frames(self):
        stream = frame('x', n=1) + b'oo' + frame('X', t=1)
        self.assertEqual(BOARD.between(stream, 'x', 'X'), b'oo')
        self.assertEqual([p[0] for p in BOARD.segments(stream)], ['frame', 'raw', 'frame'])

    def test_a_frame_still_arriving_is_not_read(self):
        self.assertEqual(BOARD.segments(frame('b', c=1)[:-4]), [])


if __name__ == '__main__':
    unittest.main()
