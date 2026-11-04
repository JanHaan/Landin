#!/usr/bin/env python3
"""Offline controls for the two windowed, internal-SRAM ESP ports."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import common
import esp
import xtensa
from scripts.tests.test_board_common import elf32


def ram_elf(chip):
    stack = common.RAM_REGIONS[chip.name][1][1]
    names = ('_landin_firmware_stack_bottom', '_landin_firmware_stack_top')
    strings = b'\0' + b''.join(n.encode() + b'\0' for n in names)
    symbols, offset = bytearray(bytes(16)), 1
    for name, address in zip(names, (stack - 4096, stack)):
        symbols += struct.pack('<IIIBBH', offset, address, 0, 0x10, 0, 0xfff1)
        offset += len(name) + 1
    data = bytearray(elf32([
        ('.isr_vector', chip.origin, bytes(1024)),
        ('.text', chip.origin + 1024, b'code'),
        ('.strtab', 0, strings), ('.symtab', 0, symbols)],
        [(chip.origin, '.isr_vector'), (chip.origin + 1024, '.text')]))
    struct.pack_into('<H', data, 18, 94)
    struct.pack_into('<I', data, 24, chip.origin + 1024)
    table = struct.unpack_from('<I', data, 32)[0]
    for index in (3, 4):
        struct.pack_into('<I', data, table + index * 40 + 8, 0)
    struct.pack_into('<I', data, table + 3 * 40 + 4, 3)
    struct.pack_into('<I', data, table + 4 * 40 + 4, 2)
    struct.pack_into('<I', data, table + 4 * 40 + 24, 3)
    struct.pack_into('<I', data, table + 4 * 40 + 36, 16)
    return data


class Image(unittest.TestCase):
    def test_each_ram_map_and_entry_accepts_only_its_own_elf(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.elf'
            for chip in (xtensa.ESP32(), xtensa.ESP32S3()):
                with self.subTest(chip=chip.name):
                    good = ram_elf(chip)
                    path.write_bytes(good)
                    self.assertEqual(common.validate_ram_image(path, chip.name), chip.origin)
                    other = 'esp32s3' if chip.name == 'esp32' else 'esp32'
                    with self.assertRaises(common.Failed):
                        common.validate_ram_image(path, other)
                    for offset, value in ((18, 243), (24, chip.origin)):
                        bad = bytearray(good)
                        struct.pack_into('<H' if offset == 18 else '<I', bad, offset, value)
                        path.write_bytes(bad)
                        with self.assertRaises(common.Failed):
                            common.validate_ram_image(path, chip.name)

    def test_vectors_and_warm_state_are_independent_oracles(self):
        chip = xtensa.ESP32S3()
        named = {'_landin_firmware_vectors': chip.origin}
        self.assertEqual(chip.mtvec({'.isr_vector': (chip.origin, 0, 1024)}, named), chip.origin)
        for length in (256, 1023, 1025):
            with self.assertRaises(common.Failed):
                chip.mtvec({'.isr_vector': (chip.origin, 0, length)}, named)
        self.assertEqual(chip.boot(dict(d=0, f=0, p=0x86))['cpu1_stall'], 0x86)
        for field, value in (('d', 1), ('f', 1), ('p', 0)):
            with self.assertRaises(common.Failed):
                chip.boot(dict(dict(d=0, f=0, p=0x86), **{field: value}))

    def test_rom_decimal_lengths_and_reset_names_are_chip_specific(self):
        image = dict(entry=0x40080400, segments=[(0x40080000, bytes(1024))])
        text = ('rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)\n'
                'load:0x40080000,len:1024\nentry 0x40080400\n')
        self.assertEqual(esp.boot_log(text, image, xtensa.ESP32())['reset'], 'POWERON_RESET')
        with self.assertRaises(common.Failed):
            esp.boot_log(text, image, xtensa.ESP32S3())
        self.assertEqual(common.rom_log(text.replace('len:1024', 'len:0x400'))['loads'],
                         [(0x40080000, 1024)])

    def test_cold_fixed_image_must_reach_its_marker_before_uart_reset(self):
        chip = xtensa.ESP32()
        probe = mock.Mock()
        named = {common.FIXED_READY_SYMBOL: 0x3ffb0000}
        probe.read_words.side_effect = [[1], [common.FIXED_READY_MAGIC]]
        self.assertEqual(xtensa.power_on_boot(probe, chip, named)['reset_cause'], 1)
        probe.read_words.side_effect = [[1], [0]]
        with self.assertRaises(common.Failed):
            xtensa.power_on_boot(probe, chip, named)
        probe.read_words.side_effect = [[3]]
        with self.assertRaises(common.Failed):
            xtensa.power_on_boot(probe, chip, named)


class Inspection(unittest.TestCase):
    def args(self, path):
        return SimpleNamespace(mode='boot', record=None, bundle=path / 'bundle', recover=False,
            image_control=False, ram_loader='loader', probe_rs='probe-rs', probe='P',
            output=path / 'inspection', pace=common.Pace(state=path / 'pace', kernel=lambda _: []))

    def test_inspection_admission_precedes_preflight_or_any_probe(self):
        for flags, phrase in (([], '--mode=boot'), (['--mode=boot', '--record=record.json'], '--record'),
                (['--mode=boot'], 'checked bundle'),
                (['--mode=boot', '--bundle=bundle', '--recover'], 'recovery'),
                (['--mode=boot', '--bundle=bundle', '--image-control'], 'image controls')):
            with self.subTest(flags=flags), mock.patch.object(sys, 'argv',
                    ['board.py', '--inspect-boot', '--output=unused', *flags]), \
                    mock.patch.object(common, 'board_preflight') as preflight, \
                    mock.patch.object(common, 'Probe') as probe:
                with self.assertRaisesRegex(common.Failed, phrase):
                    xtensa.main(xtensa.ESP32S3, 'inspection control')
                preflight.assert_not_called()
                probe.assert_not_called()

    def test_inspection_flag_bypasses_hub_discovery_and_normal_boot_workflow(self):
        with mock.patch.object(sys, 'argv', ['board.py', '--inspect-boot', '--mode=boot',
                '--bundle=checked', '--output=observations']), \
                mock.patch.object(common, 'board_preflight') as preflight, \
                mock.patch.object(common, 'rerun_in_group'), \
                mock.patch.object(esp, 'required_tools'), \
                mock.patch.object(xtensa, 'inspect_boot', return_value=0) as inspect, \
                mock.patch.object(common, 'place_hubs') as hubs, \
                mock.patch.object(esp, 'run_board') as normal:
            self.assertEqual(xtensa.main(xtensa.ESP32S3, 'inspection control'), 0)
            preflight.assert_called_once()
            inspect.assert_called_once()
            self.assertTrue(inspect.call_args.args[1].inspect_boot)
            hubs.assert_not_called()
            normal.assert_not_called()

    def observe(self, chip, pointer=0x3fce1000, fail_read=None, helper_error=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name)
        args = self.args(path)
        elf = path / 'app.elf'
        elf.write_bytes(b'checked bundle ELF')
        names = {'_landin_firmware_trap_' + cell: 0x3fca9000 + 4 * index
                 for index, cell in enumerate(esp.TRAP_CELLS)}
        args.prepared_bundle = dict(symbols=names)
        lock = mock.Mock()
        probe = mock.Mock()
        events = []
        def read(name, address, count):
            lock.acquire.assert_called_once()
            lock.release.assert_not_called()
            events.append((name, address, count))
            if name == fail_read:
                raise common.Failed('read control')
            if address == 0x3fceffc4:
                return [pointer]
            if address in (0x600c4000, 0x600c4060, 0x3ff00040, 0x3ff00058):
                return [9]  # Cache-enabled pre-state remains an observation.
            return [0] * count  # Unstalled CPU1 is observable too.
        probe.read_words.side_effect = read
        with mock.patch.object(common, 'verify_ram_helper', return_value={'source_sha256': 'checked'},
                side_effect=helper_error) as helper, \
                mock.patch.object(esp, 'build', return_value=(elf, None, {})), \
                mock.patch.object(common, 'fixed_elf', return_value=elf), \
                mock.patch.object(common, 'fixed_marker_address', return_value=0x3fca8000), \
                mock.patch.object(common, 'rig_lock', return_value=lock), \
                mock.patch.object(common, 'Probe', return_value=probe) as factory, \
                mock.patch.object(esp, 'run_board') as normal, \
                mock.patch.object(common, 'switch_ports') as power, \
                mock.patch.object(common, 'finish_boot') as restore, \
                mock.patch.object(common, 'TtyConsole') as console, \
                contextlib.redirect_stdout(io.StringIO()):
            if helper_error:
                with self.assertRaisesRegex(common.Failed, 'stale helper'):
                    xtensa.inspect_boot(chip, args)
                lock.acquire.assert_not_called()
                factory.assert_not_called()
                return None
            status = xtensa.inspect_boot(chip, args)
            helper.assert_called_once_with(args)
            self.assertEqual(factory.call_args.kwargs['read_mode'], 'boot-read')
            self.assertNotIn('require_cpu1_stalled', factory.call_args.kwargs)
            self.assertEqual(probe.method_calls, [mock.call.read_words(*event) for event in events])
            for action in (normal, power, restore, console):
                action.assert_not_called()
        lock.release.assert_called_once()
        return status, json.loads((args.output / 'result.json').read_text()), events

    def test_both_ports_observe_enabled_caches_and_unstalled_cpu1_without_board_verdict(self):
        for chip in (xtensa.ESP32(), xtensa.ESP32S3()):
            with self.subTest(board=chip.name):
                status, result, events = self.observe(chip)
                self.assertEqual((status, result['status'], result['scope']), (0, 'observed', 'boot-inspection'))
                self.assertTrue(result['observational'])
                self.assertEqual(result['active_image'], 'not-established')
                self.assertFalse(result['cpu1']['cpu1_stalled'])
                self.assertTrue(all(cache['enabled'] for cache in result['caches'].values()))
                for field in ('flash_written', 'reset_requested', 'power_switched'):
                    self.assertFalse(result[field])
                self.assertEqual(result['kernel_usb']['status'], 'captured')
                self.assertEqual(len(events), len(result['observations']))
                self.assertTrue(all('seconds' in item and 'bytes_le' in item for item in result['observations']))
                symbols = [item for item in result['observations'] if item['name'].startswith(('fixed-', 'trap-'))]
                self.assertEqual(len(symbols), 6)
                self.assertTrue(all('active image unknown' in item['role'] for item in symbols))
                if chip.name == 'esp32':
                    self.assertIn(('inspect-gpio-strap', 0x3ff44038, 1), events)
                    self.assertIn(('inspect-rtc-sdio-conf', 0x3ff48074, 1), events)
                else:
                    for address in (0x400016f8, 0x4000186c, 0x40001884, 0x4004eaec, 0x4004f2b8, 0x4004f32c):
                        self.assertIn(address, [event[1] for event in events])
                    self.assertIn(('inspect-rom-table', 0x3fce1000, 16), events)
                    self.assertFalse(result['rom_table']['callbacks_dereferenced'])

    def test_rom_pointer_never_allows_arbitrary_or_out_of_bound_reads(self):
        for pointer, count in ((0, 0), (0x40000000, 0), (0x3fce0001, 0),
                               (0x3fcf0000, 0), (0x3fcefffc, 1), (0x3ff1e2b4, 16),
                               (0x3ff1e2b0, 0), (0x3ff1e2b8, 0)):
            with self.subTest(pointer=pointer):
                status, result, events = self.observe(xtensa.ESP32S3(), pointer)
                tables = [event for event in events if event[0] == 'inspect-rom-table']
                self.assertEqual(tables, [('inspect-rom-table', pointer, count)] if count else [])
                self.assertEqual(status, 0)
                if not count:
                    self.assertIn('skipped', result['rom_table'])

    def test_failed_read_is_timed_retained_and_never_retried(self):
        status, result, events = self.observe(xtensa.ESP32S3(), fail_read='inspect-data-cache')
        self.assertEqual((status, result['status']), (1, 'failed'))
        self.assertEqual(len(events), 2)
        self.assertEqual(result['observations'][-1]['error'], 'read control')
        self.assertIn('seconds', result['observations'][-1])
        self.assertIn('kernel_usb', result)

    def test_stale_helper_is_refused_before_lock_or_probe(self):
        self.observe(xtensa.ESP32S3(), helper_error=common.Failed('stale helper'))


if __name__ == '__main__':
    unittest.main()
