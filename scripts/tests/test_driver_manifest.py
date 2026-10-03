#!/usr/bin/env python3
"""Report-only comparisons must preserve every old warning and help line."""
import base64
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "driver_manifest.py"
SPEC = importlib.util.spec_from_file_location("driver_manifest", SCRIPT)
driver_manifest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver_manifest)
KEY = "negative/example|linux-x86-64|plain"
ERROR = b"error[L0001]: original\n  = note: stable\n"
HELP = b"  = help: try this\n"
WARNING = b"warning[L0002]: original warning\n  = note: detail\n"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def entry(report):
    return {
        "status": 1,
        "stdout": digest(b""),
        "stderr": digest(report),
        "stderr_base64": base64.b64encode(report).decode("ascii"),
        "errors": digest(driver_manifest.without_additions(report)),
        "asm": "absent",
        "report": "absent",
        "layout": digest(b"\0\0"),
    }


def compare(old, new, report_only=True):
    with tempfile.TemporaryDirectory() as tmp:
        first, second = Path(tmp) / "old.json", Path(tmp) / "new.json"
        first.write_text(json.dumps({KEY: old}))
        second.write_text(json.dumps({KEY: new}))
        command = [sys.executable, str(SCRIPT), "compare"]
        if report_only:
            command.append("--report-only")
        return subprocess.run(command + [str(first), str(second)],
                              capture_output=True, text=True)


class ReportOnlyComparison(unittest.TestCase):
    def test_help_appended_inside_existing_warning_is_accepted(self):
        old = b"warning[L0326]: local mut is unused\n  = note: unchanged\n"
        new = old + b"  = help: remove mut\n"
        result = compare(entry(old), entry(new))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 reports grew", result.stdout)

    def test_existing_warning_help_cannot_be_removed_or_replaced(self):
        old = WARNING + HELP
        for new in (WARNING, WARNING + b"  = help: something else\n"):
            with self.subTest(report=new):
                self.assertEqual(compare(entry(old), entry(new)).returncode,
                                 1)

    def test_new_help_and_whole_warning_are_accepted(self):
        result = compare(entry(ERROR), entry(ERROR + HELP + WARNING))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 reports grew", result.stdout)

    def test_removed_warning_is_rejected(self):
        result = compare(entry(ERROR + WARNING), entry(ERROR))
        self.assertEqual(result.returncode, 1)
        self.assertIn("stderr", result.stderr)

    def test_replaced_warning_is_rejected(self):
        changed = b"warning[L0002]: replacement\n  = note: detail\n"
        self.assertEqual(compare(entry(ERROR + WARNING),
                                 entry(ERROR + changed)).returncode, 1)

    def test_removed_or_replaced_help_is_rejected(self):
        old = entry(ERROR + HELP)
        for report in (ERROR, ERROR + b"  = help: something else\n"):
            with self.subTest(report=report):
                self.assertEqual(compare(old, entry(report)).returncode, 1)

    def test_existing_warning_cannot_be_reordered(self):
        other = b"warning[L0003]: second warning\n"
        self.assertEqual(compare(entry(ERROR + WARNING + other),
                                 entry(ERROR + other + WARNING)).returncode, 1)

    def test_existing_report_line_cannot_change(self):
        changed = b"error[L0001]: replacement\n  = note: stable\n"
        new = entry(changed + HELP)
        new["errors"] = digest(changed)
        self.assertEqual(compare(entry(ERROR), new).returncode, 1)

    def test_missing_or_false_raw_report_cannot_approve_a_change(self):
        old = entry(ERROR)
        new = entry(ERROR + HELP)
        for damaged in (dict(old, stderr_base64="!"), dict(old),
                        dict(old, stderr_base64=base64.b64encode(
                            b"other").decode("ascii"))):
            with self.subTest(damaged=damaged):
                if damaged == old:
                    damaged.pop("stderr_base64")
                self.assertEqual(compare(damaged, new).returncode, 1)

    def test_strict_comparison_rejects_addition(self):
        self.assertEqual(compare(entry(ERROR), entry(ERROR + HELP),
                                 report_only=False).returncode, 1)

    def test_emit_keeps_the_raw_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "negative" / "example"
            fixture.mkdir(parents=True)
            result = SimpleNamespace(returncode=1, stdout=b"",
                                     stderr=ERROR + WARNING)
            with patch.object(driver_manifest.subprocess, "run",
                              return_value=result):
                emitted = driver_manifest.run_one(
                    Path("refine"), fixture, ["program.ldn"], "linux-x86-64",
                    "plain", Path(tmp) / "work")
        self.assertEqual(base64.b64decode(emitted["stderr_base64"]),
                         ERROR + WARNING)
        self.assertEqual(emitted["stderr"], digest(ERROR + WARNING))
        self.assertEqual(emitted["errors"], digest(ERROR))


if __name__ == "__main__":
    unittest.main()
