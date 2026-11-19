#!/usr/bin/env python3
"""Hold what the units that find the library link, and the closure reader."""
from pathlib import Path
import sys
import tempfile
import unittest

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


class DapClosure(unittest.TestCase):
    """`refine-dap` links no front end (D1423, D1523).

    It reads source tables through Landin.Site_Tables, never
    Landin.Source_Maps, which writes them from a compilation; finds the
    library through Landin.Library; and frames its messages with the
    language server's transport, whose parent is a pure specification.
    A unit added here is a choice to make in review: one of the front
    end, the driver or `Landin.Commands`, whose body withs the whole
    compiler, would link all of it.  The generated Landin.Build_Identity,
    which names the source digest `--describe` answers with, adds
    Landin.Targets.Selection, Landin.Targets and Landin.Evidence, the
    host's target facts; a build tree's objects show it.
    """

    def test_the_adapter_links_eighteen_units(self):
        units = unit_closure.read_units()
        members = {units[key].name
                   for key in unit_closure.closure(units, ["Refine_Dap"])}
        self.assertEqual(members, {
            "Refine_Dap", "Landin", "Landin.Adapter", "Landin.Adapter.MI",
            "Landin.Adapter.Sessions", "Landin.Diagnostics",
            "Landin.Diagnostics.Catalogue", "Landin.Json", "Landin.Library",
            "Landin.Paths", "Landin.Platform", "Landin.Platform.Native",
            "Landin.Platform.Native.Byte_Strings",
            "Landin.Platform.Native.Tools", "Landin.Server",
            "Landin.Server.Transport", "Landin.Site_Tables",
            "Landin.Source"})


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

    def test_an_unknown_root_is_named(self):
        units = unit_closure.read_units(self.sources)
        with self.assertRaisesRegex(KeyError, "no unit x"):
            unit_closure.closure(units, ["X"])


if __name__ == "__main__":
    unittest.main()
