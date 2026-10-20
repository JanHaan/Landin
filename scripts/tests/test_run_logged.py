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
                              capture_output=True, text=True, timeout=10)

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
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 127)
        self.assertEqual(self.result()["exit_status"], 127)
        self.assertIn("launch_error", self.result())

    def test_signal_exit_is_not_reported_as_success(self):
        result = self.run_python(
            "import os, signal; os.kill(os.getpid(), signal.SIGTERM)")
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)
        self.assertEqual(self.result()["returncode"], -signal.SIGTERM)

    def test_cancellation_reaches_the_command_and_records_a_result(self):
        process = subprocess.Popen(self.command(
            sys.executable, "-c", "import time; print('ready', flush=True); "
            "time.sleep(60)"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

        self.addCleanup(cleanup)
        deadline = time.monotonic() + 5
        log = self.output / "command.log"
        while not log.exists() or "ready" not in log.read_text():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        process.terminate()
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM,
                         (stdout, stderr))
        self.assertEqual(self.result()["interrupted_by"], signal.SIGTERM)
        self.assertEqual(self.result()["returncode"], -signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
