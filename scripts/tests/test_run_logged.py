#!/usr/bin/env python3
"""Hold logged commands to their output, status and cancellation contracts."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "run_logged.py"
#  Seconds before a run that should have ended or spoken is called hung.
#  Each case here takes a second or so on an idle host, and every wait ends
#  as soon as what it waits for happens, so the limit costs nothing there;
#  it is wide because scripts/script_tests.py's workers load the host.
HANG = 120


class LoggedCommands(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="landin-logged-")
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name) / "run with spaces"

    def command(self, *arguments):
        return [sys.executable, str(SCRIPT), "--output", str(self.output),
                "--", *arguments]

    def run_python(self, code, *arguments):
        return subprocess.run(self.command(sys.executable, "-c", code,
                                           *arguments),
                              capture_output=True, text=True, timeout=HANG)

    def result(self):
        return json.loads((self.output / "result.json").read_text())

    def test_preserves_arguments_full_output_and_success_status(self):
        result = self.run_python(
            "import sys; print(repr(sys.argv[1:])); "
            "print('out' * 10000); print('stderr-marker', file=sys.stderr)",
            "a b", "$(must remain literal)", "--suite=fixture execution")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = (self.output / "command.log").read_text()
        self.assertIn("$(must remain literal)", log)
        self.assertIn("--suite=fixture execution", log)
        self.assertIn("out" * 10000, log)
        self.assertIn("stderr-marker", log)
        self.assertNotIn("stderr-marker", result.stdout)
        record = self.result()
        self.assertEqual(record["exit_status"], 0)
        self.assertEqual(record["cwd"], os.getcwd())
        self.assertGreaterEqual(record["elapsed_seconds"], 0)
        self.assertGreaterEqual(record["user_cpu_seconds"], 0)
        self.assertGreater(record["peak_child_rss_bytes"], 0)

    def test_failure_keeps_exit_status_and_bounded_tail(self):
        result = self.run_python(
            "print('first-marker'); print('x' * 50000); "
            "print('failure-marker'); raise SystemExit(23)")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.result()["exit_status"], 23)
        self.assertIn("failure-marker", result.stdout)
        self.assertNotIn("first-marker", result.stdout)
        self.assertLess(len(result.stdout), 18000)
        self.assertIn("first-marker",
                      (self.output / "command.log").read_text())

    def test_existing_output_is_refused_without_running_command(self):
        self.output.mkdir()
        marker = self.output / "retained"
        marker.write_text("keep")
        result = self.run_python("raise SystemExit(99)")
        self.assertEqual(result.returncode, 2)
        self.assertIn("new output directory", result.stderr)
        self.assertEqual(marker.read_text(), "keep")
        self.assertFalse((self.output / "command.log").exists())

    def test_launch_failure_is_recorded(self):
        result = subprocess.run(self.command(str(self.output / "absent")),
                                capture_output=True, text=True, timeout=HANG)
        self.assertEqual(result.returncode, 127)
        self.assertEqual(self.result()["exit_status"], 127)
        self.assertIn("launch_error", self.result())

    def test_signal_exit_is_not_reported_as_success(self):
        result = self.run_python(
            "import os, signal; os.kill(os.getpid(), signal.SIGTERM)")
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)
        self.assertEqual(self.result()["returncode"], -signal.SIGTERM)

    def test_cancellation_reaches_the_command_and_records_a_result(self):
        self.cancelled_by(signal.SIGTERM)

    def test_a_hangup_or_quit_ends_the_command_too(self):
        #  The command is in a session of its own, so a hangup that only
        #  ended the wrapper left it running with no result.
        base = self.output
        for number in (signal.SIGHUP, signal.SIGQUIT):
            with self.subTest(signal=number):
                self.output = base.parent / ("run %d" % number)
                self.cancelled_by(number)

    def cancelled_by(self, number):
        process = subprocess.Popen(self.command(
            sys.executable, "-c", "import time; print('ready', flush=True); "
            "time.sleep(60)"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=HANG)

        self.addCleanup(cleanup)
        deadline = time.monotonic() + HANG
        log = self.output / "command.log"
        while not log.exists() or "ready" not in log.read_text():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        process.send_signal(number)
        stdout, stderr = process.communicate(timeout=HANG)
        self.assertEqual(process.returncode, 128 + number, (stdout, stderr))
        self.assertEqual(self.result()["interrupted_by"], number)
        self.assertEqual(self.result()["returncode"], -number)

    def start(self, code):
        """Start a logged run without waiting for it, as in the background."""
        process = subprocess.Popen(self.command(sys.executable, "-c", code),
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=HANG)

        self.addCleanup(cleanup)
        return process

    def wait(self, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--wait", str(self.output),
             *arguments], capture_output=True, text=True, timeout=2 * HANG)

    def test_wait_returns_the_runs_status_and_tail(self):
        self.start("import time; time.sleep(1); print('failure-marker'); "
                   "raise SystemExit(23)")
        result = self.wait("--timeout=%d" % HANG)
        self.assertEqual(result.returncode, 23, result.stdout)
        self.assertIn("exit=23", result.stdout)
        self.assertIn("failure-marker", result.stdout)
        self.assertIn(str(self.output / "result.json"), result.stdout)
        self.assertEqual(result.stdout.splitlines()[0], "state=finished")

    def test_a_finished_run_never_answers_with_the_waits_own_statuses(self):
        #  timeout(1) exits 124 when it stops its command and 125 when it
        #  cannot run it; from --wait those mean "wait again" and "lost".
        base = self.output
        for status in (124, 125):
            with self.subTest(status=status):
                self.output = base.parent / ("run %d" % status)
                process = self.start("raise SystemExit(%d)" % status)
                self.assertEqual(process.wait(timeout=HANG), status)
                result = self.wait("--timeout=%d" % HANG)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(result.stdout.splitlines()[0], "state=finished")
                self.assertIn("exit=%d" % status, result.stdout)
                self.assertIn("the command itself exited %d" % status, result.stdout)
                self.assertEqual(self.result()["exit_status"], status)

    def test_wait_reads_a_run_file_still_being_written_as_no_run_yet(self):
        #  A wait that reads running.json while a wrapper is writing it sees
        #  an empty file; it once failed with a traceback, exit 1 and
        #  nothing on stdout, where it should look again.
        self.output.mkdir(parents=True)
        (self.output / "running.json").write_text("")
        result = self.wait("--timeout=1")
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("holds no run_logged.py run", result.stderr)

    def until(self, ready):
        """Wait for READY to hold, failing once HANG seconds have passed."""
        deadline = time.monotonic() + HANG
        while not ready():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)

    def logged(self, marker):
        log = self.output / "command.log"
        return log.exists() and marker in log.read_text()

    def test_wait_says_a_run_is_still_going_and_can_be_repeated(self):
        #  The run ends when the test says so, not after a fixed sleep: a
        #  three-second run once ended under load before a one-second wait
        #  had started, and a wait started before the run had made its
        #  directory refuses it.
        release = self.output.parent / "release"
        process = self.start(
            "import os, time\nprint('progress-marker', flush=True)\n"
            "deadline = time.monotonic() + %d\n"
            "while not os.path.exists(%r) and time.monotonic() < deadline:\n"
            "    time.sleep(0.01)\n" % (HANG, str(release)))
        self.until(lambda: self.logged("progress-marker"))
        result = self.wait("--timeout=1")
        self.assertEqual(result.returncode, 124, result.stdout)
        self.assertEqual(result.stdout.splitlines()[0], "state=running")
        self.assertIn("still running", result.stdout)
        self.assertIn("progress-marker", result.stdout)
        release.write_text("")
        self.assertEqual(self.wait("--timeout=%d" % HANG).returncode, 0)
        self.assertEqual(process.wait(timeout=HANG), 0)

    def test_wait_reports_a_wrapper_that_died_without_a_result(self):
        #  The command outlives its wrapper only until it sees the wrapper
        #  gone, so however long the host takes to get here the run cannot
        #  end on its own first and write a result.
        process = self.start(
            "import os, time\nparent = os.getppid()\n"
            "deadline = time.monotonic() + %d\n"
            "while os.getppid() == parent and time.monotonic() < deadline:\n"
            "    time.sleep(0.01)\n" % HANG)
        self.until((self.output / "running.json").exists)
        process.kill()
        process.wait(timeout=HANG)
        result = self.wait("--timeout=%d" % HANG)
        self.assertEqual(result.returncode, 125, result.stdout)
        self.assertEqual(result.stdout.splitlines()[0], "state=lost")
        self.assertIn("ended without a result", result.stdout)

    def test_wait_refuses_a_directory_no_run_writes(self):
        result = self.wait("--timeout=0.5")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("holds no run_logged.py run", result.stderr)

    def detached(self, *arguments):
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--output", str(self.output), "--detach",
             *arguments], capture_output=True, text=True, timeout=HANG)

        def cleanup():
            subprocess.run([sys.executable, str(SCRIPT), "--stop", str(self.output)],
                           capture_output=True, timeout=2 * HANG)

        if completed.returncode == 0:
            self.addCleanup(cleanup)
        return completed

    def test_a_detached_run_outlives_the_session_that_started_it(self):
        #  The launcher runs in a session of its own, as a harness's
        #  background command does, and that whole session is then ended.
        marker = self.output.parent / "marker"
        work = self.output.parent / "work.py"
        work.write_text("import pathlib, time\ntime.sleep(2)\n"
                        "pathlib.Path(%r).write_text('x')\n" % str(marker))
        launcher = self.output.parent / "launcher.py"
        launcher.write_text(
            "import subprocess, sys, time\n"
            "subprocess.run([sys.executable, %r, '--output', %r, '--detach',"
            " '--limit', '%d', '--', sys.executable, %r], stdout=subprocess.DEVNULL)\n"
            "print('launched', flush=True)\ntime.sleep(600)\n"
            % (str(SCRIPT), str(self.output), HANG, str(work)))
        harness = subprocess.Popen([sys.executable, str(launcher)], stdout=subprocess.PIPE,
                                   text=True, start_new_session=True)
        self.addCleanup(harness.wait, HANG)
        self.assertEqual(harness.stdout.readline().strip(), "launched")
        os.killpg(harness.pid, signal.SIGKILL)
        harness.stdout.close()
        result = self.wait("--timeout=%d" % HANG)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(marker.exists())
        self.assertTrue(self.result()["detached"])
        self.assertFalse(self.result()["limit_reached"])

    def test_a_detached_run_past_its_limit_is_ended_and_says_so(self):
        launched = self.detached("--limit", "1", "--", sys.executable, "-c",
                                 "import time; time.sleep(600)")
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertIn("--wait " + str(self.output), launched.stdout)
        result = self.wait("--timeout=%d" % HANG)
        self.assertEqual(result.returncode, 128 + signal.SIGTERM, result.stdout)
        self.assertTrue(self.result()["limit_reached"])
        self.assertEqual(self.result()["interrupted_by"], signal.SIGTERM)

    def test_stop_ends_a_detached_run_and_a_finished_one_is_left(self):
        launched = self.detached("--limit", str(HANG), "--", sys.executable, "-c",
                                 "import time; print('ready', flush=True); time.sleep(600)")
        self.assertEqual(launched.returncode, 0, launched.stderr)
        deadline = time.monotonic() + HANG
        log = self.output / "command.log"
        while not log.exists() or "ready" not in log.read_text():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        stop = [sys.executable, str(SCRIPT), "--stop", str(self.output)]
        stopped = subprocess.run(stop, capture_output=True, text=True, timeout=2 * HANG)
        self.assertEqual(stopped.returncode, 0, stopped.stdout + stopped.stderr)
        self.assertEqual(self.result()["interrupted_by"], signal.SIGTERM)
        self.assertFalse(self.result()["limit_reached"])
        again = subprocess.run(stop, capture_output=True, text=True, timeout=HANG)
        self.assertEqual(again.returncode, 0)
        self.assertIn("already finished", again.stdout)

    def test_detaching_needs_a_limit_and_a_new_directory(self):
        refused = self.detached("--", sys.executable, "-c", "pass")
        self.assertEqual(refused.returncode, 2)
        self.assertIn("--detach needs --limit", refused.stderr)
        self.assertFalse(self.output.exists())
        self.output.mkdir()
        refused = self.detached("--limit", "5", "--", sys.executable, "-c", "pass")
        self.assertEqual(refused.returncode, 2)
        self.assertIn("cannot create a new output directory", refused.stderr)
        for arguments in (["--wait", str(self.output), "--limit", "5"],
                          ["--stop", str(self.output), "--detach"],
                          ["--output", str(self.output) + "2", "--limit", "0", "--", "true"]):
            with self.subTest(arguments=arguments):
                refused = subprocess.run([sys.executable, str(SCRIPT), *arguments],
                                         capture_output=True, text=True, timeout=HANG)
                self.assertEqual(refused.returncode, 2, refused.stdout)


if __name__ == "__main__":
    unittest.main()
