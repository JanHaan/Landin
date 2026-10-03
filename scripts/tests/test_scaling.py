"""Regression checks for the scaling command's input validation."""

import pathlib
import subprocess
import sys
import unittest


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


if __name__ == "__main__":
    unittest.main()
