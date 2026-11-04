#!/usr/bin/env python3
"""Entry-module staging controls for the native Xtensa fixture runner."""
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from environments.xtensa.backend import CommandFailed, configuration, description, stage
from environments.xtensa.corpus import selected_image_limit


class EntrySources(unittest.TestCase):
    def test_capacity_does_not_hide_assembler_or_undefined_symbol_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            run = SimpleNamespace(out=Path(directory))
            log = run.out / 'link.log'
            row = {'profile_limit': 'selected-image'}
            log.write_text("region `DRAM' overflowed by 10 bytes\nundefined reference to f\n")
            self.assertIsNone(selected_image_limit(run, row, CommandFailed('link', log, 'failed'),
                                                   'esp32', 'sim'))
            log.write_text("region `DRAM' overflowed by 10 bytes\n")
            self.assertIsNone(selected_image_limit(run, row, CommandFailed('assemble', log, 'failed'),
                                                   'esp32', 'sim'))
            self.assertIsNone(selected_image_limit(run, {}, CommandFailed('link', log, 'failed'),
                                                   'esp32', 'sim'))

    def test_sim_is_explicit_virtual_memory_with_the_same_cpu(self):
        for chip in ('esp32', 'esp32s3'):
            native = configuration(chip)
            virtual = configuration(chip, 'sim')
            self.assertEqual(native['evidence_scope'], 'CHIP_MEMORY_MAP')
            self.assertEqual(native['regions']['IRAM']['bytes'], 128 * 1024)
            self.assertEqual(native['stack_bytes'], 16 * 1024)
            self.assertEqual(virtual['evidence_scope'], 'EMULATOR_ONLY')
            self.assertEqual(virtual['qemu_arguments'], ['-M', 'sim', '-cpu', chip, '-m', '64M'])
            self.assertEqual(virtual['cpu_level'], native['cpu_level'])
            self.assertEqual(virtual['regions']['IRAM']['origin'], 0x60000000)
            self.assertEqual(virtual['regions']['DRAM']['origin'], 0x61000000)
            self.assertEqual(virtual['regions']['DRAM']['origin']
                             + virtual['regions']['DRAM']['bytes'], 0x64000000)
            self.assertEqual(virtual['stack_bytes'], 8 * 1024 * 1024)
            self.assertIn('"xtensa-test-sim-' + chip + '"', description(chip, 'sim'))

    def test_explicit_files_keep_order_contents_and_import_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            one, two = root / 'entry/main.ldn', root / 'library/growth.ldn'
            one.parent.mkdir()
            two.parent.mkdir()
            one.write_bytes(b'main: () -> none = end main\n')
            two.write_bytes(b'-- unchanged companion source\n')
            run = SimpleNamespace(out=root / 'run')
            flags = ['--root=/first', '--root=/second']
            arguments = stage(run, [*flags, one, two], 'esp32')
            self.assertEqual(arguments[:2], flags)
            self.assertEqual(arguments[2], '--root=' + str(run.out / 'source'))
            self.assertEqual([Path(p).name for p in arguments[3:]],
                             ['main.ldn', 'growth.ldn', 'xtensa-oracle.ldn'])
            for original, staged in zip((one, two), arguments[3:5]):
                self.assertEqual(Path(staged).read_bytes(), original.read_bytes())

    def test_equal_basename_content_is_accepted_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            one, two = root / 'one/main.ldn', root / 'two/main.ldn'
            one.parent.mkdir()
            two.parent.mkdir()
            for source in (one, two):
                source.write_bytes(b'main: () -> none = end main\n')
            arguments = stage(SimpleNamespace(out=root / 'run'), [one, two], 'esp32')
            self.assertEqual([Path(p).name for p in arguments[1:]],
                             ['main.ldn', 'xtensa-oracle.ldn'])

    def test_unequal_basename_content_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            one, two = root / 'one/main.ldn', root / 'two/main.ldn'
            one.parent.mkdir()
            two.parent.mkdir()
            one.write_bytes(b'first\n')
            two.write_bytes(b'second\n')
            with self.assertRaisesRegex(RuntimeError, 'basename has unequal contents'):
                stage(SimpleNamespace(out=root / 'run'), [one, two], 'esp32')

    def test_wrapper_collision_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'xtensa-oracle.ldn'
            source.write_text('main: () -> none = end main\n')
            with self.assertRaisesRegex(RuntimeError, 'basename has unequal contents'):
                stage(SimpleNamespace(out=root / 'run'), [source], 'esp32')


if __name__ == '__main__':
    unittest.main()
