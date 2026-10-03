#!/usr/bin/env python3
"""Real-host formatter replacement regression; pass an already-built refine.

Every source that can be damaged by a fault lives in a disposable directory
under /tmp/landin-loop.  The file-size limit reproduces issue 0076.
"""
import argparse
import errno
import os
from pathlib import Path
import resource
import signal
import stat
import struct
import sys
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

    def metadata_visibility_known(self):
        if sys.platform != "linux":
            return True
        try:
            os.setxattr(self.source, "trusted.landin-format-test", b"",
                        os.XATTR_CREATE)
        except OSError as error:
            return error.errno == errno.ENOTSUP
        os.removexattr(self.source, "trusted.landin-format-test")
        return True

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
        visible = self.metadata_visibility_known()
        result = self.fmt(link)
        self.assertEqual(result.returncode, 0 if visible else 1, result.stderr)
        self.assertEqual(os.readlink(link), self.source.name)
        self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), 0o640)
        if visible:
            self.assertNotEqual(self.source.read_bytes(), LOOSE)
        else:
            self.assertEqual(self.source.read_bytes(), LOOSE)

    def test_replacement_preserves_all_mode_bits(self):
        for mode in (0o4755, 0o2755, 0o6755, 0o7777):
            with self.subTest(mode=oct(mode)):
                self.source.write_bytes(LOOSE)
                self.source.chmod(mode)
                self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), mode)
                visible = self.metadata_visibility_known()
                result = self.fmt()
                self.assertEqual(result.returncode, 0 if visible else 1,
                                 result.stderr)
                self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), mode)
                if visible:
                    self.assertNotEqual(self.source.read_bytes(), LOOSE)
                else:
                    self.assertEqual(self.source.read_bytes(), LOOSE)

    def assert_metadata_refused(self):
        before = self.source.stat()
        result = self.fmt()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"L0005", result.stderr)
        self.assertEqual(self.source.read_bytes(), LOOSE)
        self.assertEqual(self.source.stat().st_ino, before.st_ino)
        self.assertEqual(self.source.stat().st_mode, before.st_mode)
        self.assertEqual(list(self.root.iterdir()), [self.source])

    @unittest.skipUnless(sys.platform == "linux", "Linux hidden namespace")
    def test_unknown_privileged_metadata_refuses_plain_source(self):
        if self.metadata_visibility_known():
            self.skipTest("host can establish privileged metadata visibility")
        self.assertEqual(os.listxattr(self.source), [])
        self.assert_metadata_refused()

    def test_extended_attribute_refuses_without_metadata_loss(self):
        name = "user.landin-format" if sys.platform == "linux" else "landin-format"
        try:
            os.setxattr(self.source, name, b"retained metadata")
        except OSError as error:
            if error.errno == errno.ENOTSUP:
                self.skipTest("test filesystem has no extended attributes")
            raise
        self.assert_metadata_refused()
        self.assertEqual(os.getxattr(self.source, name), b"retained metadata")

    @unittest.skipUnless(sys.platform == "linux", "Linux POSIX ACL encoding")
    def test_posix_acl_refuses_without_metadata_loss(self):
        # A named user makes this an extended ACL, not mode bits alone.
        entries = [(1, 6, 0xffffffff), (2, 4, os.getuid() + 1),
                   (4, 4, 0xffffffff), (16, 4, 0xffffffff),
                   (32, 4, 0xffffffff)]
        acl = struct.pack("<I", 2) + b"".join(
            struct.pack("<HHI", *entry) for entry in entries)
        try:
            os.setxattr(self.source, "system.posix_acl_access", acl)
        except OSError as error:
            if error.errno == errno.ENOTSUP:
                self.skipTest("test filesystem has no POSIX ACL support")
            raise
        self.assert_metadata_refused()
        self.assertEqual(os.getxattr(self.source, "system.posix_acl_access"), acl)

    @unittest.skipUnless(sys.platform == "linux", "Linux default ACL encoding")
    def test_inherited_acl_refuses_before_replacement(self):
        entries = [(1, 7, 0xffffffff), (2, 4, os.getuid() + 1),
                   (4, 5, 0xffffffff), (16, 5, 0xffffffff),
                   (32, 5, 0xffffffff)]
        acl = struct.pack("<I", 2) + b"".join(
            struct.pack("<HHI", *entry) for entry in entries)
        try:
            os.setxattr(self.root, "system.posix_acl_default", acl)
        except OSError as error:
            if error.errno == errno.ENOTSUP:
                self.skipTest("test filesystem has no default ACL support")
            raise
        self.assert_metadata_refused()
        self.assertEqual(os.listxattr(self.source), [])

    @unittest.skipUnless(sys.platform == "darwin", "Darwin extended ACL")
    def test_darwin_acl_refuses_without_metadata_loss(self):
        subprocess.run(["chmod", "+a", "everyone allow read", str(self.source)],
                       check=True, capture_output=True)
        before = subprocess.check_output(["ls", "-le", str(self.source)])
        self.assert_metadata_refused()
        self.assertEqual(subprocess.check_output(["ls", "-le", str(self.source)]),
                         before)

    @unittest.skipUnless(sys.platform == "linux", "Linux xattr adapter")
    def test_metadata_query_failure_preserves_source(self):
        # Force EIO at the actual adapter seam, including after temporary
        # creation, rather than relying on a filesystem permission accident.
        adapter = Path(__file__).resolve().parents[1] / "ada/src/platform/landin_format_replace.c"
        harness = self.root / "metadata_failure.c"
        harness.write_text(
            '#define flistxattr fault_listxattr\n'
            '#define fsetxattr trusted_visible\n'
            '#define fremovexattr trusted_removed\n'
            '#include "' + str(adapter) + '"\n'
            'int trusted_visible(int fd, const char *n, const void *v, size_t s, int f) {\n'
            '  (void)fd; (void)n; (void)v; (void)s; (void)f; return 0;\n'
            '}\n'
            'int trusted_removed(int fd, const char *n) {\n'
            '  (void)fd; (void)n; return 0;\n'
            '}\n'
            'static int calls;\n'
            'static int fail_at;\n'
            'ssize_t fault_listxattr(int fd, char *list, size_t size) {\n'
            '  (void)fd; (void)list; (void)size;\n'
            '  if (++calls == fail_at) { errno = EIO; return -1; }\n'
            '  return 0;\n'
            '}\n'
            'int main(int argc, char **argv) {\n'
            '  if (argc != 3) return 2;\n'
            '  fail_at = atoi(argv[2]);\n'
            '  if (fail_at == 4) {\n'
            '    char data[4096] = {0};\n'
            '    return landin_replace_existing_file(argv[1], data, sizeof data) == -1 ? 0 : 1;\n'
            '  }\n'
            '  int result = landin_replace_existing_file(argv[1], "changed", 7);\n'
            '  return result == (fail_at == 0 ? 0 : -1) ? 0 : 1;\n'
            '}\n')
        binary = self.root / "metadata_failure"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        str(harness), "-o", str(binary)], check=True,
                       capture_output=True)
        # With visibility proved, exercise replacement and post-write mode
        # restoration on the real filesystem through the same adapter.
        self.source.chmod(0o6755)
        subprocess.run([str(binary), str(self.source), "0"], check=True,
                       capture_output=True)
        self.assertEqual(self.source.read_bytes(), b"changed")
        self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), 0o6755)
        self.source.write_bytes(LOOSE)
        before = self.source.stat()
        subprocess.run([str(binary), str(self.source), "4"], check=True,
                       capture_output=True, preexec_fn=limit_file_size)
        self.assertEqual(self.source.read_bytes(), LOOSE)
        self.assertEqual(self.source.stat().st_ino, before.st_ino)
        self.assertEqual(list(self.root.glob("*.fmt-*")), [])
        for failure in (1, 2, 3):
            with self.subTest(query=failure):
                subprocess.run([str(binary), str(self.source), str(failure)],
                               check=True, capture_output=True)
                self.assertEqual(self.source.read_bytes(), LOOSE)
                self.assertEqual(self.source.stat().st_ino, before.st_ino)
                self.assertEqual(list(self.root.glob("*.fmt-*")), [])

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
