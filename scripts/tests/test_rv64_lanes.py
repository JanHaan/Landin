#!/usr/bin/env python3
"""Controls require complete source-matching native RV64 verdicts."""
import importlib.util
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('rv64_lane', ROOT / 'compiler/tests/rv64/check.py')
LANE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LANE)


class RV64Controls(unittest.TestCase):
    def test_nonempty_coverage_in_each_fixture_lane(self):
        for kind in ('runtime', 'abi', 'isa'):
            self.assertTrue(LANE.select(kind))
        self.assertTrue(LANE.ABI_REQUIRED <= {p.name for p, _ in LANE.select('abi')})
        self.assertEqual(LANE.ISA_REQUIRED, {p.name for p, _ in LANE.select('isa')})

    def test_empty_selection_refuses_every_lane(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(LANE, 'ROOT', Path(tmp)):
            for kind in ('runtime', 'abi', 'isa'):
                with self.assertRaisesRegex(ValueError, 'empty fixture selection'):
                    LANE.select(kind)

    def test_independent_peer_and_abi_coverage_are_required(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(LANE, 'ROOT', Path(tmp)):
            fixture = Path(tmp) / 'compiler/tests/fixtures/abi/one'
            fixture.mkdir(parents=True)
            meta = fixture / 'fixture.meta'
            meta.write_text('targets: linux-rv64\n')
            with self.assertRaisesRegex(ValueError, 'independently compiled C peer'):
                LANE.select('abi')
            meta.write_text('targets: linux-rv64\nc-sources: peer.c\n')
            with self.assertRaisesRegex(ValueError, 'ABI coverage missing'):
                LANE.select('abi')

    def test_runtime_and_isa_profiles_cannot_be_empty_or_partial(self):
        args = SimpleNamespace(kind='isa', case=None)
        work = LANE.work_items(args)
        self.assertEqual({item[-1] for item in work}, set(LANE.LEVELS))
        for name in LANE.ISA_REQUIRED:
            self.assertEqual({(o, s, level) for p, _, o, s, level in work if p.name == name},
                             {(o, s, level) for o, s in LANE.PROFILES for level in LANE.LEVELS})

    def test_filtered_payload_cannot_supply_ci_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            prepared = Path(tmp)
            (prepared / 'prepared.json').write_text(json.dumps({'target': 'linux-rv64', 'kind': 'abi',
                    'scope': 'filtered', 'results': [{}]}))
            args = SimpleNamespace(kind='abi', prepared=prepared)
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}):
                with self.assertRaisesRegex(ValueError, 'filtered payload'):
                    LANE.load_prepared(args)

    def test_native_execution_refuses_another_architecture(self):
        with patch.object(LANE.platform, 'system', return_value='Linux'), \
             patch.object(LANE.platform, 'machine', return_value='x86_64'):
            with self.assertRaisesRegex(ValueError, 'physical RV64'):
                LANE.native_identity(Path('/tmp/unused'))

    def test_physical_probe_failure_prevents_any_extended_execution(self):
        args = SimpleNamespace(kind='isa', output=Path('/tmp/output'))
        manifest = {'results': [{'label': 'would-execute'}]}
        result = SimpleNamespace(returncode=77, stdout=b'unsupported', stderr=b'')
        with patch.object(LANE.subprocess, 'run', return_value=result) as run, \
             patch.object(Path, 'write_bytes'):
            with self.assertRaisesRegex(ValueError, 'hardware does not execute xtheadba'):
                LANE.execute(args, manifest)
            self.assertEqual(run.call_count, 1)

    def test_prepared_payload_rejects_incomplete_profiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            prepared = Path(tmp)
            manifest = {'target': 'linux-rv64', 'kind': 'isa', 'scope': 'complete',
                        'status': 'emitted', 'sources_sha256': {}, 'results': [
                            {'case': 'runtime/rv64-feature-fact', 'optimize': 'none',
                             'specialize': 'off', 'level': 'rv64gc'}]}
            (prepared / 'prepared.json').write_text(json.dumps(manifest))
            args = SimpleNamespace(kind='isa', case=None, prepared=prepared)
            with patch.object(LANE, 'source_hashes', return_value={}), \
                 patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(ValueError, 'prepared corpus incomplete'):
                    LANE.load_prepared(args)

    def test_prepared_payload_rejects_modified_sources_and_binaries(self):
        with tempfile.TemporaryDirectory() as tmp:
            prepared = Path(tmp)
            bundle = prepared / 'bundle'
            bundle.mkdir()
            (bundle / 'program').write_bytes(b'changed executable')
            manifest = {'target': 'linux-rv64', 'kind': 'abi', 'scope': 'filtered',
                        'status': 'emitted', 'sources_sha256': {'source': 'old'},
                        'results': [{'label': 'program'}],
                        'bundle_sha256': {'program': '0' * 64}}
            path = prepared / 'prepared.json'
            path.write_text(json.dumps(manifest))
            args = SimpleNamespace(kind='abi', prepared=prepared)
            with patch.object(LANE, 'source_hashes', return_value={}), \
                 patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(ValueError, 'source checkout differs'):
                    LANE.load_prepared(args)
                manifest['sources_sha256'] = {}
                path.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, 'prepared bundle checksum'):
                    LANE.load_prepared(args)

    def test_fixed_if_fact_cannot_pass_with_one_verdict_at_both_levels(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = SimpleNamespace(kind='isa', output=Path(tmp))
            result = {'case': 'runtime/rv64-feature-fact', 'label': 'extended',
                      'level': 'rv64gc_xtheadba', 'meta': {'status': '42'}}
            manifest = {'results': [result]}
            probe = SimpleNamespace(returncode=0, stdout=b'confirmed', stderr=b'')
            wrong = SimpleNamespace(returncode=42, stdout=b'', stderr=b'')
            with patch.object(LANE.subprocess, 'run', side_effect=[probe, wrong]):
                with self.assertRaisesRegex(ValueError, 'expected 43'):
                    LANE.execute(args, manifest)

    def test_merged_stream_preserves_cross_descriptor_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            bundle = output / 'bundle'
            bundle.mkdir()
            program = bundle / 'program'
            program.write_text('#!' + sys.executable + '\nimport os\n'
                               'os.write(1, b"first\\n")\n'
                               'os.write(2, b"second\\n")\n'
                               'os.write(1, b"third\\n")\nos._exit(42)\n')
            program.chmod(0o755)
            result = {'case': 'runtime/control', 'label': 'program',
                      'meta': {'status': '42', 'stream': 'merged',
                               'stdout': 'first\nsecond\nthird\n'}}
            LANE.execute(SimpleNamespace(kind='runtime', output=output), {'results': [result]})
            self.assertEqual(result['status'], 'passed')
            self.assertEqual((output / 'program.stderr').read_bytes(), b'')

    def test_trap_requires_sigill_instead_of_an_exit_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = SimpleNamespace(kind='runtime', output=Path(tmp))
            for returncode, passes in ((-4, True), (132, False), (-5, False)):
                result = {'case': 'runtime/control', 'label': 'trap', 'meta': {'traps': 'yes'}}
                with patch.object(LANE.subprocess, 'run', return_value=
                                  SimpleNamespace(returncode=returncode, stdout=b'', stderr=None)):
                    if passes:
                        LANE.execute(args, {'results': [result]})
                        self.assertEqual(result['status'], 'passed')
                    else:
                        with self.assertRaisesRegex(ValueError, 'expected -4'):
                            LANE.execute(args, {'results': [result]})

    def test_workflow_requires_all_native_and_emit_verdicts(self):
        workflow = (ROOT / '.github/workflows/gate.yml').read_text()
        for kind in ('runtime', 'debugger', 'abi', 'isa'):
            self.assertIn('rv64-' + kind, workflow)
            self.assertIn('rv64-emit-' + kind, workflow)
        self.assertIn('runs-on: ubuntu-24.04-riscv\n', workflow)
        self.assertIn('libc6-dev-riscv64-cross', workflow)
        self.assertIn('-print-file-name=libm.a', workflow)
        rv64_setup = workflow.split('  rv64-emit:\n', 1)[1].split(
            '  #  Build and compare assembly manifests', 1)[0]
        self.assertEqual(rv64_setup.count('timeout-minutes: 25'), 1)
        self.assertEqual(rv64_setup.count('timeout-minutes: 10'), 1)
        self.assertEqual(rv64_setup.count('Acquire::http::Timeout=30'), 4)
        self.assertEqual(rv64_setup.count('Acquire::https::Timeout=30'), 4)
        self.assertEqual(rv64_setup.count('Acquire::Retries=3'), 4)
        self.assertNotIn('apt-mirrors.txt', rv64_setup)
        action = (ROOT / '.github/actions/pinned-toolchain/action.yml').read_text()
        self.assertIn("if: runner.os == 'Linux' && runner.arch == 'X64'", action)
        self.assertIn('if test -f /etc/apt/apt-mirrors.txt;', action)
        self.assertIn("sudo sed -i '\\|^http://azure\\.archive\\.ubuntu\\.com/ubuntu/|d'", action)
        self.assertIn('cat /etc/apt/apt-mirrors.txt', action)
        self.assertLess(action.index('apt-mirrors.txt'), action.index('landin_install_toolchain'))
        aggregate = workflow.split('  gate:\n', 1)[1]
        self.assertIn('rv64-emit, rv64', aggregate)


if __name__ == '__main__':
    unittest.main()
