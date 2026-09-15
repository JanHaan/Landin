"""Fail-closed schema-3 coverage and producer/consumer checks, without native tools."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import common
import darwin_parity as parity


class DarwinParityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'output'
        self.output.mkdir()
        self.source = self.root / 'source'
        self.base = self.source / 'compiler/tests/fixtures/runtime/probe'
        self.base.mkdir(parents=True)
        inputs = self.source / 'compiler/tests/darwin'
        inputs.mkdir(parents=True)
        (inputs / 'parity.json').write_text('{"differences": {}}')
        self.meta = dict(program='main.ldn', status='42', profiles='standard', **{'class': 'runtime'})
        self.worker = Path('/accepted/source')
        self.original = Path('/accepted/executions')
        self.compiler = Path('/accepted/refine')
        self.key = 'runtime-probe-none-off'
        self.commands = []
        self.summary = dict(scope='R5.50', status='passed', refine_sha256='compiler', differences={}, results=[])
        row = dict(case='runtime/probe', optimize='none', specialize='off', status='passed', exit=42)
        for suffix, field in (('.s', 'assembly'), ('.o', 'object'), ('', 'executable')):
            path = self.output / (self.key + suffix)
            path.write_text(field)
            row[field] = common.file_hash(path)
        self.summary['results'].append(row)
        (self.output / 'retain-clang').write_text(
            '#!/bin/sh\nexec /usr/bin/clang -save-temps=obj -x assembler "$@"\n')
        executable = str(self.original / self.key)
        self.command('build', [str(self.compiler), '--target=darwin-arm64', '--optimize=none', '--specialize=off',
            str(self.worker / 'compiler/tests/fixtures/runtime/probe/main.ldn'),
            '--toolchain=' + str(self.original / 'retain-clang'), '--emit=exe', '-o', executable])
        self.command('file', ['/usr/bin/file', executable], stdout='Mach-O 64-bit executable arm64')
        self.command('execute', [executable], status=42)
        self.schedule = [('runtime/probe', 'none', 'off', self.meta, self.base)]

    def command(self, suffix, argv, status=0, stdout=''):
        name = self.key + '-' + suffix
        self.commands.append(dict(argv=argv, cwd=str(self.worker / 'compiler/ada'), status=status,
            timeout=False, stdout=name + '.stdout', stderr=name + '.stderr'))
        (self.output / (name + '.stdout')).write_text(stdout)
        (self.output / (name + '.stderr')).write_text('')

    def validate(self):
        (self.output / 'summary.json').write_text(json.dumps(self.summary))
        (self.output / 'commands.json').write_text(json.dumps(self.commands))
        with patch.object(parity, 'runtime_schedule', return_value=self.schedule):
            parity.validate_runtime(self.output, self.source, 'compiler', self.worker, self.original, self.compiler)

    def test_complete_native_producer_chain(self):
        self.validate()

    def test_missing_profile_or_relabelled_scope(self):
        for field, value in (('results', []), ('scope', 'filtered'), ('refine_sha256', 'another')):
            original = copy.deepcopy(self.summary)
            self.summary[field] = value
            with self.subTest(field=field), self.assertRaises(common.Invalid):
                self.validate()
            self.summary = original

    def test_failed_timeout_or_substituted_commands(self):
        for index, field, value in ((0, 'status', 1), (0, 'argv', ['true']),
                                    (1, 'timeout', True), (2, 'argv', ['/another/executable']),
                                    (2, 'status', 1), (2, 'cwd', '/other')):
            original = copy.deepcopy(self.commands)
            self.commands[index][field] = value
            with self.subTest(index=index, field=field), self.assertRaises(common.Invalid):
                self.validate()
            self.commands = original

    def test_substituted_object_or_unexplained_limit(self):
        (self.output / (self.key + '.o')).write_text('another object')
        with self.assertRaises(common.Invalid):
            self.validate()
        (self.output / (self.key + '.o')).write_text('object')
        self.summary['results'][0]['status'] = 'platform-limited'
        with self.assertRaises(common.Invalid):
            self.validate()

    def test_shared_output_is_not_optional(self):
        self.meta['stdout'] = 'required output\n'
        with self.assertRaises(common.Invalid):
            self.validate()
        (self.output / (self.key + '-execute.stdout')).write_text(self.meta['stdout'])
        self.validate()

    def test_native_replacement_and_profile_inventory(self):
        schedule = parity.runtime_schedule(ROOT)
        names = {(n, o, s) for n, o, s, _, _ in schedule}
        for fixture in ('derived-parser', 'derived-containers', 'derived-hosted-memory'):
            for opt, spec in parity.PROFILES + [('none', 'all'), ('speed', 'all')]:
                self.assertIn(('runtime/' + fixture, opt, spec), names)
        for name in ('varargs', 'transport', 'platform'):
            self.assertTrue(any(n == name for n, _, _ in names))

    def test_debugger_refuses_failed_missing_and_weakened_values(self):
        stop = dict(name='entry', source='/source/main.ldn', line=12, stack=['main'], values={'value': 42})
        expected = {'stops': ['entry'], 'inferior state': 10, 'inferior status': 42,
                    'stdout': '', 'stderr': '', 'entry.function': 'main', 'entry.line': 12,
                    'entry.file': '/source/main.ldn', 'entry.stack': ['main'], 'entry.value': 42}
        session = dict(status='passed', checks=[dict(label=n, actual=v, expected=v) for n, v in expected.items()])
        parity.validate_session(session, [stop], '')
        failed = copy.deepcopy(session)
        failed['status'] = 'failed'
        missing = copy.deepcopy(session)
        missing['checks'].pop()
        weakened = copy.deepcopy(session)
        weakened['checks'][-1].update(actual=0, expected=0)
        for result in (failed, missing, weakened):
            with self.assertRaises(common.Invalid):
                parity.validate_session(result, [stop], '')


if __name__ == '__main__':
    unittest.main()
