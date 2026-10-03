#!/usr/bin/env python3
"""Real-host formatter replacement regression; pass an already-built refine.

Every source that can be damaged by a fault lives in a disposable directory
under /tmp/landin-loop.  The file-size limit reproduces issue 0076.
"""
import argparse
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile
import unittest


REFINE = None
SCRATCH = Path("/tmp/landin-loop")
LOOSE = b"  x: u32 = 0\n" + b"-- comment\n" * 2000


def limit_file_size():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))


class FormatterWriteSafety(unittest.TestCase):
    def setUp(self):
        SCRATCH.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="fmt-safety-", dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.ldn"
        self.source.write_bytes(LOOSE)

    def fmt(self, path=None, *, limited=False):
        return subprocess.run(
            [str(REFINE), "fmt", str(path or self.source)],
            capture_output=True, timeout=30,
            preexec_fn=limit_file_size if limited else None)

    def test_failed_write_preserves_every_source_byte(self):
        before = self.source.read_bytes()
        result = self.fmt(limited=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"L0005", result.stderr)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(list(self.root.iterdir()), [self.source],
                         "a failed replacement removes its temporary file")

    def test_replacement_preserves_mode_and_symlink(self):
        self.source.chmod(0o640)
        link = self.root / "link.ldn"
        link.symlink_to(self.source.name)
        result = self.fmt(link)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(link), self.source.name)
        self.assertEqual(self.source.stat().st_mode & 0o777, 0o640)
        self.assertNotEqual(self.source.read_bytes(), LOOSE)

    def test_readonly_and_hardlinked_sources_are_refused(self):
        self.source.chmod(0o444)
        result = self.fmt()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.source.read_bytes(), LOOSE)
        self.source.chmod(0o644)
        alias = self.root / "alias.ldn"
        os.link(self.source, alias)
        result = self.fmt()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.source.read_bytes(), LOOSE)
        self.assertEqual(alias.read_bytes(), LOOSE)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--refine", required=True, type=Path)
    REFINE = parser.parse_args().refine.resolve()
    unittest.main(argv=[__file__])
