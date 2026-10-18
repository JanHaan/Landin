#!/usr/bin/env python3
"""Real-host formatter replacement regression; pass an already-built refine.

D358: `refine fmt` writes the formatted bytes into the file it read, so the
file keeps its inode and everything it carries, and keeps a synced copy of
the original bytes beside it until the new ones are synced.  These cases run
as the user who runs them, with no privilege, which is the point: before it,
only root could format a file on Linux.

Every source that can be damaged by a fault lives in a disposable directory
under --scratch, /tmp/landin-loop by default; name a directory on another
file system (tmpfs, ZFS, ext4, APFS) to hold the adapter to that one.  The
file-size limit reproduces issue 0076.
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
LAID_OUT = b"x: u32 = 0\n" + b"-- comment\n" * 2000
ADAPTER = (Path(__file__).resolve().parents[1]
           / "ada/src/platform/landin_format_replace.c")


def limit_file_size():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))


class FormatterWriteSafety(unittest.TestCase):
    def setUp(self):
        SCRATCH.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="fmt-safety-",
                                                dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.ldn"
        self.source.write_bytes(LOOSE)
        # Darwin inherits /tmp's group (often wheel), which the runner need
        # not belong to. Test setgid on a group this process can establish.
        os.chown(self.source, -1, os.getgid())
        self.assertEqual(self.source.stat().st_gid, os.getgid())

    def fmt(self, path=None, *, limited=False):
        return subprocess.run(
            [str(REFINE), "fmt", str(path or self.source)],
            capture_output=True, timeout=30,
            preexec_fn=limit_file_size if limited else None)

    def assert_formatted(self, result, inode):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.source.read_bytes(), LAID_OUT)
        self.assertEqual(self.source.stat().st_ino, inode,
                         "the file is written in place, not replaced")
        self.assertEqual(list(self.root.glob("*.fmt-*")), [],
                         "the copy of the original is removed")

    def assert_refused(self, result, cause):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"L0005", result.stderr)
        self.assertIn(cause, result.stderr)
        self.assertNotIn(b"cannot write:", result.stderr)
        self.assertEqual(self.source.read_bytes(), LOOSE)

    def test_plain_file_is_formatted_without_privilege(self):
        # The first refusal D358 removed: an ordinary user's ordinary file.
        inode = self.source.stat().st_ino
        self.assert_formatted(self.fmt(), inode)
        self.assertEqual(self.fmt().returncode, 0, "formatted is a fixpoint")

    def test_failed_write_preserves_every_source_byte(self):
        result = self.fmt(limited=True)
        self.assert_refused(result, b"File too large")
        self.assertEqual(list(self.root.iterdir()), [self.source],
                         "a refused write leaves no copy behind")

    def test_replacement_preserves_mode_and_symlink(self):
        self.source.chmod(0o640)
        link = self.root / "link.ldn"
        link.symlink_to(self.source.name)
        inode = self.source.stat().st_ino
        self.assert_formatted(self.fmt(link), inode)
        self.assertEqual(os.readlink(link), self.source.name)
        self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), 0o640)

    def test_replacement_preserves_all_mode_bits(self):
        # A write clears set-user-ID and set-group-ID; the adapter sets them
        # again, as the owner in the file's group may.
        for mode in (0o4755, 0o2755, 0o6755, 0o7777):
            with self.subTest(mode=oct(mode)):
                self.source.write_bytes(LOOSE)
                self.source.chmod(mode)
                self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), mode)
                inode = self.source.stat().st_ino
                self.assert_formatted(self.fmt(), inode)
                self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), mode)

    def test_extended_attribute_is_kept(self):
        name = "user.landin-format" if sys.platform == "linux" else "landin-format"
        try:
            if sys.platform == "darwin":
                # Python's os xattr functions are Linux-only. The native
                # command's hex mode preserves the exact test bytes.
                subprocess.run(["xattr", "-wx", name,
                                b"retained metadata".hex(), str(self.source)],
                               check=True, capture_output=True)
            else:
                os.setxattr(self.source, name, b"retained metadata")
        except OSError as error:
            if error.errno == errno.ENOTSUP:
                self.skipTest("test filesystem has no extended attributes")
            raise
        inode = self.source.stat().st_ino
        self.assert_formatted(self.fmt(), inode)
        if sys.platform == "darwin":
            value = bytes.fromhex(subprocess.check_output(
                ["xattr", "-px", name, str(self.source)], text=True))
        else:
            value = os.getxattr(self.source, name)
        self.assertEqual(value, b"retained metadata")

    @unittest.skipUnless(sys.platform == "linux", "Linux POSIX ACL encoding")
    def test_posix_acl_is_kept(self):
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
        inode = self.source.stat().st_ino
        self.assert_formatted(self.fmt(), inode)
        self.assertEqual(os.getxattr(self.source, "system.posix_acl_access"), acl)

    @unittest.skipUnless(sys.platform == "linux", "Linux default ACL encoding")
    def test_inherited_acl_does_not_reach_the_source(self):
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
        inode = self.source.stat().st_ino
        self.assert_formatted(self.fmt(), inode)
        self.assertEqual(os.listxattr(self.source), [])

    @unittest.skipUnless(sys.platform == "darwin", "Darwin extended ACL")
    def test_darwin_acl_is_kept(self):
        subprocess.run(["chmod", "+a", "everyone allow read", str(self.source)],
                       check=True, capture_output=True)

        def acl():
            listing = subprocess.check_output(["ls", "-le", str(self.source)],
                                              text=True).splitlines()
            return listing[1:]

        before = acl()
        self.assertTrue(before)
        inode = self.source.stat().st_ino
        self.assert_formatted(self.fmt(), inode)
        self.assertEqual(acl(), before)

    def test_hard_link_names_see_the_layout(self):
        alias = self.root / "alias.ldn"
        os.link(self.source, alias)
        inode = self.source.stat().st_ino
        self.assert_formatted(self.fmt(), inode)
        self.assertEqual(alias.read_bytes(), LAID_OUT)
        self.assertEqual(self.source.stat().st_nlink, 2)

    def test_readonly_source_is_refused_naming_it(self):
        self.source.chmod(0o444)
        self.assert_refused(self.fmt(), b"it is read-only")

    def test_unwritable_directory_is_refused_naming_the_copy(self):
        if os.geteuid() == 0:
            self.skipTest("a privileged process writes any directory")
        self.root.chmod(0o555)
        self.addCleanup(self.root.chmod, 0o755)
        self.assert_refused(self.fmt(), b"cannot keep a copy of it")
        self.assertIn(b"refine fmt --stdout", self.fmt().stderr)

    def harness(self, name, prelude, main):
        """The adapter itself, with a fault put at one of its calls.

        Darwin fixes its feature level at the first system header, so the
        adapter's own `_DARWIN_C_SOURCE` comes before the fault's headers.
        """
        source = self.root / (name + ".c")
        source.write_text('#ifdef __APPLE__\n#define _DARWIN_C_SOURCE\n#endif\n'
                          + prelude + '#include "' + str(ADAPTER) + '"\n'
                          + main)
        binary = self.root / name
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        str(source), "-o", str(binary)], check=True,
                       capture_output=True)
        return binary

    def test_failed_write_is_undone_or_its_copy_kept(self):
        # pwrite's calls: the copy, the new bytes, then the restoration.
        binary = self.harness(
            "write_fault",
            '#define _POSIX_C_SOURCE 200809L\n'
            '#include <errno.h>\n#include <stdlib.h>\n#include <unistd.h>\n'
            'static int calls, fail_from, fail_to;\n'
            'static ssize_t faulty_pwrite(int fd, const void *b, size_t n, off_t at) {\n'
            '  ++calls;\n'
            '  if (calls >= fail_from && calls <= fail_to) {\n'
            '    if (n > 3) n = 3;\n'
            '    if (calls == fail_from) return pwrite(fd, b, n, at);\n'
            '    errno = ENOSPC; return -1;\n'
            '  }\n'
            '  return pwrite(fd, b, n, at);\n'
            '}\n'
            '#define pwrite faulty_pwrite\n',
            '#undef pwrite\n'
            '#include <stdio.h>\n'
            'int main(int argc, char **argv) {\n'
            '  char reason[8192];\n'
            '  if (argc != 4) return 2;\n'
            '  fail_from = atoi(argv[2]); fail_to = atoi(argv[3]);\n'
            '  int result = landin_replace_existing_file(argv[1], "changed", 7,\n'
            '                                            reason, sizeof reason);\n'
            '  puts(reason);\n'
            '  return result == 0 ? 0 : 1;\n'
            '}\n')
        inode = self.source.stat().st_ino
        # The first write of the new bytes fails part way: the original is
        # put back and the copy removed.
        run = subprocess.run([str(binary), str(self.source), "2", "3"],
                             capture_output=True)
        self.assertEqual(run.returncode, 1)
        self.assertIn(b"No space left on device; its bytes are as they were",
                      run.stdout)
        self.assertEqual(self.source.read_bytes(), LOOSE)
        self.assertEqual(self.source.stat().st_ino, inode)
        self.assertEqual(list(self.root.glob("*.fmt-*")), [])
        # The restoration fails too: the copy is kept and named.
        run = subprocess.run([str(binary), str(self.source), "2", "99"],
                             capture_output=True)
        self.assertEqual(run.returncode, 1)
        kept = list(self.root.glob("source.ldn.fmt-original-*"))
        self.assertEqual(len(kept), 1)
        self.assertIn(b"its original bytes are kept in " + bytes(kept[0]),
                      run.stdout)
        self.assertEqual(kept[0].read_bytes(), LOOSE)
        kept[0].unlink()
        # Keeping the copy fails: nothing has been written.
        self.source.write_bytes(LOOSE)
        run = subprocess.run([str(binary), str(self.source), "1", "99"],
                             capture_output=True)
        self.assertEqual(run.returncode, 1)
        self.assertIn(b"cannot keep a copy of it", run.stdout)
        self.assertEqual(self.source.read_bytes(), LOOSE)
        self.assertEqual(list(self.root.glob("*.fmt-*")), [])
        # And with no fault the adapter writes the file in place.
        run = subprocess.run([str(binary), str(self.source), "0", "0"],
                             capture_output=True)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertEqual(self.source.read_bytes(), b"changed")
        self.assertEqual(self.source.stat().st_ino, inode)

    def test_mode_a_write_clears_is_verified(self):
        # chmod can return success after clearing setgid; the adapter reads
        # the mode back, and says the file is formatted but its mode is not.
        binary = self.harness(
            "mode_fault",
            '#define _POSIX_C_SOURCE 200809L\n'
            '#include <sys/stat.h>\n'
            'static int clearing_fchmod(int fd, mode_t mode) {\n'
            '  return fchmod(fd, mode & ~S_ISGID);\n'
            '}\n'
            '#define fchmod clearing_fchmod\n',
            '#include <stdio.h>\n'
            'int main(int argc, char **argv) {\n'
            '  char reason[8192];\n'
            '  if (argc != 2) return 2;\n'
            '  int result = landin_replace_existing_file(argv[1], "changed", 7,\n'
            '                                            reason, sizeof reason);\n'
            '  puts(reason);\n'
            '  return result == 0 ? 0 : 1;\n'
            '}\n')
        self.source.chmod(0o2755)
        run = subprocess.run([str(binary), str(self.source)],
                             capture_output=True)
        if stat.S_IMODE(self.source.stat().st_mode) == 0o2755:
            # This system's write left setgid alone, so nothing was cleared
            # and nothing needed setting again.
            self.assertEqual(run.returncode, 0, run.stdout)
        else:
            self.assertEqual(run.returncode, 1)
            self.assertIn(b"its mode 2755 could not be restored", run.stdout)
        self.assertEqual(list(self.root.glob("*.fmt-*")), [])

    @unittest.skipUnless(sys.platform == "linux", "Linux file capabilities")
    def test_file_capabilities_are_refused_before_writing(self):
        # Setting security.capability needs CAP_SETFCAP, so the attribute is
        # supplied at the adapter's own query.
        binary = self.harness(
            "capability",
            '#define _POSIX_C_SOURCE 200809L\n'
            '#include <string.h>\n#include <sys/types.h>\n'
            'static ssize_t capable(int fd, const char *name, void *v, size_t n) {\n'
            '  (void)fd; (void)v; (void)n;\n'
            '  return strcmp(name, "security.capability") == 0 ? 20 : -1;\n'
            '}\n'
            '#define fgetxattr capable\n',
            '#include <stdio.h>\n'
            'int main(int argc, char **argv) {\n'
            '  char reason[8192];\n'
            '  if (argc != 2) return 2;\n'
            '  int result = landin_replace_existing_file(argv[1], "changed", 7,\n'
            '                                            reason, sizeof reason);\n'
            '  puts(reason);\n'
            '  return result == 0 ? 0 : 1;\n'
            '}\n')
        run = subprocess.run([str(binary), str(self.source)],
                             capture_output=True)
        self.assertEqual(run.returncode, 1)
        self.assertIn(b"carries file capabilities", run.stdout)
        self.assertEqual(self.source.read_bytes(), LOOSE)
        self.assertEqual(list(self.root.glob("*.fmt-*")), [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--refine", required=True, type=Path)
    parser.add_argument("--scratch", type=Path, default=SCRATCH)
    arguments, rest = parser.parse_known_args()
    REFINE = arguments.refine.resolve()
    SCRATCH = arguments.scratch
    unittest.main(argv=[__file__] + rest)
