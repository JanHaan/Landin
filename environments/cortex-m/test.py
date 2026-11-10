#!/usr/bin/env python3
"""Failure controls for the embedded probe supervisor; no emulator needed."""
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

from run import HERE, Run, oracle
from setup import AREAS, arm_archive, riscv_archive

#  Every version a supervised run requires its tools to print, in one
#  answer a mocked `Run.command` gives every version query.
VERSIONS = '10.0.13 (GNAT-FSF-builds) %s 2.46.1 16.3 9.2.2 (esp_develop_9.2.2_20260417)' % (
    arm_archive()['version'].rsplit('-', 1)[0])
assert riscv_archive()['version'] == arm_archive()['version'], 'one GCC version answers both'


class ProbeFailures(unittest.TestCase):
    def test_mandatory_runner_keeps_every_embedded_lane(self):
        from contextlib import ExitStack
        import importlib
        from unittest.mock import patch
        from run import HERE
        from setup import arm_archive, riscv_archive, sha
        calls=[]
        lanes=[('abi','execute'),('memory','execute'),('packed','execute'),
               ('rv32_controls','execute_suite'),
               ('packed_native','execute'),('backend_acceptance','execute'),
               ('backend_acceptance','execute_lane'),
               ('firmware','execute_suite'),('freestanding','execute_suite'),
               ('devices','execute_suite'),('descriptions','execute_suite'),
               ('driver','execute_suite'),('counterpart','execute_suite'),
               ('evidence','execute_suite')]
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root=Path(directory)
            (root/'installation.json').write_text(json.dumps({
                'lock_sha256':sha(HERE/'tools.lock.json'),
                'arm':{key:arm_archive()[key] for key in ('version','sha256')},
                'riscv':{key:riscv_archive()[key] for key in ('version','sha256')},
                'files':{area:{} for area in AREAS}}))
            stack.enter_context(patch('run.supported_host'))
            stack.enter_context(patch('run.inventory',return_value={}))
            stack.enter_context(patch.object(Run,'command',return_value=VERSIONS))
            stack.enter_context(patch.object(Run,'qemu',side_effect=lambda:calls.append('qemu')))
            stack.enter_context(patch.object(Run,'peripheral',side_effect=lambda:calls.append('peripheral')))
            #  Each corpus lane is execute_lane given its own name.
            for name, entry in lanes:
                stack.enter_context(patch.object(importlib.import_module(name),entry,
                    side_effect=lambda *args,n=name,e=entry:calls.append(
                        args[-1] if e == 'execute_lane' else n)))
            Run(root,root).execute(Path('relative/refine'))
        from backend_corpus import LANES as CORPUS_LANES
        names = [n for n,_ in lanes]
        at = names.index('backend_acceptance') + 1
        self.assertEqual(calls, ['qemu','peripheral'] + names[:at]
                         + ['mps2-an505', 'mps2-an500', 'esp32c3', 'sifive-e'] + names[at+1:])
        self.assertEqual(sorted(CORPUS_LANES), ['esp32c3', 'mps2-an500', 'mps2-an505', 'sifive-e'])
        self.assertTrue(set(CORPUS_LANES) <= set(__import__('run').LANES))

    def test_a_stop_at_a_line_is_held_to_that_line(self):
        from firmware import landed
        checked = landed(['break source/app/main.ldn:61', 'continue', 'break start'])
        self.assertEqual(checked[0], 'break source/app/main.ldn:61')
        self.assertEqual(checked[1], 'python')
        self.assertIn('assert lines == [61]', checked[3])
        self.assertIn('no code on line 61', checked[3])
        self.assertEqual(checked[4:], ['end', 'continue', 'break start'])

    def test_a_changed_input_is_named(self):
        from run import changed_inputs
        self.assertEqual(changed_inputs({'a.py': '1', 'b.py': '2', 'c.py': '3'},
                                        {'a.py': '1', 'b.py': '9', 'd.py': '4'}),
                         ['changed b.py', 'removed c.py', 'added d.py'])
        self.assertEqual(changed_inputs({'a.py': '1'}, {'a.py': '1'}), [])

    def test_the_guide_is_no_probe_input(self):
        from setup import inventory, probe_inputs
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'lanes').mkdir()
            for name in ('run.py', 'README.md', 'lanes/notes.md', 'lanes/start.S',
                         'validation.json'):
                (root / name).write_text(name)
            before = probe_inputs(root)
            self.assertEqual(sorted(before), ['lanes/start.S', 'run.py', 'validation.json'])
            self.assertEqual(sorted(inventory(root)), ['README.md', 'lanes/notes.md',
                                                       'lanes/start.S', 'run.py',
                                                       'validation.json'])
            #  Editing the guide while lanes run changes no input; a probe does.
            (root / 'README.md').write_text('edited')
            self.assertEqual(probe_inputs(root), before)
            (root / 'lanes/start.S').write_text('edited')
            self.assertNotEqual(probe_inputs(root), before)
        #  Both runs that hold their inputs still read them this way.
        for name in ('run.py', 'packed_native.py'):
            source = (Path(__file__).resolve().parent / name).read_text()
            self.assertNotIn('inventory(HERE)', source)
            self.assertEqual(source.count('probe_inputs(HERE)'), 2)

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

    def test_library_source_anchor_tracks_lines_and_refuses_ambiguity(self):
        from source_debug import source_line
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = Run(root, root)
            source = root / 'library.ldn'
            source.write_text('-- added helper\n\n    selected statement\n')
            self.assertEqual(source_line(run, 'library.ldn', 'selected statement'), 3)
            with self.assertRaises(RuntimeError):
                source_line(run, 'library.ldn', 'missing statement')
            source.write_text('selected statement\nselected statement\n')
            with self.assertRaises(RuntimeError):
                source_line(run, 'library.ldn', 'selected statement')

    def test_library_anchors_occur_once_in_the_library_sources(self):
        from source_debug import LIBRARY_ANCHORS
        for kind, (_, path, statement) in LIBRARY_ANCHORS.items():
            lines = (HERE.parents[1] / path.removeprefix('source/')).read_text()
            matches = [text for text in lines.splitlines()
                       if text.strip() == statement]
            self.assertEqual(len(matches), 1, kind)

    def test_cpu_debug_session_tracks_documentation_edits(self):
        from unittest.mock import patch
        import source_debug
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = 'source/platform/cortex_m/cortex_m.ldn'
            source = root / path
            source.parent.mkdir(parents=True)
            original = ('public disable_interrupts: () -> (previous: u32) =\n'
                        r'    previous = assembler.block("mrs {mask}, primask\ncpsid i",'
                        '\n        out mask: u32 at general)\nend disable_interrupts\n')
            for comments in (0, 7):
                source.write_text('--- Additional documentation.\n' * comments + original)
                expected = 2 + comments
                with patch.object(source_debug, 'checked'), \
                     patch.object(source_debug, 'execute') as execute:
                    source_debug.library(Run(root, root), root / 'core.elf', 'cpu')
                commands = execute.call_args.args[2]
                self.assertIn(f'break {path}:{expected}', commands)
                self.assertIn(f'frame("disable_interrupts",{path!r},{expected})', commands)
                self.assertIn(f'assert gdb.newest_frame().find_sal().line != {expected}', commands)

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
        from freestanding import MODULES, imports, linker_closure, programs
        self.assertEqual(imports('import core/mem\nimport platform/cortex_m\n'), {'core/mem', 'platform/cortex_m'})
        self.assertEqual(imports('import core/io'), {'core/io'})
        self.assertEqual(imports('import core/io/fake'), {'core/io/fake'})
        for name in ('heap', 'c', '../heap'):
            with self.assertRaises(RuntimeError):
                imports('import core/'+name)
        helper = '/tools/thumb/v6-m/nofp/libgcc.a'
        base = 'LOAD core.elf.o\nLOAD '+helper+'\n'
        for object_name in ('core.elf.o', './core.elf.o'):
            for suffix in ('', 'LOAD linker stubs\n'):
                mapping = base.replace('core.elf.o', object_name) + suffix
                self.assertEqual(linker_closure(mapping, helper)[0][:2],
                                 [object_name, helper])
        for bad in (base+'LOAD libc.a\n', base+'LOAD crt0.o\n',
                    base.replace(helper, '/tools/libgcc.a'),
                    base.replace('LOAD core.elf.o\n', ''),
                    base+'LOAD linker stubs\nLOAD linker stubs\n',
                    *(base.replace('core.elf.o', name) for name in
                      ('other/core.elf.o', '../core.elf.o',
                       './core.elf.o/../core.elf.o'))):
            with self.assertRaises(RuntimeError):
                linker_closure(bad, helper)
        self.assertEqual(set(programs()), {
            'cpu', 'dma', 'pool', 'zero', 'vec', 'noreturn', 'panic', 'panic-default', 'core-mem-allocators',
            'core-mem-arena-boundaries', 'core-mem-raw-storage'} |
            #  One per core module freestanding.py lists, so a new module is
            #  added there alone.
            {'library-shared-'+module.split('/')[1] for module in MODULES
             if module.startswith('core/')})

    def test_shared_library_inventory_requires_each_small_consumer(self):
        from freestanding import MODULES, ROOT
        actual = {'core/'+directory.name for directory in (ROOT / 'core').iterdir()
                  if directory.is_dir() and any(directory.glob('*.ldn'))}
        self.assertEqual(actual, {module for module in MODULES
                                  if module.startswith('core/')})
        for module in actual:
            fixture = (ROOT / 'compiler/tests/fixtures/runtime'
                       / ('library-shared-'+module.split('/')[1]))
            self.assertTrue((fixture / 'main.ldn').is_file(), module)
            self.assertTrue((fixture / 'fixture.meta').is_file(), module)

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
                with self.assertRaisesRegex(RuntimeError, 'inventory .* disagrees'):
                    inventory()

    def test_a_fixture_reading_standard_input_never_executes(self):
        import shutil
        import backend_corpus
        from unittest.mock import patch
        self.assertEqual(backend_corpus.inventory()['runtime/word-count']['mode'], 'refuse')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'cortex-m'
            shutil.copytree(backend_corpus.COUNTERPARTS, root)
            record = json.loads((root / 'corpus.json').read_text())
            record['fixtures']['runtime/word-count'] = {'mode': 'execute'}
            (root / 'corpus.json').write_text(json.dumps(record))
            with patch('backend_corpus.COUNTERPARTS', root):
                with self.assertRaisesRegex(RuntimeError, '(?s)runtime/word-count reads standard'
                                            ' input .*status oracle.*"refuse" row'):
                    backend_corpus.inventory()

    def test_a_selection_row_names_known_levels(self):
        import shutil
        import backend_corpus
        from unittest.mock import patch
        name = 'runtime/checked-products-of-arguments'
        self.assertIn('armv8-m.main', backend_corpus.inventory()[name]['selects'])
        for selects in ({'routine': 'main'}, {'armv9-m': {'has': ['smull']}},
                        {'armv7-m': {'holds': ['smull']}}):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'cortex-m'
                shutil.copytree(backend_corpus.COUNTERPARTS, root)
                record = json.loads((root / 'corpus.json').read_text())
                record['fixtures'][name]['selects'] = selects
                (root / 'corpus.json').write_text(json.dumps(record))
                with patch('backend_corpus.COUNTERPARTS', root):
                    with self.assertRaisesRegex(RuntimeError, name + ': a row\'s selects'):
                        backend_corpus.inventory()

    def test_an_output_oracle_never_executes_and_the_refusal_says_the_ways_out(self):
        import shutil
        import backend_corpus
        from unittest.mock import patch
        name = 'runtime/benchmark-game-binary-trees'
        self.assertTrue(backend_corpus.metadata(
            backend_corpus.ROOT / 'compiler/tests/fixtures' / name / 'fixture.meta')
            .get('run_expect'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'cortex-m'
            shutil.copytree(backend_corpus.COUNTERPARTS, root)
            record = json.loads((root / 'corpus.json').read_text())
            record['fixtures'][name] = {'mode': 'execute'}
            (root / 'corpus.json').write_text(json.dumps(record))
            #  Refused while the inventory is read, before anything builds.
            with patch('backend_corpus.COUNTERPARTS', root), \
                    patch('backend_corpus.fixture') as built:
                with self.assertRaises(RuntimeError) as refused:
                    backend_corpus.execute(Path(directory), root, root / 'refine')
            built.assert_not_called()
            text = str(refused.exception)
            self.assertIn(name + ' takes arguments (run_args:) and has its output as its'
                          ' oracle (run_expect:)', text)
            self.assertIn('Give each fixture a status oracle', text)
            self.assertIn('"refuse" row', text)
            self.assertIn('"restriction" row', text)

    def test_a_namespace_refusal_reads_its_modules_from_the_refusal(self):
        import backend_corpus
        from unittest.mock import patch
        log = ('error[L0015]: module unavailable for target: hosted/heap\n'
               'error[L0015]: module unavailable for target: hosted/blocking\n')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = Run(root, root)
            def refused(name, argv, timeout=30, env=None):
                (root / (name + '.log')).write_text(log)
                run.commands.append({'name': name, 'exit': 1})
                raise RuntimeError(name + ' failed with exit 1')
            row = {'mode': 'refuse', 'codes': ['L0015'], 'reason': 'Firmware has no heap.'}
            with patch.object(run, 'command', side_effect=refused):
                result = backend_corpus.source_refusal(run, root / 'refine',
                                                       'runtime/word-count', row)
                self.assertEqual(result['refused_imports'], ['hosted/blocking', 'hosted/heap'])
                self.assertEqual(result['reason'], 'Source namespace checking refuses'
                                 ' hosted/blocking and hosted/heap on the freestanding target'
                                 ' before checking declarations. Firmware has no heap.')
                #  A reason repeating a refused import goes stale when the
                #  module is renamed, so the row may not say it.
                row['reason'] = 'Firmware has no hosted/heap.'
                with self.assertRaisesRegex(RuntimeError, 'names hosted/heap, which the corpus'
                                            ' reads from the refusal'):
                    backend_corpus.source_refusal(run, root / 'refine', 'runtime/word-count', row)
                #  A refusal the row does not record is said with refine's
                #  first diagnostic and the row it would need, not as changed
                #  diagnostics: a compiler without its library refuses all.
                log = 'error[L0006]: module not found: hosted/heap\n'
                with self.assertRaises(RuntimeError) as refused:
                    backend_corpus.source_refusal(run, root / 'refine', 'runtime/word-count', row)
                text = str(refused.exception)
                self.assertIn("refine refused it with L0006, first 'error[L0006]: module not"
                              " found: hosted/heap', and its", text)
                self.assertIn('row records L0015; if that refusal is the fixture\'s verdict,'
                              ' write "codes": ["L0006"]', text)
        rows = backend_corpus.inventory()
        self.assertFalse([name for name, row in rows.items()
                          if backend_corpus.namespace_only(row)
                          and 'refuses' in row.get('reason', '')
                          and 'freestanding target' in row.get('reason', '')])

    def test_corpus_hashes_compiler_once_and_direct_fixture_retains_digest(self):
        import backend
        import backend_corpus
        from setup import sha
        from unittest.mock import patch
        name = 'runtime/fixed-conditional-runtime'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            refine = root / 'refine'
            refine.write_bytes(b'compiler identity')
            output = root / 'corpus'
            output.mkdir()
            def build(run, *args, **kwargs):
                (run.out / 'image.json').write_text(json.dumps({
                    'regions': {'FLASH': {'used': 400, 'limit': 32768},
                                'RAM': {'used': 0, 'limit': 12288}},
                    'sections': {'.isr_vector': 192, '.text': 208},
                    'routines': {'main': 120}}))
                return root / 'program.elf'
            from backend import recorded
            with (patch('backend.build', side_effect=build),
                  patch('backend.execute'),
                  patch('backend_corpus.derived',
                        side_effect=lambda run, refine, device, where: recorded(device)),
                  patch('backend.sha', wraps=sha) as fixture_digest,
                  patch('backend_corpus.sha', wraps=sha) as corpus_digest,
                  patch('backend_corpus.inventory', return_value={name: {'mode': 'execute'}})):
                summary = backend_corpus.execute(output, root, refine)
                self.assertEqual(len(summary['results']), 4)
                self.assertEqual(fixture_digest.call_count, 0)
                #  Each program's own artifacts are hashed; the compiler once.
                self.assertEqual([c.args[0] for c in corpus_digest.call_args_list
                                  if c.args[0] == refine], [refine])
                self.assertEqual(summary['compiler_sha256'], sha(refine))
                direct = backend.fixture(Run(root, root), refine, name, 'none', 'off')
                self.assertEqual(direct['compiler_sha256'], summary['compiler_sha256'])
                self.assertEqual(fixture_digest.call_count, 1)

    def test_a_level_must_change_the_executed_image(self):
        from backend import LEVELS, execute, levels_of, level_flags, recorded
        from backend_corpus import lowering
        self.assertEqual(levels_of({'levels': 'x86-64-v3, armv7-m, armv8-m.main'}),
                         ['armv7-m', 'armv8-m.main'])
        self.assertEqual(level_flags('armv7-m')[0], '-march=armv7-m')
        self.assertNotIn('-mcpu=cortex-m0', level_flags('armv7-m'))
        self.assertEqual(level_flags('armv8-m.main')[0], '-march=armv8-m.main')
        self.assertEqual(LEVELS['armv7-m']['machine'], 'mps2-an385')
        self.assertEqual(LEVELS['armv8-m.main']['machine'], 'mps2-an505')
        self.assertEqual(LEVELS['armv8-m.main']['profile'], 'mps2-an505')
        row = {'mode': 'execute', 'selects': {
            'routine': 'main',
            'armv6-m': {'has': ['bl __aeabi_lmul'], 'lacks': ['smull']},
            'armv8-m.main': {'has': ['smull', 'mla'], 'lacks': ['bl __aeabi_lmul']}}}
        main = ('00000010 <main>:\n'
                '  10:\tfb80 0102 \tsmull\tr0, r1, r0, r2\n'
                '  14:\tfb01 3302 \tmla\tr3, r1, r2, r3\n'
                '  18:\tf000 f800 \tbl\t30 <helper>\n')
        with tempfile.TemporaryDirectory() as directory:
            run = Run(Path(directory), HERE)
            listing = Path(directory) / 'disassembly.log'
            #  A local label inside main is not a routine of its own.
            (Path(directory) / 'sections-routines.log').write_text(
                '00000011 0000000c T main\n00000031 00000002 t helper\n')
            main = main.replace('  18:', '00000018 <L3_1>:\n  18:')
            listing.write_text(main + '00000030 <helper>:\n  30:\t4770      \tbx\tlr\n')
            found = lowering(run, 'runtime/x', row, 'armv8-m.main')
            self.assertEqual(found['routine'], 'main')
            self.assertEqual(found['helpers_absent'][0], '__aeabi_lmul')
            #  The same source at the default has its own lowering to keep.
            with self.assertRaisesRegex(RuntimeError, 'runtime/x at armv6-m: main lacks'
                                        ' bl __aeabi_lmul; holds smull'):
                lowering(run, 'runtime/x', row, 'armv6-m')
            #  A Thumb-2 image asks for no product anywhere, whatever its row.
            listing.write_text(main + '00000030 <helper>:\n'
                               '  30:\tf000 f800 \tbl.w\t40 <__aeabi_lmul>\n')
            with self.assertRaisesRegex(RuntimeError, 'still calls __aeabi_lmul'):
                lowering(run, 'runtime/x', {'mode': 'execute'}, 'armv7-m')
            self.assertEqual(lowering(run, 'runtime/x', {'mode': 'execute'}, 'armv6-m'), {})
            listing.write_text('00000030 <helper>:\n  30:\t4770      \tbx\tlr\n')
            (Path(directory) / 'sections-routines.log').write_text(
                '00000031 00000002 t helper\n')
            with self.assertRaisesRegex(RuntimeError, 'has no routine main'):
                lowering(run, 'runtime/x', row, 'armv8-m.main')
            #  Each machine runs the images of its own map.
            with self.assertRaisesRegex(RuntimeError, "linked for constrained-reference does"
                                        " not run on QEMU's mps2-an505"):
                execute(run, listing, 42, False, level='armv8-m.main', profile=recorded())

    def test_the_m7_lane_reaches_its_description_and_computes_in_hardware(self):
        from backend import LANE_ROOT, LEVELS, hard_float, lane_inputs, level_flags, recorded
        from backend_corpus import float_lowering
        key = 'armv7e-m+fpv5-d16'
        self.assertEqual(LEVELS[key]['machine'], 'mps2-an500')
        flags = level_flags(key)
        self.assertIn('-mfloat-abi=hard', flags)
        self.assertIn('-mfpu=fpv5-d16', flags)
        self.assertNotIn('-mfloat-abi=soft', flags)
        self.assertNotIn('-mcpu=cortex-m0', flags)
        self.assertTrue(hard_float(key))
        self.assertFalse(hard_float('armv7-m'))
        self.assertEqual(lane_inputs('armv6-m', ['a.ldn']), ['a.ldn'])
        lane = str(LANE_ROOT / 'lane-mps2-an500.ldn')
        self.assertEqual(lane_inputs(key, ['a.ldn', 'b.ldn']),
                         ['--root=' + str(LANE_ROOT), 'a.ldn', 'b.ldn', lane])
        #  The M33's lane reaches its description the same way.
        self.assertEqual(lane_inputs('armv8-m.main', ['a.ldn'])[-1],
                         str(LANE_ROOT / 'lane-mps2-an505.ldn'))
        with tempfile.TemporaryDirectory() as directory:
            module = Path(directory) / 'module'
            module.mkdir()
            (module / 'b.ldn').write_text('')
            (module / 'a.ldn').write_text('')
            self.assertEqual(lane_inputs(key, ['--root=' + directory, str(module)]),
                             ['--root=' + str(LANE_ROOT), '--root=' + directory,
                              str(module / 'a.ldn'), str(module / 'b.ldn'), lane])
        profile = recorded('mps2-an500')
        self.assertEqual((profile['flash_limit'], profile['stack_top'], profile['vector_words']),
                         (4 * 1024 * 1024, 0x20400000, 16))
        with tempfile.TemporaryDirectory() as directory:
            run = Run(Path(directory), HERE)
            (Path(directory) / 'sections-routines.log').write_text(
                '00000100 00000010 T add_32\n')
            listing = Path(directory) / 'disassembly.log'
            listing.write_text('  104:\tee30 0a20 \tvadd.f32\ts0, s0, s1\n')
            self.assertEqual(float_lowering(run)['vfp_operations'], {'add_32': {'vadd': 1}})
            listing.write_text('  104:\tf000 f800 \tbl\t200 <__aeabi_fadd>\n')
            with self.assertRaisesRegex(RuntimeError, 'in software: __aeabi_fadd'):
                float_lowering(run)
            listing.write_text('  104:\tf000 f800 \tbl\t200 <__aeabi_l2d>\n')
            self.assertEqual(float_lowering(run)['helper_float_calls'], 0)

    def test_a_restriction_names_what_stops_it(self):
        import backend_corpus
        import shutil
        record = json.loads((HERE.parent.parent / 'compiler/tests/cortex-m/corpus.json').read_text())
        name = 'abi/thread-storage-per-thread'
        self.assertEqual(record['fixtures'][name]['stops'], 'c-options')
        original = backend_corpus.COUNTERPARTS
        for broken_row in ({'mode': 'restriction', 'reason': 'Threads.'},
                           {'mode': 'restriction', 'reason': 'Threads.', 'stops': 'threads'},
                           {'mode': 'restriction', 'reason': 'Threads.', 'stops': 'c-options',
                            'witness': 'compiler/tests/fixtures/%s/fixture.meta' % name}):
            with self.subTest(row=broken_row), tempfile.TemporaryDirectory() as directory:
                broken = Path(directory)
                shutil.copytree(original / 'cases', broken / 'cases')
                (broken / 'counterparts.json').write_text(
                    (original / 'counterparts.json').read_text())
                record['fixtures'][name] = broken_row
                (broken / 'corpus.json').write_text(json.dumps(record))
                backend_corpus.COUNTERPARTS = broken
                try:
                    with self.assertRaisesRegex(RuntimeError, 'a "restriction" row says what'
                                                ' stops it'):
                        backend_corpus.inventory()
                finally:
                    backend_corpus.COUNTERPARTS = original

    def test_a_lane_refuses_what_its_target_does_not_enable(self):
        import backend_corpus
        rows = backend_corpus.inventory()
        row = rows['abi/link-symbol-exports']
        self.assertEqual((row['mode'], row['lanes']['esp32c3']['codes']), ('execute', ['L0346']))
        self.assertTrue(backend_corpus.refused_on(row, 'esp32c3'))
        self.assertFalse(backend_corpus.refused_on(row, 'mps2-an500'))
        self.assertFalse(backend_corpus.refused_on(row, None))
        restricted = rows['abi/r440-native-banks']
        self.assertEqual(restricted['mode'], 'restriction')
        self.assertTrue(backend_corpus.refused_on(restricted, 'sifive-e'))

    def test_a_restriction_is_held_to_where_its_build_stops(self):
        import backend_corpus
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = Run(root, root)
            said = {}

            def command(name, argv, timeout=30, env=None):
                text = said.get(name, '')
                (root / (name + '.log')).write_text(text)
                if name in said.get('failing', ()):
                    raise backend_corpus.CommandFailed(name, root / (name + '.log'),
                                                       'failed with exit 1')
                return text
            row = {'mode': 'restriction', 'stops': 'c-headers', 'reason': 'It prints.'}
            name = 'abi/r440-native-banks'
            with patch.object(run, 'command', side_effect=command):
                #  The headers no directory holds are read from -M -MG.
                said.update({'c-include-directory': str(root),
                             'headers-1': 'peer.o: %s/peer.c stdio.h %s/x.h\n' % (root, root)})
                result = backend_corpus.restriction(run, root / 'refine', name, row,
                                                    'none', 'off')
                self.assertEqual((result['stops'], result['stopped_by']),
                                 ('c-headers', ['stdio.h']))
                #  An option the pinned GCC refuses stops it before its headers.
                said['failing'] = ('headers-1',)
                said['headers-1'] = ("arm-eabi-gcc: error: unrecognized command-line option"
                                     " '-pthread'; did you mean '-fpthread'?\n")
                with self.assertRaisesRegex(RuntimeError, 'stops at c-options \\(-pthread\\),'
                                            ' and its .* row says "stops": "c-headers"; if'
                                            ' that is what stops it, write "stops": "c-options"'):
                    backend_corpus.restriction(run, root / 'refine', name, row, 'none', 'off')
                #  A refusal by refine is a refuse row's, with its codes.
                said['failing'] = ('compile-restricted',)
                said['compile-restricted'] = 'error[L0346]: cortex-m0 calls no variadic C function\n'
                with self.assertRaisesRegex(RuntimeError, 'so it is no restriction: write a'
                                            ' "refuse" row with "codes": \\["L0346"\\]'):
                    backend_corpus.restriction(run, root / 'refine', name, row, 'none', 'off')
                #  An internal defect is a stop of its own.
                said['compile-restricted'] = ('refine: internal compiler defect in emission:'
                                              ' unclassified compiler check\n')
                result = backend_corpus.restriction(run, root / 'refine', name,
                                                    dict(row, stops='defect'), 'none', 'off')
                self.assertEqual(result['stopped_by'], ['refine: internal compiler defect in'
                                                        ' emission: unclassified compiler check'])
                #  One that builds, links and needs nothing hosted is stale.
                said['failing'] = ()
                said['headers-1'] = 'peer.o: %s/peer.c\n' % root
                with patch('backend_corpus.c_objects', return_value=[]), \
                        patch('backend_corpus.build', return_value=root / 'program.elf'):
                    with self.assertRaisesRegex(RuntimeError, 'its restriction is stale: the'
                                                ' program builds and links .* make its .* row'
                                                ' "execute"'):
                        backend_corpus.restriction(run, root / 'refine', 'abi/c-packed-records',
                                                   dict(row, stops='link'), 'none', 'off')

    def test_every_object_of_an_abi_image_passes_floats_and_enums_as_its_lane_does(self):
        import backend
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = Run(root, root)
            attributes = {'attributes-program': 'Tag_ABI_FP_number_model: IEEE 754\n',
                          'attributes-peer': 'Tag_ABI_VFP_args: VFP registers\n'}
            with patch.object(run, 'command',
                              side_effect=lambda name, argv, **_: attributes[name]):
                with self.assertRaisesRegex(RuntimeError, 'peer.o passes float arguments in'
                                            ' the VFP bank, and the armv6-m lane passes them in'
                                            ' core registers'):
                    backend.conventions(run, [root / 'program.o', root / 'peer.o'], 'armv6-m')
                with self.assertRaisesRegex(RuntimeError, 'program.o passes float arguments'
                                            ' in core registers'):
                    backend.conventions(run, [root / 'program.o', root / 'peer.o'],
                                        'armv7e-m+fpv5-d16')
                attributes['attributes-program'] = attributes['attributes-peer']
                attributes['attributes-peer'] += 'Tag_ABI_enum_size: small\n'
                with self.assertRaisesRegex(RuntimeError, 'peer.o declares short enums'
                                            ' \\(Tag_ABI_enum_size: small\\).*'
                                            '-fno-short-enums'):
                    backend.conventions(run, [root / 'program.o', root / 'peer.o'],
                                        'armv7e-m+fpv5-d16')
                attributes['attributes-peer'] = ('Tag_ABI_VFP_args: VFP registers\n'
                                                 'Tag_ABI_enum_size: int\n')
                self.assertEqual(backend.conventions(
                    run, [root / 'program.o', root / 'peer.o'], 'armv7e-m+fpv5-d16'),
                    {'program.o': 'VFP registers', 'peer.o': 'VFP registers'})

    def test_a_lane_restriction_needs_its_reason(self):
        import backend_corpus
        record = json.loads((HERE.parent.parent / 'compiler/tests/cortex-m/corpus.json').read_text())
        name = 'runtime/r420-map-arena'
        self.assertEqual(record['fixtures'][name]['mode'], 'execute')
        original = backend_corpus.COUNTERPARTS
        with tempfile.TemporaryDirectory() as directory:
            broken = Path(directory)
            for one in ('counterparts.json', 'cases'):
                source = original / one
                target = broken / one
                if source.is_dir():
                    import shutil
                    shutil.copytree(source, target)
                else:
                    target.write_text(source.read_text())
            #  A restriction of an execute row on a lane, without its reason.
            record['fixtures'][name]['lanes'] = {'mps2-an500': {'mode': 'restriction'}}
            (broken / 'corpus.json').write_text(json.dumps(record))
            backend_corpus.COUNTERPARTS = broken
            try:
                with self.assertRaisesRegex(RuntimeError, 'a "lanes" entry names a corpus lane'):
                    backend_corpus.inventory()
            finally:
                backend_corpus.COUNTERPARTS = original

    def test_a_refuse_row_executes_only_where_its_lane_says(self):
        import backend_corpus
        record = json.loads((HERE.parent.parent / 'compiler/tests/cortex-m/corpus.json').read_text())
        name = 'runtime/assembly-float-square-root'
        row = record['fixtures'][name]
        self.assertEqual((row['mode'], row['lanes']['mps2-an500']['mode']), ('refuse', 'execute'))
        self.assertTrue(backend_corpus.executes_on(row, 'mps2-an500'))
        self.assertFalse(backend_corpus.executes_on(row, 'mps2-an505'))
        self.assertFalse(backend_corpus.executes_on(row, None))
        original = backend_corpus.COUNTERPARTS
        with tempfile.TemporaryDirectory() as directory:
            broken = Path(directory)
            for one in ('counterparts.json', 'cases'):
                source = original / one
                target = broken / one
                if source.is_dir():
                    import shutil
                    shutil.copytree(source, target)
                else:
                    target.write_text(source.read_text())
            #  An execute entry carries no codes of its own.
            row['lanes']['mps2-an500']['codes'] = ['L0304']
            (broken / 'corpus.json').write_text(json.dumps(record))
            backend_corpus.COUNTERPARTS = broken
            try:
                with self.assertRaisesRegex(RuntimeError, 'a "lanes" entry names a corpus lane'):
                    backend_corpus.inventory()
            finally:
                backend_corpus.COUNTERPARTS = original

    def test_image_limit_does_not_hide_codegen_failure(self):
        from unittest.mock import patch
        from backend import recorded
        from backend_corpus import image_limit as limit
        def image_limit(run, row, error):
            return limit(run, row, error, recorded())
        from run import CommandFailed
        row = {'profile_limit': 'selected-image', 'reason': 'test physical map'}
        sizes = {'regions': {'FLASH': {'used': 32776, 'limit': 32768},
                             'RAM': {'used': 24, 'limit': 12288}},
                 'sections': {'.isr_vector': 192, '.text': 32584, '.bss': 24}}
        with tempfile.TemporaryDirectory() as directory, \
                patch('backend_corpus.measure_overflow', return_value=sizes):
            root = Path(directory)
            run = Run(root, root)
            link = CommandFailed('assemble-link', root / 'assemble-link.log', 'failed with exit 1')
            for text in ("undefined reference to helper",
                         "region `FLASH' overflowed by 8 bytes; undefined reference to helper",
                         "region `RAM' overflowed by 8 bytes; Assembler messages: bad instruction"):
                (root / 'assemble-link.log').write_text(text)
                with self.assertRaises(RuntimeError):
                    image_limit(run, row, link)
            with self.assertRaises(RuntimeError):
                image_limit(run, row, CommandFailed('gdb-backend', root / 'gdb-backend.log',
                                                    'failed'))
            #  A link whose text happens to read like the overflow is not one.
            (root / 'assemble-link.log').write_text("region `FLASH' overflowed by 8 bytes")
            with self.assertRaises(RuntimeError):
                image_limit(run, row, RuntimeError('assemble-link failed with exit 1'))
            result = image_limit(run, row, link)
            self.assertEqual(result['verdict'], 'selected-image-limit')
            self.assertEqual(result['overflow_bytes'], {'FLASH': 8})
            self.assertEqual(result['image'], sizes)
            #  With no recorded limit the overflow fails, with its sizes and the row.
            with self.assertRaisesRegex(RuntimeError, 'FLASH 32776 of 32768, over by 8 .*'
                                        'records no profile_limit'):
                image_limit(run, {'mode': 'execute'}, link)

    def test_the_corpus_line_gives_each_region_and_section(self):
        from backend import describe_sizes
        from backend_corpus import corpus_line
        sizes = {'regions': {'FLASH': {'used': 12034, 'limit': 32768},
                             'RAM': {'used': 300, 'limit': 12288}},
                 'sections': {'.isr_vector': 192, '.text': 11800, '.data': 42, '.bss': 258}}
        self.assertEqual(describe_sizes(sizes),
                         'FLASH 12034 of 32768 (.isr_vector 192, .text 11800, .data 42); '
                         'RAM 300 of 12288 (.data 42, .bss 258)')
        line = corpus_line({'fixture': 'runtime/x', 'optimize': 'size', 'specialize': 'auto',
                            'verdict': 'executed', 'image': sizes})
        self.assertEqual(line, 'cortex corpus: runtime/x size/auto executed: '
                               + describe_sizes(sizes))

    def test_an_executed_image_reports_its_observed_stack(self):
        from backend import describe_stack, observed_stack
        from backend_corpus import corpus_line
        sizes = {'regions': {'FLASH': {'used': 668, 'limit': 32768}}, 'sections': {},
                 'routines': {'main': 286}}
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            self.assertIsNone(observed_stack(out))
            (out / 'stack-observation.json').write_text(json.dumps(
                {'lowest_changed_word': 0x20003fd8, 'reserved_bytes': 4096,
                 'stack_top': 0x20004000, 'is_stack_bound': False}))
            stack = observed_stack(out)
        self.assertEqual(stack, {'observed_bytes': 40, 'reserved_bytes': 4096})
        self.assertEqual(describe_stack(stack), 'stack 40 of 4096 observed')
        self.assertEqual(describe_stack(None), '')
        line = corpus_line({'fixture': 'runtime/x', 'optimize': 'none', 'specialize': 'off',
                            'verdict': 'executed', 'image': sizes, 'stack': stack})
        self.assertTrue(line.endswith('FLASH 668 of 32768; stack 40 of 4096 observed;'
                                      ' largest routines main 286'), line)
        #  Both sessions write the stack top the depth is measured from.
        import backend
        source = Path(backend.__file__).read_text()
        self.assertEqual(source.count('"stack_top":{bottom}+{reserved}'), 2)

    def test_programs_of_ones_own_are_named_apart_and_take_c_peers(self):
        import subprocess
        import backend_corpus
        from backend_corpus import ProgramPeers, level_names, program_names
        self.assertEqual(program_names([Path('/a/one.ldn'), Path('/a/two.ldn')]), ['one', 'two'])
        self.assertEqual(program_names([Path('/a/main.ldn'), Path('/b/main.ldn')]),
                         ['a-main', 'b-main'])
        self.assertEqual(program_names([Path('/x/a/main.ldn'), Path('/y/a/main.ldn')]),
                         ['a-main-1', 'a-main-2'])
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'peer.c'
            source.write_text('int peer(void) { return 1; }\n')
            peers = ProgramPeers([source])
            self.assertEqual((peers.c_sources, peers.c_args_for('cortex-m0'), peers.c_inputs),
                             ([source.resolve()], [], ()))
            with self.assertRaises(FileNotFoundError):
                ProgramPeers([Path(directory) / 'absent.c'])
            #  C peers belong to one program, refused before anything is built.
            with self.assertRaisesRegex(RuntimeError, 'C peers of one program'):
                backend_corpus.observe(Path(directory), None, None, [source, source],
                                       [('none', 'off')], c_sources=[source])
        #  The help names refine's level where the corpus's own differs.
        self.assertEqual(level_names(), 'the same names, except armv7e-m for armv7e-m+fpv5-d16')
        self.assertIn(level_names(), ' '.join(subprocess.run(
            [sys.executable, str(Path(backend_corpus.__file__)), '--help'],
            capture_output=True, text=True, check=True).stdout.split()))

    def test_the_corpus_gives_each_routine_size(self):
        from backend import describe_routines, routine_sizes
        from backend_corpus import corpus_line
        listing = ('00000000 000000c0 T _landin_harness_vectors\n'
                   '000000c1 00000010 t small\n'
                   '000000d1 00000400 T parse_entry\n'
                   '000004d1 00000020 T tie_b\n'
                   '000004f1 00000020 T tie_a\n'
                   '20000000 00000008 D buffer\n'
                   '00000201 T unsized\n')
        routines = routine_sizes(listing)
        self.assertEqual(list(routines.items()),
                         [('parse_entry', 1024), ('_landin_harness_vectors', 192),
                          ('tie_a', 32), ('tie_b', 32), ('small', 16)])
        sizes = {'regions': {'FLASH': {'used': 32800, 'limit': 32768},
                             'RAM': {'used': 8, 'limit': 12288}},
                 'sections': {'.text': 32608}, 'routines': routines}
        self.assertEqual(describe_routines(sizes),
                         'largest routines parse_entry 1024, _landin_harness_vectors 192,'
                         ' tie_a 32')
        #  An image that overflowed is measured by relinking, and its line
        #  gives its routines as a fitting one's does.
        line = corpus_line({'fixture': 'runtime/x', 'optimize': 'none', 'specialize': 'off',
                            'verdict': 'selected-image-limit', 'image': sizes})
        self.assertTrue(line.endswith('; largest routines parse_entry 1024,'
                                      ' _landin_harness_vectors 192, tie_a 32'), line)
        self.assertIn('over by 32', line)

    def test_every_module_datum_is_typed_and_sized(self):
        from backend import check_datum_symbols, datum_symbols
        sections = (
            '  [ 1] .text             PROGBITS        00000000 000034 000010 00  AX  0   0  4\n'
            '  [ 4] .bss.landin_1     NOBITS          00000000 000044 000040 00  WA  0   0  8\n'
            '  [ 5] .data.landin_2    PROGBITS        00000000 000044 000008 00  WA  0   0  4\n'
            '  [ 6] .rodata.landin_3  PROGBITS        00000000 00004c 000000 00   A  0   0  1\n')
        symbols = (
            '     1: 00000000     0 SECTION LOCAL  DEFAULT    4 .bss.landin_1\n'
            '     2: 00000000     0 NOTYPE  LOCAL  DEFAULT    5 $d\n'
            '     3: 00000000    64 OBJECT  LOCAL  DEFAULT    4 backing\n'
            '     4: 00000000     8 OBJECT  GLOBAL DEFAULT    5 table\n'
            '     5: 00000000     0 OBJECT  LOCAL  DEFAULT    6 empty\n'
            '     6: 00000001    16 FUNC    GLOBAL DEFAULT    1 main\n')
        found, sizes = datum_symbols(sections + symbols)
        self.assertEqual(sorted(found), ['backing', 'empty', 'table'])
        self.assertEqual(sizes['.bss.landin_1'], 64)

        class Listing:
            def __init__(self, text, out):
                self.text, self.out, self.arm = text, out, Path('/arm')

            def command(self, name, argv):
                return self.text

        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(sorted(check_datum_symbols(
                Listing(sections + symbols, Path(tmp)), 'program.o')),
                ['backing', 'empty', 'table'])
            #  What the backend emitted before every datum was typed: a
            #  label with neither a type nor a size.
            untyped = symbols.replace('8 OBJECT  GLOBAL', '0 NOTYPE  GLOBAL')
            with self.assertRaisesRegex(RuntimeError, 'table is NOTYPE'):
                check_datum_symbols(Listing(sections + untyped, Path(tmp)), 'program.o')
            unsized = symbols.replace('64 OBJECT', ' 0 OBJECT')
            with self.assertRaisesRegex(RuntimeError, 'backing has no size'):
                check_datum_symbols(Listing(sections + unsized, Path(tmp)), 'program.o')

    def test_a_limit_no_profile_meets_is_stale(self):
        from backend_corpus import stale_limits
        fits = {'regions': {'FLASH': {'used': 30000, 'limit': 32768},
                            'RAM': {'used': 24, 'limit': 12288}}, 'sections': {}}
        rows = {'runtime/a': {'mode': 'execute', 'profile_limit': 'selected-image', 'reason': 'r'},
                'runtime/b': {'mode': 'execute', 'profile_limit': 'selected-image', 'reason': 'r'},
                'runtime/c': {'mode': 'execute'}}
        results = [{'fixture': 'runtime/a', 'optimize': 'none', 'specialize': 'off',
                    'status': 'passed', 'verdict': 'executed', 'image': fits},
                   {'fixture': 'runtime/b', 'optimize': 'none', 'specialize': 'off',
                    'status': 'passed', 'verdict': 'selected-image-limit'},
                   {'fixture': 'runtime/b', 'optimize': 'size', 'specialize': 'auto',
                    'status': 'passed', 'verdict': 'executed', 'image': fits},
                   {'fixture': 'runtime/c', 'optimize': 'none', 'specialize': 'off',
                    'status': 'passed', 'verdict': 'executed', 'image': fits}]
        stale = stale_limits(rows, results)
        self.assertEqual(len(stale), 1)
        self.assertIn('runtime/a: every profile fits', stale[0])
        self.assertIn('remove profile_limit', stale[0])

    def test_a_profile_may_be_written_as_the_log_prints_it(self):
        from backend_corpus import profile_name
        self.assertEqual(profile_name('none/off'), 'none-off')
        self.assertEqual(profile_name('speed-all'), 'speed-all')

    def test_missing_tools_are_refused_naming_the_path_and_option(self):
        from setup import installed_tools
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SystemExit) as refused:
                installed_tools(Path(directory) / 'absent')
            self.assertIn(str(Path(directory).resolve() / 'absent'), str(refused.exception))
            self.assertIn('--tools', str(refused.exception))
            self.assertIn('arm-eabi-gcc', str(refused.exception))

    def test_a_failed_command_names_its_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = Run(root, root)
            with self.assertRaisesRegex(RuntimeError, 'compile failed with exit 3; inspect '
                                        + str(root / 'compile.log')):
                run.command('compile', [sys.executable, '-c', 'raise SystemExit(3)'])
            with self.assertRaisesRegex(RuntimeError, 'reached its 0.5-second limit'):
                run.command('slow', [sys.executable, '-c', 'import time; time.sleep(5)'],
                            timeout=0.5)

    def test_a_firmware_failure_names_its_case(self):
        from firmware import case
        with self.assertRaisesRegex(RuntimeError, 'compiler firmware dma at size/auto: '
                                    'compile failed with exit 1; inspect /x/compile.log'):
            with case('dma at size/auto'):
                raise RuntimeError('compile failed with exit 1; inspect /x/compile.log')

    def test_a_timed_out_program_says_the_fixture_ran_too_long(self):
        from backend import timed_out
        from run import CommandFailed
        class Running:
            returncode = None
            def poll(self):
                return None
        class Exited:
            returncode = 1
            def poll(self):
                return 1
        error = CommandFailed('gdb-backend', Path('/x/gdb-backend.log'), 'timed out')
        text = str(timed_out(error, Running(), 20.4))
        self.assertIn('ran for 20.4 s under QEMU', text)
        self.assertIn('20-second session limit', text)
        self.assertIn('the fixture takes longer', text)
        self.assertIn('/x/gdb-backend.log', text)
        self.assertIn('QEMU exited with status 1', str(timed_out(error, Exited(), 3.0)))

    def test_a_session_interrupts_a_program_still_running_and_names_its_pc(self):
        import backend
        from backend import SESSION_GRACE, SESSION_LIMIT, still_running, watched_continue
        watched = '\n'.join(watched_continue())
        self.assertIn('threading.Timer(%d, lambda: gdb.post_event(interrupt_late))'
                      % SESSION_LIMIT, watched)
        self.assertIn('gdb.execute("interrupt")', watched)
        #  The timer is cancelled and disarmed however the continue ends.
        self.assertRegex(watched, r'finally:\n    watchdog\.cancel\(\)\n    armed\.clear\(\)')
        said = '\n'.join(still_running('value("$ra")'))
        self.assertIn('if late:', said)
        self.assertIn('still running after %d s' % SESSION_LIMIT, said)
        self.assertIn('its last pc is %s, called from', said)
        self.assertIn('where(value("$ra"))', said)
        #  The lines are Python a session can run: with a stopped program
        #  the check raises, naming the pc; without `late` nothing happens.
        seen = {}
        def check(holds, what):
            seen['what'] = what
        for late in ([], [True]):
            seen.clear()
            exec('if True:\n' + said, {'late': late, 'check': check, 'pc': 0x10553234,
                                       'sp': 0x203fffc8, 'value': lambda expr: 0x2e0,
                                       'where': lambda address: '%#x' % address})
            self.assertEqual(bool(seen), bool(late))
        self.assertIn('its last pc is 0x10553234, called from 0x2e0, with sp 0x203fffc8',
                      seen['what'])
        #  Both sessions continue under the watchdog and ask before taking
        #  the stop for the stack guard's; the outer limit is the backstop.
        profile = {'stack_top': 0x20004000, 'stack_reserved': 4096,
                   'regions': [], 'device': 'x'}
        with tempfile.TemporaryDirectory() as directory:
            run = Run(Path(directory), Path(directory))
            for script in (backend.session(run, 1, 0, False, profile=profile),
                           backend.rv32_session(run, 1, 0, False, profile=profile)):
                self.assertIn(watched, script)
                self.assertLess(script.index('if late:'),
                                script.index('stopped by the write watchpoint'))
                self.assertNotIn("'continue',\n'python'", script)
        self.assertGreater(SESSION_GRACE, 0)

    def test_the_inventory_names_the_row_to_write(self):
        import shutil
        from unittest.mock import patch
        import backend_corpus
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'cortex-m'
            shutil.copytree(backend_corpus.COUNTERPARTS, root)
            record = json.loads((root / 'corpus.json').read_text())
            removed = 'runtime/word-count'
            del record['fixtures'][removed]
            record['fixtures']['runtime/no-such-fixture'] = {'mode': 'execute'}
            (root / 'corpus.json').write_text(json.dumps(record))
            with patch('backend_corpus.COUNTERPARTS', root):
                with self.assertRaises(RuntimeError) as refused:
                    backend_corpus.inventory()
            text = str(refused.exception)
            self.assertIn(removed + ' has no row; python3 scripts/add_fixture.py ' + removed + ' writes it, or add "' + removed + '": {"mode": "execute"}', text)
            self.assertIn('runtime/no-such-fixture has a row and no fixture', text)
            self.assertEqual(text.count('\n'), 2)

    def test_compact_images_are_bounded_before_assembler(self):
        from backend import preflight
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.s'
            for text in ('.zero 2147483688', '.rept 4294967295\n.quad 0\n.endr',
                         '.fill 8388609, 1, 1', '.rept 256\n.fill 8193, 4, 7\n.endr'):
                path.write_text(text)
                with self.assertRaisesRegex(RuntimeError, 'materialization exceeds'):
                    preflight(path)
            path.write_text('.rept 0\n.quad 1\n.endr\n.byte 42')
            self.assertEqual(preflight(path), 1)
            path.write_text('.rept 3\n.fill 5, 2, 4660\n.endr\n.zero 2')
            self.assertEqual(preflight(path), 32)
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

    def test_a_served_session_meets_no_breakpoint_the_one_before_it_made(self):
        # `delete breakpoints` spares an internal one, which then fired in
        # the next program on the same worker.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, stack = self.server_run(root)
            with stack:
                import run as run_module
                first = self.script(root, 'first.gdb', 'python', 'import gdb',
                                    'gdb.Breakpoint("*0x100")',
                                    'gdb.Breakpoint("*0x200", internal=True)',
                                    'gdb.Breakpoint("*(int*)0x20000000", 1, 1, internal=True)',
                                    'print("FIRST_PASS")', 'end')
                second = self.script(root, 'second.gdb', 'python', 'import gdb',
                                     'print("LEFT", [b.location for b in gdb.breakpoints()])',
                                     'end')
                self.assertIn('FIRST_PASS', run.debug('gdb-first', 'x.elf', first))
                self.assertIn('LEFT []', run.debug('gdb-second', 'x.elf', second))
                run_module.SERVERS.server.stop()

    def test_a_failed_session_fails_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, stack = self.server_run(root)
            with stack:
                import run as run_module
                for lines, problem in ((('fail',), 'failed; inspect .*gdb-bad.log'),
                                       (('python', 'assert False, "no"', 'end'),
                                        'failed; inspect .*gdb-bad.log'),
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

    def test_an_overflow_is_named_by_its_part_of_the_profile(self):
        from backend import recorded
        from backend_corpus import overflowed
        from run import CommandFailed
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'assemble-link.log'
            failed = CommandFailed('assemble-link', log, 'failed with exit 1')
            log.write_text("region `AXI_SRAM' overflowed by 40 bytes\n"
                           "region `FLASH' overflowed by 8 bytes\n")
            self.assertEqual(overflowed(None, failed, recorded('stm32h753')),
                             {'RAM': 40, 'FLASH': 8})
            #  A region the program's parts are not placed in is no
            #  capacity verdict.
            self.assertIsNone(overflowed(None, failed, recorded()))
            log.write_text('ld: RAM image overlaps the reserved 4 KiB stack\n')
            self.assertEqual(overflowed(None, failed, recorded()), {'RAM': None})

    def test_each_description_holds_what_the_reference_holds(self):
        from backend import DESCRIPTIONS, REFERENCE, recorded
        from backend_corpus import dominates
        reference = recorded()
        self.assertEqual((reference['flash_limit'], reference['static_ram_limit'],
                          reference['stack_reserved'], reference['stack_top']),
                         (32768, 12288, 4096, 0x20004000))
        for device in DESCRIPTIONS:
            self.assertTrue(dominates(recorded(device), reference), device)
        smaller = dict(recorded('rp2040'), static_ram_limit=4096)
        self.assertFalse(dominates(smaller, reference))

    def test_every_lane_runs_and_is_reported_after_one_fails(self):
        from contextlib import ExitStack
        from unittest.mock import patch
        from run import LANES, selection
        from setup import arm_archive, riscv_archive, sha
        self.assertEqual(selection(['evidence']), ['driver', 'evidence'])
        self.assertEqual(selection(['sifive-e']), ['rv32-controls', 'sifive-e'])
        self.assertEqual(selection(None), list(LANES))
        with self.assertRaisesRegex(RuntimeError, 'unknown lane nowhere; the lanes are cpu'):
            selection(['nowhere'])
        ran = []
        def lane(self, name, refine):
            ran.append(name)
            if name in ('abi', 'driver'):
                raise RuntimeError(name + ' broke')
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = Path(directory)
            (root/'installation.json').write_text(json.dumps({
                'lock_sha256': sha(HERE/'tools.lock.json'),
                'arm': {key: arm_archive()[key] for key in ('version', 'sha256')},
                'riscv': {key: riscv_archive()[key] for key in ('version', 'sha256')},
                'files': {area: {} for area in AREAS}}))
            stack.enter_context(patch('run.supported_host'))
            stack.enter_context(patch('run.inventory', return_value={}))
            stack.enter_context(patch.object(Run, 'command', return_value=VERSIONS))
            stack.enter_context(patch.object(Run, 'lane', lane))
            run = Run(root, root)
            with self.assertRaises(RuntimeError) as failed:
                run.execute(Path('refine'))
        self.assertEqual(ran, [name for name in LANES if name != 'evidence'])
        self.assertEqual({key: run.verdicts['abi'][key] for key in ('status', 'error')},
                         {'status': 'failed', 'error': 'abi broke'})
        self.assertEqual(run.verdicts['evidence']['status'], 'not run')
        #  A lane that ran says how long it took; one that did not run, nothing.
        self.assertNotIn('seconds', run.verdicts['evidence'])
        self.assertEqual(sorted(run.verdicts['firmware']), ['seconds', 'status'])
        self.assertEqual(run.verdicts['firmware']['status'], 'passed')
        self.assertIn('3 of %d lanes did not pass' % len(LANES), str(failed.exception))

    def test_only_a_lane_that_compiles_needs_refine(self):
        """--refine is optional, and a run selecting a lane that needs it is
        refused naming that lane."""
        import run as run_module
        parser_text = (HERE / 'run.py').read_text()
        self.assertNotIn("'--refine', type=Path, required=True", parser_text)
        self.assertNotIn('rv32-controls', run_module.NEEDS_REFINE)
        self.assertIn('counterpart', run_module.NEEDS_REFINE)

    def test_the_gate_parts_are_every_lane_once(self):
        """The gate's three Cortex-M jobs are not FILTERED only because their
        parts are every lane, each once, and each part holds what its lanes
        need; and the workflow's matrix runs exactly run.py's parts."""
        import re
        from run import LANES, NEEDS, PARTS, selection
        named = [lane for lanes in PARTS.values() for lane in lanes]
        self.assertEqual(sorted(named), sorted(LANES), 'the parts are not every lane once')
        for name, lanes in PARTS.items():
            with self.subTest(part=name):
                self.assertEqual(selection(lanes), [lane for lane in LANES if lane in lanes])
                for lane in lanes:
                    self.assertTrue(set(NEEDS.get(lane, ())) <= set(lanes),
                                    '%s needs a lane of another part' % lane)
        workflow = (HERE.parents[1] / '.github/workflows/gate.yml').read_text()
        job = workflow.split('\n  cortex-m:\n', 1)[1].split('\n\n  #', 1)[0]
        self.assertIn('name: cortex-m-${{ matrix.part }}', job)
        part = re.search(r'\n +part: \[([^\]]*)\]', job)
        self.assertTrue(part, 'the cortex-m job has no part matrix')
        self.assertEqual([one.strip() for one in part.group(1).split(',')], list(PARTS))
        self.assertIn('--part="${{ matrix.part }}"', job)
        self.assertNotIn('--lane', job)

    def test_a_stack_overrun_is_watched_and_named(self):
        from backend import recorded, session
        with tempfile.TemporaryDirectory() as directory:
            run = Run(Path(directory), HERE)
            text = session(run, 1234, 42, False, profile=recorded())
            painted = text.index('break backend_painted')
            watched = text.index('*(unsigned char (*)[16])%d' % 0x20003000)
            self.assertLess(painted, watched)
            self.assertIn('BP_HARDWARE_WATCHPOINT', text)
            self.assertIn('the stack overran its 4096-byte reservation: %s wrote into its'
                          ' lowest 16 bytes at 0x20003000, called from %s', text)
            self.assertIn('main stack (MSP)', text)
            #  Observing holds no result.
            observed = session(run, 1234, None, False, profile=recorded())
            self.assertNotIn('expected 42', observed)
            self.assertIn('observed.json', observed)

    def test_nixos_names_the_route_to_the_locked_tools(self):
        from unittest.mock import patch
        import setup
        def host(nixos, loader, run=True, tmp=None):
            paths = {'/etc/NIXOS': nixos, '/run/current-system': run}
            return (patch('setup.os.path.realpath', return_value=loader),
                    patch('setup.os.path.exists', side_effect=lambda p: paths.get(p, True)),
                    patch('setup.os.path.isdir', side_effect=lambda p:
                          paths.get(p, p != tmp)),
                    patch.dict('setup.os.environ', {'TMPDIR': tmp} if tmp else {}, clear=False))
        for patches, said in (
                (host(True, '/nix/store/x-stub-ld-x86_64'), 'stub loader'),
                (host(False, '/usr/lib/ld-linux-x86-64.so.2', tmp='/tmp/nix-shell-1'),
                 'TMPDIR is /tmp/nix-shell-1, which does not exist')):
            with patches[0], patches[1], patches[2], patches[3]:
                with self.assertRaises(SystemExit) as refused:
                    setup.nixos_route('/home/u/out')
            self.assertIn(said, str(refused.exception))
            self.assertIn('steam-run', str(refused.exception))
            self.assertIn('TMPDIR=$HOME', str(refused.exception))
        patches = host(False, '/usr/lib/ld-linux-x86-64.so.2')
        with patches[0], patches[1], patches[2], patches[3]:
            with self.assertRaisesRegex(SystemExit, '--output /tmp/out is under /tmp'):
                setup.nixos_route('/tmp/out')
            setup.nixos_route('/home/u/out')
        #  An ordinary distribution has a loader of its own.
        patches = host(False, '/usr/lib/ld-linux-x86-64.so.2', run=False)
        with patches[0], patches[1], patches[2], patches[3]:
            setup.nixos_route('/tmp/out')

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
                    patch('platform.libc_ver', return_value=libc), \
                    patch('setup.nixos_route'):
                supported_host()

    def test_wrong_tool_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'installation.json').write_text('{"lock_sha256":"wrong"}')
            from unittest.mock import patch
            with patch('run.supported_host'), self.assertRaisesRegex(RuntimeError, 'installed from another tools.lock.json.*install a fresh --tools root'):
                Run(root, root).execute()


class CounterpartOracle(unittest.TestCase):
    """counterpart.judge, the firmware counterpart's trace oracle (D448),
    given traces it must pass and each failure it must name."""

    def trace(self, *events, output='a done\nb done\n', outcome='settled',
              fed=('WAIT 200 a\n', 'NOW b\n')):
        kinds = {'r': 'received', 's': 'started', 'f': 'finished', 'x': 'refused'}
        return {'outcome': outcome, 'lost': 0, 'rejected': 0, 'ticks': 300,
                'fed': [{'at': 0, 'bytes': one} for one in fed], 'output': output,
                'events': [{'kind': kinds[k], 'request': n, 'at': at} for k, n, at in events]}

    def kinds(self, observed, presented=((1, 2),)):
        from counterpart import judge
        return [problem.split(':')[0] for problem in judge(observed, presented)]

    GOOD = (('r', 1, 5), ('s', 1, 10), ('r', 2, 22), ('f', 1, 227), ('s', 2, 227), ('f', 2, 241))

    def test_one_answer_at_a_time_in_request_order_passes(self):
        self.assertEqual(self.kinds(self.trace(*self.GOOD)), [])

    def test_an_answer_never_written_is_missing(self):
        self.assertIn('missing answer', self.kinds(self.trace(*self.GOOD, output='a done\n')))
        self.assertIn('missing answer', self.kinds(self.trace(*self.GOOD[:-1], output='a done\n')))
        self.assertIn('missing answer', self.kinds(self.trace(*self.GOOD[:2], ('f', 1, 227),
                                                              output='a done\n')))

    def test_a_second_answer_started_before_the_first_ended_overlaps(self):
        overlapping = (('r', 1, 5), ('s', 1, 10), ('r', 2, 22), ('s', 2, 23), ('f', 2, 30),
                       ('f', 1, 227))
        kinds = self.kinds(self.trace(*overlapping, output='b done\na done\n'))
        self.assertIn('overlap', kinds)

    def test_answers_out_of_request_order_fail(self):
        swapped = (('r', 1, 5), ('r', 2, 6), ('s', 2, 10), ('f', 2, 20), ('s', 1, 20),
                   ('f', 1, 230))
        self.assertIn('order', self.kinds(self.trace(*swapped, output='b done\na done\n')))

    def test_a_wait_answered_early_fails(self):
        early = (('r', 1, 5), ('s', 1, 10), ('r', 2, 22), ('f', 1, 150), ('s', 2, 150),
                 ('f', 2, 160))
        self.assertIn('early', self.kinds(self.trace(*early)))

    def test_a_trap_a_timeout_and_a_halt_fail(self):
        self.assertIn('trap', self.kinds(self.trace(*self.GOOD, outcome='trap: unhandled exception')))
        self.assertIn('timeout', self.kinds(self.trace(*self.GOOD[:2], outcome='timeout',
                                                       output='')))
        self.assertIn('stopped', self.kinds(self.trace(*self.GOOD, outcome='stopped: 4')))

    def test_a_lost_trace_or_input_fails(self):
        lost = self.trace(*self.GOOD)
        lost['lost'] = 1
        self.assertIn('lost', self.kinds(lost))
        refused = self.trace(*self.GOOD)
        refused['rejected'] = 3
        self.assertIn('lost', self.kinds(refused))

    def test_two_in_flight_must_be_presented(self):
        late = (('r', 1, 5), ('s', 1, 10), ('f', 1, 227), ('r', 2, 230), ('s', 2, 230),
                ('f', 2, 241))
        self.assertIn('presented', self.kinds(self.trace(*late)))
        self.assertEqual(self.kinds(self.trace(*late), presented=()), [])

    def test_busy_only_for_a_full_queue(self):
        fed = ('WAIT 200 a\n', 'NOW b\nNOW c\nNOW d\nNOW e\nNOW f\n')
        full = (('r', 1, 5), ('s', 1, 10), ('r', 2, 22), ('r', 3, 22), ('r', 4, 27), ('r', 5, 27),
                ('x', 6, 27), ('f', 1, 230), ('s', 2, 230), ('f', 2, 244), ('s', 3, 244),
                ('f', 3, 258), ('s', 4, 258), ('f', 4, 272), ('s', 5, 272), ('f', 5, 286))
        output = 'busy\na done\nb done\nc done\nd done\ne done\n'
        self.assertEqual(self.kinds(self.trace(*full, output=output, fed=fed)), [])
        early = tuple(e for e in full if e[:2] != ('r', 5)) [:5] + (('x', 5, 27),)
        self.assertIn('busy', self.kinds(self.trace(*early, output='busy\n', fed=fed),
                                         presented=()))

    def test_the_protocol_answers_as_the_hosted_one(self):
        from counterpart import answer_of
        self.assertEqual(answer_of(b'WAIT 200 a'), ('a done', 200))
        self.assertEqual(answer_of(b'NOW b'), ('b done', 0))
        for line in (b'NOW', b'NOW ', b'NOW a b', b'WAIT x a', b'WAIT 60001 a', b'HELLO a',
                     b'NOW ' + b'x' * 70):
            self.assertEqual(answer_of(line), ('malformed', 0), line)

    def test_each_control_mutation_matches_the_source_once(self):
        from counterpart import CONTROLS, SOURCE
        text = (SOURCE / 'firmware/app/main.ldn').read_text()
        for name, control in CONTROLS.items():
            for old, _ in control['replace']:
                with self.subTest(control=name):
                    self.assertEqual(text.count(old), 1, old)


class RV32Lanes(unittest.TestCase):
    """The RV32 lanes' plumbing (D695), without an emulator or a toolchain."""

    def test_the_rv32_levels_build_for_rv32_with_their_own_tools(self):
        from backend import LEVELS, level_flags, lane_inputs, rv32, target, tool
        run = Run(Path('/out'), Path('/tools'))
        for level, march, machine, lane in (
                ('rv32imc', '-march=rv32imc_zicsr_zifencei', 'esp32c3', 'esp32c3'),
                ('rv32imac', '-march=rv32imac_zicsr_zifencei', 'sifive_e', 'sifive-e')):
            with self.subTest(level=level):
                self.assertTrue(rv32(level))
                self.assertEqual(target(level), 'rv32')
                flags = level_flags(level)
                self.assertEqual(flags[0], march)
                self.assertIn('-mabi=ilp32', flags)
                self.assertFalse([f for f in flags if f.startswith(('-mcpu', '-mthumb'))])
                self.assertEqual(tool(run, level, 'gcc'),
                                 Path('/tools/gnat-riscv64-elf/bin/riscv64-elf-gcc'))
                self.assertEqual((LEVELS[level]['machine'], LEVELS[level]['lane']),
                                 (machine, lane))
        #  The esp32c3 machine's core loses A, F and D, which the C3 has not;
        #  sifive_e's E31 is rv32imac as it is.
        self.assertEqual(LEVELS['rv32imc']['cpu'].split(',')[0], 'espressif')
        for off in ('a=false', 'f=false', 'd=false'):
            self.assertIn(off, LEVELS['rv32imc']['cpu'].split(','))
        self.assertNotIn('cpu', LEVELS['rv32imac'])
        self.assertEqual(target('armv6-m'), 'cortex-m0')
        self.assertEqual(tool(run, 'armv6-m', 'nm'), Path('/tools/gnat-arm-elf/bin/arm-eabi-nm'))
        #  The esp32c3 lane compiles with its entry-module file; sifive-e is
        #  the RV32 reference's map, which a program reaching no
        #  description is given.
        self.assertTrue(lane_inputs('rv32imc', ['a.ldn'])[-1].endswith('lanes/lane-esp32c3.ldn'))
        self.assertEqual(lane_inputs('rv32imac', ['a.ldn']), ['a.ldn'])
        self.assertEqual(run.espressif, Path('/tools/qemu-espressif/bin'))
        self.assertIn('/tools/root/usr/lib/x86_64-linux-gnu/pulseaudio',
                      run.env['LD_LIBRARY_PATH'].split(':'))

    def test_the_esp32c3_lane_record_is_its_description(self):
        from backend import LANE_PROFILES, LANE_ROOT, device_target, region
        record = LANE_PROFILES['esp32c3']
        self.assertEqual(device_target('esp32c3'), 'rv32')
        text, data = region(record, 'text'), region(record, 'data')
        #  The table at the first 256-byte boundary past the entry word,
        #  where the C3's mtvec, which ignores its low eight bits, can point.
        self.assertEqual(record['vector_address'], text['origin'] + 0x100)
        self.assertEqual(record['vector_address'] % 256, 0)
        #  DRAM is SRAM1's data alias, 0x70_0000 below its instruction
        #  address: the data never shares a byte with the text.
        self.assertGreaterEqual(data['origin'] + 0x700000, text['origin'] + text['length'])
        self.assertEqual(record['stack_top'], data['origin'] + data['length'])
        source = (LANE_ROOT / 'descriptions/esp32c3/core.ldn').read_text()
        self.assertIn('compiler.core("esp-rv32imc")', source)
        self.assertIn('compiler.vectors(%d)' % record['vector_words'], source)
        memory = (LANE_ROOT / 'descriptions/esp32c3/memory.ldn').read_text()
        for one in record['regions']:
            self.assertIn('linker.region("%s", 0x%s, %d * 1024, "%s")' % (
                one['name'], '%04X_%04X' % divmod(one['origin'], 0x10000),
                one['length'] // 1024, one['access']), memory)
        self.assertIn('import descriptions/esp32c3', (LANE_ROOT / 'lane-esp32c3.ldn').read_text())

    def test_an_image_is_held_to_its_levels_extensions(self):
        from backend import rv32_extensions, rv32_image
        imc = ('  Flags:                             0x1, RVC, soft-float ABI\n'
               '  Tag_RISCV_arch: "rv32i2p1_m2p0_c2p0_zicsr2p0_zifencei2p0_zmmul1p0_zca1p0"\n')
        imac = imc.replace('m2p0_c2p0', 'm2p0_a2p1_c2p0').replace(
            'zmmul1p0_zca1p0', 'zmmul1p0_zaamo1p0_zalrsc1p0_zca1p0')
        self.assertEqual(rv32_extensions(imc),
                         {'i', 'm', 'c', 'zicsr', 'zifencei', 'zmmul', 'zca'})
        self.assertIn('zalrsc', rv32_extensions(imac))
        plain = '20400000:\t00000297          \tauipc\tt0,0x0\n'
        atomic = plain + ('2040001c:\t0072ae2f          \tamoadd.w\tt3,t2,(t0)\n'
                          '20400020:\t1002aeaf          \tlr.w.aq\tt4,(t0)\n')
        rv32_image('rv32imc', imc, plain)
        rv32_image('rv32imac', imac, atomic)
        with self.assertRaisesRegex(RuntimeError, 'names a, zaamo, zalrsc, beyond the level;'
                                    ' it holds A-extension instructions: amoadd.w, lr.w'):
            rv32_image('rv32imc', imac, atomic)
        #  A tag that says nothing of A does not excuse the instructions.
        with self.assertRaisesRegex(RuntimeError, 'A-extension instructions: amoadd.w, lr.w'):
            rv32_image('rv32imc', imc, atomic)
        with self.assertRaisesRegex(RuntimeError, 'soft-float'):
            rv32_image('rv32imc', imc.replace('soft-float', 'double-float'), plain)

    def test_the_rv32_session_holds_the_rv32_oracle(self):
        from backend import LANE_PROFILES, rv32_session
        profile = dict(LANE_PROFILES['esp32c3'], device='esp32c3')
        with tempfile.TemporaryDirectory() as directory:
            run = Run(Path(directory), HERE)
            returned = rv32_session(run, 1234, 42, False, profile=profile)
            trapped = rv32_session(run, 1234, 0, True, profile=profile)
        bottom = profile['stack_top'] - profile['stack_reserved']
        self.assertLess(returned.index('break backend_painted'),
                        returned.index('*(unsigned char (*)[16])%d' % bottom))
        self.assertIn('BP_HARDWARE_WATCHPOINT', returned)
        self.assertIn('[44,55,66,77,88,99,100,111,122,133,144]', returned)
        self.assertIn('value("$s0") == 0', returned)
        self.assertIn('0x9e9e9e9e, 0x7e7e7e7e', returned)
        self.assertIn('check(value("$sp") == %d' % profile['stack_top'], returned)
        self.assertIn('cause == 2', trapped)
        self.assertIn('0xc0001073', trapped)
        #  No Arm register is asked for.
        self.assertNotRegex(returned + trapped, r'\$(r\d|lr\b|control|msp|psp)')

    def test_the_control_script_keeps_the_rv32_contract(self):
        from backend import LANE_PROFILES
        from rv32_controls import CONTROLS, control_script
        script = control_script(dict(LANE_PROFILES['esp32c3'], device='esp32c3'))
        self.assertIn('ENTRY(_landin_firmware_entry)', script)
        body = script[script.index('.text : {'):]
        self.assertLess(body.index('.text.landin_entry'), body.index('. = 256;'))
        self.assertLess(body.index('. = 256;'), body.index('KEEP(*(.isr_vector))'))
        self.assertLess(body.index('KEEP(*(.isr_vector))'), body.index('.text.landin_reset'))
        for symbol in ('data_load', 'data_start', 'data_end', 'ramtext_load', 'ramtext_start',
                       'ramtext_end', 'bss_start', 'bss_end', 'stack_bottom', 'stack_top'):
            self.assertIn('_landin_firmware_%s =' % symbol, script)
        start = (HERE / 'probes/rv32-start.S').read_text()
        for name in ('.text.landin_entry', '.text.landin_reset', '.isr_vector',
                     '_landin_firmware_entry', '_landin_firmware_reset', 'backend_painted',
                     'backend_done', 'backend_fault_done'):
            self.assertIn(name, start)
        #  Only rv32imac assembles the A-extension control.
        self.assertEqual(CONTROLS['read-modify-write'][1], ('rv32imac',))
        self.assertEqual(CONTROLS['a-extension-traps'][1], ('rv32imc',))
        self.assertEqual({level for _, levels, _ in CONTROLS.values() for level in levels},
                         {'rv32imc', 'rv32imac'})

    def test_the_lock_unpacks_espressif_qemu_into_its_own_area(self):
        from setup import AREAS, ESPRESSIF, ESPRESSIF_XTENSA, riscv_archive, xtensa_archive
        lock = json.loads((HERE / 'tools.lock.json').read_text())
        self.assertEqual({item['kind'] for item in lock}, {'deb', 'tar.xz'})
        archives = [item for item in lock if item['kind'] == 'tar.xz']
        self.assertEqual([item['into'] for item in archives], [ESPRESSIF, ESPRESSIF_XTENSA])
        self.assertIn(ESPRESSIF, AREAS)
        self.assertIn(ESPRESSIF_XTENSA, AREAS)
        for item in archives:
            self.assertIn('esp_develop_9.2.2_20260417', item['file'])
        self.assertEqual(archives[1]['sha256'],
                         '0eecb2a34a5586c0e59110f77b9343b7b336e82fdb0e1a30e1dc1bab8a547e35')
        for item in lock:
            self.assertRegex(item['sha256'], '^[0-9a-f]{64}$')
        files = [item['file'] for item in lock]
        self.assertEqual(len(files), len(set(files)), 'a lock entry is repeated')
        archive = riscv_archive()
        self.assertEqual(archive['file'],
                         'gnat-riscv64-elf-linux64-x86_64-%s.tar.gz' % archive['version'])
        self.assertTrue(archive['url'].endswith('/gnat-%s/%s' % (archive['version'], archive['file'])))
        archive = xtensa_archive()
        self.assertEqual(archive['file'],
                         'xtensa-esp-elf-16.1.0_20260609-x86_64-linux-gnu.tar.xz')
        self.assertEqual(archive['sha256'],
                         'f708752ebb35cab21f184b2574114ed1187619db0edb8a4ba913c06ca2fa675e')
        self.assertTrue(archive['url'].endswith('/esp-16.1.0_20260609/' + archive['file']))

    def test_an_incomplete_xtensa_install_names_the_missing_chip_tool_or_plugin(self):
        from setup import REQUIRED_TOOLS, installed_tools
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in REQUIRED_TOOLS:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('installed')
            self.assertEqual(installed_tools(root), root.resolve())
            for relative in ('qemu-xtensa/bin/qemu-system-xtensa',
                             'xtensa-esp-elf/bin/xtensa-esp-elf-as',
                             'xtensa-esp-elf/bin/xtensa-esp32-elf-gcc',
                             'xtensa-esp-elf/bin/xtensa-esp32s3-elf-as',
                             'xtensa-esp-elf/lib/xtensa_esp32.so',
                             'xtensa-esp-elf/lib/xtensa_esp32s3.so'):
                path = root / relative
                path.unlink()
                with self.assertRaises(SystemExit) as refused:
                    installed_tools(root)
                self.assertIn(relative, str(refused.exception))
                self.assertIn('--tools DIRECTORY', str(refused.exception))
                path.write_text('installed')

    def test_installation_inventories_every_unpacked_area_and_archive_identity(self):
        import contextlib
        import io
        import setup
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'tools'
            def fetch(packages, item):
                path = packages / item['file']
                path.write_bytes(item['file'].encode())
                return path
            def unpack(archive, into, mode):
                into.mkdir()
                (into / 'installed').write_bytes(archive.name.encode())
            def deb(*args, **kwargs):
                into = root / 'root'
                into.mkdir(exist_ok=True)
                (into / 'installed').write_bytes(b'debian tools')
            with patch.object(sys, 'argv', ['setup.py', '--tools', str(root)]), \
                    patch.object(setup, 'supported_host'), \
                    patch.object(setup, 'installer_tools'), \
                    patch.object(setup, 'fetch', side_effect=fetch), \
                    patch.object(setup, 'unpack', side_effect=unpack) as unpacked, \
                    patch.object(setup.subprocess, 'run', side_effect=deb), \
                    patch.object(setup, 'compile_gdb_python'), \
                    contextlib.redirect_stdout(io.StringIO()):
                setup.main()
            record = json.loads((root / 'installation.json').read_text())
            self.assertEqual(record['lock_sha256'], setup.sha(HERE / 'tools.lock.json'))
            self.assertEqual(set(record['files']), set(setup.AREAS))
            for area in setup.AREAS:
                self.assertEqual(record['files'][area], setup.inventory(root / area))
                self.assertTrue(record['files'][area])
            for name, archive in [('arm', setup.arm_archive()), ('riscv', setup.riscv_archive()),
                                  ('xtensa', setup.xtensa_archive())]:
                self.assertEqual(record[name], {key: archive[key] for key in ('version', 'sha256')})
            self.assertEqual({call.args[1].name: call.args[2] for call in unpacked.call_args_list},
                             {setup.ARM: '-xzf', setup.RISCV: '-xzf', setup.XTENSA: '-xJf',
                              setup.ESPRESSIF: '-xJf', setup.ESPRESSIF_XTENSA: '-xJf'})
            (root / setup.XTENSA / 'installed').write_bytes(b'changed compiler')
            self.assertNotEqual(record['files'][setup.XTENSA], setup.inventory(root / setup.XTENSA))

    def test_missing_dpkg_is_refused_before_creating_a_partial_installation(self):
        import setup
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'tools'
            with patch.object(sys, 'argv', ['setup.py', '--tools', str(root)]), \
                    patch.object(setup, 'supported_host'), \
                    patch.object(setup.shutil, 'which', side_effect=lambda tool:
                                 None if tool == 'dpkg-deb' else '/tools/' + tool), \
                    patch.object(setup, 'fetch') as fetch:
                with self.assertRaisesRegex(RuntimeError, 'needs dpkg-deb on PATH') as refused:
                    setup.main()
            self.assertIn('add dpkg', str(refused.exception))
            self.assertIn('environments/cortex-m/README.md#on-nixos', str(refused.exception))
            self.assertFalse(root.exists())
            fetch.assert_not_called()

    def test_an_archive_hash_is_checked_before_it_can_be_unpacked(self):
        import hashlib
        import io
        import setup
        from unittest.mock import patch
        body = b'a pinned archive control'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            item = {'file': 'control.tar.xz', 'url': 'https://invalid.example/control',
                    'sha256': hashlib.sha256(body).hexdigest()}
            with patch.object(setup.urllib.request, 'urlopen', return_value=io.BytesIO(body)):
                self.assertEqual(setup.fetch(root, item).read_bytes(), body)
            with patch.object(setup.urllib.request, 'urlopen', return_value=io.BytesIO(body + b'changed')):
                with self.assertRaisesRegex(RuntimeError, 'archive hash mismatch: control.tar.xz'):
                    setup.fetch(root, item)

    def test_the_atomics_probes_name_every_refused_use(self):
        from rv32_controls import READ_MODIFY_WRITE, REFUSED_USES, WIDE
        source = READ_MODIFY_WRITE.read_text()
        self.assertNotIn('u64', source)
        for use in ('atomic.exchange(', 'atomic.add(', 'atomic.compare_exchange('):
            self.assertIn(use, source)
        self.assertTrue(all(use.startswith('atomic.') for use in REFUSED_USES))
        self.assertIn('atomic.cell(u64)', WIDE.read_text())


    def test_a_lane_limit_is_stale_only_when_every_profile_fits(self):
        from backend_corpus import STACK_OVERRUN, stale_lane_limits
        rows = {'runtime/a': {'mode': 'execute',
                              'lanes': {'sifive-e': {'mode': 'limit', 'reason': 'r'}}},
                'runtime/b': {'mode': 'execute'}}
        some = [{'fixture': 'runtime/a', 'status': 'passed', 'verdict': 'executed'},
                {'fixture': 'runtime/a', 'status': 'passed', 'verdict': 'selected-stack-limit'},
                {'fixture': 'runtime/b', 'status': 'passed', 'verdict': 'executed'}]
        self.assertEqual(stale_lane_limits(rows, some, 'sifive-e'), [])
        every = [dict(one, verdict='executed') for one in some]
        stale = stale_lane_limits(rows, every, 'sifive-e')
        self.assertEqual(len(stale), 1)
        self.assertIn('runtime/a: every profile fits on sifive-e', stale[0])
        self.assertEqual(stale_lane_limits(rows, every, 'esp32c3'), [])
        #  The session's own words, which a lane limit records.
        from backend import rv32_session
        self.assertIn(STACK_OVERRUN, rv32_session(Run(Path('/out'), HERE), 1, 42, False,
                                                  profile=dict(__import__('backend').LANE_PROFILES['esp32c3'], device='esp32c3')))

    def test_the_inventory_admits_a_lane_limit_on_an_execute_row_only(self):
        corpus = json.loads((HERE.parents[1] / 'compiler/tests/cortex-m/corpus.json').read_text())
        limits = [(name, lane) for name, row in corpus['fixtures'].items()
                  for lane, own in row.get('lanes', {}).items() if own['mode'] == 'limit']
        for name, lane in limits:
            row = corpus['fixtures'][name]
            self.assertEqual(row['mode'], 'execute', name)
            self.assertIn(lane, ('esp32c3', 'sifive-e'), name)
            self.assertTrue(row['lanes'][lane]['reason'].startswith('D698: '), name)
        from backend_corpus import inventory
        inventory()


if __name__ == '__main__':
    unittest.main()
