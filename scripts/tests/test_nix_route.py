"""The nix route check refuses each way the README's nix commands can drift.

`scripts/nix_route.py` runs in the gate's `flake-compiler` job against the
real store (D1707).  Here nix and the installed compiler are stood in for,
so that each refusal is seen to fire: a default package that is the source
build, a profile that installed something other than the release archive,
a version that is not the release's, and `nix run` printing anything but
the first program's output.
"""
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import nix_route  # noqa: E402
from outside_user import first_program  # noqa: E402


class Store:
    """A fake nix: `refine-bin` and `refine` evaluate to two paths under
    ROOT, and `profile install` links the profile's `bin` to INSTALLED."""

    def __init__(self, root, source=None, installed=None):
        self.released = str(root / "store" / "landin-bin-0.2.11")
        self.source = source or str(root / "store" / "landin-0.2.11")
        self.installed = installed or self.released
        os.makedirs(self.installed + "/bin", exist_ok=True)
        Path(self.installed + "/bin/refine").write_text("")

    def __call__(self, *argv, cwd=None):
        if argv[:2] == ("eval", "--raw"):
            return {".#refine-bin.outPath": self.released,
                    ".#refine-bin.version": "0.2.11",
                    ".#refine.outPath": self.source}[argv[2]]
        if argv[:2] == ("profile", "install"):
            profile = Path(argv[3])
            profile.mkdir(parents=True)
            os.symlink(self.installed + "/bin", profile / "bin")
            return ""
        raise AssertionError(argv)


def runner(version="refine 0.2.11\n", printed=None, status=0):
    """A fake subprocess.run for `refine version` and `nix run`."""
    printed = first_program()[1] if printed is None else printed

    def run(argv, **_):
        if argv[-1] == "version":
            return subprocess.CompletedProcess(argv, 0, version, "")
        return subprocess.CompletedProcess(argv, status, printed, b"")
    return run


class Refusals(unittest.TestCase):
    def check(self, **given):
        with TemporaryDirectory() as scratch:
            root = Path(scratch)
            store = Store(root, **{key: value(root) for key, value
                                   in given.pop("store", {}).items()})
            work = root / "work"
            work.mkdir()
            return nix_route.checks(".", work, nix=store, run=runner(**given))

    def test_the_route_as_documented_passes(self):
        self.assertEqual(self.check(), [])

    def test_a_default_that_is_the_source_build_is_refused(self):
        failures = self.check(store={
            "source": lambda root: str(root / "store" / "landin-bin-0.2.11")})
        self.assertEqual(len(failures), 1)
        self.assertIn("not the source build", failures[0])

    def test_a_profile_holding_another_compiler_is_refused(self):
        failures = self.check(store={
            "installed": lambda root: str(root / "store" / "landin-0.2.11")})
        self.assertEqual(len(failures), 1)
        self.assertIn("not the release archive", failures[0])

    def test_a_version_that_is_not_the_release_is_refused(self):
        failures = self.check(version="refine dev\n")
        self.assertEqual(len(failures), 1)
        self.assertIn("'refine dev'", failures[0])

    def test_nix_run_printing_otherwise_is_refused(self):
        failures = self.check(printed=b"Hello\n")
        self.assertEqual(len(failures), 1)
        self.assertIn("nix run . -- run main.ldn", failures[0])

    def test_a_failing_nix_run_is_refused(self):
        failures = self.check(status=1)
        self.assertEqual(len(failures), 1)
        self.assertIn("exited 1", failures[0])


class Gate(unittest.TestCase):
    def test_the_flake_compiler_job_runs_the_route(self):
        workflow = (ROOT / ".github/workflows/gate.yml").read_text()
        step = workflow.split(
            "- name: Install and run refine through nix as the README says",
            1)[1].split("- name:", 1)[0]
        self.assertIn("if: matrix.part == 'compiler'", step)
        self.assertIn("python3 scripts/nix_route.py --work", step)


if __name__ == "__main__":
    unittest.main()
