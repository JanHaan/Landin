#!/usr/bin/env python3
"""Controls for environments/boards/rig.py and rig.json, without the Arty:
the loaded-bitstream record is held to a fake USB sysfs, boot id and
loader, and the repository's rig description to its reviewed shape."""
import contextlib
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import rig as RIG  # noqa: E402

COMMON = RIG.common
ARTY = '210319B3E738'


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Fixture:
    """A temporary rig: a sysfs with the Arty at 1-1.1, a boot id, a state
    directory, a pinned bitstream and a rig description pinning it."""
    def __init__(self, tmp):
        self.root = Path(tmp)
        self.sysfs = self.root / 'sys'
        self.arty(devnum=3)
        self.boot = self.root / 'boot_id'
        self.boot.write_text('6b1d3c58-0000-4000-8000-000000000001\n')
        self.state = self.root / 'state'
        self.state.mkdir()
        self.bitstream = self.root / 'arty_slots.bit'
        self.bitstream.write_bytes(b'pinned bitstream')
        self.rig = json.loads((ROOT / 'environments/boards/rig.json').read_text())
        self.rig['probehive']['bitstream']['sha256'] = sha(b'pinned bitstream')
        self.lock = COMMON.RigLock('rig.py control', self.root / 'rig.lock', report=lambda _: None)

    def arty(self, devnum, location='1-1.1', busnum=1):
        device = self.sysfs / location
        device.mkdir(parents=True, exist_ok=True)
        for name, value in (('serial', ARTY), ('busnum', busnum), ('devnum', devnum),
                            ('idVendor', '0403'), ('idProduct', '6010')):
            (device / name).write_text('%s\n' % value)

    def options(self):
        return dict(sysfs=self.sysfs, boot_id_path=self.boot)


class Description(unittest.TestCase):
    def test_the_repository_rig_description_is_complete_and_pins_the_reviewed_probehive(self):
        rig = RIG.load_rig()
        self.assertEqual(rig['probehive']['commit'], '4f69b8269a664cf1e1c47b2b40365b482e9f30ec')
        self.assertEqual(rig['probehive']['files']['flake.nix'],
                         '9b65d550aafe25a70a16a741f2c5582a410e063a492e3a6a3fa5880240a63d46')
        self.assertEqual(rig['probehive']['bitstream']['sha256'],
                         '7a4600368d76f39c1d048c0afae42abe515c13875416303021b40b73bf83bc69')
        self.assertEqual(sorted(rig['ports']), ['esp32', 'esp32c3', 'esp32c5', 'esp32s3', 'pico2',
                                                'rp2040', 'stm32h753'])
        boards = {step['board'] for port in rig['ports'].values() for step in port['steps']}
        self.assertEqual(boards, {'rp2040', 'rp2350', 'rp2350_hazard3', 'stm32h753', 'esp32c3',
                                  'esp32c5', 'esp32', 'esp32s3'})
        for name, port in rig['ports'].items():
            for step in port['steps']:
                self.assertTrue((ROOT / 'environments/boards' / step['board'] / 'board.py').is_file())
            modes = [step['mode'] for step in port['steps']]
            self.assertEqual(modes, ['boot', 'ram'] * (len(modes) // 2), name)
        self.assertEqual([(s['board'], s['mode']) for s in rig['ports']['pico2']['steps']],
                         [('rp2350', 'boot'), ('rp2350', 'ram'),
                          ('rp2350_hazard3', 'boot'), ('rp2350_hazard3', 'ram')])
        self.assertEqual(rig['ports']['pico2']['location'], dict(hub=None, port=None))

    def test_a_description_without_its_pins_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            rig = json.loads((ROOT / 'environments/boards/rig.json').read_text())
            del rig['probehive']['files']['scripts/gpio.py']
            path = Path(tmp) / 'rig.json'
            path.write_text(json.dumps(rig))
            with self.assertRaisesRegex(COMMON.Failed, 'exactly'):
                RIG.load_rig(path)
            path.write_text('{"format_version": 2}')
            with self.assertRaisesRegex(COMMON.Failed, 'format_version 1'):
                RIG.load_rig(path)


class ProbehiveFiles(unittest.TestCase):
    def test_runtime_files_are_absent_matching_or_mismatched(self):
        with tempfile.TemporaryDirectory() as tmp:
            hive = Path(tmp)
            rig = dict(probehive=dict(commit='c' * 40, files={}))
            for name in RIG.PROBEHIVE_FILES:
                (hive / name).parent.mkdir(parents=True, exist_ok=True)
                (hive / name).write_text(name)
                rig['probehive']['files'][name] = sha(name.encode())
            checked = RIG.probehive_files(rig, hive)
            self.assertEqual(sorted(checked), sorted(RIG.PROBEHIVE_FILES))
            (hive / 'scripts/gpio.py').write_text('changed')
            with self.assertRaisesRegex(COMMON.ToolMismatch, 'scripts/gpio.py'):
                RIG.probehive_files(rig, hive)
            (hive / 'flake.lock').unlink()
            with self.assertRaisesRegex(COMMON.NeedsSetup, 'flake.lock'):
                RIG.probehive_files(rig, hive)


class LoadedBitstream(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.rig = Fixture(self.temporary.name)

    def load(self, returncode=0, bitstream=None):
        calls = []

        def run(argv):
            calls.append(argv)
            return SimpleNamespace(returncode=returncode)
        kept = RIG.load_probehive(bitstream or self.rig.bitstream, self.rig.rig, self.rig.state,
                                  run=run, lock=self.rig.lock, **self.rig.options())
        return kept, calls

    def test_loading_the_pinned_bitstream_records_its_boot_and_the_arty_s_enumeration(self):
        kept, calls = self.load()
        self.assertEqual(calls, [['openFPGALoader', '-b', 'arty', str(self.rig.bitstream)]])
        path = self.rig.state / RIG.LOADED
        self.assertEqual(json.loads(path.read_text()), kept)
        self.assertEqual(path.stat().st_mode & 0o7777, 0o660)
        self.assertEqual(kept['sha256'], sha(b'pinned bitstream'))
        self.assertEqual(kept['boot_id'], '6b1d3c58-0000-4000-8000-000000000001')
        self.assertEqual((kept['arty']['location'], kept['arty']['busnum'], kept['arty']['devnum']),
                         ('1-1.1', 1, 3))
        self.assertEqual(RIG.verify(self.rig.rig, self.rig.state, **self.rig.options()), kept)

    def test_another_bitstream_or_a_failed_load_is_never_recorded(self):
        other = Path(self.temporary.name) / 'other.bit'
        other.write_bytes(b'another build')
        with self.assertRaises(COMMON.ToolMismatch):
            self.load(bitstream=other)
        with self.assertRaisesRegex(COMMON.Failed, 'nothing was recorded'):
            self.load(returncode=1)
        self.assertFalse((self.rig.state / RIG.LOADED).exists())

    def test_loading_holds_the_rig_lock(self):
        lock = mock.MagicMock()
        RIG.load_probehive(self.rig.bitstream, self.rig.rig, self.rig.state,
                           run=lambda argv: SimpleNamespace(returncode=0), lock=lock, **self.rig.options())
        lock.__enter__.assert_called_once()
        lock.__exit__.assert_called_once()

    def test_an_operator_s_record_needs_a_reason_and_loads_nothing(self):
        with self.assertRaisesRegex(COMMON.Failed, 'reason'):
            RIG.record_load(self.rig.bitstream, '  ', self.rig.rig, self.rig.state, lock=self.rig.lock,
                            **self.rig.options())
        with mock.patch.object(RIG.subprocess, 'run') as run:
            kept = RIG.record_load(self.rig.bitstream, 'loaded on 2026-11-04 by\n hand', self.rig.rig,
                                   self.rig.state, lock=self.rig.lock, **self.rig.options())
        run.assert_not_called()
        self.assertEqual((kept['method'], kept['reason']),
                         ('recorded by the operator', 'loaded on 2026-11-04 by hand'))

    def test_verification_refuses_each_reason_the_bitstream_may_be_another(self):
        with self.assertRaisesRegex(COMMON.NeedsOperator, 'no record.*load-probehive'):
            RIG.verify(self.rig.rig, self.rig.state, **self.rig.options())
        self.load()
        pinned = dict(self.rig.rig, probehive=dict(self.rig.rig['probehive'],
                      bitstream=dict(path='x', sha256='0' * 64)))
        with self.assertRaises(COMMON.ToolMismatch):
            RIG.verify(pinned, self.rig.state, **self.rig.options())
        self.rig.arty(devnum=4)
        with self.assertRaisesRegex(COMMON.NeedsOperator, 'enumerated again.*devnum, then 3, now 4'):
            RIG.verify(self.rig.rig, self.rig.state, **self.rig.options())
        self.rig.arty(devnum=3)
        RIG.verify(self.rig.rig, self.rig.state, **self.rig.options())
        self.rig.boot.write_text('6b1d3c58-0000-4000-8000-000000000002\n')
        with self.assertRaisesRegex(COMMON.NeedsOperator, 'boot'):
            RIG.verify(self.rig.rig, self.rig.state, **self.rig.options())
        (self.rig.state / RIG.LOADED).write_text('not json')
        with self.assertRaises(COMMON.NeedsOperator):
            RIG.verify(self.rig.rig, self.rig.state, **self.rig.options())

    def test_an_absent_arty_is_unavailable(self):
        self.load()
        for name in ('serial', 'busnum', 'devnum', 'idVendor', 'idProduct'):
            (self.rig.sysfs / '1-1.1' / name).unlink()
        (self.rig.sysfs / '1-1.1').rmdir()
        with self.assertRaises(COMMON.Unavailable):
            RIG.verify(self.rig.rig, self.rig.state, **self.rig.options())

    def test_the_command_line_says_the_outcome(self):
        stderr = io.StringIO()
        with mock.patch.object(COMMON, 'RIG_STATE', self.rig.state), \
                contextlib.redirect_stderr(stderr):
            self.assertEqual(RIG.main(['verify']), 1)
        self.assertIn('rig.py needs-operator: no record', stderr.getvalue())


if __name__ == '__main__':
    unittest.main()
