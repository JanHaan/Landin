#!/usr/bin/env python3
"""Build/copy/run boundary controls; every SSH/SCP operation is simulated."""
import json
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
            board='rp2040', mode='ram', refine=self.root / 'refine', output=self.root / 'out')

    def test_reject_options_and_bundle_override_before_any_process(self):
        for host, arguments in (('-oProxyCommand=bad', ()), ('rigpi', ('--bundle=/other',)),
                                ('rigpi', ('--output', '/other')), ('rigpi', ('--mode=boot',))):
            self.args.host = host
            with mock.patch.object(subprocess, 'run') as process:
                with self.assertRaises(board_run.bundle.Invalid):
                    board_run.execute(self.args, arguments)
                process.assert_not_called()
            self.assertFalse(self.args.output.exists())

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
