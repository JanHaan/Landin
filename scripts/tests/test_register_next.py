#!/usr/bin/env python3
"""Controls for scripts/register_next.py, the register's identity allocator.

The numbers here are far past any the register will reach, so the
identities they make name no real row.
"""
import io
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import register_next  # noqa: E402
from temporary_git import environment  # noqa: E402

#  A row's identity, written so that this file spells none.
ROW = "SR-%d"
TEXT = "---\nstatus: open\n---\n\nA row.\n\nCompletion: x\n"


def git(root, *arguments):
    subprocess.run(["git", *arguments], cwd=root, check=True,
                   env=environment(), stdout=subprocess.DEVNULL)


class Allocate(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.rows = self.root / register_next.DIRECTORY
        self.rows.mkdir(parents=True)
        git(self.root, "init", "-q")

    def tearDown(self):
        self.scratch.cleanup()

    def write(self, number):
        (self.rows / ("SR-%d.md" % number)).write_text(TEXT)

    def commit(self):
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "--allow-empty", "-m", "x")

    def test_an_empty_register_starts_after_the_second_roadmap(self):
        self.assertEqual(register_next.allocate(self.root, 2),
                         ["SR-%d" % (register_next.SECOND_ROADMAP_LAST + n)
                          for n in (1, 2)])

    def test_the_highest_file_decides(self):
        self.write(90000)
        self.write(90007)
        self.assertEqual(register_next.allocate(self.root, 1), [ROW % 90008])

    def test_a_deleted_row_keeps_its_number(self):
        #  A retired row has no file, and its number is not taken again.
        self.write(90000)
        self.write(90009)
        self.commit()
        (self.rows / (ROW % 90009 + ".md")).unlink()
        self.commit()
        self.assertEqual(register_next.allocate(self.root, 1), [ROW % 90010])

    def test_another_local_branch_counts(self):
        self.commit()
        git(self.root, "checkout", "-q", "-b", "other")
        self.write(90020)
        self.commit()
        git(self.root, "checkout", "-q", "-")
        self.assertFalse((self.rows / (ROW % 90020 + ".md")).exists())
        self.assertEqual(register_next.allocate(self.root, 1), [ROW % 90021])

    def test_file_writes_rows_check_py_refuses_until_filled(self):
        self.write(90030)
        out = io.StringIO()
        with redirect_stdout(out):
            register_next.main(["2", "--file", "--root", str(self.root)])
        self.assertEqual(out.getvalue().split(),
                         ["roadmap/register/%s.md" % (ROW % n)
                          for n in (90031, 90032)])
        text = (self.rows / (ROW % 90031 + ".md")).read_text()
        self.assertTrue(text.startswith("---\nkind: TODO\n"))
        import check
        fields, body, problems = check.register_row(text)
        self.assertEqual(problems, [])
        self.assertFalse(check.REGISTER_VALUES["kind"].fullmatch(
            fields["kind"][1]))

    def test_outside_a_repository_the_files_alone_count(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        root = Path(scratch.name)
        (root / register_next.DIRECTORY).mkdir(parents=True)
        (root / register_next.DIRECTORY
         / (ROW % 90040 + ".md")).write_text(TEXT)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(register_next.allocate(root, 1), [ROW % 90041])


if __name__ == "__main__":
    unittest.main()
