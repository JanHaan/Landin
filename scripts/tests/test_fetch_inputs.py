"""The vendor-input fetcher verifies every byte it caches (D559).

No network: a fake opener serves the bytes, so a wrong download, a stale
cache and the offline refusal are each asked for by name.
"""
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import fetch_inputs  # noqa: E402

GOOD = b'<device/>\n'
PIN = {'url': 'https://example.invalid/device.svd',
       'sha256': hashlib.sha256(GOOD).hexdigest()}


class Opener:
    def __init__(self, data):
        self.data = data
        self.calls = 0

    def __call__(self, url, timeout):
        self.calls += 1
        return io.BytesIO(self.data)


class FetchInputs(unittest.TestCase):
    def test_the_lock_is_well_formed(self):
        inputs = fetch_inputs.read_lock()
        self.assertIn('rp2040/RP2040.svd', inputs)
        self.assertIn('stm32h753/STM32H753.svd', inputs)

    def test_a_download_is_verified_and_cached(self):
        with tempfile.TemporaryDirectory() as cache:
            opener = Opener(GOOD)
            path = fetch_inputs.fetch('d/device.svd', {'d/device.svd': PIN},
                                      cache, opener=opener)
            self.assertEqual(path.read_bytes(), GOOD)
            fetch_inputs.fetch('d/device.svd', {'d/device.svd': PIN}, cache,
                               opener=opener)
            self.assertEqual(opener.calls, 1, 'a verified cache is reused')

    def test_other_bytes_are_refused_and_not_cached(self):
        with tempfile.TemporaryDirectory() as cache:
            with self.assertRaisesRegex(fetch_inputs.InputError,
                                        'not the pinned'):
                fetch_inputs.fetch('d/device.svd', {'d/device.svd': PIN},
                                   cache, opener=Opener(b'<other/>'))
            self.assertFalse((Path(cache) / 'd/device.svd').exists())

    def test_a_changed_cache_is_fetched_again(self):
        with tempfile.TemporaryDirectory() as cache:
            stale = Path(cache) / 'd/device.svd'
            stale.parent.mkdir()
            stale.write_bytes(b'edited')
            opener = Opener(GOOD)
            fetch_inputs.fetch('d/device.svd', {'d/device.svd': PIN}, cache,
                               opener=opener)
            self.assertEqual((opener.calls, stale.read_bytes()), (1, GOOD))

    def test_offline_refuses_a_missing_input(self):
        with tempfile.TemporaryDirectory() as cache:
            with self.assertRaisesRegex(fetch_inputs.InputError, '--offline'):
                fetch_inputs.fetch('d/device.svd', {'d/device.svd': PIN},
                                   cache, offline=True)

    def test_an_unpinned_name_is_refused(self):
        with self.assertRaisesRegex(fetch_inputs.InputError, 'pins no such'):
            fetch_inputs.fetch('d/other.svd', {'d/device.svd': PIN})

    def test_a_malformed_lock_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / 'inputs.json'
            for text in ('{"schema": 2, "inputs": {}}',
                         '{"schema": 1, "inputs": {"../x": %s}}'
                         % '{"url": "https://a", "sha256": "%s"}' % ('0' * 64),
                         '{"schema": 1, "inputs": {"x": {"url": "http://a",'
                         ' "sha256": "%s"}}}' % ('0' * 64)):
                lock.write_text(text)
                with self.assertRaises(fetch_inputs.InputError):
                    fetch_inputs.read_lock(lock)

    def test_a_hand_supplied_input_is_verified_and_never_fetched(self):
        pin = dict(PIN, fetch='by hand')
        with tempfile.TemporaryDirectory() as cache:
            opener = Opener(GOOD)
            with self.assertRaisesRegex(fetch_inputs.InputError,
                                        'supplied by hand.*put it at'):
                fetch_inputs.fetch('m/manual.pdf', {'m/manual.pdf': pin}, cache,
                                   opener=opener)
            self.assertEqual(opener.calls, 0, 'a hand-supplied input is downloaded')
            copy = Path(cache) / 'm/manual.pdf'
            copy.parent.mkdir()
            copy.write_bytes(b'another revision')
            with self.assertRaisesRegex(fetch_inputs.InputError,
                                        'The copy there has SHA-256'):
                fetch_inputs.fetch('m/manual.pdf', {'m/manual.pdf': pin}, cache,
                                   opener=opener)
            copy.write_bytes(GOOD)
            self.assertEqual(fetch_inputs.fetch('m/manual.pdf',
                                                {'m/manual.pdf': pin}, cache,
                                                opener=opener), copy)
            self.assertEqual(opener.calls, 0)

    def test_the_by_hand_refusal_gives_both_reasons(self):
        #  A publisher that will not serve a script, and a URL that serves
        #  the current release, are both reasons a pin is by hand.
        pin = dict(PIN, fetch='by hand')
        with tempfile.TemporaryDirectory() as cache:
            with self.assertRaises(fetch_inputs.InputError) as refused:
                fetch_inputs.fetch('m/manual.pdf', {'m/manual.pdf': pin},
                                   cache, opener=Opener(GOOD))
        self.assertIn('does not serve it to a script', str(refused.exception))
        self.assertIn('serves whatever release is current',
                      str(refused.exception))
        self.assertIn('serves whatever release is current',
                      ' '.join(fetch_inputs.__doc__.split()))

    def test_a_directory_selects_every_input_under_it(self):
        inputs = {'a/one.h': PIN, 'a/sub/two.h': PIN, 'ab/three.h': PIN,
                  'a/manual.pdf': dict(PIN, fetch='by hand'), 'b/four.h': PIN}
        self.assertEqual(fetch_inputs.select(['a/', 'b/four.h', 'a/one.h'],
                                             inputs),
                         ['a/manual.pdf', 'a/one.h', 'a/sub/two.h',
                          'b/four.h'])
        self.assertEqual(fetch_inputs.select([], inputs),
                         ['a/one.h', 'a/sub/two.h', 'ab/three.h', 'b/four.h'])
        self.assertEqual(len(fetch_inputs.select([], inputs, every=True)), 5)

    def test_a_directory_naming_no_input_is_refused(self):
        with self.assertRaisesRegex(fetch_inputs.InputError,
                                    'c/: devices/inputs.json pins no input'
                                    ' under this directory'):
            fetch_inputs.select(['c/'], {'a/one.h': PIN})
        with self.assertRaisesRegex(fetch_inputs.InputError,
                                    'name it as a/ to fetch'):
            fetch_inputs.select(['a'], {'a/one.h': PIN})

    def test_the_pinned_cmsis_directories_select_headers(self):
        inputs = fetch_inputs.read_lock()
        chosen = fetch_inputs.select(['rp2040-cmsis/', 'stm32h753-cmsis/'],
                                     inputs)
        self.assertIn('rp2040-cmsis/m-profile/cmsis_gcc_m.h', chosen)
        self.assertIn('stm32h753-cmsis/core_cm7.h', chosen)
        self.assertTrue(all(name.endswith('.h') for name in chosen), chosen)

    def test_rm0433_is_pinned_and_supplied_by_hand(self):
        pin = fetch_inputs.read_lock()['rm0433/RM0433.pdf']
        self.assertEqual(pin['fetch'], 'by hand')
        self.assertEqual(pin['sha256'], '672a9433d6602da224e5215f571beed2'
                                        'be0e683cb025526f4afe9db61c26b6a0')


if __name__ == '__main__':
    unittest.main()
