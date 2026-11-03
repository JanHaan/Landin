#!/usr/bin/env python3
"""Controls for the RP2040 board tool's oracle, without a board (D595)."""
import importlib.util
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


class Oracle(unittest.TestCase):
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
            argv = ['board.py', '--refine=refine', '--ram-loader=loader', '--probe-rs=probe',
                    '--nm=nm', '--probehive=' + tmp, '--output=' + tmp + '/run', '--cascade=1-1']
            with mock.patch.object(BOARD.sys, 'argv', argv), \
                    mock.patch.object(BOARD.common, 'place_hubs'), \
                    mock.patch.object(BOARD.common, 'Pace'), \
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

if __name__ == '__main__':
    unittest.main()
