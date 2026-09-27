#!/usr/bin/env python3
"""Failure controls for the embedded probe supervisor; no emulator needed."""
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

from run import HERE, Run, oracle


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
                'files':{'root':{}}}))
            stack.enter_context(patch('run.supported_host'))
            stack.enter_context(patch('run.inventory',return_value={}))
            stack.enter_context(patch.object(Run,'command',return_value=
                '10.0.13 14.2.1 20241119 2.44 16.3'))
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

    def server_run(self, root):
        """A Run whose debugger is the stand-in, with a server of its own."""
        import run as run_module
        from unittest.mock import patch
        (root / 'gdb-multiarch').symlink_to(HERE / 'probes/fake_gdb.py')
        run = Run(root, root)
        run.bin = root
        return run, patch.object(run_module, 'SERVERS', threading.local())

    def script(self, root, name, *lines):
        (root / name).write_text('\n'.join(lines) + '\nquit\n')
        return name

    def test_a_served_session_cannot_see_the_one_before_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, stack = self.server_run(root)
            with stack:
                import run as run_module
                first = self.script(root, 'first.gdb', 'python', 'left = 1',
                                    'print("FIRST_PASS")', 'end')
                second = self.script(root, 'second.gdb', 'python',
                                     'print("SECOND_PASS" if "left" not in globals() else "LEAKED")',
                                     'end')
                self.assertIn('FIRST_PASS', run.debug('gdb-first', 'x.elf', first))
                text = run.debug('gdb-second', 'x.elf', second)
                self.assertIn('SECOND_PASS', text)
                self.assertNotIn('LEAKED', text)
                run_module.SERVERS.server.stop()

    def test_a_failed_session_fails_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, stack = self.server_run(root)
            with stack:
                import run as run_module
                for lines, problem in ((('fail',), 'failed; inspect retained log'),
                                       (('python', 'assert False, "no"', 'end'),
                                        'failed; inspect retained log'),
                                       (('die',), 'lost its debugger'),
                                       (('sleep 5',), 'timed out')):
                    name = self.script(root, 'bad.gdb', *lines)
                    with self.assertRaisesRegex(RuntimeError, problem):
                        run.debug('gdb-bad', 'x.elf', name, timeout=1)
                    ok = self.script(root, 'ok.gdb', 'python', 'print("OK_PASS")', 'end')
                    self.assertIn('OK_PASS', run.debug('gdb-ok', 'x.elf', ok))
                record = json.loads((root / 'commands.json').read_text())
                self.assertEqual([r.get('exit') for r in record if r['name'] == 'gdb-bad'][:2], [1, 1])
                self.assertTrue(any(r.get('timed_out') for r in record))
                run_module.SERVERS.server.stop()

    def test_concurrent_workers_each_have_their_own_debugger(self):
        from concurrent.futures import ThreadPoolExecutor
        import run as run_module
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, stack = self.server_run(root)
            with stack:
                def session(index):
                    out = root / ('w%d' % index)
                    out.mkdir()
                    worker = Run(out, root)
                    worker.bin = root
                    name = self.script(out, 'w.gdb', 'python',
                                       'import os, time',
                                       'assert "mine" not in globals()',
                                       'mine = %d' % index, 'time.sleep(0.2)',
                                       'print("PID", os.getpid(), "PASS%d" % mine)', 'end')
                    text = worker.debug('gdb-w', 'x.elf', name)
                    self.assertIn('PASS%d' % index, text)
                    server = run_module.SERVERS.server
                    return int(text.split('PID ')[1].split()[0]), server
                with ThreadPoolExecutor(max_workers=4) as pool:
                    results = list(pool.map(session, range(8)))
                pids = {pid for pid, _ in results}
                self.assertGreater(len(pids), 1)
                self.assertLessEqual(len(pids), 4)
                for server in {id(s): s for _, s in results}.values():
                    server.stop()

    def test_the_debugger_stub_socket_keeps_nodelay(self):
        # Without it each reply waits on Nagle and a session costs seconds.
        from run import gdb_listener
        listener, port, stub = gdb_listener()
        with listener:
            self.assertIn('nodelay=on', stub[1])
            self.assertIn('fd=%d' % listener.fileno(), stub[1])
            self.assertEqual(stub[2:], ['-gdb', 'chardev:gdb'])
            self.assertEqual(listener.getsockname(), ('127.0.0.1', port))

    def test_workers_is_bounded(self):
        from unittest.mock import patch
        from run import workers
        for value in ('0', '65', 'x', ''):
            with patch.dict('os.environ', {'LANDIN_CORTEX_JOBS': value}), \
                    self.assertRaises(RuntimeError):
                workers()
        with patch.dict('os.environ', {'LANDIN_CORTEX_JOBS': '8'}):
            self.assertEqual(workers(), 8)

    def test_a_served_script_quits_only_at_its_end(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, stack = self.server_run(root)
            with stack:
                import run as run_module
                (root / 'early.gdb').write_text('quit\npython\nprint(1)\nend\n')
                with self.assertRaisesRegex(RuntimeError, 'quit only at its end'):
                    run.debug('gdb-early', 'x.elf', 'early.gdb')
                if getattr(run_module.SERVERS, 'server', None) is not None:
                    run_module.SERVERS.server.stop()

    def test_decoder_reads_only_single_loads_and_stores(self):
        from machine import Refused, decode
        # str r1, [r2, #4]; ldrh r3, [r4, #2]; ldrsb r0, [r1, r2]; strb r5, [r6, r7]
        self.assertEqual(decode(0x6051), (True, 4, False, 1, 2, None, 4))
        self.assertEqual(decode(0x8863), (False, 2, False, 3, 4, None, 2))
        self.assertEqual(decode(0x5688), (False, 1, True, 0, 1, 2, 0))
        self.assertEqual(decode(0x55f5), (True, 1, False, 5, 6, 7, 0))
        # PC- and SP-relative loads and stores, LDM, STM, PUSH and POP never
        # reach a device through the decoder.
        for half in (0x4a00, 0x9801, 0x9001, 0xc60f, 0xcc0f, 0xb4f0, 0xbdf0, 0xbf30):
            with self.subTest(half=hex(half)), self.assertRaises(Refused):
                decode(half)

    def test_models_refuse_what_their_contracts_do_not_name(self):
        from machine import Refused
        from models import (DriverPeripheral, EncodingPeripheral, FixturePeripheral,
                            PrototypePeripheral)
        cases = [(FixturePeripheral(), [(False, 0x114, 4), (True, 0x218, 4), (False, 0x1008, 2),
                                        (True, 0x200, 1), (False, 0x204, 4)]),
                 (PrototypePeripheral(), [(False, 0x6004, 4), (True, 0x6000, 4),
                                          (False, 0x6068, 4), (False, 0, 2), (True, 0x10, 2)]),
                 (EncodingPeripheral(), [(False, 8, 4), (True, 4, 4), (False, 0, 2),
                                         (False, 16, 4), (True, 0, 1)]),
                 (DriverPeripheral(), [(False, 0x200, 4), (True, 0x328, 4), (False, 4, 2),
                                       (True, 4, 1)])]
        for model, accesses in cases:
            for write, offset, width in accesses:
                with self.subTest(model=type(model).__name__, offset=offset, width=width), \
                        self.assertRaises(Refused):
                    if write:
                        model.write(offset, width, 0)
                    else:
                        model.read(offset, width)
        for model, (offset, value) in ((FixturePeripheral(), (0x114, 0x40000000)),
                                       (EncodingPeripheral(), (0, 0)),
                                       (DriverPeripheral(), (0x224, 0x10000))):
            with self.subTest(model=type(model).__name__, reserved=offset), \
                    self.assertRaises(Refused):
                model.write(offset, 4, value)

    def test_the_decoder_agrees_with_the_disassembler_or_fails(self):
        from machine import agree
        listing = (' 2f40:\t6810      \tldr\tr0, [r2, #0]\n'
                   ' 2f42:\t5688      \tldrsb\tr0, [r1, r2]\n'
                   ' 2f44:\t4a00      \tldr\tr2, [pc, #0]\n')
        self.assertEqual(agree(listing), 2)
        # An objdump line whose operands disagree with its encoding: the
        # harness would perform a different access than the CPU's.
        with self.assertRaisesRegex(RuntimeError, 'disagrees'):
            agree(' 2f40:\t6810      \tldr\tr1, [r2, #0]\n')

    def test_a_driver_descriptor_cannot_change_while_it_drains(self):
        from machine import Refused
        from models import DriverPeripheral
        model = DriverPeripheral()
        model.machine = type('Bus', (), {'write': lambda self, address, data: None})()
        model.write(0x1000, 4, 0x40070200)
        model.write(0x1004, 4, 0x20000100)
        model.write(0x1008, 4, 8)
        model.write(0x100c, 4, 0xa84e1)
        self.assertTrue(model.busy)
        with self.assertRaises(Refused):
            model.write(0x1004, 4, 0x20000200)
        model.feed(1)
        self.assertEqual((model.remaining, model.events[-1]), (7, 'dma8:0:01'))

    def test_unsupported_host(self):
        from unittest.mock import patch
        from setup import supported_host
        with patch('platform.system', return_value='Darwin'), self.assertRaises(RuntimeError):
            supported_host()
        # The locked binaries ask for glibc 2.38; an older one, or another C
        # library, cannot load them, whatever the distribution.
        for libc in (('glibc', '2.37'), ('glibc', '2.9'), ('musl', '1.2.5'), ('', '')):
            with patch('platform.system', return_value='Linux'), \
                    patch('platform.machine', return_value='x86_64'), \
                    patch('platform.libc_ver', return_value=libc), \
                    self.assertRaises(RuntimeError):
                supported_host()
        for libc in (('glibc', '2.38'), ('glibc', '2.39'), ('glibc', '3.0')):
            with patch('platform.system', return_value='Linux'), \
                    patch('platform.machine', return_value='x86_64'), \
                    patch('platform.libc_ver', return_value=libc):
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
