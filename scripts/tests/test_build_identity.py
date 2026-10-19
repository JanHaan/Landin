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
        for name in ('compiler/ada/src/base/main.ads', 'scripts/build.sh',
                     'README.md'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name + '\n')
        (self.root / 'compiler/ada/refine.gpr').write_text(
            'project Refine is\n   for Source_Dirs use ("src/base");\n'
            'end Refine;\n')
        (self.root / 'compiler/ada/landin_tests.gpr').write_text(
            'project Landin_Tests is\n   for Source_Dirs use ();\n'
            'end Landin_Tests;\n')
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

    def test_tracked_prose_dirty_without_changing_source_digest(self):
        before = IDENTITY.identity(self.root, 'debug')
        (self.root / 'README.md').write_text('changed explanation\n')
        (self.root / 'compiler/ada/src/base/README.md').write_text('source prose\n')
        prose = IDENTITY.identity(self.root, 'debug')
        self.assertTrue(prose[2])
        self.assertEqual(before[1], prose[1])
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
        self.assertEqual(archive, ('unknown', digest, False, 'debug', ''))
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

    def test_release_is_an_exact_tag_independent_of_mode(self):
        self.assertEqual(IDENTITY.identity(self.root, 'release')[4], '')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'tag', '-a', 'v0.2.7', '-m', 'release')
        for mode in ('debug', 'release'):
            tagged = IDENTITY.identity(self.root, mode)
            self.assertEqual(tagged[4], '0.2.7')
            self.assertFalse(tagged[2])
        (self.root / 'README.md').write_text('modified release declaration\n')
        dirty = IDENTITY.identity(self.root, 'release')
        self.assertEqual(dirty[4], '0.2.7')
        self.assertTrue(dirty[2])
        self.git('add', 'README.md')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'after release')
        self.assertEqual(IDENTITY.identity(self.root, 'release')[4], '')

    def test_nonrelease_and_ambiguous_tags(self):
        self.git('tag', 'experiment')
        self.git('tag', 'v0.2.7-not-a-release')
        self.assertEqual(IDENTITY.identity(self.root, 'debug')[4], '')
        self.git('tag', 'v0.2.7')
        self.git('tag', 'v0.2.8')
        with self.assertRaisesRegex(RuntimeError, 'multiple release tags'):
            IDENTITY.identity(self.root, 'debug')

    def test_staged_reverted_worktree_and_deleted_prose_are_dirty(self):
        original = (self.root / 'README.md').read_text()
        (self.root / 'README.md').write_text('staged change\n')
        self.git('add', 'README.md')
        (self.root / 'README.md').write_text(original)
        self.assertTrue(IDENTITY.identity(self.root, 'debug')[2])
        self.git('reset', '-q', 'HEAD', '--', 'README.md')
        self.assertFalse(IDENTITY.identity(self.root, 'debug')[2])
        (self.root / 'README.md').unlink()
        self.assertTrue(IDENTITY.identity(self.root, 'debug')[2])

    def test_tag_and_prose_changes_refresh_generated_identity_only(self):
        output = self.root / 'compiler/ada/build/generated/landin-build_identity.ads'
        IDENTITY.generate(self.root, 'debug', output)
        original = output.read_bytes()
        digest = IDENTITY.identity(self.root, 'debug')[1]
        self.git('tag', 'v0.2.7')
        IDENTITY.generate(self.root, 'debug', output)
        self.assertNotEqual(original, output.read_bytes())
        self.assertIn('Release_Version : constant String := "0.2.7"', output.read_text())
        tagged = output.read_bytes()
        (self.root / 'README.md').write_text('dirty prose\n')
        IDENTITY.generate(self.root, 'debug', output)
        self.assertNotEqual(tagged, output.read_bytes())
        self.assertEqual(digest, IDENTITY.identity(self.root, 'debug')[1])
        self.assertIn('Dirty : constant Boolean := True', output.read_text())

    def test_command_line_manifest_and_generation(self):
        output = Path(self.temp.name) / 'generated source' / 'landin-build_identity.ads'
        command = ['python3', str(ROOT / 'scripts/build_identity.py'), '--root',
                   str(self.root), '--mode', 'debug', '--output', str(output)]
        subprocess.run(command, check=True)
        manifest = subprocess.run(command + ['--manifest'], check=True,
                                  capture_output=True, text=True).stdout
        import hashlib
        rows = manifest.splitlines()
        self.assertEqual(rows[-1], 'identity '
                         + hashlib.sha256(output.read_bytes()).hexdigest()
                         + ' ' + self.git('rev-parse', 'HEAD') + ' clean')
        self.assertEqual([row.split()[0] + ' ' + row.split()[2]
                          for row in rows[:-1]],
                         ['project compiler/ada/landin_tests.gpr',
                          'project compiler/ada/refine.gpr',
                          'source compiler/ada/src/base/main.ads'])
        for row in rows[:-1]:
            self.assertEqual(row.split()[1], hashlib.sha256(
                (self.root / row.split()[2]).read_bytes()).hexdigest())

    def test_inputs_are_found_from_the_projects(self):
        ada = self.root / 'compiler/ada'
        (ada / 'common.gpr').write_text(
            'abstract project Common is\n   package Compiler is\n'
            '      for Local_Configuration_Pragmas use "local.adc";\n'
            '   end Compiler;\nend Common;\n')
        (ada / 'local.adc').write_text('pragma Ada_2022;\n')
        (ada / 'other/deep').mkdir(parents=True)
        (ada / 'other/deep/unit.adb').write_text('unit\n')
        (ada / 'other/deep/notes.txt').write_text('prose\n')
        (ada / 'other/host.c').write_text('host\n')
        (ada / 'refine.gpr').write_text(
            'with "common.gpr";\nproject Refine is\n'
            '   for Languages use ("Ada", "C");  --  "ignored.adc"\n'
            '   for Source_Dirs use ("src/base", "other/**",\n'
            '                        Landin_Common.Build_Dir & "/generated");\n'
            '   for Object_Dir use Landin_Common.Build_Dir & "/obj";\n'
            'end Refine;\n')
        projects, sources, files = IDENTITY.project_inputs(self.root)
        self.assertEqual(projects, ['compiler/ada/common.gpr',
                                    'compiler/ada/landin_tests.gpr',
                                    'compiler/ada/refine.gpr'])
        self.assertEqual(files, ['compiler/ada/local.adc'])
        self.assertEqual(sources, ['compiler/ada/other/deep/unit.adb',
                                   'compiler/ada/other/host.c',
                                   'compiler/ada/src/base/main.ads'])
        # A new kind of input counts from the moment a project names it.
        before = IDENTITY.identity(self.root, 'debug')[1]
        (ada / 'local.adc').write_text('pragma Ada_2012;\n')
        self.assertNotEqual(before, IDENTITY.identity(self.root, 'debug')[1])

    def test_unreadable_project_inputs_are_refused(self):
        ada = self.root / 'compiler/ada'
        for text, said in (
                ('project Refine is\n   for Languages use ("Rust");\n'
                 'end Refine;\n', 'uses rust'),
                ('project Refine is\n   for Source_Dirs use (Dirs);\n'
                 'end Refine;\n', 'names a source directory Dirs'),
                ('with "missing.gpr";\nproject Refine is\nend Refine;\n',
                 'missing.gpr does not exist')):
            with self.subTest(said=said):
                (ada / 'refine.gpr').write_text(text)
                with self.assertRaisesRegex(IDENTITY.ProjectError, said):
                    IDENTITY.project_inputs(self.root)

    def test_changed_names_what_moved(self):
        base = ['project 1 compiler/ada/refine.gpr',
                'source 2 compiler/ada/src/a.adb',
                'identity 3 abc clean', 'mode debug tag t']
        def said(after):
            return IDENTITY.changed('\n'.join(base), '\n'.join(after))
        self.assertEqual(said(base), [])
        self.assertEqual(said([base[0], 'source 9 compiler/ada/src/a.adb',
                               'identity 4 abc clean', base[3]]),
                         ['compiler/ada/src/a.adb changed'])
        self.assertEqual(said(base[:2] + ['identity 4 abc dirty', base[3]]),
                         ['the checkout went from clean to dirty: a tracked'
                          ' file the compiler does not build from was edited'
                          ' or restored, which changes only the provenance'
                          ' `refine --version` reports'])
        self.assertEqual(said(base[:2] + ['identity 4 def clean', base[3]]),
                         ['HEAD moved from abc to def'])
        self.assertEqual(said(base[:2] + ['identity 4 abc clean', base[3]]),
                         ['a build script changed, which the provenance'
                          ' `refine --version` reports covers'])
        self.assertEqual(said(base + ['source 5 compiler/ada/src/b.adb']),
                         ['compiler/ada/src/b.adb appeared'])


class CheckoutInputs(unittest.TestCase):
    """Every file of compiler/ada is an input of the build or named here."""

    NOT_INPUTS = {'compiler/ada/README.md', 'compiler/ada/TOOLCHAIN.md'}

    def test_every_compiler_file_is_an_input_or_prose(self):
        listed = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '-z',
                                 'compiler/ada'], capture_output=True,
                                check=True).stdout
        tracked = {name.decode() for name in listed.split(b'\0') if name}
        inputs = set(IDENTITY.inputs(ROOT))
        unclassified = sorted(tracked - inputs - self.NOT_INPUTS)
        self.assertEqual(unclassified, [], 'a file under compiler/ada that no'
                         ' project names reaches no object; name it in'
                         ' CheckoutInputs.NOT_INPUTS if that is so, or in a'
                         ' project file if it is an input')
        self.assertEqual(sorted(self.NOT_INPUTS & inputs), [])


if __name__ == '__main__':
    unittest.main()
