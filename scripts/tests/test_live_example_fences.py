#!/usr/bin/env python3
"""Every live Landin fence accepted by sections receives lexical checking."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("landin_check", ROOT / "check.py")
CHECK = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CHECK)


class LiveExampleFences(unittest.TestCase):
    def test_accepted_fences_are_checked_before_findings(self):
        document = (
            "Intro\n"
            "```landin\n"
            "x: i32 = @\n"
            "```\n"
            "```landin  \n"
            "x: i32 = @\n"
            "```\n"
            "  ```landin\t\n"
            "x: i32 = @\n"
            "  ```\n"
            "```landin-grammar\n"
            "x: i32 = @\n"
            "```\n"
            "## WHAT THIS ONE FOUND\n"
            "```landin\n"
            "x: i32 = @\n"
            "```\n")
        self.assertEqual([kind for kind, _, _ in CHECK.sections(
            document.splitlines(keepends=True)) if kind == "landin"],
            ["landin"] * 4)
        expected = [
            (2, "live Landin example: no rule spells '@'"),
            (5, "live Landin example: no rule spells '@'"),
            (8, "live Landin example: no rule spells '@'")]
        self.assertEqual(CHECK.live_example_tokens(document), expected)


if __name__ == "__main__":
    unittest.main()
