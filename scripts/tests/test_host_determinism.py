#!/usr/bin/env python3
"""Controls for the cross-host emission check.

A check that cannot fail is worse than no check: renaming tour.md once made
four of check.py's checks vacuous while the run still said `all clean`.  So
the comparison is exercised against manifests that disagree in each of the
three ways they can -- a changed digest, a missing entry and an extra one --
and against agreeing manifests, which must stay silent.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "scripts" / "emit_manifest.py"

BASE = {
    "alias-conversion|linux-x86-64|debug": "a" * 64,
    "alias-conversion|cortex-m0|release": "b" * 64,
    "loop-carry|darwin-arm64|debug": "refused:2",
}


def compare(*manifests):
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for n, manifest in enumerate(manifests):
            path = Path(tmp) / ("m%d.json" % n)
            path.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
            paths.append(str(path))
        return subprocess.run([sys.executable, str(CHECK), "compare"] + paths,
                              capture_output=True, text=True)


class Comparison(unittest.TestCase):
    def test_agreeing_manifests_pass(self):
        result = compare(BASE, dict(BASE))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agree on all 3 entries", result.stdout)

    def test_a_changed_digest_fails(self):
        other = dict(BASE)
        other["alias-conversion|linux-x86-64|debug"] = "c" * 64
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not host-neutral", result.stderr)
        self.assertIn("alias-conversion|linux-x86-64|debug", result.stderr)

    def test_a_missing_entry_fails(self):
        other = dict(BASE)
        del other["loop-carry|darwin-arm64|debug"]
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is absent", result.stderr)

    def test_an_extra_entry_fails(self):
        other = dict(BASE)
        other["invented|cortex-m0|debug"] = "d" * 64
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("invented|cortex-m0|debug", result.stderr)

    def test_a_refusal_that_became_an_emission_fails(self):
        #  Accept/refuse must agree too: a fixture one host compiles and
        #  another rejects is a host leak in the frontend, not the backend.
        other = dict(BASE)
        other["loop-carry|darwin-arm64|debug"] = "e" * 64
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)

    def test_one_manifest_is_not_a_comparison(self):
        result = compare(BASE)
        self.assertEqual(result.returncode, 2)
        self.assertIn("at least two", result.stderr)


if __name__ == "__main__":
    unittest.main()
