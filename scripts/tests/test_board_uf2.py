#!/usr/bin/env python3
"""Offline UF2 framing, exact flash payload and refused recovery images."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import uf2

SPEC = importlib.util.spec_from_file_location('uf2_test_elf', ROOT / 'scripts/tests/test_board_common.py')
ELF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ELF)


def executable(block=uf2.IMAGE_DEF, extra=(), segments=None):
    vectors = struct.pack('<68I', 0x20082000, 0x10000201, *([0] * 66))
    sections = [('.isr_vector', uf2.FLASH, vectors),
                ('.embedded_block', uf2.FLASH + len(vectors), struct.pack('<5I', *block)),
                ('.text', uf2.FLASH + 0x200, b'\xfe\xe7' + bytes(range(253)))] + list(extra)
    if segments is None:
        segments = [(address, name) for name, address, _ in sections]
    data = bytearray(ELF.elf32(sections, segments))
    struct.pack_into('<I', data, 24, 0x10000201)
    return bytes(data)


def jal(address, target):
    offset = (target - address) & 0x1fffff
    return (((offset >> 20) & 1) << 31 | ((offset >> 1) & 0x3ff) << 21
            | ((offset >> 11) & 1) << 20 | ((offset >> 12) & 0xff) << 12 | 0x6f)


def riscv_executable(block=uf2.RISCV_IMAGE_DEF, bad_slot=None):
    reset, handler = uf2.FLASH + 0x400, uf2.FLASH + 0x408
    vectors = [jal(uf2.FLASH + 512 + index * 4, handler) for index in range(68)]
    if bad_slot is not None:
        vectors[bad_slot] = 0
    sections = [('.entry', uf2.FLASH, struct.pack('<I', jal(uf2.FLASH, reset))),
                ('.isr_vector', uf2.FLASH + 512, struct.pack('<68I', *vectors)),
                ('.embedded_block', uf2.FLASH + 512 + 68 * 4, struct.pack('<5I', *block)),
                ('.text', reset, bytes(range(16)))]
    data = bytearray(ELF.elf32(sections, [(address, name) for name, address, _ in sections]))
    struct.pack_into('<H', data, 18, 243)
    struct.pack_into('<I', data, 24, uf2.FLASH)
    return bytes(data)


class RecoveryUF2(unittest.TestCase):
    def convert(self, data, architecture='arm'):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixed.elf'
            path.write_bytes(data)
            return uf2.convert(path, architecture)

    def test_hazard3_family_framing_and_complete_payload(self):
        source = riscv_executable()
        result = self.convert(source, 'hazard3')
        memory = {}
        pages = []
        for number in range(len(result) // 512):
            block = result[number * 512:(number + 1) * 512]
            header = struct.unpack_from('<8I', block)
            self.assertEqual(header[:3], (0x0a324655, 0x9e5d5157, 0x2000))
            self.assertEqual(header[4:], (256, number, len(result) // 512, 0xe48bff5a))
            self.assertEqual(header[3] % 256, 0)
            self.assertEqual(block[288:508], bytes(220))
            self.assertEqual(struct.unpack_from('<I', block, 508)[0], 0x0ab16f30)
            pages.append(header[3])
            memory.update((header[3] + i, byte) for i, byte in enumerate(block[32:288]))
        self.assertEqual(pages, sorted(set(pages)))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'hazard3.elf'
            path.write_bytes(source)
            for address, body, _ in uf2.common.elf_segments(path):
                self.assertEqual(bytes(memory[address + i] for i in range(len(body))), body)

    def test_family_architecture_entry_and_every_hazard3_trap_are_checked(self):
        for source, architecture in ((riscv_executable(), 'arm'), (executable(), 'hazard3'),
                                     (riscv_executable(bad_slot=0), 'hazard3'),
                                     (riscv_executable(bad_slot=67), 'hazard3'),
                                     (riscv_executable(block=uf2.IMAGE_DEF), 'hazard3')):
            with self.subTest(architecture=architecture), self.assertRaises(uf2.common.Failed):
                self.convert(source, architecture)
        bad_entry = bytearray(riscv_executable())
        struct.pack_into('<I', bad_entry, 24, uf2.FLASH + 0x408)
        with self.assertRaisesRegex(uf2.common.Failed, 'flash entry'):
            self.convert(bad_entry, 'hazard3')
        for index in range(5):
            block = list(uf2.RISCV_IMAGE_DEF)
            block[index] ^= 1
            with self.subTest(index=index), self.assertRaisesRegex(uf2.common.Failed, 'IMAGE_DEF'):
                self.convert(riscv_executable(block=block), 'hazard3')

    def test_headers_and_payload_reconstruct_every_flash_byte(self):
        source = executable(extra=[('.data', uf2.FLASH + 0x900, b'initialized')])
        result = self.convert(source)
        memory = {}
        count = len(result) // 512
        self.assertEqual(count, 4)
        for number in range(count):
            block = result[number * 512:(number + 1) * 512]
            magic, magic2, flags, address, size, index, total, family = struct.unpack_from('<8I', block)
            self.assertEqual((magic, magic2, flags, size, index, total, family),
                             (0x0a324655, 0x9e5d5157, 0x2000, 256, number, count, 0xe48bff59))
            self.assertEqual(block[288:508], bytes(220))
            self.assertEqual(struct.unpack_from('<I', block, 508)[0], 0x0ab16f30)
            self.assertEqual(address % 256, 0)
            memory.update((address + i, byte) for i, byte in enumerate(block[32:288]))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'source.elf'
            path.write_bytes(source)
            for address, body, _ in uf2.common.elf_segments(path):
                self.assertEqual(bytes(memory[address + i] for i in range(len(body))), body)
        self.assertEqual(memory[uf2.FLASH + 0x1ff], 0)  # an unspecified page gap

    def test_wrong_architecture_ram_loads_and_overlaps_are_refused(self):
        riscv = bytearray(executable())
        struct.pack_into('<H', riscv, 18, 243)
        for source in (bytes(riscv),
                       executable(extra=[('.ram', 0x20000000, b'RAM!')]),
                       executable(extra=[('.overlap', uf2.FLASH + 4, b'bad!')])):
            with self.subTest(source=source[:20]), self.assertRaises(uf2.common.Failed):
                self.convert(source)

    def test_every_image_def_word_is_checked(self):
        for index in range(5):
            block = list(uf2.IMAGE_DEF)
            block[index] ^= 1
            with self.subTest(word=index), self.assertRaisesRegex(uf2.common.Failed, 'IMAGE_DEF'):
                self.convert(executable(block=block))

    def test_unloaded_block_invalid_reset_and_truncated_tables_are_refused(self):
        unloaded = executable(segments=[(uf2.FLASH, '.isr_vector'),
                                        (uf2.FLASH + 0x200, '.text')])
        bad_reset = bytearray(executable())
        phoff = struct.unpack_from('<I', bad_reset, 28)[0]
        vectors_at = struct.unpack_from('<I', bad_reset, phoff + 4)[0]
        struct.pack_into('<I', bad_reset, vectors_at + 4, 0x20000001)
        bad_tables = bytearray(executable())
        struct.pack_into('<I', bad_tables, 32, 0xfffffff0)
        for source in (unloaded, bytes(bad_reset), bytes(bad_tables), b'\x7fELF'):
            with self.subTest(length=len(source)), self.assertRaises(uf2.common.Failed):
                self.convert(source)


if __name__ == '__main__':
    unittest.main()
