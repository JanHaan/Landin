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
from test_macho_identity import binary

spec = importlib.util.spec_from_file_location('darwin_cases', ROOT / 'compiler/tests/darwin/check.py')
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)


class DarwinEvidenceTests(unittest.TestCase):
    def test_committed_policy_contains_the_required_commands(self):
        self.assertEqual(json.loads((ROOT / darwin.MARKER).read_text()), darwin.required_policy(parity=True))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        policy = darwin.required_policy()
        manifest = {'fixtures': ['example'], 'darwin': [], 'profiles': [['none', 'off']]}
        environment = json.loads((ROOT / 'environments/macos-arm64/policy.json').read_text())
        contents = {darwin.MARKER: common.canonical(policy),
                    'compiler/tests/darwin/cases.json': common.canonical(manifest),
                    'environments/macos-arm64/policy.json': common.canonical(environment)}
        for name in ('main.ldn', 'caller"\\path.ldn', 'darwin-scalars.ldn'):
            contents['compiler/tests/debugging/' + name] = b'source snapshot'
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
                 '{executions}': '/archive/executions', '{bindings}': '/archive/bindings',
                 '{debugging}': '/archive/debugging'}
        commands = [{'name': f'step-{i}', 'argv': [paths.get(a, a) for a in argv],
                     'cwd': paths['source'], 'returncode': 0, 'timeout': False}
                    for i, argv in enumerate(policy['commands'])]
        for path in ('evidence', 'executions', 'bindings', 'debugging'):
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
        self.record = {'schema': 1, 'status': 'passed', 'scope': policy['scope'],
                       'run_id': '20260915T000000Z-123456789abc', 'source': self.source,
                       'environment': {'platform': 'Darwin-arm64', 'translated': False, 'policy': environment,
                                       'tools': {'debugger': {'path': '/lldb', 'sha256': 'a' * 64},
                                                 'clang': {'path': '/clang', 'sha256': 'a' * 64},
                                                 'dsymutil': {'path': '/dsymutil', 'sha256': 'a' * 64},
                                                 'dwarfdump': {'path': '/dwarfdump', 'sha256': 'a' * 64}}},
                       'policy': policy, 'paths': paths}
        results = []
        for opt, spec in [('none', 'off'), ('size', 'auto'), ('size', 'all')]:
            key = opt + '-' + spec
            results.append({'optimize': opt, 'specialize': spec, 'status': 'passed', 'checks': 168,
                            'identity': {'uuid': (b'u' * 16).hex(), 'build_id': 'a' * 64, 'kind': 2}})
            self.write('debugging/' + key + '-session.json', {'status': 'passed', 'checks': list(range(168))})
            self.write('debugging/' + key + '-scalars-session.json', {'status': 'passed', 'scalar_types': 13})
            for suffix in ('', '.s', '.o', '.sources.json', '.lldb', '-lldb.stdout',
                           '-verify.stdout', '-object-verify.stdout', '-unwind.stdout', '-uuid.stdout',
                           '-debug-map.stdout', '-stripped', '.dSYM/Contents/Resources/DWARF/' + key):
                path = self.root / ('debugging/' + key + suffix)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('LANDIN LLDB ACCEPTANCE PASSED')
            for suffix in ('', '-stripped'):
                (self.root / ('debugging/' + key + suffix)).write_bytes(binary())
            (self.root / ('debugging/' + key + '.dSYM/Contents/Resources/DWARF/' + key)).write_bytes(binary(kind=10))
            self.write('debugging/' + key + '.sources.json', {'build_id': 'a' * 64,
                       'assembly_sha256': common.file_hash(self.root / ('debugging/' + key + '.s'))})
        self.write('debugging/summary.json', {'status': 'passed', 'scope': 'R5.40', 'filtered': False,
                   'refine_sha256': compiler_hash, 'results': results,
                   'tools': {name: {'path': '/' + name, 'sha256': 'a' * 64}
                             for name in ('lldb', 'clang', 'dwarfdump', 'dsymutil', 'strip', 'otool')},
                   'sources': {name: common.digest(data) for name, data in contents.items()
                               if name.startswith('compiler/tests/debugging/')}})
        self.write('debugging/identity-checks.json', {name: 'passed' for name in (
            'default_none', 'caller_only', 'optional_filenames', 'comment_mismatch', 'dsym_mismatch')})
        self.seal()

    def test_lldb_missing_filtered_failed_and_substituted(self):
        original = common.read_json(self.root / 'debugging/summary.json')
        for key, value in (('filtered', True), ('status', 'failed'), ('results', []),
                           ('refine_sha256', 'b' * 64), ('sources', {}), ('tools', {})):
            with self.subTest(key=key):
                self.write('debugging/summary.json', dict(original, **{key: value}))
                self.seal()
                with self.assertRaises((common.Invalid, KeyError)):
                    darwin.validate(self.root, self.source)
        self.write('debugging/summary.json', original)
        self.write('debugging/none-off-session.json', {'status': 'passed', 'checks': []})
        self.seal()
        with self.assertRaises(common.Invalid):
            darwin.validate(self.root, self.source)

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
