#!/usr/bin/env python3
"""A published example's edited routine reaches its copies by one command.

check.py holds each copy of a shared routine to the published example's
text, and its refusal names scripts/sync_routines.py.  A small tree with
one published file and one copy shows the refusal naming the copy, the
published file and the command, the command making the check pass, and
what it leaves alone.
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("landin_check", ROOT / "check.py")
CHECK = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CHECK)
spec = importlib.util.spec_from_file_location(
    "sync_routines", ROOT / "scripts/sync_routines.py")
SYNC = importlib.util.module_from_spec(spec)
spec.loader.exec_module(SYNC)

PUBLISHED = "published/main.ldn"
COPY = "copy/main.ldn"
ROUTINES = ("count", "blank")
SOURCE = """import core/io

blank: fn (byte: u8) -> bool
    return byte == 32
end blank

count: fn (text: view u8) -> usize
    return text.len
end count

main: fn ()
    count("published")
end main
"""
#  The copy has its own main and the routines in another order.
HELD = """import core/io

count: fn (text: view u8) -> usize
    return text.len
end count

blank: fn (byte: u8) -> bool
    return byte == 32
end blank

main: fn ()
    count("the copy's own entry")
end main
"""


class SyncRoutines(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="landin-sync-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name, text in ((PUBLISHED, SOURCE), (COPY, HELD)):
            (self.root / name).parent.mkdir(parents=True)
            (self.root / name).write_text(text)
        for name, value in (("ROOT", str(self.root)),
                            ("SHARED_ROUTINES", {PUBLISHED: {COPY: ROUTINES}})):
            patcher = patch.object(CHECK, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        #  The script reaches check.py as its own import.
        patcher = patch.object(SYNC, "check", CHECK)
        patcher.start()
        self.addCleanup(patcher.stop)

    def sync(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = SYNC.main(["sync_routines.py"])
        return status, out.getvalue(), err.getvalue()

    def edit_published(self):
        edited = SOURCE.replace("    return text.len\n",
                                "    //  How many bytes.\n    return text.len\n")
        (self.root / PUBLISHED).write_text(edited)
        return edited

    def test_copies_that_agree_pass_and_are_left_alone(self):
        self.assertEqual(CHECK.shared_routine_witnesses(), [])
        self.assertEqual(self.sync(), (
            0, "every copy already carries its published routine\n", ""))
        self.assertEqual((self.root / COPY).read_text(), HELD)

    def test_the_refusal_names_the_copy_the_published_file_and_the_command(self):
        self.edit_published()
        self.assertEqual(CHECK.shared_routine_witnesses(), [(
            COPY, 1, "count differs from published/main.ldn's; the published "
            "file is the source, so copy its routine here with python3 "
            "scripts/sync_routines.py")])
        #  The command it names is this script.
        self.assertTrue((ROOT / CHECK.SYNC_ROUTINES.split()[1]).is_file())

    def test_the_command_writes_the_routine_and_nothing_else(self):
        self.edit_published()
        status, said, errors = self.sync()
        self.assertEqual((status, said, errors),
                         (0, "wrote count into copy/main.ldn\n", ""))
        self.assertEqual(CHECK.shared_routine_witnesses(), [])
        self.assertEqual(
            (self.root / COPY).read_text(),
            HELD.replace("    return text.len\n",
                         "    //  How many bytes.\n    return text.len\n"))
        #  A second run has nothing to write.
        self.assertIn("every copy already carries", self.sync()[1])

    def test_a_copy_without_the_routine_is_refused_not_guessed(self):
        (self.root / COPY).write_text(HELD.replace("end blank", "end other")
                                          .replace("blank:", "other:"))
        status, said, errors = self.sync()
        self.assertEqual(status, 1)
        self.assertIn("copy/main.ldn does not declare blank, so there is no "
                      "routine to replace; add published/main.ldn's to it",
                      errors)

    def test_every_real_copy_is_reachable(self):
        #  Unpatched: the tree's own table names files that are here.
        for patcher in ("ROOT", "SHARED_ROUTINES"):
            self.assertTrue(hasattr(CHECK, patcher))
        real = importlib.util.spec_from_file_location("real", ROOT / "check.py")
        module = importlib.util.module_from_spec(real)
        real.loader.exec_module(module)
        for published, copies in module.SHARED_ROUTINES.items():
            source = (ROOT / published).read_text()
            for copy, names in copies.items():
                for name in names:
                    self.assertIsNotNone(module.shared_routine(name, source))
                    self.assertIsNotNone(module.shared_routine(
                        name, (ROOT / copy).read_text()))


if __name__ == "__main__":
    unittest.main()
