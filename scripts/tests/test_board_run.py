#!/usr/bin/env python3
"""Build/copy/run boundary controls; every SSH/SCP operation is simulated."""
import json
import contextlib
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import run as board_run


class Transfer(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.args = SimpleNamespace(host='jan@10.42.0.60', identity=Path('/key with spaces'),
            board='rp2040', mode='ram', refine=self.root / 'refine', output=self.root / 'out', record=None)

    def test_reject_options_and_bundle_override_before_any_process(self):
        for host, arguments in (('-oProxyCommand=bad', ()), ('rigpi', ('--bundle=/other',)),
                                ('rigpi', ('--output', '/other')), ('rigpi', ('--mode=boot',)),
                                ('rigpi', ('--record=other.json',)), ('rigpi', ('--record', 'other.json')),
                                ('rigpi', ('--recor=other.json',)), ('rigpi', ('--rec', 'other.json'))):
            self.args.host = host
            with mock.patch.object(subprocess, 'run') as process:
                with self.assertRaises(board_run.bundle.Invalid):
                    board_run.execute(self.args, arguments)
                process.assert_not_called()
            self.assertFalse(self.args.output.exists())

    def test_record_cli_is_owned_by_wrapper(self):
        with mock.patch.object(board_run, 'execute', return_value=0) as execute:
            self.assertEqual(board_run.main(['--board=rp2040', '--refine=refine',
                '--output=run', '--record=ram-record.json', '--', '--probehive', '/probe']), 0)
        args, forwarded = execute.call_args.args
        self.assertEqual(args.record, Path('ram-record.json'))
        self.assertEqual(forwarded, ['--probehive', '/probe'])

    def test_existing_records_symlinks_and_ram_boot_name_are_refused_before_work(self):
        existing = self.root / 'existing.json'
        existing.write_bytes(b'previous evidence')
        link = self.root / 'broken.json'
        link.symlink_to(self.root / 'absent')
        for destination in (existing, link, self.root / 'record.json'):
            self.args.record = destination
            with self.subTest(destination=destination), \
                    mock.patch.object(board_run.build, 'prepare') as build, \
                    mock.patch.object(subprocess, 'run') as process:
                with self.assertRaises(board_run.bundle.Invalid):
                    board_run.execute(self.args)
                build.assert_not_called()
                process.assert_not_called()
            self.assertFalse(self.args.output.exists())
        self.assertEqual(existing.read_bytes(), b'previous evidence')

    def record_run(self, *, tool_status=0, record_status=0, payload=None, race=False):
        """An actual remote record is simulated as opaque transferred bytes."""
        calls = []
        identity = {'sha256': 'source-bytes', 'files': {}}
        def prepare(board, mode, refine, output, source):
            output.mkdir()
        def snapshot(destination, root):
            destination.mkdir()
            return identity
        def transport(command, log):
            command = [str(value) for value in command]
            calls.append(command)
            Path(log).write_text('simulated transport\n')
            if command[0] == 'ssh':
                return tool_status
            if command[-1].endswith('/rigpi'):
                Path(command[-1]).mkdir()
                (Path(command[-1]) / 'result.json').write_text('{"status":"passed"}')
            elif Path(log).name == 'record-retrieve.log':
                if payload is not None:
                    Path(command[-1]).write_bytes(payload)
                if race:
                    self.args.record.write_bytes(b'newer evidence')
                return record_status
            return 0
        with mock.patch.object(board_run.bundle, 'source_identity', return_value=identity), \
                mock.patch.object(board_run.bundle, 'snapshot', side_effect=snapshot), \
                mock.patch.object(board_run.build, 'prepare', side_effect=prepare), \
                mock.patch.object(board_run, 'transport', side_effect=transport), \
                mock.patch.object(subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout='/tmp/landin-board.ABC123\n', stderr='')):
            status = board_run.execute(self.args)
        transfer = json.loads((self.args.output / 'transfer.json').read_text())
        return status, transfer, calls

    def test_passed_tool_record_is_copied_byte_for_byte_for_each_mode(self):
        for mode, remote_name in (('ram', 'ram-record.json'), ('boot', 'record.json')):
            with self.subTest(mode=mode):
                self.args.mode = mode
                self.args.output = self.root / ('out-' + mode)
                self.args.record = self.root / ('evidence-' + mode + '.json')
                data = b'{ "status": "passed", "mode": "' + mode.encode() + b'", "image_sha256": "tool hash" }\n'
                status, transfer, calls = self.record_run(payload=data)
                self.assertEqual(status, 0)
                self.assertEqual(self.args.record.read_bytes(), data)
                self.assertEqual(transfer['record_status'], 'written')
                self.assertIn('--record=/tmp/landin-board.ABC123/' + remote_name, calls[1][-1])
                self.assertNotIn(str(self.args.record), calls[1][-1])

    def test_failed_tool_never_fetches_or_writes_a_record(self):
        self.args.record = self.root / 'ram-record.json'
        status, transfer, calls = self.record_run(tool_status=7)
        self.assertEqual(status, 7)
        self.assertEqual(transfer['record_status'], 'skipped')
        self.assertEqual([command[0] for command in calls], ['scp', 'ssh', 'scp'])
        self.assertFalse(self.args.record.exists())

    def test_missing_bad_or_failed_record_copy_never_creates_local_evidence(self):
        for label, code, payload in (('copy', 8, None), ('missing', 0, None),
                ('json', 0, b'bad JSON'), ('failed', 0, b'{"status":"failed","mode":"ram"}'),
                ('mode', 0, b'{"status":"passed","mode":"boot"}')):
            with self.subTest(label=label):
                self.args.output = self.root / label
                self.args.record = self.root / (label + '.json')
                status, transfer, _ = self.record_run(record_status=code, payload=payload)
                self.assertEqual(status, 1)
                self.assertEqual(transfer['exit_status'], 0)
                self.assertEqual(transfer['record_status'], 'failed')
                self.assertFalse(self.args.record.exists())
                self.assertTrue((self.args.output / 'rigpi/result.json').is_file())

    def test_record_created_during_run_is_not_replaced(self):
        self.args.record = self.root / 'ram-record.json'
        status, transfer, _ = self.record_run(payload=b'{"status":"passed","mode":"ram"}', race=True)
        self.assertEqual(status, 1)
        self.assertEqual(transfer['record_status'], 'failed')
        self.assertEqual(self.args.record.read_bytes(), b'newer evidence')

    def test_failed_local_write_never_publishes_a_partial_record(self):
        self.args.record = self.root / 'ram-record.json'
        class FullDisk:
            def write(self, _):
                raise OSError('disk full')
        with mock.patch.object(board_run.tempfile, 'NamedTemporaryFile',
                               return_value=contextlib.nullcontext(FullDisk())):
            status, transfer, _ = self.record_run(payload=b'{"status":"passed","mode":"ram"}')
        self.assertEqual(status, 1)
        self.assertIn('disk full', transfer['record_error'])
        self.assertFalse(self.args.record.exists())

    def test_failed_remote_run_is_retrieved_and_keeps_exit_status(self):
        calls = []
        identity = {'sha256': 'source-bytes', 'files': {}}
        def prepare(board, mode, refine, output, source):
            output.mkdir()
            (output / 'bundle.json').write_text('{}')
        def snapshot(destination, root):
            destination.mkdir()
            return identity
        def transport(command, log):
            calls.append([str(value) for value in command])
            Path(log).write_text('simulated transport\n')
            if command[0] == 'ssh':
                return 7
            if str(command[-1]).endswith('/rigpi'):
                Path(command[-1]).mkdir()
                (Path(command[-1]) / 'result.json').write_text('{"status":"failed"}')
            return 0
        with mock.patch.object(board_run.bundle, 'source_identity', return_value=identity), \
                mock.patch.object(board_run.bundle, 'snapshot', side_effect=snapshot), \
                mock.patch.object(board_run.build, 'prepare', side_effect=prepare), \
                mock.patch.object(board_run, 'transport', side_effect=transport), \
                mock.patch.object(subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout='/tmp/landin-board.ABC123\n', stderr='')) as process:
            status = board_run.execute(self.args, ('--probehive', '/path with spaces'))
        self.assertEqual(status, 7)
        self.assertEqual(process.call_count, 1)  # remote mktemp only
        self.assertEqual([command[0] for command in calls], ['scp', 'ssh', 'scp'])
        self.assertIn("'/path with spaces'", calls[1][-1])
        self.assertIn('--mode=ram', calls[1][-1])
        self.assertTrue((self.args.output / 'rigpi/result.json').is_file())
        transfer = json.loads((self.args.output / 'transfer.json').read_text())
        self.assertEqual(transfer['source_identity'], 'source-bytes')
        self.assertEqual(transfer['exit_status'], 7)

    def test_unexpected_remote_path_is_never_used_by_scp(self):
        with mock.patch.object(board_run.bundle, 'source_identity', return_value={}), \
                mock.patch.object(board_run.bundle, 'snapshot', return_value={}), \
                mock.patch.object(board_run.build, 'prepare'), \
                mock.patch.object(board_run, 'transport') as copy, \
                mock.patch.object(subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout='/tmp/evil; touch /tmp/injected\n', stderr='')):
            with self.assertRaisesRegex(board_run.bundle.Invalid, 'remote staging failed'):
                board_run.execute(self.args)
            copy.assert_not_called()


if __name__ == '__main__':
    unittest.main()
