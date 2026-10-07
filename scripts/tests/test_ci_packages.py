#!/usr/bin/env python3
"""Package setup avoids apt for warm tools and rejects a wrong installed pin."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FAKE = '''import json, os, sys
from pathlib import Path
sys.argv = sys.argv[1:]
state = Path(os.environ["PACKAGE_STATE"])
packages = json.loads(state.read_text())
if Path(sys.argv[0]).name == "dpkg-query":
    name = sys.argv[-1]
    if name not in packages:
        sys.exit(1)
    print("installed" if sys.argv[-2] == "-f=${db:Status-Status}" else packages[name])
else:
    with open(os.environ["PACKAGE_LOG"], "a") as stream:
        stream.write(json.dumps(sys.argv[1:]) + "\\n")
    if "install" in sys.argv:
        for value in sys.argv[sys.argv.index("--no-install-recommends") + 1:]:
            name, separator, version = value.partition("=")
            packages[name] = "wrong" if os.environ.get("PACKAGE_WRONG") else version or "1"
        state.write_text(json.dumps(packages))
'''


class Packages(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        fake = self.root / "fake.py"
        fake.write_text(FAKE)
        for name in ("dpkg-query", "sudo"):
            wrapper = self.root / name
            wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable)
                               + " " + shlex.quote(str(fake)) + ' "$0" "$@"\n')
            wrapper.chmod(0o755)
        self.state = self.root / "state.json"
        self.log = self.root / "apt.log"
        self.state.write_text(json.dumps({"clang-19": "19-pinned", "libc6-dev": "1"}))

    def run_setup(self, *packages, wrong=False):
        return subprocess.run(["/bin/sh", str(ROOT / "scripts/ci_packages.sh"), *packages],
                              env={**os.environ, "PATH": str(self.root) + ":" + os.environ["PATH"],
                                   "PACKAGE_STATE": str(self.state), "PACKAGE_LOG": str(self.log),
                                   "PACKAGE_WRONG": "yes" if wrong else ""},
                              text=True, capture_output=True, timeout=10)

    def test_warm_matching_packages_do_not_call_apt(self):
        result = self.run_setup("clang-19=19-pinned", "libc6-dev")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_missing_or_mismatched_package_installs_then_verifies(self):
        for package in ("nodejs", "clang-19=changed-pin"):
            with self.subTest(package=package):
                self.log.unlink(missing_ok=True)
                result = self.run_setup(package)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                self.assertEqual(len(calls), 2)
                self.assertIn("update", calls[0])
                self.assertIn("install", calls[1])
                self.assertIn(package, calls[1])

    def test_wrong_pin_after_install_fails(self):
        result = self.run_setup("clang-19=new-pin", wrong=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("identity mismatch", result.stderr)

    def test_option_and_shell_metacharacters_are_rejected_before_apt(self):
        for package in ("--danger", "package;echo", "package name"):
            with self.subTest(package=package):
                self.assertEqual(self.run_setup(package).returncode, 2)
                self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
