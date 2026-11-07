#!/usr/bin/env python3
"""core/line's divisor arithmetic against an exact oracle (D955, D956).

The oracle here chooses, among the two integers either side of the exact
divisor, the one nearer it, the larger at a tie, and accepts it when the
register holds it and the rate it gives is within two percent: written
from the definition with fractions, apart from both core/line's integer
arithmetic and the host tools' formulas.  It is held to

* the sweep runtime/library-shared-line folds on every target, whose
  literal must be the oracle's fold, so core/line agrees with it at every
  rate of eight peripheral clocks;
* the host's own formulas: environments/boards/common.py's
  nearest_divisor, the derived driver lane's PL011 oracle, and the
  STM32H753's and the ESP ports' line oracles, over the same rates and the
  standard ones.
"""
from fractions import Fraction
import importlib.util
import math
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
sys.path.insert(0, str(ROOT / 'environments/cortex-m'))
import common  # noqa: E402
import driver  # noqa: E402

FIXTURE = ROOT / 'compiler/tests/fixtures/runtime/library-shared-line/main.ldn'
# (clock, oversampling, fraction bits, least, most), as the fixture's
# `families` lists them: the derived driver's PL011 at 48 MHz and the
# Picos' at 12 MHz, the STM32H753's USART3 at 64 MHz by 16 and by 8, the
# ESP32's 20-bit CLKDIV at 40 MHz and the 12-bit one at 40, 48 and 20 MHz.
FAMILIES = ((48000000, 16, 6, 64, 65535 * 64), (12000000, 16, 6, 64, 65535 * 64),
            (64000000, 16, 4, 16, 65535), (64000000, 8, 4, 16, 65535),
            (40000000, 1, 4, 256, 0xffffff), (40000000, 1, 4, 256, 0xffff),
            (48000000, 1, 4, 256, 0xffff), (20000000, 1, 4, 256, 0xffff))
STANDARD = (300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400,
            460800, 921600, 1000000, 2000000, 3000000)


def sweep():
    """The fixture's rates: 50, then each the last plus a seventh and one,
    to 6,000,000."""
    rate = 50
    while rate <= 6000000:
        yield rate
        rate = rate + rate // 7 + 1


def exact(clock, rate, oversampling, fraction_bits, least, most):
    """The oracle's divisor, or None where it refuses."""
    if rate == 0:
        return None
    ideal = Fraction(clock * 2 ** fraction_bits, oversampling * rate)
    below = math.floor(ideal)
    value = below + 1 if ideal - below >= Fraction(1, 2) else below
    if not least <= value <= most or value == 0:
        return None
    given = Fraction(clock * 2 ** fraction_bits, oversampling * value)
    return value if abs(given - rate) <= Fraction(2, 100) * rate else None


class Divisors(unittest.TestCase):

    def test_the_fixture_folds_the_oracles_sweep(self):
        fold = 0
        for family in FAMILIES:
            for rate in sweep():
                fold = (fold * 1000003 + (exact(family[0], rate, *family[1:]) or 0)) & 0xffffffff
        found = re.search(r'ok = sweep\(\) == (\d+)', FIXTURE.read_text())
        self.assertIsNotNone(found, 'the fixture names no fold')
        self.assertEqual(int(found.group(1)), fold)

    def test_the_fixtures_literals_are_the_oracles(self):
        pl011, picos, h753, _, esp32, s3, _, _ = FAMILIES
        self.assertEqual(exact(pl011[0], 115200, *pl011[1:]), 26 * 64 + 3)
        self.assertEqual(exact(picos[0], 115200, *picos[1:]), 6 * 64 + 33)
        self.assertEqual(exact(h753[0], 115200, *h753[1:]), 556)
        self.assertEqual(exact(esp32[0], 115200, *esp32[1:]), 347 * 16 + 4)
        self.assertIsNone(exact(pl011[0], 45, *pl011[1:]))
        self.assertEqual(exact(pl011[0], 46, *pl011[1:]), 4173913)
        self.assertIsNone(exact(pl011[0], 3100000, *pl011[1:]))
        # In range but 2.56 percent fast: the tolerance refuses it.
        self.assertIsNone(exact(h753[0], 3900000, *h753[1:]))
        self.assertTrue(16 <= round(Fraction(h753[0], 3900000)) <= 65535)
        self.assertEqual(exact(h753[0], 3800000, *h753[1:]), 17)
        self.assertIsNone(exact(s3[0], 9600, *s3[1:]))

    def test_the_hosts_formula_agrees(self):
        for family in FAMILIES:
            for rate in (*sweep(), *STANDARD):
                with self.subTest(family=family, rate=rate):
                    self.assertEqual(common.nearest_divisor(family[0], rate, *family[1:]),
                                     exact(family[0], rate, *family[1:]))

    def test_the_driver_lanes_pl011_oracle_agrees(self):
        clock = driver.DriverPeripheral.CLOCK
        for rate in (*sweep(), *STANDARD):
            value = exact(clock, rate, 16, 6, 64, 65535 * 64)
            for data_bits, parity, stop_bits in ((8, 0, 1), (5, 1, 2), (7, 2, 1)):
                with self.subTest(rate=rate, frame=(data_bits, parity, stop_bits)):
                    images = driver.pl011(rate, data_bits, parity, stop_bits)
                    self.assertEqual(images and images[0] * 64 + images[1], value)
                    if images:
                        self.assertEqual(images[2], (data_bits - 5) << 5 | 0x10
                                         | (8 if stop_bits == 2 else 0) | (0, 6, 2)[parity])
        self.assertIsNone(driver.pl011(115200, 9, 0, 1))
        self.assertIsNone(driver.pl011(115200, 4, 0, 1))

    def test_the_board_oracles_agree(self):
        spec = importlib.util.spec_from_file_location(
            'h753_board', ROOT / 'environments/boards/stm32h753/board.py')
        h753 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(h753)
        import esp
        import xtensa
        ports = ((h753.line_oracle, 64000000, 16, 4, 16, 65535, lambda i: i['b']),
                 (esp.line_oracle(xtensa.ESP32()), 40000000, 1, 4, 256, 0xffffff,
                  lambda i: (i['b'] & 0xfffff) << 4 | i['b'] >> 20),
                 (esp.line_oracle(xtensa.ESP32S3()), 40000000, 1, 4, 256, 0xffff,
                  lambda i: (i['b'] & 0xfff) << 4 | i['b'] >> 20))
        for oracle, clock, oversampling, bits, least, most, divisor in ports:
            for rate in (*sweep(), *STANDARD):
                with self.subTest(oracle=oracle, rate=rate):
                    outcome, images = oracle((rate, 8, 'none', 1), clock)
                    value = exact(clock, rate, oversampling, bits, least, most)
                    self.assertEqual(outcome, 'accepted' if value else 'unsupported_rate')
                    if value:
                        self.assertEqual(divisor(images), value)
        # The defaults every port writes today.
        self.assertEqual(h753.line_oracle(common.DEFAULT_LINE, 64000000),
                         ('accepted', dict(b=556, f=0, x=0)))
        self.assertEqual(esp.line_oracle(xtensa.ESP32())(common.DEFAULT_LINE, 40000000),
                         ('accepted', dict(b=0x0040015b, f=0x1c)))


if __name__ == '__main__':
    unittest.main()
