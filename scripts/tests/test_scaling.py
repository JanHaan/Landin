"""Regression checks for the scaling command's input validation."""

import contextlib
import io
from unittest import mock
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
import pathlib
import subprocess
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import scaling

SCALING = pathlib.Path(__file__).resolve().parents[1] / "scaling.py"


class ScalingArguments(unittest.TestCase):
    def test_empty_generated_range_fails(self):
        result = subprocess.run(
            [sys.executable, str(SCALING), "--refine=" + sys.executable,
             "--largest=999", "--no-derived"],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--largest must be at least 1000", result.stderr)
        self.assertNotIn("functions:", result.stdout)


class StageReportFreshness(unittest.TestCase):
    def test_success_without_new_report_rejects_previous_measurement(self):
        with tempfile.TemporaryDirectory() as work:
            report = Path(work) / "stages.json"
            calls = 0

            def compile_once(command, **_kwargs):
                nonlocal calls
                calls += 1
                self.assertEqual(command[2], "--stage-report=" + str(report))
                if calls == 1:
                    report.write_text(json.dumps({
                        "stages": [
                            {"stage": name, "processor_us": 100,
                             "peak_kib": 32}
                            for name in scaling.FRONTEND + scaling.EMISSION
                        ],
                        "sizes": {"declarations": 111},
                    }))
                return subprocess.CompletedProcess(command, 0, b"", b"")

            with patch.object(scaling.subprocess, "run",
                              side_effect=compile_once):
                first = scaling.measure("refine", work, work, str(report), 5)
                self.assertEqual(first["sizes"]["declarations"], 111)
                with self.assertRaisesRegex(
                        RuntimeError, "did not write the stage report"):
                    scaling.measure("refine", work, work, str(report), 5)
            self.assertEqual(calls, 2)


class CapturedOutput(io.StringIO):
    def reconfigure(self, **kwargs):
        pass


class ScalingMemory(unittest.TestCase):
    def verdict(self, peaks):
        samples = iter({"frontend": float(size), "emission": float(size),
                        "peak_kib": peak,
                        "sizes": {"declarations": size}}
                       for size, peak in zip(scaling.SIZES, peaks))
        stdout, stderr = CapturedOutput(), io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "measurements.json"
            with (mock.patch.object(scaling, "FAMILIES", (("sample", lambda _: {}),)),
                  mock.patch.object(scaling, "write_program"),
                  mock.patch.object(scaling, "median_of", side_effect=lambda *args: next(samples)),
                  contextlib.redirect_stdout(stdout),
                  contextlib.redirect_stderr(stderr)):
                status = scaling.main(["--refine", sys.executable, "--runs=1",
                                       "--no-derived", "--json", str(report)])
            record = json.loads(report.read_text())
        return status, stdout.getvalue(), stderr.getvalue(), record

    def test_quadratic_memory_fails_with_linear_time(self):
        status, output, errors, record = self.verdict(
            [1024, 4096, 16384, 65536, 262144])
        self.assertEqual(status, 1)
        self.assertIn("peak memory 1000 -> 2000 grew 4.00x", errors)
        self.assertNotIn("frontend", errors)
        self.assertIn("4.00x", output)
        self.assertEqual(record["memory_limit"], 2.5)
        self.assertEqual(record["families"]["sample"][1]["ratios"]["peak_kib"], 4)

    def test_memory_at_limit_passes(self):
        status, _, errors, _ = self.verdict([1024, 2560, 6400, 16000, 40000])
        self.assertEqual(status, 0)
        self.assertEqual(errors, "")

    def test_missing_peak_fails(self):
        status, _, errors, record = self.verdict([0, 2048, 4096, 8192, 16384])
        self.assertEqual(status, 1)
        self.assertIn("no positive peak memory measurement", errors)
        self.assertEqual(record["families"]["sample"], [])


if __name__ == "__main__":
    unittest.main()
