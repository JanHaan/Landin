#!/usr/bin/env python3
"""Controls for the cross-host emission check.

A check that cannot fail is worse than no check: renaming tour.md once made
four of check.py's checks vacuous while the run still said `all clean`.  So
the comparison is exercised against differing manifests, unexpected shared
refusals, and agreeing manifests with real assembly evidence.
"""
import hashlib
import json
import re
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


def merge(*parts):
    """Run merge over PARTS and return its result and the merged manifest."""
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for n, part in enumerate(parts):
            path = Path(tmp) / ("p%d.json" % n)
            path.write_text(json.dumps(part) + "\n")
            paths.append(str(path))
        out = Path(tmp) / "whole.json"
        result = subprocess.run([sys.executable, str(CHECK), "merge", str(out)] + paths,
                                capture_output=True, text=True)
        return result, (json.loads(out.read_text()) if out.exists() else None)


def by_target(targets):
    return {"alias-conversion|%s|debug|optimize=none|specialize=off" % target: "a" * 64
            for target in targets}


class Parts(unittest.TestCase):
    """The gate emits each host's targets in two jobs and joins them."""

    def setUp(self):
        sys.path.insert(0, str(CHECK.parent))
        self.addCleanup(sys.path.remove, str(CHECK.parent))
        import emit_manifest
        self.targets = emit_manifest.TARGETS

    def test_parts_covering_every_target_make_the_whole(self):
        half = len(self.targets) // 2
        result, whole = merge(by_target(self.targets[:half]),
                              by_target(self.targets[half:]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(whole, by_target(self.targets))

    def test_a_target_in_no_part_fails(self):
        result, whole = merge(by_target(self.targets[:2]), by_target(self.targets[3:]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no part emitted " + self.targets[2], result.stderr)
        self.assertIsNone(whole)

    def test_a_key_in_two_parts_fails(self):
        result, whole = merge(by_target(self.targets), by_target(self.targets[:1]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("is in two parts", result.stderr)
        self.assertIsNone(whole)

    def test_emit_refuses_an_unknown_or_repeated_target(self):
        for targets in ("linux-x86-64,linux-x86-64", "linux-sparc64", ""):
            with self.subTest(targets=targets):
                result = subprocess.run(
                    [sys.executable, str(CHECK), "emit", "refine", ".", "out.json", targets],
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)


class Workflows(unittest.TestCase):
    """The workflows' parts emit every target the check names, once."""

    def setUp(self):
        sys.path.insert(0, str(CHECK.parent))
        self.addCleanup(sys.path.remove, str(CHECK.parent))
        import emit_manifest
        self.check = emit_manifest

    @staticmethod
    def parts(workflow, job):
        """{key: [targets of each part]} for JOB's matrix in WORKFLOW."""
        text = (ROOT / ".github/workflows" / workflow).read_text()
        body = re.search(r"\n  %s:\n(.*?)(?=\n  [a-z-]+:\n)" % job, text, re.S).group(1)
        #  The matrix's include list, up to the job's next own key.
        include = re.search(r"\n +include:\n(.*?)(?=\n    \w)", body, re.S).group(1)
        found = {}
        for item in re.split(r"\n +- (?=\w+:)", "\n" + include)[1:]:
            platform = re.search(r"platform: (\S+)", item)
            targets = re.search(r"\btargets: (\S+)", item)
            found.setdefault(platform.group(1) if platform else "", []).append(
                targets.group(1).split(","))
        return found

    def assertPartition(self, parts, targets):
        joined = [t for part in parts for t in part]
        self.assertEqual(sorted(joined), sorted(targets))

    def test_each_host_emits_every_target_once(self):
        hosts = self.parts("determinism.yml", "manifest")
        self.assertEqual(sorted(hosts), ["aarch64-darwin", "aarch64-linux", "x86_64-linux"])
        for host, parts in hosts.items():
            with self.subTest(host=host):
                self.assertPartition(parts, self.check.TARGETS)
        #  Every host splits its targets alike, so a part is one comparison.
        self.assertEqual(len({json.dumps(parts) for parts in hosts.values()}), 1)

    def test_the_build_modes_jobs_compare_every_mode_target_once(self):
        self.assertPartition(self.parts("gate.yml", "build-modes")[""],
                             self.check.MODE_TARGETS)

    def test_every_firmware_target_is_compared_in_both_build_modes(self):
        self.assertLessEqual(set(self.check.FIRMWARE_TARGETS),
                             set(self.check.MODE_TARGETS))


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

    def test_written_c_function_refusal_is_confined_to_firmware(self):
        #  Neither firmware target has a C ABI (D660 for rv32).
        for target in ("cortex-m0", "linux-x86-64", "linux-arm64",
                       "darwin-arm64", "freebsd-x86-64", "freebsd-arm64",
                       "linux-rv64", "rv32"):
            other = dict(BASE)
            key = (f"written-type-c-function|{target}|debug"
                   "|optimize=size|specialize=auto")
            other[key] = "refused:1"
            result = compare(other, dict(other))
            self.assertEqual(result.returncode,
                             0 if target in ("cortex-m0", "rv32") else 1,
                             result.stderr)

    def test_every_expected_refusal_names_a_positive_fixture(self):
        #  A retired fixture left in the list is never checked again, so its
        #  successor's refusal is reported as unexpected only on the gate.
        sys.path.insert(0, str(ROOT / "scripts"))
        import emit_manifest
        positive = ROOT / "compiler/tests/fixtures/positive"
        missing = sorted(fixture for fixture, _ in emit_manifest.REFUSAL_PAIRS
                         if not (positive / fixture).is_dir())
        self.assertEqual(missing, [])

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
        self.assertEqual(sum(len(value) == 64 for value in manifest.values()), 126)

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
            self.assertEqual(len(manifest), 8 * 2 * 3 * 3)
            for target in ("linux-x86-64", "linux-arm64", "darwin-arm64", "cortex-m0",
                           "freebsd-x86-64", "freebsd-arm64", "linux-rv64", "rv32"):
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


class Levels(unittest.TestCase):
    """A fixture is compiled at the level its `args` request, on their target."""

    def test_the_level_applies_only_to_the_target_its_args_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            area = Path(tmp)
            fixture = area / "compiler/tests/fixtures/positive/example"
            fixture.mkdir(parents=True)
            (fixture / "fixture.meta").write_text(
                "program: main.ldn\nargs: --target=rv32 --level=rv32imac\n")
            refine = area / "refine"
            refine.write_text(
                "#!" + sys.executable + "\n"
                "import pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "said = [a for a in args if a.startswith(('--target=', '--level='))]\n"
                "pathlib.Path(args[args.index('-o') + 1]).write_text(' '.join(said))\n")
            refine.chmod(0o755)
            out = area / "manifest.json"
            result = subprocess.run(
                [sys.executable, str(CHECK), "emit", str(refine), str(area), str(out)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads(out.read_text())
            for target in ("rv32", "cortex-m0", "linux-rv64"):
                said = "--target=" + target + (" --level=rv32imac" if target == "rv32" else "")
                key = "example|%s|release|optimize=size|specialize=auto" % target
                self.assertEqual(manifest[key], hashlib.sha256(said.encode()).hexdigest())


def modes(debug_body, release_body):
    """Run `modes` over a small corpus with two stub compilers."""
    with tempfile.TemporaryDirectory() as tmp:
        area = Path(tmp)
        tests = area / "compiler/tests"
        positive = tests / "fixtures/positive/example"
        runtime = tests / "fixtures/runtime/hosted"
        executed = tests / "fixtures/runtime/executed"
        replaced = tests / "fixtures/runtime/replaced"
        case = tests / "cortex-m/cases/counterpart"
        for directory in (positive, runtime, executed, replaced, case):
            directory.mkdir(parents=True)
            (directory / "main.ldn").write_text("unused by the stub\n")
        (positive / "fixture.meta").write_text("program: main.ldn\n")
        (runtime / "fixture.meta").write_text(
            "program: main.ldn\ntargets: linux-x86-64, linux-rv64\n")
        #  The firmware corpus executes one runtime fixture its `targets:`
        #  does not name, and one only through its counterpart.
        (executed / "fixture.meta").write_text(
            "program: main.ldn\ntargets: linux-x86-64\n")
        (replaced / "fixture.meta").write_text(
            "program: main.ldn\ntargets: linux-x86-64\n")
        (tests / "cortex-m/corpus.json").write_text(json.dumps({"fixtures": {
            "runtime/executed": {"mode": "execute"},
            "runtime/replaced": {"mode": "execute", "counterpart": "counterpart"},
            "runtime/hosted": {"mode": "refuse", "codes": ["L0015"]}}}))
        stubs = []
        for name, body in (("debug", debug_body), ("release", release_body)):
            refine = area / name
            refine.write_text(
                "#!" + sys.executable + "\n"
                "import pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "out = pathlib.Path(args[args.index('-o') + 1])\n"
                "where = pathlib.Path.cwd().name\n" + body)
            refine.chmod(0o755)
            stubs.append(str(refine))
        return subprocess.run(
            [sys.executable, str(CHECK), "modes"] + stubs + [str(area)],
            capture_output=True, text=True)


class BuildModes(unittest.TestCase):
    """The debug and release builds of one tree emit the same bytes."""

    SAME = "out.write_text(' '.join(args[:4]) + where)\n"

    def test_agreeing_builds_pass_over_every_source_and_profile(self):
        result = modes(self.SAME, self.SAME)
        self.assertEqual(result.returncode, 0, result.stderr)
        #  The positive fixture on four targets; each runtime fixture on
        #  the one of them its record names, and the one the firmware
        #  corpus executes on both firmware targets too; the counterpart on
        #  both firmware targets; each at the four standard profiles.
        self.assertIn("sources 5  requests 44  emitted 44", result.stdout)

    def test_the_firmware_corpus_reaches_rv32(self):
        result = modes(self.SAME, self.SAME.replace(
            "out.write_text(", "out.write_text('x' * ("
            "where == 'executed' and '--target=rv32' in args) + "))
        self.assertEqual(result.returncode, 1)
        self.assertIn("runtime/executed|rv32|", result.stderr)

    def test_one_differing_emission_fails_and_is_named(self):
        result = modes(self.SAME, self.SAME.replace(
            "out.write_text(", "out.write_text('x' * ("
            "where == 'hosted' and '--optimize=none' in args) + "))
        self.assertEqual(result.returncode, 1)
        self.assertIn("do not emit the same bytes: 1 fault", result.stderr)
        self.assertIn("runtime/hosted|linux-x86-64|optimize=none|specialize=off",
                      result.stderr)

    def test_a_refusal_must_be_said_the_same_way(self):
        refuse = "if where == 'counterpart':\n    print('%s'); sys.exit(1)\n"
        result = modes(refuse % "no" + self.SAME, refuse % "no" + self.SAME)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("refused alike 8", result.stdout)
        result = modes(refuse % "no" + self.SAME, refuse % "not so" + self.SAME)
        self.assertEqual(result.returncode, 1)
        self.assertIn("cortex-m/counterpart|cortex-m0", result.stderr)

    def test_builds_that_refuse_everything_alike_fail(self):
        result = modes("sys.exit(1)\n", "sys.exit(1)\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no assembly digest was emitted", result.stderr)


if __name__ == "__main__":
    unittest.main()
