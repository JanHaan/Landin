#!/usr/bin/env python3
"""Controls for the cross-host emission check.

A check that cannot fail is worse than no check: renaming tour.md once made
four of check.py's checks vacuous while the run still said `all clean`.  So
the comparison is exercised against differing manifests, unexpected shared
refusals, and agreeing manifests with real assembly evidence.
"""
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "scripts" / "emit_manifest.py"

BASE = {
    "alias-conversion|linux-x86-64|debug|optimize=size|specialize=auto": "a" * 64,
    "alias-conversion|cortex-m0|release|optimize=size|specialize=auto": "b" * 64,
    "external-scalar-c-boundary|cortex-m0|debug|optimize=size|specialize=auto": "refused:1",
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


def emit(stub):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = root / "compiler/tests/fixtures/positive/external-scalar-c-boundary"
        fixture.mkdir(parents=True)
        (fixture / "fixture.meta").write_text("program: main.ldn\n")
        (fixture / "main.ldn").write_text("unused by the stub\n")
        refine = root / "refine"
        refine.write_text("#!/bin/sh\n" + stub)
        refine.chmod(0o755)
        out = root / "manifest.json"
        result = subprocess.run(
            [sys.executable, str(CHECK), "emit", str(refine), str(root), str(out)],
            capture_output=True, text=True)
        return result, json.loads(out.read_text())


class Comparison(unittest.TestCase):
    def test_agreeing_manifests_pass(self):
        result = compare(BASE, dict(BASE))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agree on all 3 entries", result.stdout)

    def test_a_changed_digest_fails(self):
        other = dict(BASE)
        key = "alias-conversion|linux-x86-64|debug|optimize=none|specialize=off"
        other[key] = "c" * 64
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not host-neutral", result.stderr)
        self.assertIn(key, result.stderr)

    def test_a_missing_entry_fails(self):
        other = dict(BASE)
        del other["external-scalar-c-boundary|cortex-m0|debug|optimize=size|specialize=auto"]
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is absent", result.stderr)

    def test_an_extra_entry_fails(self):
        other = dict(BASE)
        other["invented|cortex-m0|debug|optimize=none|specialize=all"] = "d" * 64
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("invented|cortex-m0|debug|optimize=none|specialize=all",
                      result.stderr)

    def test_a_refusal_that_became_an_emission_fails(self):
        #  Accept/refuse must agree too: a fixture one host compiles and
        #  another rejects is a host leak in the frontend, not the backend.
        other = dict(BASE)
        other["external-scalar-c-boundary|cortex-m0|debug|optimize=size|specialize=auto"] = "e" * 64
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)

    def test_shared_unexpected_refusal_fails(self):
        other = dict(BASE)
        other["alias-conversion|linux-x86-64|debug|optimize=size|specialize=auto"] = "refused:1"
        result = compare(other, dict(other))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected emission result", result.stderr)

    def test_all_expected_refusals_still_fail(self):
        refused = {"external-scalar-c-boundary|cortex-m0|debug|optimize=size|specialize=auto": "refused:1"}
        result = compare(refused, dict(refused))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no assembly digest was emitted", result.stderr)

    def test_missing_assembly_is_not_an_expected_refusal(self):
        other = dict(BASE)
        other["external-scalar-c-boundary|cortex-m0|debug|optimize=size|specialize=auto"] = "refused:0"
        result = compare(other, dict(other))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected emission result", result.stderr)

    def test_one_manifest_is_not_a_comparison(self):
        result = compare(BASE)
        self.assertEqual(result.returncode, 2)
        self.assertIn("at least two", result.stderr)


class Emission(unittest.TestCase):
    def test_universal_refusal_fails(self):
        result, manifest = emit("exit 1\n")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(set(manifest.values()), {"refused:1"})
        self.assertIn("no assembly digest was emitted", result.stderr)

    def test_declared_target_refusal_passes_with_assembly(self):
        result, manifest = emit(
            'for arg do\n'
            '  case "$arg" in\n'
            '    --target=cortex-m0) exit 1 ;;\n'
            '  esac\n'
            'done\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  if [ "$1" = -o ]; then shift; printf "asm\\n" > "$1"; exit 0; fi\n'
            '  shift\n'
            'done\n'
            'exit 2\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(value == "refused:1" for value in manifest.values()), 18)
        self.assertEqual(sum(len(value) == 64 for value in manifest.values()), 54)

    def test_every_profile_is_emitted_and_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            area = Path(tmp)
            fixture = area / "compiler/tests/fixtures/positive/example"
            fixture.mkdir(parents=True)
            (fixture / "fixture.meta").write_text("program: main.ldn\n")
            refine = area / "refine"
            refine.write_text(
                "#!" + sys.executable + "\n"
                "import pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "if '--target=cortex-m0' in args and "
                "'--optimize=speed' in args and '--specialize=all' in args:\n"
                "    sys.exit(2)\n"
                "controls = [a for a in args if a.startswith((\n"
                "    '--target=', '--build-mode=', '--optimize=', '--specialize='))]\n"
                "pathlib.Path(args[args.index('-o') + 1]).write_text('|'.join(controls))\n")
            refine.chmod(0o755)
            out = area / "manifest.json"
            result = subprocess.run(
                [sys.executable, str(CHECK), "emit", str(refine), str(area),
                 str(out)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("unexpected emission result", result.stderr)
            manifest = json.loads(out.read_text())
            self.assertEqual(len(manifest), 4 * 2 * 3 * 3)
            for target in ("linux-x86-64", "linux-arm64", "darwin-arm64", "cortex-m0"):
                for mode in ("debug", "release"):
                    for optimize in ("none", "size", "speed"):
                        for specialize in ("off", "auto", "all"):
                            key = (f"example|{target}|{mode}|optimize={optimize}"
                                   f"|specialize={specialize}")
                            self.assertIn(key, manifest)
                            if (target == "cortex-m0" and
                                    (optimize, specialize) == ("speed", "all")):
                                self.assertEqual(manifest[key], "refused:2")
                            else:
                                controls = (f"--target={target}|--build-mode={mode}|"
                                            f"--optimize={optimize}|--specialize={specialize}")
                                self.assertEqual(manifest[key], hashlib.sha256(
                                    controls.encode()).hexdigest())


if __name__ == "__main__":
    unittest.main()
