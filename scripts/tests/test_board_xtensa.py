#!/usr/bin/env python3
"""Offline controls for the two windowed, internal-SRAM ESP ports."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
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


if __name__ == '__main__':
    unittest.main()
