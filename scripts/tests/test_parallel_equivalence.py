#!/usr/bin/env python3
"""Exercise the equivalence wrapper without building the Ada harness."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

#  Seconds before a subprocess here is called hung.  It ends in well under
#  a second on an idle host; the limit only stops a hang, and is wide
#  because scripts/script_tests.py's own workers load the host.
HANG = 300


SCRIPTS = Path(__file__).resolve().parents[1]
PASS = "fixture execution\n  pass  one\n\ncases 1, passed 1, failed 0, checks 1\n"
FAIL = "fixture execution\n  FAIL  one\n  mismatch\n\ncases 1, passed 0, failed 1, checks 1\n"


class ParallelEquivalence(unittest.TestCase):
    def run_wrapper(self, sequential, parallel=None, statuses=(0, 0),
                    errors=("", ""), build_status=0):
        if parallel is None:
            parallel = sequential
        with tempfile.TemporaryDirectory(prefix="landin-parallel-") as tmp:
            root = Path(tmp)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("parallel-equivalence.sh", "env.sh", "build_lock.py"):
                shutil.copy2(SCRIPTS / name, scripts / name)
            (root / "compiler/ada").mkdir(parents=True)
            harness = root / "fake-tests"
            harness.write_text(
                "#!/bin/sh\n"
                f"python3 {shlex.quote(str(scripts / 'build_lock.py'))} "
                "--check mode || exit 97\n"
                #  The property, rather than timing tables, is being tested.
                '[ "${LANDIN_TEST_TIMINGS+x}" != x ] || exit 99\n'
                'printf "%s\\n" "$LANDIN_TEST_JOBS:$*" >> "'
                + str(root / "invocations") + '"\n'
                'if [ "$LANDIN_TEST_JOBS" = 1 ]; then\n'
                f"  printf %s {shlex.quote(sequential)}\n"
                f"  printf %s {shlex.quote(errors[0])} >&2\n"
                f"  exit {statuses[0]}\n"
                "fi\n"
                f"printf %s {shlex.quote(parallel)}\n"
                f"printf %s {shlex.quote(errors[1])} >&2\n"
                f"exit {statuses[1]}\n"
            )
            harness.chmod(0o755)
            build = scripts / "build.sh"
            build.write_text(
                "#!/bin/sh\n"
                f"python3 {shlex.quote(str(scripts / 'build_lock.py'))} "
                "--check mode || exit 97\n"
                'printf "build\\n" >> "' + str(root / "builds") + '"\n'
                "echo 'one-time build recovery'\n"
                "echo 'build diagnostic' >&2\n"
                f"[ {build_status} = 0 ] || exit {build_status}\n"
                'mkdir -p "$LANDIN_BUILD_DIR/bin"\n'
                f'cp {shlex.quote(str(harness))} '
                '"$LANDIN_BUILD_DIR/bin/landin_tests"\n'
            )
            build.chmod(0o755)
            #  The wrapper must not rebuild through test.sh for each run.
            test = scripts / "test.sh"
            test.write_text("#!/bin/sh\nexit 98\n")
            test.chmod(0o755)
            evidence = root / "evidence"
            result = subprocess.run(
                [str(scripts / "parallel-equivalence.sh"),
                 "--suite=fixture execution", "--output=" + str(evidence)],
                capture_output=True, text=True, timeout=HANG,
                env={**os.environ, "LANDIN_BUILD_TAG": "test",
                     "LANDIN_TEST_TIMINGS": "yes"},
            )
            result.evidence = {p.name: p.read_text()
                               for p in evidence.iterdir()}
            result.builds = (root / "builds").read_text().splitlines()
            invoked = root / "invocations"
            result.invocations = (invoked.read_text().splitlines()
                                  if invoked.exists() else [])
            return result

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

    def test_build_once_and_keep_its_separate_diagnostics(self):
        result = self.run_wrapper(PASS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.builds, ["build"])
        self.assertEqual(result.invocations,
                         ["1:--suite=fixture execution",
                          "8:--suite=fixture execution"])
        self.assertEqual(result.evidence["build.stdout"],
                         "one-time build recovery\n")
        self.assertEqual(result.evidence["build.stderr"], "build diagnostic\n")
        self.assertEqual(result.evidence["one-job.stdout"], PASS)
        self.assertEqual(result.evidence["many-jobs.stdout"], PASS)
        self.assertIn("LANDIN_TEST_JOBS=1", result.evidence["one-job.command"])
        self.assertIn("--suite=fixture execution",
                      result.evidence["many-jobs.command"])

    def test_build_failure_is_retained_and_never_runs_cases(self):
        result = self.run_wrapper(PASS, build_status=12)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.invocations, [])
        self.assertEqual(result.evidence["build.status"], "12\n")
        self.assertIn("build diagnostic", result.stderr)

    def test_only_progress_elapsed_time_is_normalized(self):
        errors = ("progress: fixture execution: 1 cases, 0 failed, 12.3s\n",
                  "progress: fixture execution: 1 cases, 0 failed, 0.1s\n")
        result = self.run_wrapper(PASS, errors=errors)
        self.assertEqual(result.returncode, 0, result.stderr)
        for prefix, raw in zip(("one-job", "many-jobs"), errors):
            self.assertEqual(result.evidence[prefix + ".stderr"], raw)
        self.assertEqual(result.evidence["stderr.diff"], "")

    def test_progress_counts_suite_order_and_unknown_errors_still_compare(self):
        first = "progress: fixture execution: 1 cases, 0 failed, 1.0s\n"
        for other in (
                "progress: fixture execution: 2 cases, 0 failed, 2.0s\n",
                "progress: fixture execution: 1 cases, 1 failed, 2.0s\n",
                "progress: another suite: 1 cases, 0 failed, 2.0s\n",
                first + "unexpected error\n",
                "progress: malformed duration 2.0s\n"):
            with self.subTest(other=other):
                result = self.run_wrapper(PASS, errors=(first, other))
                self.assertEqual(result.returncode, 1)
                self.assertNotEqual(result.evidence["stderr.diff"], "")
        second = "progress: other: 1 cases, 0 failed, 0.0s\n"
        result = self.run_wrapper(PASS, errors=(first + second, second + first))
        self.assertEqual(result.returncode, 1)

    def test_fixture_lines_compare_by_verdict_and_not_by_order(self):
        #  A corpus case tells standard error each fixture's verdict as
        #  its worker ends, so the order and the counts are the workers'.
        case = "fixture: runtime fixtures execute: runtime/"
        one = (case + "a: pass (1 of 2)\n" + case + "b: pass (2 of 2)\n"
               "progress: fixture execution: 1 cases, 0 failed, 9.0s\n")
        many = (case + "b: pass (1 of 2)\n" + case + "a: pass (2 of 2)\n"
                "progress: fixture execution: 1 cases, 0 failed, 1.0s\n")
        result = self.run_wrapper(PASS, errors=(one, many))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.evidence["one-job.stderr"], one)
        self.assertEqual(result.evidence["many-jobs.stderr"], many)
        self.assertEqual(
            result.evidence["many-jobs.stderr.comparison"],
            "progress: fixture execution: 1 cases, 0 failed, <TIME>\n"
            + case + "a: pass\n" + case + "b: pass\n")
        self.assertIn("progress: ", result.stdout)
        self.assertIn("one-job.stderr", result.stdout)
        #  A fixture whose verdict differs, or that one run never
        #  reached, is still a difference.
        for other in (many.replace("a: pass", "a: FAIL"),
                      many.replace(case + "a: pass (2 of 2)\n", "")):
            with self.subTest(other=other):
                result = self.run_wrapper(PASS, errors=(one, other))
                self.assertEqual(result.returncode, 1)
                self.assertNotEqual(result.evidence["stderr.diff"], "")

    def test_progress_like_stdout_is_not_normalized(self):
        first = PASS + "progress: suite: 1 cases, 0 failed, 1.0s\n"
        second = first.replace("1.0s", "2.0s")
        result = self.run_wrapper(first, second)
        self.assertEqual(result.returncode, 1)
        self.assertIn("2.0s", result.evidence["stdout.diff"])

    def test_matching_unknown_stderr_is_retained(self):
        diagnostic = "unknown diagnostic: 1.0s\n"
        result = self.run_wrapper(PASS, errors=(diagnostic, diagnostic))
        self.assertEqual(result.returncode, 0, result.stderr)
        for prefix in ("one-job", "many-jobs"):
            self.assertEqual(result.evidence[prefix + ".stderr.comparison"],
                             diagnostic)

    def test_changed_failure_details_are_not_hidden(self):
        result = self.run_wrapper(FAIL, FAIL.replace("mismatch", "other error"),
                                  statuses=(1, 1))
        self.assertEqual(result.returncode, 1)
        self.assertIn("other error", result.evidence["stdout.diff"])
        self.assertEqual(result.evidence["one-job.status"], "1\n")
        self.assertEqual(result.evidence["many-jobs.status"], "1\n")

    def test_matching_failures_are_visible_and_retained(self):
        result = self.run_wrapper(FAIL, statuses=(1, 1))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("both harness runs failed", result.stderr)
        self.assertIn("  FAIL  one\n  mismatch", result.stderr)
        self.assertEqual(result.evidence["one-job.stdout"], FAIL)
        self.assertEqual(result.evidence["many-jobs.stdout"], FAIL)


if __name__ == "__main__":
    unittest.main()
