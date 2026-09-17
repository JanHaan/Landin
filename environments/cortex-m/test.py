#!/usr/bin/env python3
"""Failure controls for the embedded probe supervisor; no emulator needed."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

from run import Run, oracle, remove_renode_lock


class ProbeFailures(unittest.TestCase):
    def test_oracle_refuses_false_pass(self):
        for text in ('', 'PASS PASS', 'PASS\nAssertionError', 'PASS\n[WARNING] bad',
                     'PASS\nThere was an error executing command'):
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                oracle(text, 'PASS')
        oracle('PASS', 'PASS')

    def command_failure(self, argv, timeout=2):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = Run(root, root / 'absent-tools')
            with self.assertRaises((RuntimeError, OSError)):
                run.command('failure', argv, timeout)
            record = json.loads((root / 'commands.json').read_text())[0]
            self.assertNotEqual(record.get('exit'), 0)
            return record

    def test_missing_tool(self):
        self.command_failure(['/nonexistent/r610/tool'])

    def test_failed_command(self):
        self.assertEqual(self.command_failure([sys.executable, '-c', 'raise SystemExit(9)'])['exit'], 9)

    def test_timeout(self):
        record = self.command_failure([sys.executable, '-c', 'import time; time.sleep(10)'], .05)
        self.assertTrue(record['timed_out'])

    def test_ephemeral_renode_lock_is_not_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = root / 'renode.config.lock'
            lock.touch()
            remove_renode_lock(root)
            self.assertFalse(lock.exists())
            lock.write_text('unexpected bytes')
            with self.assertRaises(RuntimeError):
                remove_renode_lock(root)
            lock.unlink()
            lock.symlink_to(root / 'absent')
            with self.assertRaises(RuntimeError):
                remove_renode_lock(root)

    def test_abi_contract_and_synthetic_goldens(self):
        from abi import contract, synthetic_agreement, CONTRACT, GOLDEN
        text = CONTRACT.read_text()
        rows = contract(text)
        synthetic_agreement(rows, GOLDEN.read_text())
        for bad in (text + 'u8 1 1\n', text.replace('u8 1 1\n', ''),
                    text.replace('gap.arg1 0 1 0 0 0', 'gap.arg1 3 2 0 0 0')):
            with self.assertRaises(ValueError):
                contract(bad)
        rows['usize'] = [8, 8]
        with self.assertRaises(ValueError):
            synthetic_agreement(rows, GOLDEN.read_text())

    def test_memory_model_independent_oracles(self):
        from memory_model import run as model, store_buffer, sc_oracle, publication
        from unittest.mock import patch
        result = model()
        self.assertEqual(result['status'], 'passed')
        self.assertNotIn((0, 0), sc_oracle())
        self.assertIn((0, 0), store_buffer(False)[0])
        self.assertIn(0, publication(False))
        # Removing the drain obligation must fail the independent oracle.
        original = store_buffer
        with patch('memory_model.store_buffer', side_effect=lambda fence: original(False)):
            with self.assertRaises(AssertionError):
                model()

    def test_complete_backend_inventory_and_counterparts(self):
        from backend_corpus import inventory
        from unittest.mock import patch
        rows = inventory()
        self.assertGreater(len(rows), 500)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'corpus.json').write_text('{"schema":1,"fixtures":{}}')
            with patch('backend_corpus.COUNTERPARTS', root):
                with self.assertRaisesRegex(RuntimeError, 'inventory disagrees'):
                    inventory()

    def test_image_limit_does_not_hide_codegen_failure(self):
        from backend_corpus import image_limit
        row = {'profile_limit': 'selected-image', 'reason': 'test physical map'}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = Run(root, root)
            for text in ("undefined reference to helper",
                         "region `FLASH' overflowed by 8 bytes; undefined reference to helper",
                         "region `RAM' overflowed by 8 bytes; Assembler messages: bad instruction"):
                (root / 'assemble-link.log').write_text(text)
                with self.assertRaises(RuntimeError):
                    image_limit(run, row, RuntimeError('assemble-link failed; inspect retained log'))
            with self.assertRaises(RuntimeError):
                image_limit(run, row, RuntimeError('gdb-backend failed; inspect retained log'))
            (root / 'assemble-link.log').write_text("region `FLASH' overflowed by 8 bytes")
            result = image_limit(run, row, RuntimeError('assemble-link failed; inspect retained log'))
            self.assertEqual(result['verdict'], 'selected-image-limit')
            self.assertEqual(result['overflow_bytes'], {'FLASH': 8})

    def test_compact_images_are_bounded_before_assembler(self):
        from backend import preflight
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.s'
            for text in ('.zero 2147483688', '.rept 4294967295\n.quad 0\n.endr'):
                path.write_text(text)
                with self.assertRaisesRegex(RuntimeError, 'materialization exceeds'):
                    preflight(path)
            path.write_text('.rept 0\n.quad 1\n.endr\n.byte 42')
            self.assertEqual(preflight(path), 1)
            path.write_text('.endr')
            with self.assertRaisesRegex(RuntimeError, 'unbalanced'):
                preflight(path)

    def test_elf_profile_guard_checks_physical_extents(self):
        import struct
        from backend import image_contract
        # A structural ELF witness only; no instruction execution is claimed.
        header = struct.pack('<16sHHIIIIIHHHHHH', b'\x7fELF\x01\x01' + b'\0'*10,
                             2, 40, 1, 193, 52, 0, 0, 52, 32, 1, 0, 0, 0)
        segment = struct.pack('<8I', 1, 84, 0, 0, 256, 256, 5, 4)
        payload = struct.pack('<II', 0x20004000, 193) + b'\0'*248
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.elf'
            original = header + segment + payload
            path.write_bytes(original)
            self.assertEqual(image_contract(path)['flash_load_extent'], 256)
            for offset, value in ((52+12, 32768), (52+8, 0x20002fff), (84, 0), (24, 192)):
                altered = bytearray(original)
                struct.pack_into('<I', altered, offset, value)
                path.write_bytes(altered)
                with self.assertRaises(RuntimeError):
                    image_contract(path)

    def test_unsupported_host(self):
        from unittest.mock import patch
        from setup import supported_host
        with patch('platform.system', return_value='Darwin'), self.assertRaises(RuntimeError):
            supported_host()

    def test_wrong_tool_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'installation.json').write_text('{"lock_sha256":"wrong"}')
            from unittest.mock import patch
            with patch('run.supported_host'), self.assertRaisesRegex(RuntimeError, 'tool lock mismatch'):
                Run(root, root).execute()


if __name__ == '__main__':
    unittest.main()
