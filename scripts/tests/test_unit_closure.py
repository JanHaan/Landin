#!/usr/bin/env python3
"""Hold what the units that find the library link, and the closure reader."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import unit_closure  # noqa: E402


class LibraryClosure(unittest.TestCase):
    """D1386: finding the library links no front end and no driver."""

    def members(self, *roots):
        units = unit_closure.read_units()
        return {units[key].name
                for key in unit_closure.closure(units, roots)}

    def test_finding_the_library_links_four_units(self):
        # A with added to Landin.Library or Landin.Paths lands here: a
        # unit of the front end, or Landin.Driver, whose body withs all
        # of it, would be linked into every command that finds the
        # library, a split one included.
        self.assertEqual(
            self.members("Landin.Library"),
            {"Landin", "Landin.Library", "Landin.Paths", "Landin.Platform"})

    def test_path_text_stands_alone(self):
        self.assertEqual(self.members("Landin.Paths"),
                         {"Landin", "Landin.Paths"})


class ContextClauses(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="landin-units-")
        self.addCleanup(self.temporary.cleanup)
        self.sources = Path(self.temporary.name)

    def write(self, name, text):
        (self.sources / name).write_text(text, encoding="utf-8")

    def test_reads_the_context_clause_only(self):
        self.write("a.ads", "package A is\nend A;\n")
        self.write("a-b.ads",
                   "with C, D;  --  with E;\nprivate with F;\n"
                   "limited with G;\npackage A.B is\n"
                   "   procedure P\n   with Inline;\nend A.B;\n")
        self.write("a-b.adb", "with H;\npackage body A.B is\nend A.B;\n")
        for name in "cdefgh":
            self.write(name + ".ads",
                       f"package {name.upper()} is\nend {name.upper()};\n")
        self.write("inline.ads", "package Inline is\nend Inline;\n")
        units = unit_closure.read_units(self.sources)
        self.assertEqual(units["a.b"].withs,
                         {"a", "c", "d", "f", "g", "h"})
        self.assertEqual(units["a.b"].name, "A.B")

    def test_a_cut_unit_is_not_followed(self):
        self.write("a.ads", "with B;\npackage A is\nend A;\n")
        self.write("b.ads", "with C;\npackage B is\nend B;\n")
        self.write("c.ads", "package C is\nend C;\n")
        units = unit_closure.read_units(self.sources)
        self.assertEqual(unit_closure.closure(units, ["A"]),
                         {"a", "b", "c"})
        self.assertEqual(unit_closure.closure(units, ["A"], cut=["B"]),
                         {"a"})

    def parent_and_child(self):
        """P's body withs Q; P.C withs R; S withs P.C."""
        self.write("p.ads", "package P is\nend P;\n")
        self.write("p.adb", "with Q;\npackage body P is\nend P;\n")
        self.write("p-c.ads", "with R;\npackage P.C is\nend P.C;\n")
        self.write("s.ads", "with P.C;\npackage S is\nend S;\n")
        for name in "qr":
            self.write(name + ".ads",
                       f"package {name.upper()} is\nend {name.upper()};\n")
        return unit_closure.read_units(self.sources)

    def test_a_child_links_its_parents_body_withs(self):
        # D1423: the spec and body of a unit are one, so a child, through
        # its parent, links what the parent's body withs.
        units = self.parent_and_child()
        self.assertEqual(units["p"].withs, {"q"})
        self.assertEqual(unit_closure.closure(units, ["P.C"]),
                         {"p.c", "p", "q", "r"})

    def test_a_cut_parent_of_a_kept_unit_is_refused(self):
        units = self.parent_and_child()
        for roots in (["P.C"], ["S"]):
            with self.subTest(roots=roots), self.assertRaisesRegex(
                    unit_closure.CutError,
                    r"--cut P: the closure keeps its child P\.C, .*"
                    r"brings P back: \d+ units"):
                unit_closure.closure(units, roots, cut=["P"])
        # A cut that no kept unit is a child of is honoured.
        self.assertEqual(unit_closure.closure(units, ["P.C"], cut=["Q"]),
                         {"p.c", "p", "r"})

    def test_the_command_line_says_why_and_fails(self):
        self.parent_and_child()
        import contextlib
        import io
        said = io.StringIO()
        with mock.patch.object(unit_closure.measure, "__defaults__",
                               ((), None, (self.sources,))), \
                contextlib.redirect_stderr(said), \
                self.assertRaises(SystemExit) as stopped:
            unit_closure.main(["--cut", "P", "S"])
        self.assertEqual(stopped.exception.code, 2)
        self.assertIn("a real link brings P back", said.getvalue())

    def test_an_unknown_cut_is_named(self):
        units = self.parent_and_child()
        with self.assertRaisesRegex(KeyError, "no unit x"):
            unit_closure.closure(units, ["S"], cut=["X"])

    def test_an_unknown_root_is_named(self):
        units = unit_closure.read_units(self.sources)
        with self.assertRaisesRegex(KeyError, "no unit x"):
            unit_closure.closure(units, ["X"])


if __name__ == "__main__":
    unittest.main()
