#!/usr/bin/env python3
"""check.py holds the tour's examples to what a scan sees of the layout."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("landin_check", ROOT / "check.py")
CHECK = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CHECK)


def problems(source):
    _, trees, _ = CHECK.read_grammar(os.path.join(CHECK.ROOT, CHECK.SPEC_NAME))
    tokens, complaint = CHECK.landin_tokens(source, CHECK.grammar_signs(trees))
    assert tokens is not None, complaint
    return [complaint for _, complaint in
            CHECK.tour_layout_problems(source, tokens)]


class TourLayout(unittest.TestCase):
    def test_the_layout_passes(self):
        self.assertEqual(problems(
            "f: (n: i32) -> none =\n"
            "    g(n) -- one space before a comment\n"
            "\n"
            "    help := \"\"\"\n"
            "        aligned  inside   a raw literal  \n"
            "\n"
            "\n"
            "        \"\"\"\n"
            "end f\n"), [])

    def test_aligned_columns_are_reported(self):
        self.assertEqual(problems("tiny:  u8 = 5\n"),
                         ["2 spaces between two tokens, where the layout has"
                          " one or none"])
        self.assertEqual(problems("x := 1      -- a comment\n"),
                         ["a comment after code stands one space after it"])
        self.assertEqual(problems("x := 1\ny := 2  -- last\n"),
                         ["a comment after code stands one space after it"])

    def test_blank_lines_and_line_ends_are_reported(self):
        self.assertEqual(problems("x := 1 \n"), ["space at the end of a line"])
        self.assertEqual(problems("x := 1\n\n\ny := 2\n"),
                         ["a run of blank lines, which the layout makes one"])
        self.assertEqual(problems("x := 1\n\n"),
                         ["a blank line at an end of the example"])

    def test_the_tour_is_held_and_an_exemption_needs_its_reason(self):
        self.assertEqual(CHECK.check_tour_layout(True), [])
        saved = CHECK.TOUR_NAME
        self.addCleanup(setattr, CHECK, "TOUR_NAME", saved)
        with tempfile.TemporaryDirectory() as directory:
            tour = Path(directory) / "tour.md"
            tour.write_text(
                "```landin\ntiny:  u8 = 5\n```\n"
                "```landin\n-- not in the layout: columns, to compare\n"
                "tiny:  u8 = 5\n```\n"
                "```landin\n-- not in the layout:\ntiny:  u8 = 5\n```\n"
                "## WHAT WAS TRIED AND DROPPED\n"
                "```landin\ntiny:  u8 = 5\n```\n")
            CHECK.TOUR_NAME = str(tour)
            found = CHECK.check_tour_layout(True)
        self.assertEqual([line for _, line, _ in found], [2, 9])
        self.assertIn("2 spaces", found[0][2])
        self.assertIn("says what it shows", found[1][2])

    def test_a_placeholder_body_is_refused(self):
        # `... end` bodies parse nowhere, and a reader copies them.
        saved = CHECK.TOUR_NAME
        self.addCleanup(setattr, CHECK, "TOUR_NAME", saved)
        with tempfile.TemporaryDirectory() as directory:
            tour = Path(directory) / "tour.md"
            tour.write_text(
                "```landin\nf: () -> none = ... end\n```\n"
                "```landin\nt: type = struct ... end t\n```\n"
                "```landin\ng: () -> none ! ... =\n    h()\nend g\n```\n"
                "## WHAT WAS TRIED AND DROPPED\n"
                "```landin\nf: () -> none = ... end\n```\n")
            CHECK.TOUR_NAME = str(tour)
            found = CHECK.check_tour_layout(True)
        self.assertEqual([line for _, line, _ in found], [2, 5])
        self.assertTrue(all("placeholder" in what for _, _, what in found))


if __name__ == "__main__":
    unittest.main()
