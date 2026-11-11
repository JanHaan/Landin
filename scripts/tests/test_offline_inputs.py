#!/usr/bin/env python3
"""The generators' test scripts pass --offline to the input fetcher.

`devices/test.py --refine` and `bindings/test.py` read pinned vendor
inputs through `scripts/fetch_inputs.py`.  With `--offline` neither may
fetch: against an empty cache each refuses, naming the input, and reaches
no network.  The cache here is an empty directory, and the fetcher's
download is replaced by one that fails the test if it is ever asked.
"""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import fetch_inputs  # noqa: E402

REFUSAL = '--offline forbids fetching it'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(script, *arguments, cache):
    environment = dict(os.environ, LANDIN_INPUTS=str(cache),
                       LANDIN_REFINE='',
                       #  Any attempt to fetch is refused at once rather
                       #  than reaching a network.
                       http_proxy='http://127.0.0.1:9',
                       https_proxy='http://127.0.0.1:9')
    return subprocess.run(
        [sys.executable, str(ROOT / script), *arguments],
        env=environment, capture_output=True, text=True, timeout=120)


class OfflineInputs(unittest.TestCase):
    def test_devices_refuses_an_input_the_cache_lacks(self):
        with tempfile.TemporaryDirectory() as cache:
            result = run(
                'devices/test.py', '--refine', sys.executable, '--offline',
                'Regeneration.'
                'test_a_changed_output_is_put_back_and_a_stale_one_removed',
                cache=cache)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('rp2040/RP2040.svd: not in the cache at',
                          result.stderr)
            self.assertIn(REFUSAL, result.stderr)
            self.assertEqual(os.listdir(cache), [])

    def test_devices_fetch_follows_the_switch(self):
        devices = load('landin_devices_test', ROOT / 'devices/test.py')
        asked = []

        def fetch(name, offline=False):
            asked.append((name, offline))
            return Path(name)

        held = fetch_inputs.fetch
        fetch_inputs.fetch = fetch
        try:
            devices.fetch_input('rp2040/RP2040.svd')
            devices.OFFLINE = True
            devices.fetch_input('rp2040/RP2040.svd')
        finally:
            fetch_inputs.fetch = held
        self.assertEqual(asked, [('rp2040/RP2040.svd', False),
                                 ('rp2040/RP2040.svd', True)])

    def test_no_devices_case_fetches_past_the_switch(self):
        text = (ROOT / 'devices/test.py').read_text()
        self.assertEqual(text.count('fetch_inputs.fetch('), 1,
                         'every case fetches through fetch_input')

    def test_bindings_takes_offline_without_write(self):
        with tempfile.TemporaryDirectory() as cache:
            result = run('bindings/test.py', '--refine', sys.executable,
                         '--offline', '-k', 'no_case_has_this_name',
                         cache=cache)
            self.assertNotIn('goes with --write', result.stderr)
            self.assertIn('Ran 0 tests', result.stderr)

    def test_bindings_regeneration_refuses_an_input_the_cache_lacks(self):
        bindings = load('landin_bindings_test', ROOT / 'bindings/test.py')
        held = os.environ.get('LANDIN_INPUTS')
        with tempfile.TemporaryDirectory() as cache, \
                tempfile.TemporaryDirectory() as work:
            os.environ['LANDIN_INPUTS'] = cache
            bindings.REFINE = sys.executable
            bindings.OFFLINE = True
            try:
                with self.assertRaisesRegex(fetch_inputs.InputError,
                                            REFUSAL):
                    bindings.regenerate(
                        'cortex-cmsis-bindings', Path(work) / 'made',
                        Path(sys.executable), Path(work))
            finally:
                if held is None:
                    del os.environ['LANDIN_INPUTS']
                else:
                    os.environ['LANDIN_INPUTS'] = held
            self.assertEqual(os.listdir(cache), [])

    def test_no_bindings_case_fetches_past_the_switch(self):
        text = (ROOT / 'bindings/test.py').read_text()
        calls = re.findall(r'fetch_inputs\.fetch\(([^)]*)\)', text)
        self.assertEqual(len(calls), 3)
        for call in calls:
            self.assertRegex(call, r'offline=(offline|OFFLINE)$')


if __name__ == '__main__':
    unittest.main()
