"""Regression checks for the scaling command's input validation."""

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



if __name__ == "__main__":
    unittest.main()
