#!/usr/bin/env python3
"""Failure controls for the embedded probe supervisor; no emulator needed."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

from run import Run, oracle, remove_renode_lock


class ProbeFailures(unittest.TestCase):
    def test_mandatory_runner_keeps_every_embedded_lane(self):
        from contextlib import ExitStack
        import importlib
        from unittest.mock import patch
        from run import HERE
        from setup import sha
        calls=[]
        lanes=[('abi','execute'),('memory','execute'),('packed','execute'),
               ('packed_native','execute'),('backend_acceptance','execute'),
               ('firmware','execute_suite'),('freestanding','execute_suite'),
               ('devices','execute_suite'),('driver','execute_suite'),
               ('evidence','execute_suite')]
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root=Path(directory)
            (root/'installation.json').write_text(json.dumps({
                'lock_sha256':sha(HERE/'tools.lock.json'),
                'files':{'root':{},'renode':{}}}))
            stack.enter_context(patch('run.supported_host'))
            stack.enter_context(patch('run.inventory',return_value={}))
            stack.enter_context(patch.object(Run,'command',return_value=
                '10.0.13 14.2.1 20241119 2.44 16.3 1.17.0+20260907gitf1dd1b4af'))
            stack.enter_context(patch.object(Run,'qemu',side_effect=lambda:calls.append('qemu')))
            stack.enter_context(patch.object(Run,'peripheral',side_effect=lambda:calls.append('peripheral')))
            for name, entry in lanes:
                stack.enter_context(patch.object(importlib.import_module(name),entry,
                    side_effect=lambda *args,n=name:calls.append(n)))
            Run(root,root).execute(Path('relative/refine'))
        self.assertEqual(calls,['qemu','peripheral']+[n for n,_ in lanes])

    def test_stack_observation_sites(self):
        from resources import hook_addresses
        sites, changes = hook_addresses('''000000c0 <reset>:
  c0: b4f0       push {r4, r5, r6, r7}
  c2: b084       sub sp, #16
  c4: 4695       mov sp, r2
  c6: f380 8808  msr MSP, r0
  ca: 4770       bx lr
  cc: 00000000   .word 0x00000000
''')
        self.assertEqual(sites, [0xc0,0xc2,0xc4,0xc6,0xca])
        self.assertEqual(len(changes), 4)
        with self.assertRaises(RuntimeError):
            hook_addresses('00000000 <empty>:\n  0: 4770 bx lr\n')

    def test_debug_selector_rejects_malformed_elf(self):
        import source_debug
        from cortex_debug import Image
        self.assertTrue(callable(source_debug.checked))
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'bad.elf'
            for data in (b'', b'\x7fELF\x01\x02'+bytes(100),
                         b'\x7fELF\x01\x01\x01'+bytes(100)):
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    Image(path)

    def test_freestanding_module_and_linker_closure(self):
        from freestanding import imports, linker_closure, programs
        self.assertEqual(imports('import core/mem\nimport core/cpu\n'), {'mem', 'cpu'})
        for name in ('heap', 'io', 'c', '../heap'):
            with self.assertRaises(RuntimeError):
                imports('import core/'+name)
        helper = '/tools/thumb/v6-m/nofp/libgcc.a'
        base = 'LOAD core.elf.o\nLOAD '+helper+'\n'
        for suffix in ('', 'LOAD linker stubs\n'):
            self.assertEqual(linker_closure(base+suffix, helper)[0][:2],
                             ['core.elf.o', helper])
        for bad in (base+'LOAD libc.a\n', base+'LOAD crt0.o\n',
                    base.replace(helper, '/tools/libgcc.a'),
                    base.replace('LOAD core.elf.o\n', ''),
                    base+'LOAD linker stubs\nLOAD linker stubs\n'):
            with self.assertRaises(RuntimeError):
                linker_closure(bad, helper)
        self.assertEqual(set(programs()), {
            'cpu', 'dma', 'pool', 'zero', 'vec', 'noreturn', 'panic', 'panic-default', 'core-mem-allocators',
            'core-mem-arena-boundaries', 'core-mem-raw-storage'})

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
