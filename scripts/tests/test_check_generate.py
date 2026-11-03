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
                with patch.object(CHECK, "write_file",
                                  lambda path, _: written.append(
                                      os.path.relpath(path, CHECK.ROOT))), \
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


if __name__ == "__main__":
    unittest.main()
