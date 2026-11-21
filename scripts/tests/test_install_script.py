"""install.sh installs the archive a release publishes, and refuses the rest.

The gate runs scripts/install_check.py against its packaged compiler on
each host a release serves.  Here the same cases run against a stand-in
archive, whose bin/refine prints the first program's output, so the
script's own logic is held on every scripts job; and the names the script
downloads are held to the ones the release workflow publishes.
"""
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import install_check  # noqa: E402

STAND_IN = """#!/bin/sh
[ "$1 $2" = "run main.ldn" ] || exit 2
[ -d "$(dirname "$0")/../lib/landin/core" ] || exit 3
cat <<'EOF'
%s
EOF
"""


def stand_in_archive(path):
    printed = (install_check.FIRST_PROGRAM / "output.txt").read_text()
    with tarfile.open(path, "w:gz") as archive:
        for name, data, mode in (
                ("bin/refine",
                 (STAND_IN % printed.rstrip("\n")).encode(), 0o755),
                ("lib/landin/core/io.ldn", b"", 0o644),
                ("libexec/landin/.keep", b"", 0o644)):
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = mode
            archive.addfile(member, io.BytesIO(data))


class Installs(unittest.TestCase):
    def test_every_case_against_a_stand_in_archive(self):
        with TemporaryDirectory() as scratch:
            archive = Path(scratch) / "landin.tar.gz"
            stand_in_archive(archive)
            passed, failures = install_check.run_checks(
                archive, Path(scratch) / "work", "0.0.0",
                platform="x86_64-linux")
            self.assertEqual(failures, [])
            self.assertEqual(passed, 8)


class Names(unittest.TestCase):
    def test_the_script_names_what_the_release_workflow_publishes(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        build = workflow.split("\n  build:\n", 1)[1].split("\n  user-image:", 1)[0]
        platforms = re.findall(r"^ +platform: (\S+)$", build, re.M)
        self.assertEqual(len(platforms), 3)
        self.assertIn('asset="landin-$version-${{ matrix.platform }}.tar.gz"',
                      workflow)
        self.assertIn('> "$file.sha256"', workflow)
        listed = subprocess.run(
            ["sh", str(install_check.SCRIPT), "--list", "--version", "1.2.3"],
            capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(listed, [
            name for one in platforms
            for name in ("landin-1.2.3-%s.tar.gz" % one,
                         "landin-1.2.3-%s.tar.gz.sha256" % one)])

    def test_options_it_refuses(self):
        for argv, said in ((["--platform", "x86_64-freebsd"],
                            "no release archive is named for"),
                           (["--version", "1.x", "--list"],
                            "is not a release version"),
                           (["--frobnicate"], "unknown option")):
            ran = subprocess.run(["sh", str(install_check.SCRIPT)] + argv,
                                 capture_output=True, text=True,
                                 env={"PATH": os.environ["PATH"]})
            self.assertEqual(ran.returncode, 1, argv)
            self.assertIn(said, ran.stderr, argv)

    def test_help_prints_the_options(self):
        ran = subprocess.run(["sh", str(install_check.SCRIPT), "--help"],
                             capture_output=True, text=True, check=True)
        self.assertIn("--version VERSION", ran.stdout)
        self.assertIn("LANDIN_RELEASES", ran.stdout)


if __name__ == "__main__":
    unittest.main()
