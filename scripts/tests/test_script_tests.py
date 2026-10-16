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

    def run_runner(self, *arguments):
        return subprocess.run(
            [sys.executable, str(RUNNER), *arguments, str(self.tests)],
            capture_output=True, text=True, timeout=60,
            env={"RAN": str(self.ran), "PATH": "/usr/bin:/bin"})

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

    def test_output_is_in_module_order_whatever_finishes_first(self):
        self.module("test_a.py", "import time\ntime.sleep(1)\nprint('first')\n")
        self.module("test_b.py", "print('second')\n")
        result = self.run_runner("--jobs=2")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertLess(result.stdout.index("first"),
                        result.stdout.index("second"))


if __name__ == "__main__":
    unittest.main()
