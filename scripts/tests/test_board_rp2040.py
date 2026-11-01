#!/usr/bin/env python3
"""Controls for the RP2040 board tool's oracle, without a board (D595)."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

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
        return self.status if name == 'hub-status' else ''


STATUS = """Current status for hub 7-2.3.3 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]
  Port 1: 0100 power
  Port 2: 0103 power enable connect [2e8a:000f]
  Port 3: 0100 power
  Port 4: 0503 power highspeed enable connect [0403:6010 Digilent Digilent USB Device 210319B3E738]
"""


class Oracle(unittest.TestCase):
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

    def test_a_hub_whose_guarded_port_is_not_the_device_named_is_not_switched(self):
        args = SimpleNamespace(hub='7-2.3.3', port=1, guard_port=4,
                               guard_serial='210319B3E738', off_seconds=0)
        for status in (STATUS.replace('210319B3E738', 'SOMEONE-ELSE'),
                       STATUS.replace('  Port 4:', '  Port 5:')):
            hub = Hub(status)
            with self.assertRaises(BOARD.Failed):
                BOARD.power_cycle(hub, args)
            self.assertEqual(hub.calls, ['hub-status'])
        hub = Hub(STATUS)
        with self.assertRaises(BOARD.Failed):
            BOARD.power_cycle(hub, SimpleNamespace(vars(args), port=4))
        self.assertEqual(hub.calls, ['hub-status'])
        hub = Hub(STATUS)
        BOARD.power_cycle(hub, args)
        self.assertEqual(hub.calls, ['hub-status', 'power-cycle'])


if __name__ == '__main__':
    unittest.main()
