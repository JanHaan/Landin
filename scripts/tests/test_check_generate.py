#!/usr/bin/env python3
"""check.py's generator flags: one for everything, several at once, refusals.

Every generator is replaced by a recorder, so nothing here writes into
the tree; what is under test is which generators main runs, in which
order, and what it refuses.
"""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("landin_check", ROOT / "check.py")
CHECK = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CHECK)

ORDER = ["--tokens", "--catalogue", "--coverage", "--matrix", "highlighters"]


class GeneratorFlags(unittest.TestCase):
    def run_main(self, *arguments, failing=None):
        """(status, generators run, output) for check.py with arguments."""
        ran = []

        def recorder(name):
            def run():
                ran.append(name)
                return 2 if name == failing else 0
            return run

        generators = tuple((flag, recorder(flag))
                           for flag, _ in CHECK.GENERATORS)
        output = io.StringIO()
        here = os.getcwd()
        try:
            with patch.object(CHECK, "GENERATORS", generators), \
                    patch.object(CHECK, "generate_highlighters",
                                 recorder("highlighters")), \
                    patch.object(CHECK, "check", side_effect=AssertionError(
                        "a generator flag must not check files")), \
                    contextlib.redirect_stdout(output):
                status = CHECK.main(["check.py", *arguments])
        finally:
            os.chdir(here)
        return status, ran, output.getvalue()

    def test_the_generators_are_the_ones_named(self):
        self.assertEqual([flag for flag, _ in CHECK.GENERATORS], ORDER[:-1])

    def test_generate_runs_every_generator_in_order(self):
        self.assertEqual(self.run_main("--generate")[:2], (0, ORDER))

    def test_several_flags_run_each_in_a_fixed_order(self):
        status, ran, _ = self.run_main("--matrix", "--tokens", "--catalogue")
        self.assertEqual(status, 0)
        self.assertEqual(ran, ["--tokens", "--catalogue", "--matrix"])
        self.assertEqual(self.run_main("--coverage", "--catalogue")[1],
                         ["--catalogue", "--coverage"])

    def test_one_flag_runs_one_generator(self):
        for flag in ORDER[:-1]:
            with self.subTest(flag=flag):
                self.assertEqual(self.run_main(flag)[:2], (0, [flag]))

    def test_a_repeated_flag_runs_once(self):
        self.assertEqual(self.run_main("--tokens", "--tokens")[1],
                         ["--tokens"])

    def test_a_failing_generator_stops_the_run_and_fails(self):
        status, ran, _ = self.run_main("--generate", failing="--catalogue")
        self.assertEqual(status, 2)
        self.assertEqual(ran, ["--tokens", "--catalogue"])

    def test_a_flag_with_a_path_is_refused(self):
        for arguments in (("--tokens", "spec.md"), ("spec.md", "--generate")):
            with self.subTest(arguments=arguments):
                status, ran, said = self.run_main(*arguments)
                self.assertEqual(status, 2)
                self.assertEqual(ran, [])
                self.assertIn("takes no file", said)
                self.assertIn("--generate", said)

    def test_help_prints_the_usage_and_runs_nothing(self):
        for flag in ("--help", "-h"):
            with self.subTest(flag=flag):
                status, ran, said = self.run_main(flag)
                self.assertEqual((status, ran), (0, []))
                self.assertEqual(said.strip(), CHECK.usage())

    def test_an_unknown_flag_is_refused_naming_the_valid_ones(self):
        for arguments in (("--bogus",), ("--generate", "--bogus"),
                          ("spec.md", "--bogus")):
            with self.subTest(arguments=arguments):
                status, ran, said = self.run_main(*arguments)
                self.assertEqual(status, 2)
                self.assertEqual(ran, [])
                self.assertIn("--bogus", said)
                for flag in ["--generate"] + ORDER[:-1]:
                    self.assertIn(flag, said)


class GeneratedFiles(unittest.TestCase):
    """Each generated file is named by the flag that writes it.

    The usage line once let --matrix read as regenerating
    compiler/tests/diagnostics.matrix, which only --catalogue writes.
    """

    def test_the_table_has_a_row_for_each_generator(self):
        self.assertEqual([flag for flag, _ in CHECK.GENERATED],
                         [flag for flag, _ in CHECK.GENERATORS])

    def test_each_generator_writes_the_files_its_row_names(self):
        #  The real generators over the real tree, with the writes caught,
        #  so what is compared is what each one would write.
        for flag, run in CHECK.GENERATORS:
            with self.subTest(flag=flag):
                written = []
                with patch.object(CHECK, "write_generated",
                                  lambda path, _: written.append(path)), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(run(), 0)
                self.assertEqual(sorted(written),
                                 sorted(dict(CHECK.GENERATED)[flag]))

    def test_the_usage_names_each_file_beside_its_flag(self):
        lines = CHECK.usage().splitlines()
        for flag, files in CHECK.GENERATED:
            with self.subTest(flag=flag):
                at = next(n for n, line in enumerate(lines)
                          if line.split()[2:3] == [flag])
                named = [lines[at].split()[-1]] + [
                    line.strip() for line in lines[at + 1:at + len(files)]]
                self.assertEqual(named, list(files))
                self.assertIn("--generate (or %s)" % flag,
                              CHECK.regenerating(files[-1]))

    def test_a_stale_file_message_names_its_flag_from_the_table(self):
        #  A message spelling its flag out is a second place to get it
        #  wrong; regenerating() is the one.
        source = (ROOT / "check.py").read_text(encoding="utf-8")
        self.assertNotRegex(source, r"--generate \(or --")
        with self.assertRaises(KeyError):
            CHECK.regenerating("compiler/tests/unknown.matrix")


class GeneratedWrite(unittest.TestCase):
    def test_bytes_mtime_and_mode(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root, \
                patch.object(CHECK, "ROOT", root):
            path = Path(root) / "generated"
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                CHECK.write_generated("generated", "café\n")
                path.chmod(0o640)
                os.utime(path, ns=(1_000_000_000, 1_000_000_000))
                CHECK.write_generated("generated", "café\n")
                self.assertEqual(path.stat().st_mtime_ns, 1_000_000_000)
                CHECK.write_generated("generated", "café\r\n")
            self.assertEqual(path.read_bytes(), "café\r\n".encode())
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(output.getvalue().splitlines(),
                             ["wrote generated", "unchanged generated",
                              "wrote generated"])

    def test_read_failure_is_not_treated_as_a_missing_file(self):
        #  A file that cannot be read is not one to write afresh: the
        #  error stops the write and nothing is created where it was.
        import tempfile
        with tempfile.TemporaryDirectory() as root, \
                patch.object(CHECK, "ROOT", root), \
                patch.object(CHECK, "read_file", side_effect=PermissionError), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(PermissionError):
                CHECK.write_generated("generated", "x")
            self.assertEqual(os.listdir(root), [])
        self.assertEqual(output.getvalue(), "")


class GeneratorRefusals(unittest.TestCase):
    """A generator that cannot generate prints what stopped it."""

    def generate(self, generator):
        output = io.StringIO()
        with patch.object(CHECK, "write_generated",
                          side_effect=AssertionError("nothing is written")), \
                contextlib.redirect_stdout(output):
            status = generator()
        return status, output.getvalue()

    def test_an_unexplained_code_is_named(self):
        sections, problems = CHECK.explanation_sections()
        code = next(iter(sections))
        less = {key: value for key, value in sections.items() if key != code}
        with patch.object(CHECK, "explanation_sections",
                          return_value=(less, problems)):
            status, output = self.generate(CHECK.generate_catalogue)
        self.assertEqual(status, 2)
        self.assertIn("the explanations could not be generated; fix these"
                      " first:", output)
        self.assertIn("docs/diagnostics.md:1  %s is not explained" % code,
                      output)
        self.assertNotIn("run check.py", output)

    def test_a_page_problem_is_named(self):
        sections, _ = CHECK.explanation_sections()
        with patch.object(CHECK, "explanation_sections", return_value=(
                sections, [("docs/diagnostics.md", 40, "two examples")])):
            status, output = self.generate(CHECK.generate_catalogue)
        self.assertEqual(status, 2)
        self.assertIn("docs/diagnostics.md:40  two examples", output)

    def test_an_unreadable_coverage_register_is_named(self):
        register = (CHECK.SPEC_NAME, "#### No such coverage",
                    CHECK.GUARANTEE_REGISTER[2])
        with patch.object(CHECK, "GUARANTEE_REGISTER", register):
            status, output = self.generate(CHECK.generate_coverage)
        self.assertEqual(status, 2)
        self.assertIn("the coverage registers could not be generated", output)
        self.assertIn("spec.md:1  no heading '#### No such coverage'", output)

    def test_a_register_whose_columns_differ_is_named(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root, \
                patch.object(CHECK, "ROOT", root):
            Path(root, "r.md").write_text(
                "## R\n\n| A | C |\n|---|---|\n| 1 | 2 |\n")
            self.assertEqual(CHECK.table_problems("r.md", "## R", ("A", "B")),
                             [("r.md", 3, "the table's columns are A | C,"
                               " not A | B")])
            Path(root, "r.md").write_text(
                "## R\n\n| A | B |\n|---|---|\n| 1 |\n")
            self.assertEqual(CHECK.table_problems("r.md", "## R", ("A", "B")),
                             [("r.md", 5, "this row has 1 cells, not 2")])


if __name__ == "__main__":
    unittest.main()
