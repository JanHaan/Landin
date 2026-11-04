#!/usr/bin/env python3
"""Offline coverage and record drift controls, using simulated compiler output."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import build
import bundle


class Build(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_elf_and_esp_image_hashes_are_compared_separately(self):
        record = self.root / 'record.json'
        manifest = dict(files=dict(elf=dict(path='board.elf', sha256='ELF'),
                                   image=dict(path='board.elf.bin', sha256='IMAGE')))
        record.write_text(json.dumps(dict(image_name='board.elf.bin',
                                         image_sha256='IMAGE', elf_sha256='ELF')))
        self.assertEqual(build.compare(manifest, self.root, record), [])
        manifest['files']['elf']['sha256'] = 'changed-ELF'
        difference, = build.compare(manifest, self.root, record)
        self.assertIn('elf_sha256: record=ELF built=changed-ELF', difference)
        self.assertNotIn('image_sha256', difference)

    def test_legacy_record_name_and_missing_ram_record(self):
        record = self.root / 'record.json'
        manifest = dict(files=dict(elf=dict(path='board.elf', sha256='HASH')))
        record.write_text(json.dumps(dict(image_sha256='HASH')))
        self.assertEqual(build.compare(manifest, self.root, record), [])
        self.assertIn('no hardware record', build.compare(manifest, self.root, self.root / 'ram-record.json')[0])

    def test_record_filename_selects_compiler_output_and_cannot_escape(self):
        directory = self.root / 'esp32c3'
        directory.mkdir()
        record = directory / 'record.json'
        with mock.patch.object(build, 'HERE', self.root):
            self.assertEqual(build.image_name('esp32c3', 'boot'), 'board.elf')
            record.write_text('{"image_name":"recorded.elf.bin"}')
            self.assertEqual(build.image_name('esp32c3', 'boot'), 'recorded.elf')
            record.write_text('{"image_name":"../outside"}')
            with self.assertRaisesRegex(bundle.Invalid, 'must be a filename'):
                build.image_name('esp32c3', 'boot')

    def test_all_six_ports_both_modes_continue_after_failure(self):
        calls = []
        def prepare(board, mode, refine, directory, source):
            calls.append((board, mode))
            if board == 'rp2040' and mode == 'boot':
                raise build.common.Failed('compile failed; see compile.log')
            return dict(files=dict(elf=dict(path='board.elf', sha256=mode)))
        with mock.patch.object(build, 'prepare', side_effect=prepare), \
                mock.patch.object(bundle, 'source_identity', return_value={}), \
                contextlib.redirect_stdout(io.StringIO()) as log:
            status = build.build_all(build.BOARDS, ('boot', 'ram'), 'refine', self.root / 'out', 'report')
        self.assertEqual(len(calls), 12)
        self.assertEqual(status, 1)
        self.assertIn('compile failed; see compile.log', log.getvalue())
        rows = json.loads((self.root / 'out/summary.json').read_text())
        self.assertEqual(rows[-1]['board'], 'esp32c5')
        self.assertEqual(rows[0]['status'], 'failed')

    def test_report_mode_does_not_fail_hardware_record_drift(self):
        prepared = dict(files=dict(elf=dict(path='board.elf', sha256='new')))
        for policy, expected in (('strict', 1), ('report', 0)):
            with mock.patch.object(build, 'prepare', return_value=prepared), \
                    mock.patch.object(bundle, 'source_identity', return_value={}), \
                    contextlib.redirect_stdout(io.StringIO()):
                status = build.build_all(('rp2040',), ('ram',), 'refine', self.root / policy, policy)
            self.assertEqual(status, expected)

    def test_prepare_uses_only_build_seam_and_packages_fixed_image(self):
        refine = self.root / 'refine'
        refine.write_bytes(b'compiler')
        output = self.root / 'prepared'
        commands = []
        class Run:
            def __init__(self, out):
                self.out = out
            def command(self, name, argv):
                commands.append((name, [str(a) for a in argv]))
                (self.out / 'fixed.elf').write_bytes(b'fixed')
                (self.out / 'fixed-build.json').write_text('{}')
        def compile_image(run, args):
            self.assertEqual(args.mode, 'boot')
            elf = run.out / 'board.elf'
            elf.write_bytes(b'ELF')
            (run.out / 'build.json').write_text('{}')
            return elf, b'stage', 17, {'start': 100}
        with mock.patch.object(build, 'load', return_value=SimpleNamespace(build=compile_image)), \
                mock.patch.object(build, 'tool', return_value='/tool/nm'), \
                mock.patch.object(build.common, 'Run', Run), \
                mock.patch.object(bundle, 'source_identity', return_value={'sha256': 'sources'}):
            manifest = build.prepare('rp2040', 'boot', refine, output)
        self.assertEqual([name for name, _ in commands], ['compile-fixed'])
        self.assertIn('--target=cortex-m0', commands[0][1])
        self.assertEqual(manifest['files']['elf']['sha256'], bundle.sha(output / 'board.elf'))
        self.assertEqual(manifest['files']['fixed_image']['sha256'], bundle.sha(output / 'fixed.elf'))
        self.assertEqual(manifest['metadata'], dict(stage=b'stage'.hex(), crc=17))

    def test_arm_pico2_bundle_keeps_ready_uf2_recovery_artifact(self):
        import uf2
        refine = self.root / 'refine'
        refine.write_bytes(b'compiler')
        # Exercise a symlinked parent on every host, like Darwin's /var.
        linked_root = self.root / 'linked'
        linked_root.symlink_to(self.root, target_is_directory=True)
        output = linked_root / 'pico2'
        class Run:
            def __init__(self, out):
                self.out = out
            def command(self, name, argv):
                (self.out / 'fixed.elf').write_bytes(b'fixed ELF')
                (self.out / 'fixed-build.json').write_text('{}')
        def compile_image(run, args):
            elf = run.out / 'board.elf'
            elf.write_bytes(b'ELF')
            (run.out / 'build.json').write_text('{}')
            return elf, b'head', {'start': 1}
        with mock.patch.object(build, 'load', return_value=SimpleNamespace(build=compile_image)), \
                mock.patch.object(build, 'tool', return_value='/tool/nm'), \
                mock.patch.object(build.common, 'Run', Run), \
                mock.patch.object(uf2, 'convert', return_value=b'converted UF2') as convert, \
                mock.patch.object(bundle, 'source_identity', return_value={'sha256': 'sources'}):
            manifest = build.prepare('rp2350', 'boot', refine, output)
        convert.assert_called_once_with((output / 'fixed.elf').resolve())
        self.assertEqual((output / 'fixed.uf2').read_bytes(), b'converted UF2')
        self.assertEqual(manifest['files']['fixed_uf2']['sha256'], bundle.sha(output / 'fixed.uf2'))

    def test_esp_preparation_keeps_binary_and_elf_and_serializes_header_bytes(self):
        refine = self.root / 'refine'
        refine.write_bytes(b'compiler')
        output = self.root / 'esp'
        class Run:
            def __init__(self, out):
                self.out = out
            def command(self, name, argv):
                (self.out / 'fixed.elf').write_bytes(b'fixed ELF')
                (self.out / 'fixed.elf.bin').write_bytes(b'fixed binary')
                (self.out / 'fixed-build.json').write_text('{}')
        def compile_image(run, args, chip):
            elf, image = run.out / 'board.elf', run.out / 'board.elf.bin'
            elf.write_bytes(b'ELF')
            image.write_bytes(b'IMAGE')
            (run.out / 'build.json').write_text('{}')
            return elf, image, {}
        esp = SimpleNamespace(build=compile_image, objdump=lambda *args: 'listing',
            instructions=lambda *args: [], check_image=lambda *args: dict(
                drive=bytes(3), segments=[(0x4000, b'code')]))
        with mock.patch.object(build, 'load', return_value=SimpleNamespace(C3=lambda: object())), \
                mock.patch.dict(sys.modules, {'esp': esp}), \
                mock.patch.object(build, 'tool', return_value='/tool/nm'), \
                mock.patch.object(build.common, 'Run', Run), \
                mock.patch.object(build.common, 'symbols', return_value={'start': 1}), \
                mock.patch.object(bundle, 'source_identity', return_value={'sha256': 'sources'}):
            manifest = build.prepare('esp32c3', 'boot', refine, output)
        self.assertEqual(manifest['metadata']['image']['drive'], '000000')
        self.assertEqual(manifest['files']['fixed_image']['path'], 'fixed.elf.bin')
        self.assertEqual(manifest['files']['fixed_elf']['path'], 'fixed.elf')
        self.assertNotEqual(manifest['files']['elf']['sha256'], manifest['files']['image']['sha256'])


if __name__ == '__main__':
    unittest.main()
