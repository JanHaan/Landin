#!/usr/bin/env python3
"""Native CLI integration. Run with LANDIN_REFINE naming the built compiler."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

REFINE = os.environ.get('LANDIN_REFINE')
SOURCE = 'public main: () -> (code: i32) = code = 0 end main\n'


@unittest.skipUnless(REFINE, 'set LANDIN_REFINE for native CLI integration')
class NativeCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='landin cli native ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.refine = str(Path(REFINE).resolve())
        (self.root / 'main.ldn').write_text(SOURCE)

    def run_cli(self, *args, status=0):
        result = subprocess.run([self.refine, *args], cwd=self.root,
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return result

    def test_warning_controls(self):
        (self.root / 'warnings.ldn').write_text(
            'public main: () -> (code: i32) =\n'
            'mut value: i32 = 1\nunused: i32 = 42\n'
            'code = value - 1\nend main\n')

        def diagnostics(*controls, status=0):
            result = self.run_cli('check', 'warnings.ldn', '--diagnostics=json',
                                  *controls, status=status)
            return [json.loads(line) for line in result.stderr.splitlines()]

        original = diagnostics()
        self.assertEqual([d['code'] for d in original], ['L0326', 'L0349'])
        self.assertEqual(diagnostics('--warnings=default'), original)
        self.assertEqual(diagnostics('--warnings=all'), original)
        self.assertEqual(diagnostics('--warnings=none'), [])
        self.assertEqual(diagnostics('--allow=all'), [])
        self.assertEqual(diagnostics('--warn=all', '--warnings=none'), original)
        self.assertEqual(diagnostics('--deny=all', '--allow=all'), [])
        self.assertEqual(diagnostics('--allow=all', '--warn=L0349'), [original[1]])
        denied = diagnostics('--allow=all', '--deny=L0326', status=1)
        self.assertEqual(len(denied), 1)
        self.assertEqual(denied[0]['severity'], 'error')
        for field in ('code', 'message', 'labels', 'fixes'):
            self.assertEqual(denied[0][field], original[0][field])
        self.assertEqual(denied[0]['notes'][:-1], original[0]['notes'])
        self.assertIn('denied by command-line policy', denied[0]['notes'][-1])
        for style in ('human', 'short'):
            result = self.run_cli('check', 'warnings.ldn', '--deny=all',
                                  '--diagnostics=' + style, status=1)
            self.assertIn('error[L0326]', result.stderr)
            self.assertIn('error[L0349]', result.stderr)
            self.assertIn('warning denied by command-line policy' if style == 'short'
                          else 'warning was denied by command-line policy', result.stderr)
            normal = self.run_cli('check', 'warnings.ldn', '--diagnostics=' + style)
            self.assertNotIn('denied by command-line policy', normal.stderr)
        for path in ('program', 'program.d', 'build.json', 'stage.json'):
            (self.root / path).write_text('preserved')
        self.run_cli('compile', 'warnings.ldn', '--deny=all', '-vv',
                     '-o=program', '--depfile=program.d',
                     '--build-report=build.json', '--stage-report=stage.json',
                     status=1)
        for path in ('program', 'program.d', 'build.json', 'stage.json'):
            self.assertEqual((self.root / path).read_text(), 'preserved')
        self.assertFalse((self.root / 'program.s').exists())
        self.run_cli('compile', 'warnings.ldn', '--allow=all', '-o=allowed')
        self.assertEqual(subprocess.run([str(self.root / 'allowed')]).returncode, 0)
        (self.root / 'bad.ldn').write_text('@')
        self.run_cli('check', 'bad.ldn', '--warnings=none', '--allow=all', status=1)
        for flag in ('--warn=L0001', '--deny=L9999', '--allow=bad',
                     '--warnings=some'):
            self.run_cli('check', 'missing.ldn', flag, status=2)
        self.run_cli('--warn=all', 'check', 'missing.ldn', status=2)
        self.run_cli('missing.ldn', '--warn=all', status=2)
        advisory = Path(__file__).resolve().parents[2] / 'compiler/tests/fixtures/negative/warning-advisory/program.ldn'
        result = self.run_cli('check', str(advisory), '--diagnostics=json')
        emitted = [json.loads(line) for line in result.stderr.splitlines()]
        self.assertEqual([d['code'] for d in emitted],
                         ['L0326', 'L0349', 'L0349', 'L0349'])
        self.assertTrue(all(d['fixes'] == [] for d in emitted))

    def test_help_queries_compile_and_tool_trace(self):
        helps = [self.run_cli(*args).stdout for args in
                 (('compile', '--help'), ('--help', 'compile'), ('help', 'compile'))]
        self.assertEqual(helps[0], helps[1])
        self.assertEqual(helps[0], helps[2])
        self.run_cli('build', '--help', status=2)
        self.run_cli('--target=linux-x86-64', '--version', status=2)
        misuse = self.run_cli('check', '--emit=asm', status=2)
        machine = self.run_cli('check', '--emit=asm', '--diagnostics=json', status=2)
        code = json.loads(machine.stderr.splitlines()[0])['code']
        self.assertIn('error[' + code + ']', misuse.stderr)
        info = json.loads(self.run_cli('version', '--json').stdout)
        self.assertRegex(info['revision'], r'^[0-9a-f]{40}$|^unknown$')
        self.assertRegex(info['source_digest'], r'^[0-9a-f]{64}$')
        self.assertIn('targets', json.loads(self.run_cli('targets', '--json').stdout))
        self.run_cli('check', 'main.ldn')
        traced = self.run_cli('compile', '-v', '--verbose', 'main.ldn', '-o', 'program')
        self.assertIn('run [', traced.stderr)
        self.assertEqual(subprocess.run([str(self.root / 'program')]).returncode, 0)
        second = self.run_cli('compile', '-vv', 'main.ldn', '-o', 'program')
        self.assertIn('run [', second.stderr)
        planned = self.run_cli('compile', '--dry-run', '-v', '--build-mode=release',
                               '--optimize=speed', '--specialize=off', 'main.ldn')
        self.assertIn('build-mode=release; optimize=speed; specialize=off', planned.stderr)

    def test_literal_operands_color_quiet_and_json(self):
        for name in ('-literal.ldn', '@literal.ldn', 'fmt'):
            (self.root / name).write_text(SOURCE)
            self.run_cli('check', '--', name)
        (self.root / 'bad.ldn').write_text('@')
        human = self.run_cli('check', 'bad.ldn', status=1).stderr
        never = self.run_cli('check', '--color=never', 'bad.ldn', status=1).stderr
        quiet = self.run_cli('check', '--quiet', 'bad.ldn', status=1).stderr
        always = self.run_cli('check', '--color=always', 'bad.ldn', status=1).stderr
        self.assertEqual(human, never)
        self.assertEqual(human, quiet)
        self.assertIn('\x1b[', always)
        self.assertEqual(human, re.sub(r'\x1b\[[0-9;]*m', '', always))
        structured = self.run_cli('check', '--diagnostics=json', 'bad.ldn', status=1)
        self.assertEqual(structured.stdout, '')
        rows = [json.loads(line) for line in structured.stderr.splitlines()]
        self.assertTrue(rows)
        self.assertTrue(all(row['schema'] == 1 for row in rows))
        (self.root / 'warning.ldn').write_text(
            'public f: () -> none = mut value: i32 = 1 end f\n')
        warning = self.run_cli('check', 'warning.ldn').stderr
        self.assertIn('warning[', warning)
        self.assertEqual(warning, self.run_cli('check', '--quiet', 'warning.ldn').stderr)

    def test_json_fix_transport(self):
        fixtures = Path(__file__).resolve().parents[2] / 'compiler/tests/fixtures/negative'
        cases = [('mut-never-written', 0, 'L0326'),
                 ('unused-pure-local', 0, 'L0349'),
                 ('misspelt-name-is-offered-its-neighbour', 1, 'L0201')]
        for fixture, status, code in cases:
            with self.subTest(fixture=fixture):
                source = self.root / (fixture + '.ldn')
                source.write_bytes(next((fixtures / fixture).glob('*.ldn')).read_bytes())
                run = self.run_cli('check', '--diagnostics=json', str(source), status=status)
                self.assertEqual(run.stdout, '')
                rows = [json.loads(line) for line in run.stderr.splitlines()]
                self.assertGreaterEqual(len(rows), 2)
                self.assertIn(code, [row['code'] for row in rows])
                for row in rows:
                    self.assertEqual(row['kind'], 'diagnostic')
                    self.assertTrue(row['labels'])
                    self.assertTrue(row['fixes'])
                    self.assertIsInstance(row['notes'], list)
                    for label in row['labels']:
                        self.assertEqual(label['path'], str(source))
                        self.assertEqual(bytes.fromhex(label['path_hex']).decode(), str(source))
                    for fix in row['fixes']:
                        self.assertIn(fix['applicability'], ('exact', 'likely'))
                        self.assertTrue(fix['edits'])
                        for edit in fix['edits']:
                            self.assertEqual(edit['path'], str(source))
                            self.assertEqual(bytes.fromhex(edit['path_hex']).decode(), str(source))
                            self.assertIsInstance(edit['first_byte'], int)
                            self.assertIsInstance(edit['last_byte'], int)
                            self.assertIsInstance(edit['replacement'], str)
                if status == 0:
                    self.assertTrue(all(row['severity'] == 'warning' for row in rows))
                    self.assertTrue(any(row['notes'] for row in rows))
                else:
                    self.assertTrue(any(len(row['fixes']) == 3 for row in rows))
        source = self.root / 'likely.ldn'
        source.write_text('public f: () -> none = value: i32 = 1 value = 2 end f\n')
        run = self.run_cli('check', '--diagnostics=json', '-v', str(source), status=1)
        rows = [json.loads(line) for line in run.stderr.splitlines()]
        diagnostic = next(row for row in rows if row['kind'] == 'diagnostic')
        self.assertEqual(diagnostic['code'], 'L0303')
        self.assertEqual(diagnostic['fixes'][0]['applicability'], 'likely')
        self.assertGreater(len(diagnostic['labels']), 1)
        self.assertTrue(any(row['kind'] == 'trace' for row in rows))

    def test_bash_completion_scope(self):
        if not shutil.which('bash'):
            self.skipTest('bash is unavailable')
        completion = self.root / 'completion.bash'
        completion.write_text(self.run_cli('completion', 'bash').stdout)
        subprocess.run(['bash', '-n', str(completion)], check=True)
        command = ('source "$1"; COMP_WORDS=(refine fmt --); COMP_CWORD=2; '
                   '_refine_complete; printf "%s\\n" "${COMPREPLY[@]}"')
        words = subprocess.check_output(['bash', '-c', command, 'test', str(completion)],
                                        text=True).splitlines()
        self.assertIn('--check', words)
        self.assertNotIn('--emit', words)
        command = command.replace('refine fmt --', 'refine compile --')
        words = subprocess.check_output(['bash', '-c', command, 'test', str(completion)],
                                        text=True).splitlines()
        self.assertIn('--emit', words)

    def test_make_depfile_tracks_imports_and_root_membership(self):
        if not shutil.which('make'):
            self.skipTest('make is unavailable')
        entry = self.root / 'entry module'
        first = self.root / 'first root'
        second = self.root / 'second root'
        for directory in (entry, first, second / 'lib', self.root / 'out'):
            directory.mkdir(parents=True)
        (entry / 'main.ldn').write_text(
            'import lib\npublic main: () -> (code: i32) = code = lib.answer() end main\n')
        imported = second / 'lib/value.ldn'
        imported.write_text('public answer: () -> (value: i32) = value = 1 end answer\n')
        args = [self.refine, 'compile', '--emit=asm', '--root', str(first),
                '--root', str(second), str(entry), '-o', 'out/program.s',
                '--depfile', 'out/program.d']
        (self.root / 'Makefile').write_text(
            '.DEFAULT_GOAL := all\n.PHONY: all\nall: out/program.s\n'
            'out/program.s:\n\t@echo compile >> invocations\n\t'
            + shlex.join(args) + '\n-include out/program.d\n')

        def make(count):
            result = subprocess.run(['make', '--no-print-directory'], cwd=self.root,
                                    text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(len((self.root / 'invocations').read_text().splitlines()), count)

        make(1)
        deps = (self.root / 'out/program.d').read_text()
        self.assertIn('entry\\ module/main.ldn', deps)
        self.assertIn('second\\ root/lib/value.ldn', deps)
        make(1)  # A real consumer must regard the unchanged output as current.
        original = hashlib.sha256((self.root / 'out/program.s').read_bytes()).digest()
        # Apple's GNU Make 3.81 compares timestamps at whole-second precision.
        # Cross that boundary before each dependency edit, including a root's
        # directory membership change, so the real consumer sees newer inputs.
        time.sleep(1.1)
        imported.write_text('public answer: () -> (value: i32) = value = 2 end answer\n')
        make(2)
        self.assertNotEqual(original, hashlib.sha256((self.root / 'out/program.s').read_bytes()).digest())
        make(2)
        time.sleep(1.1)
        (first / 'lib').mkdir()
        (first / 'lib/value.ldn').write_text(
            'public answer: () -> (value: i32) = value = 3 end answer\n')
        make(3)  # An earlier ordered root now supplies the imported module.
        self.assertIn('first\\ root/lib/value.ldn', (self.root / 'out/program.d').read_text())
        make(3)
        time.sleep(1.1)
        (entry / 'main.ldn').write_text(
            'import lib\npublic main: () -> (code: i32) = code = lib.answer() + 1 end main\n')
        make(4)
        make(4)


if __name__ == '__main__':
    unittest.main()
