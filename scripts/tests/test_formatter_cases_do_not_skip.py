#!/usr/bin/env python3
"""The formatter's write-safety cases fail where they cannot run.

compiler/tests/test_formatter_write_safety.py needs a built refine and a
real file system, so the gate runs it as a command and reads its exit
status.  A case that skipped itself, on a scratch file system without
extended attributes or ACLs or under a privileged user, left that status
zero, and the property the case holds went unchecked in a green run.  These
controls give the cases a host that cannot arrange their precondition,
without a compiler: each fails before it would format anything.
"""
import errno
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "formatter_write_safety", ROOT / "compiler/tests/test_formatter_write_safety.py")
CASES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CASES)


class Unsupported(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        saved = CASES.SCRATCH, CASES.ALLOW_UNSUPPORTED
        CASES.SCRATCH = Path(self.temporary.name)
        self.addCleanup(lambda: setattr(CASES, "SCRATCH", saved[0]))
        self.addCleanup(lambda: setattr(CASES, "ALLOW_UNSUPPORTED", saved[1]))

    def outcome(self, name, allow):
        CASES.ALLOW_UNSUPPORTED = allow
        result = unittest.TestResult()
        CASES.FormatterWriteSafety(name).run(result)
        self.assertEqual(result.errors, [])
        return ("skipped" if result.skipped else
                "failed" if result.failures else "passed"), result

    def refusing(self):
        """A file system that takes no extended attribute or ACL."""
        return mock.patch.object(
            CASES.os, "setxattr", create=True,
            side_effect=OSError(errno.ENOTSUP, "Operation not supported"))

    def test_a_file_system_without_the_attribute_fails_the_case(self):
        names = ["test_posix_acl_is_kept", "test_inherited_acl_does_not_reach_the_source"]
        if sys.platform == "linux":
            names.append("test_extended_attribute_is_kept")
        else:
            # The two ACL cases are Linux's and skip elsewhere, as no host
            # but Linux can run them; nothing here judges that.
            names = []
        for name in names:
            with self.subTest(name=name), self.refusing():
                verdict, result = self.outcome(name, allow=False)
                self.assertEqual(verdict, "failed")
                self.assertIn("what it holds is unchecked", result.failures[0][1])
                self.assertIn("--scratch", result.failures[0][1])
                # A developer who knows the file system may go without it.
                self.assertEqual(self.outcome(name, allow=True)[0], "skipped")

    def test_a_privileged_user_fails_the_case_it_cannot_run(self):
        name = "test_unwritable_directory_is_refused_naming_the_copy"
        with mock.patch.object(CASES.os, "geteuid", return_value=0):
            verdict, result = self.outcome(name, allow=False)
            self.assertEqual(verdict, "failed")
            self.assertIn("a privileged process writes any directory", result.failures[0][1])
            self.assertEqual(self.outcome(name, allow=True)[0], "skipped")

    def test_no_case_skips_itself_any_other_way(self):
        source = (ROOT / "compiler/tests/test_formatter_write_safety.py").read_text()
        self.assertEqual(source.count("skipTest("), 1,
                         "only `unsupported` may skip, and only when allowed")


if __name__ == "__main__":
    unittest.main()
