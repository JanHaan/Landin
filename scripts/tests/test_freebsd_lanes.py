#!/usr/bin/env python3
"""Controls for FreeBSD corpus selection and checked release inputs."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('freebsd_lane', ROOT / 'compiler/tests/freebsd/check.py')
LANE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LANE)
import vm


class FreeBSDControls(unittest.TestCase):
    def test_prepared_execution_refuses_missing_architecture_profiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            prepared = Path(tmp)
            manifest = {'arch': 'amd64', 'kind': 'runtime', 'scope': 'complete',
                        'results': [{'case': 'runtime/assembly-operands', 'optimize': 'none',
                                     'specialize': 'off', 'level': None}]}
            (prepared / 'prepared.json').write_text(json.dumps(manifest))
            args = SimpleNamespace(prepared=prepared, arch='amd64', kind='runtime', case=None)
            with self.assertRaisesRegex(ValueError, 'prepared corpus incomplete'):
                LANE.load_prepared(args)
            manifest['results'] = []
            (prepared / 'prepared.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'empty prepared fixture selection'):
                LANE.load_prepared(args)

    def test_prepared_payload_mutation_cannot_execute(self):
        with tempfile.TemporaryDirectory() as tmp:
            prepared = Path(tmp)
            (prepared / 'payload.tar.gz').write_bytes(b'changed')
            manifest = {'arch': 'amd64', 'kind': 'runtime', 'scope': 'filtered',
                        'results': [{}], 'payload_sha256': '0' * 64}
            (prepared / 'prepared.json').write_text(json.dumps(manifest))
            args = SimpleNamespace(prepared=prepared, arch='amd64', kind='runtime', case=None)
            with patch.dict('os.environ', {}, clear=True):
                with self.assertRaisesRegex(ValueError, 'prepared payload checksum'):
                    LANE.load_prepared(args)

    def test_existing_checkout_is_refused_and_not_cleaned_up(self):
        lane = LANE.Lane.__new__(LANE.Lane)
        lane.output = Path('/tmp/output')
        lane.source_root = Path('/real/checkout/Landin')
        lane.remote_prefix = '/tmp/landin-owned'
        lane.transferred = False
        guest = Mock()
        guest.checked.side_effect = ValueError('existing checkout')
        with self.assertRaisesRegex(ValueError, 'existing checkout'):
            lane.transfer(guest)
        self.assertFalse(lane.transferred)
        guest.put.assert_not_called()
        command = guest.checked.call_args.args[0]
        self.assertIn('set -e; test ! -e', command)
        self.assertNotIn('rm', command)

    def test_persistent_guest_limit_is_restored_after_a_failed_lane(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane = SimpleNamespace(args=SimpleNamespace(runner_ssh='ssh ci@freebsd-vm',
                                   output=Path(tmp)), cleanup=Mock())
            guest = Mock()
            guest.checked.side_effect = [b'1073741824', b'', b'kern.maxdsiz: 4294967296', b'']
            with patch.object(LANE, 'Guest', return_value=guest):
                with self.assertRaisesRegex(ValueError, 'execution failed'):
                    with LANE.configured_guest(lane, None):
                        raise ValueError('execution failed')
            self.assertEqual(guest.checked.call_args.args[0], 'sysctl kern.maxdsiz=1073741824')

    def test_runner_transport_preserves_binary_input_and_sudo_quoting(self):
        guest = vm.Guest(ssh='ssh -T ci@freebsd-vm', sudo=True)
        with patch.object(vm.subprocess, 'run') as run:
            guest.run("printf '%s' '$literal'", input=b'\0\xff')
        self.assertEqual(run.call_args.kwargs['input'], b'\0\xff')
        self.assertEqual(run.call_args.args[0][:3], ['ssh', '-T', 'ci@freebsd-vm'])
        self.assertIn('sudo -n /bin/sh -c', run.call_args.args[0][-1])

    def test_each_architecture_has_runtime_operands_and_required_c_peers(self):
        for arch in ('amd64', 'arm64'):
            self.assertIn('assembly-operands', {p.name for p, _ in LANE.select(arch, 'runtime')})
            selected = {p.name for p, _ in LANE.select(arch, 'abi')}
            self.assertTrue(LANE.ABI_REQUIRED <= selected)
            self.assertGreater(len(selected), len(LANE.ABI_REQUIRED))

    def test_linux_fault_paths_have_explicit_bsd_endpoint_peers(self):
        for arch in ('amd64', 'arm64'):
            selected = {p.name: m for p, m in LANE.select(arch, 'runtime')}
            for name in ('core-io-erased-system', 'r440-errno-detail'):
                self.assertEqual(selected[name]['c-sources'], '../../../freebsd/io_endpoints.c')

    def test_empty_selection_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(LANE, 'ROOT', Path(tmp)):
            for arch in ('amd64', 'arm64'):
                for kind in ('runtime', 'abi'):
                    with self.assertRaisesRegex(ValueError, 'empty fixture selection'):
                        LANE.select(arch, kind)

    def test_removing_an_import_export_peer_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(LANE, 'ROOT', Path(tmp)):
            fixture = Path(tmp) / 'compiler/tests/fixtures/abi/only-one'
            fixture.mkdir(parents=True)
            (fixture / 'fixture.meta').write_text('targets: freebsd-x86-64, freebsd-arm64\nc-sources: peer.c\n')
            with self.assertRaisesRegex(ValueError, 'ABI coverage missing'):
                LANE.select('amd64', 'abi')
            with self.assertRaisesRegex(ValueError, 'ABI coverage missing'):
                LANE.select('arm64', 'abi')

    def test_an_abi_fixture_without_a_c_peer_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(LANE, 'ROOT', Path(tmp)):
            fixture = Path(tmp) / 'compiler/tests/fixtures/abi/only-one'
            fixture.mkdir(parents=True)
            (fixture / 'fixture.meta').write_text('targets: freebsd-x86-64, freebsd-arm64\n')
            with self.assertRaisesRegex(ValueError, 'independently compiled C peer'):
                LANE.select('amd64', 'abi')

    def test_linked_checks_use_function_extents_past_local_labels(self):
        symbols = '1000 g F .text 0020 main\n2000 g F .text 0020 _start\n'
        listing = ('1000 <main>:\n 1000: nop\n1010 <.L1_1>:\n'
                   ' 1010: ldaddal w0, w1, [x2]\n2000 <_start>:\n 2000: ldxr w0, [x2]\n')
        code = LANE.fixture_code(symbols, listing, {'main'})
        self.assertIn('ldaddal', code)
        self.assertNotIn('ldxr', code)
        with self.assertRaisesRegex(ValueError, 'missing from linked ELF'):
            LANE.fixture_code(symbols, listing, {'absent'})

    def test_cached_download_must_still_match_its_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'image.xz'
            path.write_bytes(b'changed archive')
            with self.assertRaisesRegex(ValueError, 'cached checksum'):
                vm.download('https://example.invalid/never-fetched', path, '0' * 64)

    def test_guest_failure_cannot_supply_a_feature_verdict(self):
        guest = vm.Guest(1)
        with patch.object(guest, 'run', return_value=type('Result', (), {
                'returncode': 2, 'stdout': b'no LSE', 'stderr': b''})()):
            with self.assertRaisesRegex(ValueError, 'guest command failed'):
                guest.checked('processor')


if __name__ == '__main__':
    unittest.main()
