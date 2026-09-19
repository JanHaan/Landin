#!/usr/bin/env python3
"""Tiny malformed controls for R7.30's terminal dispositions.

Each control alters one row of ROADMAP.md's inherited review register, or
the successor entry that must name it, and requires `migration_problems` to
refuse the result. The unaltered roadmap must produce none.
"""
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("landin_check", ROOT / "check.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class Register(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (ROOT / "ROADMAP.md").read_text(encoding="utf-8")

    def row(self, legacy_id):
        appendix = self.text[self.text.index(CHECK.MIGRATION_HEADING):]
        return next(line for line in appendix.splitlines()
                    if line.startswith("| %s — " % legacy_id))

    def problems(self, old, new):
        self.assertIn(old, self.text)
        return [message for _, message in
                CHECK.migration_problems(self.text.replace(old, new, 1))]

    def refused(self, old, new, fragment):
        messages = self.problems(old, new)
        self.assertTrue(any(fragment in message for message in messages),
                        "%r not in %r" % (fragment, messages))

    def test_the_repository_register_is_complete(self):
        self.assertEqual(CHECK.migration_problems(self.text), [])

    def test_every_row_needs_the_new_shape_and_a_disposition(self):
        row = self.row("A2")
        self.refused(row, row.rsplit(" | ", 2)[0] + " |",
                     "malformed legacy migration row A2")
        self.refused(row, row.replace("| implemented |", "| done |"),
                     "A2 has no terminal disposition")
        self.refused(row, row.rsplit(" | ", 1)[0] + " | TBD |",
                     "A2 records no disposition evidence")

    def test_rows_stay_whole_and_anchored(self):
        row = self.row("C5")
        self.refused(row + "\n", "", "legacy migration row C5 is missing")
        self.refused(row, row + "\n" + row, "legacy migration row C5 is duplicated")
        self.refused(row, row.replace("`[0620]`", "the design record"),
                     "C5 migration row omits required anchors")

    def test_implemented_and_rejected_rows_cite_a_finished_item(self):
        row = self.row("D4")
        stripped = row.replace("Implement in R2.50;", "Implement it;") \
                      .replace("R2.50 implements", "The compiler implements")
        self.refused(row, stripped, "D4 is implemented and cites no finished roadmap item")
        self.refused(row, stripped.replace("| implemented |", "| rejected |"),
                     "D4 is rejected and cites no finished roadmap item")

    def test_a_transfer_names_one_listed_successor(self):
        row = self.row("C3")
        self.refused(row, row.replace("transfer to Language evolution",
                                      "transfer to Somebody"),
                     "C3 is transferred and its owner names 0 successors")
        self.refused(row, row.replace("transfer to Language evolution",
                                      "transfer to Language evolution or"
                                      " Release readiness"),
                     "C3 is transferred and its owner names 2 successors")
        entry = "inherited C1, C2, C3, C4 and C5"
        self.refused(entry, "inherited C1, C2, C4 and C5",
                     "C3 is transferred to Language evolution, whose entry")

    def test_a_transfer_carries_activation_and_completion(self):
        row = self.row("E3")
        self.refused(row, row.replace("Activation:", "When:"),
                     "E3 is transferred without an Activation:")
        cut = row.index("Completion:")
        self.refused(row, row[:cut] + "Completion: |",
                     "E3 is transferred without an Activation:")

    def test_a_decided_row_cannot_hide_as_implemented(self):
        #  Changing a transfer to implemented needs a finished item's evidence.
        row = self.row("C4")
        self.refused(row, row.replace("| transferred |", "| implemented |"),
                     "C4 is implemented and cites no finished roadmap item")


if __name__ == "__main__":
    unittest.main()
