#!/usr/bin/env python3
"""Bounded malformed Mach-O and source/dSYM substitution controls."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import macho_identity


def binary(kind=2, uuid=b'u' * 16, digest=b'a' * 64):
    section = struct.pack('<16s16sQQ8I', b'__landin_id', b'__TEXT', 0, 64,
                          32 + 24 + 152, 0, 0, 0, 0, 0, 0, 0)
    segment = struct.pack('<II16s4Q4I', 0x19, 152, b'__TEXT', 0, 64, 0, 64, 5, 5, 1, 0) + section
    return (struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, kind, 2, 176, 0, 0)
            + struct.pack('<II16s', 0x1B, 24, uuid) + segment + digest)


class MachOIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.exe = self.root / 'exe'
        self.exe.write_bytes(binary())
        self.dsym = self.root / 'debug'
        self.dsym.write_bytes(binary(kind=10, digest=b'\0' * 64))
        self.table = {'build_id': 'a' * 64, 'files': [{'file_id': 2, 'path_hex': b'odd"\\path.ldn'.hex()}]}

    def test_executable_matches_and_dsym_uses_uuid_not_virtual_text(self):
        self.assertEqual(macho_identity.match(self.table, self.exe, self.dsym)['uuid'], (b'u' * 16).hex())

    def test_mismatched_map_and_dsym_refused(self):
        for table, data in ((dict(self.table, build_id='b' * 64), binary(kind=10)),
                            (self.table, binary(kind=10, uuid=b'v' * 16))):
            self.dsym.write_bytes(data)
            with self.assertRaises(ValueError):
                macho_identity.match(table, self.exe, self.dsym)

    def test_malformed_headers_sections_and_digest_refused(self):
        good = binary()
        for data in (good[:20], b'ELF!' + good[4:], good[:40], good[:-1],
                     good[:-64] + b'z' * 64):
            self.exe.write_bytes(data)
            with self.assertRaises(ValueError):
                macho_identity.identity(self.exe)
        for offset, value in ((16, 9999), (20, 9999), (36, 0), (60, 8), (120, 2), (176, 9999)):
            data = bytearray(good)
            struct.pack_into('<I', data, offset, value)
            self.exe.write_bytes(data)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                macho_identity.identity(self.exe)

    def test_cli_matching_and_mismatch(self):
        table = self.root / 'map.json'
        table.write_text(json.dumps(self.table))
        args = [sys.executable, ROOT / 'scripts/source-location.py', table, '2', '11', '12',
                '--macho', self.exe, '--dsym', self.dsym]
        result = subprocess.run(args, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'odd"\\path.ldn:11:12\n')
        self.dsym.write_bytes(binary(kind=10, uuid=b'v' * 16))
        result = subprocess.run(args, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'UUID does not match', result.stderr)


if __name__ == '__main__':
    unittest.main()
