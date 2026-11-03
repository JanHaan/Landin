#!/usr/bin/env python3
"""Bundle corruption, containment and dirty-source controls; no rig or network."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import bundle


def source_tree(root):
    root.mkdir(parents=True)
    for name in bundle.SOURCE_FILES:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(name)
    for name in bundle.SOURCE_ROOTS:
        directory = root / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'input.ldn').write_text(name)


class Bundles(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        source_tree(self.source)
        self.directory = self.root / 'bundle'
        self.directory.mkdir()
        for name in ('board.elf', 'build.json'):
            (self.directory / name).write_text(name)
        self.manifest = bundle.write(self.directory, 'rp2040', 'boot',
            dict(elf=self.directory / 'board.elf', report=self.directory / 'build.json'),
            dict(stage='1234', crc=17), {'start': 123}, {'sha256': 'compiler'},
            bundle.source_identity(self.source))

    def validate(self, **kwargs):
        return bundle.validate(self.directory, board='rp2040', mode='boot',
                               source_root=self.source, **kwargs)

    def alter(self, change):
        change(self.manifest)
        (self.directory / 'bundle.json').write_text(json.dumps(self.manifest))

    def test_valid_bundle_and_artifact(self):
        prepared = self.validate()
        self.assertEqual(bundle.artifact(prepared, 'elf'), self.directory / 'board.elf')
        self.assertEqual(prepared['symbols'], {'start': 123})

    def test_corrupt_artifact_is_refused(self):
        (self.directory / 'board.elf').write_bytes(b'changed')
        with self.assertRaisesRegex(bundle.Invalid, 'elf artifact checksum'):
            self.validate()

    def test_wrong_mode_is_refused(self):
        with self.assertRaisesRegex(bundle.Invalid, 'mode'):
            bundle.validate(self.directory, board='rp2040', mode='ram', source_root=self.source)

    def test_dirty_and_new_sources_change_identity(self):
        path = self.source / 'devices/input.ldn'
        path.write_text('uncommitted bytes')
        with self.assertRaisesRegex(bundle.Invalid, 'source identity'):
            self.validate()

        path.write_text('devices')
        (self.source / 'devices/new.ldn').write_text('new input')
        with self.assertRaisesRegex(bundle.Invalid, 'source identity'):
            self.validate()

    def test_toolchain_pin_changes_invalidate_bundle(self):
        (self.source / 'environments/pins.sh').write_text('new toolchain')
        with self.assertRaisesRegex(bundle.Invalid, 'source identity'):
            self.validate()

    def test_snapshot_preserves_dirty_inputs_but_omits_cache(self):
        (self.source / 'devices/new.ldn').write_bytes(b'dirty')
        cache = self.source / 'environments/boards/__pycache__'
        cache.mkdir()
        (cache / 'cached.pyc').write_bytes(b'cache')
        destination = self.root / 'snapshot'
        identity = bundle.snapshot(destination, self.source)
        self.assertEqual(identity, bundle.source_identity(destination))
        self.assertEqual((destination / 'devices/new.ldn').read_bytes(), b'dirty')
        self.assertFalse((destination / 'environments/boards/__pycache__').exists())

    def test_traversal_absolute_and_symlink_paths_are_refused(self):
        for value in ('../outside', '/etc/passwd'):
            with self.subTest(value=value):
                self.alter(lambda manifest: manifest['files']['elf'].update(path=value))
                with self.assertRaisesRegex(bundle.Invalid, 'unsafe artifact'):
                    self.validate()
        self.alter(lambda manifest: manifest['files']['elf'].update(path='link'))
        (self.directory / 'link').symlink_to(self.directory / 'board.elf')
        with self.assertRaisesRegex(bundle.Invalid, 'symlink'):
            self.validate()

    def test_consume_retains_checked_files_without_running_commands(self):
        output = self.root / 'run'
        # consume uses this module's runtime root, normally the transferred tree.
        original = bundle.validate
        with mock.patch.object(bundle, 'validate', side_effect=lambda directory, **kw:
                original(directory, source_root=self.source, **kw)):
            prepared = bundle.consume(SimpleNamespace(out=output),
                SimpleNamespace(bundle=self.directory, mode='boot'), 'rp2040')
        self.assertEqual(bundle.artifact(prepared, 'elf').read_bytes(), b'board.elf')
        self.assertTrue((output / 'bundle.json').is_file())

    def test_manifest_shape_errors_are_actionable(self):
        for value in ([], {'format_version': 1, 'board': 'rp2040', 'mode': 'boot', 'files': []}):
            (self.directory / 'bundle.json').write_text(json.dumps(value))
            with self.assertRaises(bundle.Invalid):
                self.validate()

    def test_snapshot_cannot_recursively_copy_into_inputs(self):
        with self.assertRaisesRegex(bundle.Invalid, 'outside the source input'):
            bundle.snapshot(self.source / 'devices/snapshot', self.source)


if __name__ == '__main__':
    unittest.main()
