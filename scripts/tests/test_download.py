#!/usr/bin/env python3
"""A failed download says what failed, and only a server's "wait" is retried.

No network beyond this host: environments/pins.sh's landin_fetch runs its
own curl against a server on 127.0.0.1 that answers a scripted run of
statuses, and the two Python fetchers are given openers that raise them.
"""
import hashlib
import http.server
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'environments/cortex-m'))
import download  # noqa: E402
import fetch_inputs  # noqa: E402
import setup  # noqa: E402

GOOD = b'<device/>\n'


class Scripted:
    """An opener answering STATUSES in turn, then BODY for good."""

    def __init__(self, statuses, body=GOOD):
        self.statuses, self.body, self.calls = list(statuses), body, 0

    def __call__(self, url, timeout):
        self.calls += 1
        if self.statuses:
            status = self.statuses.pop(0)
            if status == 'reset':
                raise ConnectionResetError('connection reset by peer')
            raise urllib.error.HTTPError(url, status, 'Gateway Time-out' if status == 504 else 'Refused',
                                         {}, None)
        return io.BytesIO(self.body)


class Download(unittest.TestCase):
    def fetch(self, opener, **options):
        waits = []
        try:
            return download.download('https://example.invalid/a.tar', 'a.tar', lambda r: r.read(),
                                     opener=opener, sleep=waits.append, **options), waits
        except download.DownloadError as error:
            return error, waits

    def test_a_transient_status_is_asked_again_with_growing_waits(self):
        opener = Scripted([504, 'reset', 503])
        said = []
        result, waits = self.fetch(opener, report=said.append)
        self.assertEqual((result, opener.calls, waits), (GOOD, 4, [2.0, 4.0, 8.0]))
        self.assertIn('a.tar: HTTP 504 Gateway Time-out from https://example.invalid/a.tar;'
                      ' attempt 2 of 4 in 2 s', said)

    def test_the_retries_are_bounded_and_the_failure_names_everything(self):
        opener = Scripted([504] * 9)
        error, waits = self.fetch(opener)
        self.assertEqual((opener.calls, len(waits)), (download.ATTEMPTS, download.ATTEMPTS - 1))
        said = str(error)
        self.assertTrue(said.startswith('a.tar: cannot fetch https://example.invalid/a.tar:'
                                        ' HTTP 504 Gateway Time-out after 4 attempts'), said)
        self.assertIn('not the pin', said)

    def test_a_status_that_is_an_answer_ends_at_once(self):
        for status in (403, 404, 410):
            opener = Scripted([status, 504])
            error, waits = self.fetch(opener)
            with self.subTest(status=status):
                self.assertEqual((opener.calls, waits), (1, []))
                self.assertEqual(str(error), 'a.tar: cannot fetch https://example.invalid/a.tar:'
                                             ' HTTP %d Refused' % status)

    def test_a_connection_lost_while_reading_starts_the_read_afresh(self):
        class Dropping(io.BytesIO):
            def read(self, *args):
                raise ConnectionResetError('reset mid-body')
        answers = [Dropping(GOOD), io.BytesIO(GOOD)]
        result, waits = self.fetch(lambda url, timeout: answers.pop(0))
        self.assertEqual((result, waits), (GOOD, [2.0]))


class Fetchers(unittest.TestCase):
    """Both Python fetchers retry through the one rule and keep the hash final."""

    PIN = {'url': 'https://example.invalid/device.svd', 'sha256': hashlib.sha256(GOOD).hexdigest()}

    def test_fetch_inputs_retries_then_caches(self):
        with tempfile.TemporaryDirectory() as cache, \
                unittest.mock.patch.object(sys, 'stderr', io.StringIO()):
            opener, waits = Scripted([504, 502]), []
            path = fetch_inputs.fetch('d/device.svd', {'d/device.svd': self.PIN}, cache,
                                      opener=opener, sleep=waits.append)
            self.assertEqual((path.read_bytes(), opener.calls, len(waits)), (GOOD, 3, 2))

    def test_fetch_inputs_names_the_input_the_url_and_the_status(self):
        with tempfile.TemporaryDirectory() as cache, \
                unittest.mock.patch.object(sys, 'stderr', io.StringIO()):
            with self.assertRaisesRegex(
                    fetch_inputs.InputError,
                    r'^d/device\.svd: cannot fetch https://example\.invalid/device\.svd:'
                    r' HTTP 504 Gateway Time-out after 4 attempts'):
                fetch_inputs.fetch('d/device.svd', {'d/device.svd': self.PIN}, cache,
                                   opener=Scripted([504] * 9), sleep=lambda wait: None)

    def test_fetch_inputs_never_retries_other_bytes(self):
        with tempfile.TemporaryDirectory() as cache:
            opener, waits = Scripted([], b'<other/>'), []
            with self.assertRaisesRegex(fetch_inputs.InputError, 'not the pinned'):
                fetch_inputs.fetch('d/device.svd', {'d/device.svd': self.PIN}, cache,
                                   opener=opener, sleep=waits.append)
            self.assertEqual((opener.calls, waits), (1, []))

    def item(self, body=GOOD):
        return {'file': 'control.tar.xz', 'url': 'https://example.invalid/control.tar.xz',
                'sha256': hashlib.sha256(body).hexdigest()}

    def setup_fetch(self, opener, item):
        waits = []
        with tempfile.TemporaryDirectory() as directory, \
                unittest.mock.patch.object(setup.urllib.request, 'urlopen', opener), \
                unittest.mock.patch.object(sys, 'stderr', io.StringIO()):
            try:
                return setup.fetch(Path(directory), item, sleep=waits.append).read_bytes(), waits
            except (SystemExit, RuntimeError) as error:
                return error, waits

    def test_setup_retries_a_gateway_timeout(self):
        opener = Scripted([504])
        self.assertEqual(self.setup_fetch(opener, self.item()), (GOOD, [2.0]))

    def test_setup_fails_with_the_archive_url_and_status_not_a_traceback(self):
        error, waits = self.setup_fetch(Scripted([504] * 9), self.item())
        self.assertIsInstance(error, SystemExit)
        self.assertTrue(str(error).startswith(
            'setup.py: control.tar.xz: cannot fetch https://example.invalid/control.tar.xz:'
            ' HTTP 504 Gateway Time-out after 4 attempts'), str(error))
        self.assertEqual(len(waits), 3)

    def test_setup_never_retries_a_hash_mismatch(self):
        opener = Scripted([], GOOD + b'changed')
        error, waits = self.setup_fetch(opener, self.item())
        self.assertIsInstance(error, RuntimeError)
        self.assertRegex(str(error), r'archive hash mismatch: control\.tar\.xz from https://\S+ has SHA-256'
                                     r' [0-9a-f]{64}, not the pinned [0-9a-f]{64}')
        self.assertEqual((opener.calls, waits), (1, []))


class Server:
    """127.0.0.1 answering STATUSES in turn, then the archive."""

    def __init__(self, statuses, body):
        outer = self
        self.statuses, self.body, self.requests = list(statuses), body, 0

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.requests += 1
                status = outer.statuses.pop(0) if outer.statuses else 200
                self.send_response(status)
                payload = outer.body if status == 200 else b'no'
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = 'http://127.0.0.1:%d' % self.server.server_address[1]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@unittest.skipUnless(shutil.which('curl') and shutil.which('sha256sum'),
                     'landin_fetch needs curl and sha256sum')
class LandinFetch(unittest.TestCase):
    """environments/pins.sh's own curl, against a server on this host."""

    def setUp(self):
        packed = io.BytesIO()
        with tarfile.open(fileobj=packed, mode='w:gz') as archive:
            member = tarfile.TarInfo('top/hello')
            member.size = 3
            archive.addfile(member, io.BytesIO(b'hi\n'))
        self.body = packed.getvalue()
        self.sha = hashlib.sha256(self.body).hexdigest()

    def fetch(self, statuses, sha=None, retries='3'):
        server = Server(statuses, self.body)
        self.addCleanup(server.close)
        into = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, into)
        done = subprocess.run(
            ['sh', '-c', '. "$0"; landin_fetch "$1" a.tar.gz "$2" "$3" unpacked',
             str(ROOT / 'environments/pins.sh'), into, server.url, sha or self.sha],
            capture_output=True, text=True, timeout=120,
            env={'PATH': os.environ['PATH'], 'LANDIN_FETCH_RETRIES': retries,
                 'LANDIN_FETCH_RETRY_DELAY': '1'})
        return done, server, Path(into)

    def test_a_gateway_timeout_is_asked_again(self):
        done, server, into = self.fetch([504])
        self.assertEqual((done.returncode, server.requests), (0, 2), done.stderr)
        self.assertEqual((into / 'unpacked/hello').read_text(), 'hi\n')

    def test_the_retries_are_bounded_and_the_failure_names_everything(self):
        done, server, into = self.fetch([504] * 9, retries='1')
        self.assertEqual((done.returncode, server.requests), (1, 2))
        self.assertIn('landin_fetch: a.tar.gz: cannot fetch %s/a.tar.gz: HTTP status 504'
                      ' after up to 2 attempts' % server.url, done.stderr)
        self.assertFalse((into / 'a.tar.gz').exists())

    def test_a_missing_archive_ends_at_once(self):
        done, server, _ = self.fetch([404, 404])
        self.assertEqual((done.returncode, server.requests), (1, 1))
        self.assertIn('HTTP status 404', done.stderr)

    def test_a_hash_mismatch_is_fatal_at_once(self):
        done, server, into = self.fetch([], sha='0' * 64)
        self.assertEqual((done.returncode, server.requests), (1, 1))
        self.assertIn('landin_fetch: a.tar.gz: %s/a.tar.gz is not the pinned archive' % server.url,
                      done.stderr)
        self.assertFalse((into / 'unpacked').exists())


if __name__ == '__main__':
    unittest.main()
