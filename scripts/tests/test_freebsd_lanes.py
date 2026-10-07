#!/usr/bin/env python3
"""Controls for FreeBSD corpus selection and checked release inputs."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('freebsd_lane', ROOT / 'compiler/tests/freebsd/check.py')
LANE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LANE)
import vm


class FreeBSDControls(unittest.TestCase):
    def test_each_architecture_has_runtime_operands_and_required_c_peers(self):
        for arch in ('amd64', 'arm64'):
            self.assertIn('assembly-operands', {p.name for p, _ in LANE.select(arch, 'runtime')})
            selected = {p.name for p, _ in LANE.select(arch, 'abi')}
            self.assertTrue(LANE.ABI_REQUIRED <= selected)
            self.assertGreater(len(selected), len(LANE.ABI_REQUIRED))

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
            (fixture / 'fixture.meta').write_text('targets: freebsd-x86-64, freebsd-arm64\n')
            with self.assertRaisesRegex(ValueError, 'ABI coverage missing'):
                LANE.select('amd64', 'abi')
            with self.assertRaisesRegex(ValueError, 'ABI coverage missing'):
                LANE.select('arm64', 'abi')

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
