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


class RecoveryUF2(unittest.TestCase):
    def convert(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixed.elf'
            path.write_bytes(data)
            return uf2.convert(path)

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
