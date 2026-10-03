#!/usr/bin/env python3
"""Exercise the equivalence wrapper without building the Ada harness."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
PASS = "fixture execution\n  pass  one\n\ncases 1, passed 1, failed 0, checks 1\n"
FAIL = "fixture execution\n  FAIL  one\n  mismatch\n\ncases 1, passed 0, failed 1, checks 1\n"


class ParallelEquivalence(unittest.TestCase):
    def run_wrapper(self, sequential, parallel=None, statuses=(0, 0)):
        if parallel is None:
            parallel = sequential
        with tempfile.TemporaryDirectory(prefix="landin-parallel-") as tmp:
            scripts = Path(tmp) / "scripts"
            scripts.mkdir()
            for name in ("parallel-equivalence.sh", "env.sh"):
                shutil.copy2(SCRIPTS / name, scripts / name)
            test = scripts / "test.sh"
            test.write_text(
                "#!/bin/sh\n"
                "if [ \"$LANDIN_TEST_JOBS\" = 1 ]; then\n"
                f"  printf %s {shlex.quote(sequential)}\n"
                f"  exit {statuses[0]}\n"
                "fi\n"
                f"printf %s {shlex.quote(parallel)}\n"
                f"exit {statuses[1]}\n"
            )
            test.chmod(0o755)
            return subprocess.run(
                [str(scripts / "parallel-equivalence.sh"),
                 "--suite=fixture execution"],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, "LANDIN_BUILD_TAG": "test"},
            )

    def test_identical_setup_failure_is_not_equivalent(self):
        result = self.run_wrapper("landin: gprbuild is not on PATH\n",
                                  statuses=(127, 127))
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not complete", result.stderr)

    def test_no_matching_cases_is_not_equivalent(self):
        result = self.run_wrapper(
            "cases 0, passed 0, failed 0, checks 0\n", statuses=(1, 1))
        self.assertEqual(result.returncode, 1)

    def test_summary_requires_case_rows(self):
        result = self.run_wrapper("cases 1, passed 1, failed 0, checks 1\n")
        self.assertEqual(result.returncode, 1)

    def test_identical_passes_and_failures_are_equivalent(self):
        for transcript, status in ((PASS, 0), (FAIL, 1)):
            with self.subTest(status=status):
                result = self.run_wrapper(transcript, statuses=(status, status))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("identical at 1 and 8 jobs", result.stdout)

    def test_harness_status_must_match_summary(self):
        for statuses in ((0, 1), (127, 127), (0, 0)):
            with self.subTest(statuses=statuses):
                transcript = PASS if statuses != (0, 0) else FAIL
                result = self.run_wrapper(transcript, statuses=statuses)
                self.assertEqual(result.returncode, 1)

    def test_duplicate_summary_is_not_a_complete_run(self):
        result = self.run_wrapper(PASS + "cases 1, passed 1, failed 0, checks 1\n")
        self.assertEqual(result.returncode, 1)

    def test_different_case_verdicts_are_not_equivalent(self):
        result = self.run_wrapper(PASS, FAIL, statuses=(0, 1))
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
