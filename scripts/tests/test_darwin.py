"""Failure-path checks for native evidence, independent of the current host."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import common
import darwin

spec = importlib.util.spec_from_file_location('darwin_cases', ROOT / 'compiler/tests/darwin/check.py')
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)


class DarwinEvidenceTests(unittest.TestCase):
    def test_committed_policy_contains_the_required_commands(self):
        self.assertEqual(json.loads((ROOT / darwin.MARKER).read_text()), darwin.required_policy())

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        policy = json.loads((ROOT / darwin.MARKER).read_text())
        manifest = {'fixtures': ['example'], 'darwin': [], 'profiles': [['none', 'off']]}
        environment = json.loads((ROOT / 'environments/macos-arm64/policy.json').read_text())
        contents = {darwin.MARKER: common.canonical(policy),
                    'compiler/tests/darwin/cases.json': common.canonical(manifest),
                    'environments/macos-arm64/policy.json': common.canonical(environment)}
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for name, data in contents.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
        payload = stream.getvalue()
        self.source = {'commit': '1' * 40, 'tree': '2' * 40, 'source_sha256': '3' * 64,
                       'archive_sha256': common.digest(payload),
                       'inventory': common.archive_inventory(payload)}
        (self.root / 'source.tar.gz').write_bytes(payload)
        (self.root / 'policy.json').write_bytes(contents[darwin.MARKER])
        (self.root / 'cases.json').write_bytes(contents['compiler/tests/darwin/cases.json'])
        (self.root / 'environment-policy.json').write_bytes(contents['environments/macos-arm64/policy.json'])
        for path in ('refine', 'source-manifest.txt', 'configuration.cgpr'):
            (self.root / path).write_text('retained build identity')
        paths = {'source': '/archive/source', '{refine}': '/archive/refine',
                 '{executions}': '/archive/executions', '{bindings}': '/archive/bindings'}
        commands = [{'name': f'step-{i}', 'argv': [paths.get(a, a) for a in argv],
                     'cwd': paths['source'], 'returncode': 0, 'timeout': False}
                    for i, argv in enumerate(policy['commands'])]
        for path in ('evidence', 'executions', 'bindings'):
            (self.root / path).mkdir()
        self.write('evidence/commands.json', commands)
        (self.root / 'evidence/step-1.stdout').write_text(
            'HOST-ONLY compiler checks; target workload emission/execution excluded\n'
            'cases 1, passed 1, failed 0, checks 1\n')
        compiler_hash = common.file_hash(self.root / 'refine')
        self.write('executions/summary.json', {'status': 'passed', 'scope': 'R5.30',
                   'refine_sha256': compiler_hash, 'cases_sha256': common.file_hash(self.root / 'cases.json'),
                   'results': [{'case': 'example', 'optimize': 'none', 'specialize': 'off', 'status': 'passed'}]})
        self.write('bindings/summary.json', {'status': 'passed', 'refine_sha256': compiler_hash,
                                           'archive_selection': 'passed'})
        self.record = {'schema': 1, 'status': 'passed', 'scope': 'R5.30 native lowering',
                       'run_id': '20260915T000000Z-123456789abc', 'source': self.source,
                       'environment': {'platform': 'Darwin-arm64', 'translated': False, 'policy': environment},
                       'policy': policy, 'paths': paths}
        self.seal()

    def write(self, path, value):
        (self.root / path).write_bytes(common.canonical(value))

    def seal(self):
        self.record['files'] = darwin.files_under(self.root)
        self.write('record.json', self.record)

    def test_matching_native_evidence_and_annotation(self):
        annotation = darwin.validate(self.root, self.source)
        darwin.validate_annotation(annotation, self.source)
        self.assertTrue(darwin.required(self.source))
        changed = copy.deepcopy(annotation)
        changed['commit'] = '4' * 40
        with self.assertRaises(common.Invalid):
            darwin.validate_annotation(changed, self.source)

    def test_source_and_retained_artifact_mismatch(self):
        changed = {**self.source, 'commit': '4' * 40}
        with self.assertRaises(common.Invalid):
            darwin.validate(self.root, changed)
        (self.root / 'refine').write_text('different binary')
        with self.assertRaises(common.Invalid):
            darwin.validate(self.root, self.source)

    def test_relabelled_or_incomplete_matrix_is_refused(self):
        summary = common.read_json(self.root / 'executions/summary.json')
        summary['results'] = []
        self.write('executions/summary.json', summary)
        self.seal()
        with self.assertRaises(common.Invalid):
            darwin.validate(self.root, self.source)

    def test_failed_or_substituted_command_is_refused(self):
        commands = common.read_json(self.root / 'evidence/commands.json')
        for key, value in (('timeout', True), ('returncode', 1), ('argv', ['true'])):
            altered = copy.deepcopy(commands)
            altered[0][key] = value
            self.write('evidence/commands.json', altered)
            self.seal()
            with self.assertRaises(common.Invalid):
                darwin.validate(self.root, self.source)

    def test_added_symlink_cannot_escape_manifest(self):
        (self.root / 'extra').symlink_to('refine')
        with self.assertRaises(common.Invalid):
            darwin.validate(self.root, self.source)

    def test_native_oracles_require_exact_status_output_and_trap(self):
        cases.outcome({'status': 42}, 42, b'ok', b'', b'ok')
        cases.outcome({'traps': 'yes'}, -cases.signal.SIGTRAP, b'', b'')
        for meta, status, stdout, stderr, expected in (
                ({'status': 42}, 0, b'ok', b'', b'ok'),
                ({'status': 42}, 42, b'wrong', b'', b'ok'),
                ({'status': 42}, 42, b'ok', b'error', b'ok'),
                ({'traps': 'yes'}, -cases.signal.SIGSEGV, b'', b'', None)):
            with self.assertRaises(ValueError):
                cases.outcome(meta, status, stdout, stderr, expected)


if __name__ == '__main__':
    unittest.main()
