#!/usr/bin/env python3
"""Hold what the units that find the library and the split commands link,
and the closure reader."""
import json
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


class SplitClosures(unittest.TestCase):
    """D1543: each split command's main links none of the front end.

    A split shares `refine`'s library and is held to the units its own
    work needs: what every split's process surface links (SURFACE), and
    each command's own units.  A with that brings in the scanner, the
    parser, the checker, the IR, a backend, Landin.Driver or
    Landin.Commands, whose bodies with the whole compiler, lands here.
    The generated Landin.Build_Identity is under the build tree, not the
    sources this reads, and is left out.
    """

    SURFACE = {
        "Landin",
        "Landin.Byte_Encoding",
        "Landin.Diagnostics",
        "Landin.Diagnostics.Catalogue",
        "Landin.Diagnostics.Suggestions",
        "Landin.Diagnostics.Text",
        "Landin.Evidence",
        "Landin.Json",
        "Landin.Outcomes",
        "Landin.Platform",
        "Landin.Platform.Native",
        "Landin.Platform.Native.Byte_Strings",
        "Landin.Platform.Native.Tools",
        "Landin.Presentation",
        "Landin.Response_Files",
        "Landin.Source",
        "Landin.Source.Sets",
        "Landin.Splits",
        "Landin.Splits.Native",
        "Landin.Targets",
        "Landin.Targets.Selection",
}

    OWN = {
        "svd": {"Refine_Svd", "Landin.Splits.Svd", "Landin.Devices",
                "Landin.Devices.Policies", "Landin.Devices.Projection",
                "Landin.Platform.Publication", "Landin.Source.Names",
                "Landin.Targets.Assembly", "Landin.Targets.Firmware",
                "Landin.Targets.Levels", "Landin.Targets.RiscV_ISA",
                "Landin.Tokens", "Landin.Xml"},
        "bindings": {"Refine_Bindings", "Landin.Splits.Bindings",
                     "Landin.Bindings", "Landin.Bindings.Clang",
                     "Landin.Bindings.Generation",
                     "Landin.Bindings.Policies", "Landin.Bindings.Texts",
                     "Landin.Platform.Publication", "Landin.Source.Names",
                     "Landin.Tokens", "Landin.Types"},
        "site": {"Refine_Site", "Landin.Splits.Site", "Landin.Site_Tables"},
    }

    #  A split that takes no part of Landin.Splits, pinned by a case of
    #  its own.
    APART = {"dap": "DapClosure"}

    def test_each_listed_split_has_its_pin(self):
        # A split command entered in the one list (D1483) is pinned here
        # in the same change.
        listed = json.loads((ROOT / "compiler/ada/split-commands.json")
                            .read_text(encoding="utf-8"))["commands"]
        for entry in listed:
            with self.subTest(split=entry["name"]):
                self.assertIn(entry["name"], {*self.OWN, *self.APART})

    def test_each_split_links_its_own_units_and_the_surface(self):
        units = unit_closure.read_units()
        for name, own in self.OWN.items():
            main = "Refine_" + name.capitalize()
            with self.subTest(split=name):
                self.assertEqual(
                    {units[key].name
                     for key in unit_closure.closure(units, [main])},
                    self.SURFACE | own)


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
