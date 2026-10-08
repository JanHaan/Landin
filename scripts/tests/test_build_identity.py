#!/usr/bin/env python3
"""Build provenance for Git checkouts and source archives."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('build_identity', ROOT / 'scripts/build_identity.py')
IDENTITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IDENTITY)


class BuildIdentity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='landin identity ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'checkout with spaces'
        self.root.mkdir()
        for name in ('compiler/ada/src/base/main.ads', 'compiler/ada/test.gpr',
                     'scripts/build.sh', 'README.md'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name + '\n')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'fixture')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_revision_and_relative_digest(self):
        before = IDENTITY.identity(self.root, 'debug')
        self.assertEqual(before[0], self.git('rev-parse', 'HEAD'))
        self.assertEqual(len(before[0]), 40)
        copy = Path(self.temp.name) / 'another path'
        shutil.copytree(self.root, copy)
        self.assertEqual(before, IDENTITY.identity(copy, 'debug'))

    def test_source_dirty_docs_clean(self):
        before = IDENTITY.identity(self.root, 'debug')
        (self.root / 'README.md').write_text('changed explanation\n')
        (self.root / 'compiler/ada/src/base/README.md').write_text('source prose\n')
        self.assertEqual(before, IDENTITY.identity(self.root, 'debug'))
        source = self.root / 'compiler/ada/src/base/main.ads'
        source.write_text('changed compiler\n')
        changed = IDENTITY.identity(self.root, 'debug')
        self.assertTrue(changed[2])
        self.assertNotEqual(before[1], changed[1])
        source.unlink()
        self.assertTrue(IDENTITY.identity(self.root, 'debug')[2])

    def test_untracked_input_and_generator_change(self):
        before = IDENTITY.identity(self.root, 'debug')
        path = self.root / 'scripts/build_identity.py'
        path.write_text('generator one\n')
        first = IDENTITY.identity(self.root, 'debug')
        self.assertTrue(first[2])
        self.assertNotEqual(before[1], first[1])
        path.write_text('generator two\n')
        self.assertNotEqual(first[1], IDENTITY.identity(self.root, 'debug')[1])

    def test_ignored_compiler_inputs_are_dirty(self):
        (self.root / '.gitignore').write_text('ignored.ads\ncompiler/ada/build/\n')
        self.git('add', '.gitignore')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'ignore fixture')
        before = IDENTITY.identity(self.root, 'debug')
        self.assertFalse(before[2])
        generated = self.root / 'compiler/ada/build/generated/ignored.ads'
        generated.parent.mkdir(parents=True)
        generated.write_text('ignored output\n')
        self.assertEqual(before, IDENTITY.identity(self.root, 'debug'))
        (self.root / 'compiler/ada/src/base/ignored.ads').write_text('compiler input\n')
        changed = IDENTITY.identity(self.root, 'debug')
        self.assertTrue(changed[2])
        self.assertNotEqual(before[1], changed[1])

    def test_archive_fallback(self):
        digest = IDENTITY.identity(self.root, 'debug')[1]
        shutil.rmtree(self.root / '.git')
        archive = IDENTITY.identity(self.root, 'debug')
        self.assertEqual(archive, ('unknown', digest, False, 'debug'))
        nested = self.root / 'nested archive'
        shutil.copytree(self.root / 'compiler', nested / 'compiler')
        self.git('init', '-q')
        self.assertEqual(IDENTITY.identity(nested, 'debug')[0], 'unknown')

    def test_noop_preserves_output_and_mode_and_triplet(self):
        output = self.root / 'compiler/ada/build/tag/debug/generated/landin-build_identity.ads'
        IDENTITY.generate(self.root, 'debug', output)
        text = output.read_text()
        stamp = output.stat().st_mtime_ns
        IDENTITY.generate(self.root, 'debug', output)
        self.assertEqual(output.stat().st_mtime_ns, stamp)
        self.assertIn('Landin.Targets.Selection.Build_Triplet', text)
        self.assertNotIn(str(self.root), text)
        self.assertIn('Mode : constant String := "debug"', text)
        IDENTITY.generate(self.root, 'release', output)
        self.assertIn('Mode : constant String := "release"', output.read_text())

    def test_command_line_manifest_and_generation(self):
        output = Path(self.temp.name) / 'generated source' / 'landin-build_identity.ads'
        command = ['python3', str(ROOT / 'scripts/build_identity.py'), '--root',
                   str(self.root), '--mode', 'debug', '--output', str(output)]
        subprocess.run(command, check=True)
        manifest = subprocess.run(command + ['--manifest'], check=True,
                                  capture_output=True, text=True).stdout
        import hashlib
        self.assertEqual(manifest, hashlib.sha256(output.read_bytes()).hexdigest()
                         + ' identity ' + str(output) + '\n')


if __name__ == '__main__':
    unittest.main()
