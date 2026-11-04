#!/usr/bin/env python3
"""Controls for the STM32H753 board tool's oracle, without a board (D650,
D651): its IEEE 754 arithmetic, its operand encoding and frames, its
accounting of what the board must echo, its boot verdicts and its reading
of the float routines' instructions, each held to fixed inputs."""
import importlib.util
import contextlib
import json
import tempfile
import math
import random
import struct
import unittest
from unittest import mock
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('board_stm32h753',
                                              ROOT / 'environments/boards/stm32h753/board.py')
BOARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOARD)


def bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


class Arithmetic(unittest.TestCase):
    def test_f32_results_are_rounded_once_from_binary64(self):
        one, third = 0x3f800000, 0x3eaaaaab
        got = BOARD.expected(32, one, third)
        # 0x3eaaaaab is 0.3333333432674408 exactly.  1 + it is 1.33333334,
        # nearest 0x3faaaaab; 1 - it, 0.6666666567325592, lies halfway
        # between 0x3f2aaaaa and 0x3f2aaaab and rounds to the even one; and
        # 1 / it, 2.9999999105930328, is nearer 3.0 than 0x403fffff.
        self.assertEqual(got['sum'], 0x3faaaaab)
        self.assertEqual(got['difference'], 0x3f2aaaaa)
        self.assertEqual(got['product'], third)
        self.assertEqual(got['quotient'], 0x40400000)
        self.assertEqual(got['order'], 8 | 16 | 32)
        self.assertEqual(got['root'], one)

    def test_f64_results_are_python_s_binary64(self):
        one, three = 0x3ff0000000000000, 0x4008000000000000
        got = BOARD.expected(64, one, three)
        self.assertEqual(got['quotient'], 0x3fd5555555555555)
        self.assertEqual(got['sum'], 0x4010000000000000)
        self.assertEqual(got['order'], 1 | 2 | 8)
        self.assertEqual(BOARD.expected(64, three, 0)['root'], 0x3ffbb67ae8584caa)

    def test_overflow_rounds_to_infinity_and_underflow_keeps_subnormals(self):
        largest = 0x7f7fffff
        self.assertEqual(BOARD.expected(32, largest, largest)['sum'], 0x7f800000)
        self.assertEqual(BOARD.expected(32, 0xff7fffff, largest)['difference'], 0xff800000)
        # The smallest subnormal halved is a tie, rounded to even: zero.
        self.assertEqual(BOARD.expected(32, 0x00000001, 0x40000000)['quotient'], 0)
        self.assertEqual(BOARD.expected(32, 0x00000003, 0x40000000)['quotient'], 2)
        self.assertEqual(BOARD.bits32(3.4028235677973366e38), 0x7f800000)
        self.assertEqual(BOARD.bits32(3.4028235e38), 0x7f7fffff)

    def test_division_by_zero_is_ieee_754_s(self):
        zero, negative_zero = 0x00000000, 0x80000000
        self.assertEqual(BOARD.expected(32, 0x3f800000, zero)['quotient'], 0x7f800000)
        self.assertEqual(BOARD.expected(32, 0x3f800000, negative_zero)['quotient'], 0xff800000)
        self.assertEqual(BOARD.expected(32, 0xbf800000, negative_zero)['quotient'], 0x7f800000)
        self.assertTrue(BOARD.is_nan(32, BOARD.expected(32, zero, zero)['quotient']))
        self.assertTrue(BOARD.is_nan(64, BOARD.expected(64, 0, 0)['quotient']))

    def test_signed_zero_and_the_square_root_of_a_negative(self):
        negative_zero = 0x80000000
        self.assertEqual(BOARD.expected(32, negative_zero, negative_zero)['sum'], negative_zero)
        self.assertEqual(BOARD.expected(32, negative_zero, 0)['sum'], 0)
        self.assertEqual(BOARD.expected(32, negative_zero, 0)['root'], negative_zero)
        self.assertTrue(BOARD.is_nan(32, BOARD.expected(32, 0xbf800000, 0)['root']))
        self.assertEqual(BOARD.expected(32, 0x7f800000, 0)['root'], 0x7f800000)

    def test_an_unordered_comparison_is_unequal_alone(self):
        nan = 0x7fc00000
        self.assertEqual(BOARD.expected(32, nan, 0x3f800000)['order'], 8)
        self.assertEqual(BOARD.expected(64, 0x7ff8000000000000, 0x7ff8000000000000)['order'], 8)
        self.assertEqual(BOARD.expected(32, 0, 0x80000000)['order'], 2 | 4 | 16)

    def test_a_nan_matches_any_nan_and_nothing_else_does(self):
        want = BOARD.expected(32, 0x7f800000, 0xff800000)
        self.assertTrue(BOARD.is_nan(32, want['sum']))
        got = dict(want, sum=0xffc00000)
        self.assertEqual(BOARD.compare(32, got, want), [])
        self.assertEqual(BOARD.compare(32, dict(want, sum=0x7f800000), want), ['sum'])
        self.assertEqual(BOARD.compare(32, dict(want, product=want['product'] ^ 1), want),
                         ['product'])
        # A result the firmware does not send, the square root before its
        # hook is filled, is not compared.
        del got['root']
        self.assertEqual(BOARD.compare(32, got, want), [])

    def test_seeded_operands_agree_with_a_second_reading(self):
        rng = random.Random(1230)
        for x, y in BOARD.operand_pairs(32, rng):
            a, b = BOARD.f32(x), BOARD.f32(y)
            if not (math.isfinite(a) and math.isfinite(b)) or b == 0:
                continue
            got = BOARD.expected(32, x, y)
            if math.isfinite(a * b) and abs(a * b) < 3e38:
                self.assertEqual(got['product'], bits(a * b))


class Frames(unittest.TestCase):
    def test_operands_are_letters_most_significant_first(self):
        self.assertEqual(BOARD.letters((0x3f800000, 32), (0x00000001, 32)),
                         b'dpiaaaaa' + b'aaaaaaab')
        encoded = BOARD.letters((0x400921fb54442d18, 64), (0x1, 64))
        self.assertEqual(len(encoded), 32)
        self.assertTrue(all(0x61 <= c <= 0x70 for c in encoded))
        # No operand byte is one of the board's commands or a frame's bytes.
        self.assertFalse(set(encoded) & {0x02, 0x03, 0x11, 0x12, 0x14, 0x15, 0x30, 0x31})

    def test_a_64_bit_frame_joins_each_result_s_two_words(self):
        stream = (b'\x02F a=3ff00000 b=00000001 s=00000000 t=00000002 m=00000000 n=00000003'
                  b' d=00000000 e=00000004 c=00000008\x03\n')
        got = BOARD.results(64, BOARD.common.tagged(stream, 'F')[0])
        self.assertEqual(got, dict(sum=0x3ff0000000000001, difference=2, product=3,
                                   quotient=4, order=8))
        stream = b'\x02f a=3faaaaab s=3f2aaaaa m=3eaaaaab d=40400000 c=00000038 q=3f800000\x03\n'
        got = BOARD.results(32, BOARD.common.tagged(stream, 'f')[0])
        self.assertEqual(BOARD.compare(32, got, BOARD.expected(32, 0x3f800000, 0x3eaaaaab)), [])
        self.assertEqual(got['root'], 0x3f800000)


class Accounting(unittest.TestCase):
    def test_the_echo_loses_what_was_discarded(self):
        sent = b'S1\x11A0\x11\x12' + b'B' * 300 + b'\x11' + b'C' * 10 + b'\x12' + b'D' * 100 + b'\x11'
        burst, lost = sent.index(b'B'), sent.index(b'D')
        expect = BOARD.discarded(sent, [(lost + BOARD.HELD, 100 - BOARD.HELD), (burst, 300)])
        self.assertEqual(expect, b'S1\x11A0\x11\x12\x11' + b'C' * 10 + b'\x12' + b'D' * 17 + b'\x11')

    def test_the_receiver_holds_its_fifo_and_its_data_register(self):
        # RM0433 Rev 9, Table 402, p. 2018: a 16-entry RXFIFO; 48.5.4,
        # p. 2023, and note 2 of p. 2067: one more in USART_RDR before the
        # next sets ORE.
        self.assertEqual(BOARD.HELD, 16 + 1)

    def test_the_float_exercise_fits_in_the_epoch_it_runs_in(self):
        used = 1 + 1000 + 1
        need = sum(len(BOARD.operand_pairs(w, random.Random(1))) * (1 + w // 2) for w in (32, 64))
        self.assertLessEqual(need, BOARD.BUDGET - used - 1)


class Line:
    """A console holding a fixed stream."""
    def __init__(self, received):
        self.received = received

    def wait(self, predicate, seconds, what):
        if not predicate(self.received):
            raise BOARD.Failed(what)
        return self.received


class Boot(unittest.TestCase):
    FRAME = (b'\x02b r=00fa0000 v=08000000 a=00000000 c=00040200 q=00000002'
             b' y=00006000 w=00000001\x03\nS')

    def test_a_power_on_boot_passes(self):
        got = BOARD.boot(Line(self.FRAME))
        self.assertEqual(got['rcc_rsr'], 0x00fa0000)
        self.assertEqual(got['cpacr'], 0)

    def test_each_reading_that_is_not_reset_s_is_refused(self):
        for old, new in ((b'r=00fa0000', b'r=01fa0000'),   # SFTRSTF: a software reset
                         (b'r=00fa0000', b'r=00400000'),   # PINRSTF alone
                         (b'v=08000000', b'v=00000000'),
                         (b'c=00040200', b'c=00070200'),   # IC and DC
                         (b'q=00000002', b'q=00000006'),   # the supply not configured
                         (b'q=00000002', b'q=00000001'),   # bypassed
                         (b'y=00006000', b'y=00004000'),   # the levels not valid
                         (b'y=00006000', b'y=0000e000'),   # VOS1, not reset's VOS3
                         (b'w=00000001', b'w=00000002')):   # a byte before the host's
            with self.subTest(reading=new):
                with self.assertRaises(BOARD.Failed):
                    BOARD.boot(Line(self.FRAME.replace(old, new)))

    def test_the_reserved_bit_of_rcc_rsr_is_not_read(self):
        self.assertEqual(BOARD.boot(Line(self.FRAME.replace(b'r=00fa0000', b'r=00fe0000')))
                         ['rcc_rsr'], 0x00fe0000)


SOFT = """08003450 <exercise32>:
 80034d8:\tf006 f934 \tbl\t8009744 <__addsf3>
 800350a:\tf006 f919 \tbl\t8009740 <__aeabi_fsub>
"""
HARD = """ 8003450:\tee30 0a20 \tvadd.f32\ts0, s0, s1
 8003454:\tee30 0a60 \tvsub.f32\ts0, s0, s1
 8003458:\tee20 0a20 \tvmul.f32\ts0, s0, s1
 800345c:\tee80 0a20 \tvdiv.f32\ts0, s0, s1
 8003460:\teeb4 0ac0 \tvcmpe.f32\ts0, s0
 8003660:\tee30 0b01 \tvadd.f64\td0, d0, d1
 8003664:\tee30 0b41 \tvsub.f64\td0, d0, d1
 8003668:\tee20 0b01 \tvmul.f64\td0, d0, d1
 800366c:\tee80 0b01 \tvdiv.f64\td0, d0, d1
 8003670:\teeb4 0b41 \tvcmp.f64\td0, d1
"""
SIZES = {'exercise32': (0x08003450, 0x1be), 'exercise64': (0x0800360e, 0x22a)}


class Instructions(unittest.TestCase):
    def test_software_helpers_are_pending_and_never_passed(self):
        found = BOARD.float_routines(SOFT, SIZES)
        self.assertEqual(BOARD.float_unit(dict(found, exercise64=[])),
                         ('pending', ['__addsf3', '__aeabi_fsub']))

    def test_the_float_unit_passes_only_with_every_operation(self):
        found = BOARD.float_routines(HARD, SIZES)
        self.assertEqual(BOARD.float_unit(found), ('passed', []))
        for missing in ('vdiv.f64', 'vcmpe.f32'):
            with self.subTest(missing=missing):
                lines = BOARD.float_routines(
                    '\n'.join(l for l in HARD.splitlines() if missing not in l), SIZES)
                with self.assertRaises(BOARD.Failed):
                    BOARD.float_unit(lines)

    def test_a_helper_beside_the_float_unit_fails(self):
        mixed = HARD + ' 8003674:\tf006 f934 \tbl\t8009744 <__aeabi_dmul>\n'
        with self.assertRaisesRegex(BOARD.Failed, '__aeabi_dmul'):
            BOARD.float_unit(BOARD.float_routines(mixed, SIZES))

    def test_an_image_without_the_exercises_fails(self):
        with self.assertRaises(BOARD.Failed):
            BOARD.float_unit(BOARD.float_routines(HARD, {'exercise32': SIZES['exercise32']}))


class Hub(unittest.TestCase):
    class Recorded:
        def __init__(self, status):
            self.status, self.calls = status, []

        def command(self, name, argv, **_):
            self.calls.append(name)
            return self.status if name in ('hub-status', 'hub-wait') else ''

    class Paced:
        def __init__(self, calls):
            self.calls = calls

        def before(self, what):
            self.calls.append('before ' + what)

        def after(self, what):
            self.calls.append('after ' + what)

    LISTING = ('Current status for hub 7-2.3 [0bda:5411 Generic USB2.1 Hub]\n'
               '  Port 2: 0103 power enable connect [0483:374e STMicroelectronics'
               ' STLINK-V3 001900293137511339383538]\n')

    def args(self, hub):
        return SimpleNamespace(hub='7-2.3', port=2, off_seconds=1.0, hub_seconds=0,
                               serial='001900293137511339383538', guard_serial='210319B3E738',
                               cascade='7-2', pace=self.Paced(hub.calls))

    def setUp(self):
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_only_the_port_holding_the_st_link_is_switched(self):
        hub = self.Recorded(self.LISTING)
        BOARD.power_cycle(hub, self.args(hub))
        # D725: paced, and the ST-LINK listed again before the console.
        self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'power-cycle',
                                     'after power cycle', 'hub-wait'])
        hub = self.Recorded(self.LISTING.replace('Port 2', 'Port 3'))
        with self.assertRaises(BOARD.Failed):
            BOARD.power_cycle(hub, self.args(hub))
        self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'after power cycle'])

    def test_nothing_is_switched_while_the_arty_is_on_the_cascade_or_absent(self):
        for where in ('7-2.3.4', None):
            hub = self.Recorded(self.LISTING)
            with mock.patch.object(BOARD.common, 'device_location', return_value=where), \
                    self.assertRaises(BOARD.Failed):
                BOARD.power_cycle(hub, self.args(hub))
            self.assertEqual(hub.calls, [])

    def test_a_cycle_waits_for_the_st_link_to_be_listed_again(self):
        hub = self.Recorded(self.LISTING)
        hub.status = self.LISTING.replace('STLINK-V3 001900293137511339383538', '')
        with self.assertRaisesRegex(BOARD.Failed, 'did not list 001900293137511339383538 on port 2'):
            BOARD.settle(hub, self.args(hub))


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
            argv += ['--objdump=objdump', '--readelf=readelf']
            built = (elf, b'', {}, {'float_unit': 'passed'})
            def scenario(*_):
                if failure == 'usb':
                    pace.blocked = 'xhci_hcd: HC died'
                    raise BOARD.common.USBGuardError(pace.blocked)
                if failure:
                    raise BOARD.Failed('application did not answer')
                return ({'boot': {'cpacr': BOARD.CPACR_FPU}}, {'c': 1}, 0)
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
                patch(BOARD.common, 'rerun_in_group')
                hardware.append(patch(BOARD.common, 'wait_for_tty', return_value=Path(tmp) / 'tty'))
                hardware.append(patch(BOARD.common, 'TtyConsole', return_value=console))
                hardware.append(patch(BOARD, 'floats', return_value={'square_root': 'passed'}))
                hardware.append(patch(BOARD, 'report', return_value={'c': 1}))
                hardware.append(patch(BOARD, 'scenario', side_effect=scenario))
                restore = patch(BOARD, 'restore_fixed', side_effect=lambda *_:
                    events.append('restore') or {'value': BOARD.common.FIXED_READY_MAGIC})
                status = BOARD.main()
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


if __name__ == '__main__':
    unittest.main()
