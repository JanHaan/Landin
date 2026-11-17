#!/usr/bin/env python3
"""Controls for scripts/roadmap_register.py, the register's move into files.

The rows here are invented, spelled as check.py's citation rule leaves a
test free to spell them: one digit after `SR-`, or a letter and a digit.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import roadmap_register  # noqa: E402
from temporary_git import environment  # noqa: E402

#  Two items, built so that this file names no roadmap identity.
OWNERS = "R%d.%d, R%d.%d" % (9, 10, 9, 20)

ROADMAP = """# Landin roadmap

## Register

Prose about the register.

| Record | Family | What stands | Activation | Completion | Status |
| --- | --- | --- | --- | --- | --- |
| SR-1 | Usability | A refusal names nothing. | The next change to `a.py`. | It names the file. | open |
| SR-2 | Release readiness | A boundary measured. | The next board. | Measured again. | limit |
| SR-3 | Usability | Something gone. | — | — | retired: fixed long ago |
| SR-4 | Competitive optimization | A cost. | The baselines. | Lower. | scheduled {owners} |
| A1 | Language evolution | An inherited review row. | A use. | Decided. | watch |

## Retained positions

Nothing here is a row.

| SR-5 | Usability | Not in the register. | x | y | open |
""".format(owners=OWNERS)


class Move(unittest.TestCase):
    def moved(self, text, dates=None):
        scratch = Path(tempfile.mkdtemp())
        roadmap = scratch / "ROADMAP.md"
        roadmap.write_text(text, encoding="utf-8")
        dates = dates or {"SR-1": "2026-01-01", "SR-2": "2026-01-02",
                          "SR-4": "2026-01-04", "A1": "2025-12-31"}
        written = roadmap_register.move(roadmap, scratch / "register", dates)
        return {path.name: path.read_text(encoding="utf-8")
                for path in written}, scratch

    def test_every_live_row_gets_a_file_and_a_retired_one_none(self):
        files, _ = self.moved(ROADMAP)
        self.assertEqual(sorted(files), ["A1.md", "SR-1.md", "SR-2.md",
                                         "SR-4.md"])

    def test_a_row_keeps_its_cells_as_they_were(self):
        files, _ = self.moved(ROADMAP)
        self.assertEqual(files["SR-1.md"], "\n".join([
            "---", "family: Usability", "status: open",
            "opened: 2026-01-01",
            "activation: The next change to `a.py`.", "---", "",
            "A refusal names nothing.", "", "Completion: It names the file.",
            ""]))

    def test_limit_and_watch_become_open_rows_of_that_kind(self):
        files, _ = self.moved(ROADMAP)
        self.assertIn("kind: limit\n", files["SR-2.md"])
        self.assertIn("status: open\n", files["SR-2.md"])
        self.assertIn("kind: watch\n", files["A1.md"])

    def test_a_scheduled_row_keeps_its_items(self):
        files, _ = self.moved(ROADMAP)
        self.assertIn("status: scheduled %s\n" % OWNERS, files["SR-4.md"])

    def test_a_row_without_a_date_is_refused(self):
        with self.assertRaisesRegex(ValueError, "no history dates SR-2"):
            self.moved(ROADMAP, {"SR-1": "2026-01-01", "SR-4": "2026-01-04",
                                 "A1": "2025-12-31"})

    def test_a_moved_row_is_not_moved_again(self):
        _, scratch = self.moved(ROADMAP)
        with self.assertRaisesRegex(ValueError, "is not moved again"):
            roadmap_register.move(scratch / "ROADMAP.md",
                                  scratch / "register",
                                  {"SR-1": "x", "SR-2": "x", "SR-4": "x",
                                   "A1": "x"})

    def test_a_row_without_six_cells_is_refused(self):
        with self.assertRaisesRegex(ValueError, "without six cells: SR-1"):
            self.moved(ROADMAP.replace("| It names the file. | open |",
                                       "| open |"))

    def test_an_unknown_status_is_refused(self):
        with self.assertRaisesRegex(ValueError, "not a live status"):
            self.moved(ROADMAP.replace("| Lower. | scheduled %s |" % OWNERS,
                                       "| Lower. | pending |"))

    def test_a_roadmap_without_a_register_is_refused(self):
        with self.assertRaisesRegex(ValueError, "no `## Register` section"):
            self.moved("# Landin roadmap\n")

    def test_dates_come_from_the_first_commit_that_added_the_row(self):
        repository = Path(tempfile.mkdtemp())
        run = lambda *arguments, **more: subprocess.run(
            ["git", *arguments], cwd=repository, check=True,
            env=environment(**more), stdout=subprocess.DEVNULL)
        run("init", "-q")
        steps = (("2026-01-01", "notes.md", "SR-7 was met before the table.\n"),
                 ("2026-02-01", "ROADMAP.md", ROADMAP),
                 ("2026-03-01", "ROADMAP.md",
                  ROADMAP.replace("A refusal names nothing.", "Reworded.")))
        for date, name, text in steps:
            (repository / name).write_text(text, encoding="utf-8")
            run("add", name)
            run("commit", "-q", "-m", date,
                GIT_AUTHOR_DATE=date + "T12:00:00",
                GIT_COMMITTER_DATE=date + "T12:00:00")
        self.assertEqual(
            roadmap_register.first_dates(["SR-1", "A1", "SR-7"], repository),
            {"SR-1": "2026-02-01", "A1": "2026-02-01", "SR-7": "2026-01-01"})

if __name__ == "__main__":
    unittest.main()
