#!/usr/bin/env python3
"""source_times.py and release_cache_key.py over files written here."""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import release_cache_key  # noqa: E402
import source_times  # noqa: E402

OLD = 1_000_000_000_123_456_789


class SourceTimes(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.build = self.root / "build"
        for name in ("a.adb", "b.ads", "c.c"):
            (self.root / name).write_text(name)
            os.utime(self.root / name, ns=(OLD, OLD))
        patcher = mock.patch.object(source_times.build_identity, "inputs",
                                    lambda root: ["a.adb", "b.ads", "c.c"])
        patcher.start()
        self.addCleanup(patcher.stop)

    def quiet(self, function, *args):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(function(*args), 0)
        return out.getvalue()

    def test_an_unchanged_source_gets_its_time_back_and_a_changed_one_does_not(self):
        self.quiet(source_times.save, self.root, self.build)
        #  A checkout: every file new, one of them with new content.
        for name in ("a.adb", "b.ads", "c.c"):
            os.utime(self.root / name)
        (self.root / "b.ads").write_text("changed")
        said = self.quiet(source_times.apply, self.root, self.build)
        self.assertEqual((self.root / "a.adb").stat().st_mtime_ns, OLD)
        self.assertEqual((self.root / "c.c").stat().st_mtime_ns, OLD)
        self.assertGreater((self.root / "b.ads").stat().st_mtime_ns, OLD)
        self.assertIn("2 inputs unchanged", said)
        self.assertIn("b.ads changed", said)

    def test_a_gone_source_is_named_and_nothing_fails(self):
        self.quiet(source_times.save, self.root, self.build)
        (self.root / "c.c").unlink()
        self.assertIn("c.c is gone", self.quiet(source_times.apply, self.root, self.build))

    def test_no_record_changes_nothing(self):
        os.utime(self.root / "a.adb")
        before = (self.root / "a.adb").stat().st_mtime_ns
        self.assertIn("absent", self.quiet(source_times.apply, self.root, self.build))
        self.assertEqual((self.root / "a.adb").stat().st_mtime_ns, before)


class CacheKey(unittest.TestCase):
    def test_the_key_follows_the_facts_and_nothing_else(self):
        one = release_cache_key.key("linux", ["libc6-dev 2.39", "gcc 16.1.0"])
        self.assertEqual(one, release_cache_key.key("linux", ["libc6-dev 2.39", "gcc 16.1.0"]))
        self.assertNotEqual(one, release_cache_key.key("linux", ["libc6-dev 2.40", "gcc 16.1.0"]))
        self.assertNotEqual(one, release_cache_key.key("darwin", ["libc6-dev 2.39", "gcc 16.1.0"]))
        self.assertRegex(one, r"^linux-headers-[0-9a-f]{16}$")

    def test_a_platform_it_does_not_know_is_refused(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(release_cache_key.main(["x", "windows"]), 2)


if __name__ == "__main__":
    unittest.main()
