#!/usr/bin/env python3
"""Hold the parallel scripts/tests runner to what the serial loop did."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "script_tests.py"

#  A stand-in for the sharded module: each case records that it ran.
SHARDED = '''import os, unittest

class Cases(unittest.TestCase):
%s

if __name__ == "__main__":
    unittest.main()
'''
CASE = '''    def test_%d(self):
        open(os.path.join(os.environ["RAN"], "%d"), "x").close()
'''


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="landin-scripts-")
        self.addCleanup(self.temporary.cleanup)
        self.tests = Path(self.temporary.name) / "tests"
        self.ran = Path(self.temporary.name) / "ran"
        self.tests.mkdir()
        self.ran.mkdir()

    def module(self, name, body):
        (self.tests / name).write_text(body)

    def run_runner(self, *arguments, operands=None, **options):
        if operands is None:
            operands = [str(self.tests)]
        return subprocess.run(
            [sys.executable, str(RUNNER), *arguments, *operands],
            capture_output=True, text=True, timeout=60,
            env={"RAN": str(self.ran), "PATH": "/usr/bin:/bin"}, **options)

    def test_every_sharded_case_runs_exactly_once(self):
        self.module("test_check_controls.py", SHARDED % "".join(
            CASE % (n, n) for n in range(10)))
        result = self.run_runner("--jobs=3")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(sorted(p.name for p in self.ran.iterdir()),
                         sorted(str(n) for n in range(10)))
        self.assertEqual(result.stdout.count("(shard "), 3)

    def test_one_job_runs_the_module_whole(self):
        self.module("test_check_controls.py", SHARDED % (CASE % (1, 1)))
        result = self.run_runner("--jobs=1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("(shard ", result.stdout)

    def test_a_failing_module_fails_the_run_and_is_named(self):
        self.module("test_a.py", "import sys\nsys.exit(0)\n")
        self.module("test_b.py", "print('b said this')\nraise SystemExit(1)\n")
        result = self.run_runner("--jobs=2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("b said this", result.stdout)
        self.assertIn("FAILED: ", result.stdout)
        self.assertIn("test_b.py", result.stdout.split("FAILED: ", 1)[1])

    def test_a_module_that_leaves_a_file_open_fails_the_run(self):
        self.module("test_open.py", "import unittest\n\n"
                    "class Cases(unittest.TestCase):\n"
                    "    def test_reads(self):\n"
                    "        open(__file__).read()\n\n"
                    "unittest.main()\n")
        result = self.run_runner("--jobs=1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAILED: ", result.stdout)
        self.assertIn("test_open.py (left a file or socket open",
                      result.stdout.split("FAILED: ", 1)[1])

    def test_output_is_in_module_order_whatever_finishes_first(self):
        self.module("test_a.py", "import time\ntime.sleep(1)\nprint('first')\n")
        self.module("test_b.py", "print('second')\n")
        result = self.run_runner("--jobs=2")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertLess(result.stdout.index("first"),
                        result.stdout.index("second"))

    def test_named_modules_run_alone(self):
        for name in ("a", "b", "c"):
            self.module("test_%s.py" % name, "print('ran %s')\n" % name)
        result = self.run_runner("--jobs=2", operands=[
            str(self.tests / "test_c.py"), str(self.tests / "test_a.py")])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ran a", result.stdout)
        self.assertIn("ran c", result.stdout)
        self.assertNotIn("ran b", result.stdout)
        self.assertIn("== 2 processes", result.stdout)
        #  In the order given, not the directory's.
        self.assertLess(result.stdout.index("ran c"),
                        result.stdout.index("ran a"))

    def test_a_module_is_named_as_in_scripts_tests(self):
        #  By name, with or without .py, each module once.
        listed = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, %r); import script_tests;"
             " print([p.name for p in script_tests.modules("
             "['test_fuzz_close', 'test_scaling.py', 'test_fuzz_close'])])"
             % str(RUNNER.parent)],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertEqual(listed.stdout.strip(),
                         "['test_fuzz_close.py', 'test_scaling.py']")

    def test_an_unknown_module_is_refused_naming_scripts_tests(self):
        self.module("test_a.py", "print('ran a')\n")
        result = self.run_runner(operands=[str(self.tests),
                                           "test_no_such_module"])
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertNotIn("ran a", result.stdout)
        self.assertIn("test_no_such_module is neither", result.stderr)
        self.assertIn("scripts/tests", result.stderr)

    def test_each_module_reads_no_input_from_the_caller(self):
        #  A socket on the caller's standard input once changed what a
        #  module's `bash -c` read at startup; every module gets /dev/null.
        self.module("test_stdin.py", "import os, sys\n"
                    "same = os.path.samestat(os.fstat(0),"
                    " os.stat(os.devnull))\n"
                    "print('stdin is /dev/null' if same else"
                    " 'stdin is the caller\\'s')\n"
                    "sys.exit(0 if same else 1)\n")
        result = self.run_runner(input="caller\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("stdin is /dev/null", result.stdout)


if __name__ == "__main__":
    unittest.main()
