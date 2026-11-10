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
    "r440-c-signatures|cortex-m0|debug|optimize=size|specialize=auto": "refused:1",
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
        fixture = root / "compiler/tests/fixtures/positive/r440-c-signatures"
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
        del other["r440-c-signatures|cortex-m0|debug|optimize=size|specialize=auto"]
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
        other["r440-c-signatures|cortex-m0|debug|optimize=size|specialize=auto"] = "e" * 64
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)

    def test_shared_unexpected_refusal_fails(self):
        other = dict(BASE)
        other["alias-conversion|linux-x86-64|debug|optimize=size|specialize=auto"] = "refused:1"
        result = compare(other, dict(other))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected emission result", result.stderr)

    def test_written_c_function_refusal_is_confined_to_rv32(self):
        #  rv32 has no enabled C ABI (D660), and Cortex-M's AAPCS32 has
        #  had one since D920.
        for target in ("cortex-m0", "linux-x86-64", "linux-arm64",
                       "darwin-arm64", "freebsd-x86-64", "freebsd-arm64",
                       "linux-rv64", "rv32"):
            other = dict(BASE)
            key = (f"written-type-c-function|{target}|debug"
                   "|optimize=size|specialize=auto")
            other[key] = "refused:1"
            result = compare(other, dict(other))
            self.assertEqual(result.returncode,
                             0 if target == "rv32" else 1,
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
        refused = {"r440-c-signatures|cortex-m0|debug|optimize=size|specialize=auto": "refused:1"}
        result = compare(refused, dict(refused))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no assembly digest was emitted", result.stderr)

    def test_missing_assembly_is_not_an_expected_refusal(self):
        other = dict(BASE)
        other["r440-c-signatures|cortex-m0|debug|optimize=size|specialize=auto"] = "refused:0"
        result = compare(other, dict(other))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected emission result", result.stderr)

    def test_identical_manifests_that_fail_alike_are_not_said_to_differ(self):
        #  Each manifest's own faults were once reported per manifest under
        #  "the manifests disagree", 432 of them between identical files.
        other = dict(BASE)
        other["alias-conversion|linux-x86-64|debug|optimize=size|specialize=auto"] = "refused:1"
        result = compare(other, dict(other))
        self.assertEqual(result.returncode, 1)
        self.assertIn("2 manifests agree on all 3 entries", result.stdout)
        self.assertNotIn("the manifests differ", result.stderr)
        self.assertIn("every manifest fails its own expectations, on the "
                      "same entries, so this is no difference between them: "
                      "1 fault(s)", result.stderr)
        self.assertEqual(result.stderr.count("unexpected emission result"), 1)

    def test_a_difference_and_a_manifests_own_fault_are_reported_apart(self):
        other = dict(BASE)
        key = "alias-conversion|linux-x86-64|debug|optimize=size|specialize=auto"
        other[key] = "refused:1"
        result = compare(BASE, other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("the manifests differ", result.stderr)
        self.assertIn("1 difference(s)", result.stderr)
        self.assertIn("m1.json fails its own expectations: 1 fault(s)",
                      result.stderr)
        self.assertNotIn("m0.json fails", result.stderr)

    def test_a_runtime_refusal_the_inventory_records_is_expected(self):
        #  `compare` reads this checkout's firmware inventory, as `emit`
        #  reads its ROOT's, so the documented before-and-after of the
        #  runtime corpus passes on an unchanged tree.
        inventory = json.loads(
            (ROOT / "compiler/tests/cortex-m/corpus.json").read_text())["fixtures"]
        name = next(name for name, row in sorted(inventory.items())
                    if name.startswith("runtime/") and row["mode"] == "execute"
                    and row.get("targets", {}).get("xtensa", {}).get("mode") == "refuse"
                    and row.get("lanes", {}).get("esp32c3", {}).get("mode") == "refuse")
        recorded = dict(BASE)
        for target, level in (("rv32", ""), ("xtensa", "|level=xtensa-esp32"),
                              ("xtensa", "|level=xtensa-esp32s3")):
            for debug in ("", "|debug=lines"):
                recorded["%s|%s|debug|optimize=size|specialize=auto%s%s"
                         % (name, target, level, debug)] = "refused:1"
        result = compare(recorded, dict(recorded))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agree on all 9 entries", result.stdout)
        #  On a target the inventory does not record, it is still a fault.
        recorded["%s|cortex-m0|debug|optimize=size|specialize=auto" % name] = "refused:1"
        result = compare(recorded, dict(recorded))
        self.assertEqual(result.returncode, 1)
        self.assertIn("%s|cortex-m0" % name, result.stderr)

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
        self.assertEqual(sum(len(value) == 64 for value in manifest.values()), 162)

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
            self.assertEqual(len(manifest), 10 * 2 * 3 * 3)
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


#  A stub compiler that writes the controls it was given as its assembly,
#  so each entry's digest says which request made it.
SAYS_ITS_CONTROLS = (
    "#!" + sys.executable + "\n"
    "import pathlib, sys\n"
    "args = sys.argv[1:]\n"
    "said = [a for a in args if a.startswith(('--target=', '--build-mode=',\n"
    "    '--optimize=', '--specialize=', '--debug='))]\n"
    "pathlib.Path(args[args.index('-o') + 1]).write_text(' '.join(said))\n")


def selected(stub, *options, fixtures=("positive/a", "positive/b", "runtime/r"),
             inventory=None):
    """Run `emit` with OPTIONS over a small tree of FIXTURES and STUB.

    INVENTORY is the firmware corpus's rows, written when given."""
    with tempfile.TemporaryDirectory() as tmp:
        area = Path(tmp)
        for name in fixtures:
            fixture = area / "compiler/tests/fixtures" / name
            fixture.mkdir(parents=True)
            (fixture / "fixture.meta").write_text(
                "program: main.ldn\ntargets: linux-x86-64\n")
        if inventory is not None:
            (area / "compiler/tests/cortex-m").mkdir(parents=True)
            (area / "compiler/tests/cortex-m/corpus.json").write_text(
                json.dumps({"fixtures": inventory}))
        refine = area / "refine"
        refine.write_text(stub)
        refine.chmod(0o755)
        out = area / "manifest.json"
        result = subprocess.run(
            [sys.executable, str(CHECK), "emit", str(refine), str(area), str(out)]
            + list(options), capture_output=True, text=True)
        return result, (json.loads(out.read_text()) if out.exists() else None)


def controls_digest(*said):
    return hashlib.sha256(" ".join(said).encode()).hexdigest()


class Selectors(unittest.TestCase):
    """A before-and-after proof compiles what it names and says why it refused."""

    def test_fixtures_profiles_and_modes_select_entries(self):
        result, manifest = selected(
            SAYS_ITS_CONTROLS, "linux-x86-64", "--fixture=positive/a",
            "--fixture=runtime/r", "--profile=size/auto", "--mode=release",
            "--jobs=2")
        self.assertEqual(result.returncode, 0, result.stderr)
        said = controls_digest("--target=linux-x86-64", "--build-mode=release",
                               "--optimize=size", "--specialize=auto")
        self.assertEqual(manifest, {
            "a|linux-x86-64|release|optimize=size|specialize=auto": said,
            "runtime/r|linux-x86-64|release|optimize=size|specialize=auto": said})

    def test_a_corpus_selector_adds_the_runtime_corpus(self):
        result, manifest = selected(
            SAYS_ITS_CONTROLS, "linux-x86-64", "--corpus=positive",
            "--corpus=runtime", "--profile=none-off", "--mode=debug",
            fixtures=("positive/a", "runtime/r"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(manifest), [
            "a|linux-x86-64|debug|optimize=none|specialize=off",
            "runtime/r|linux-x86-64|debug|optimize=none|specialize=off"])

    REFUSES_ON = (
        "#!" + sys.executable + "\n"
        "import pathlib, sys\n"
        "args = sys.argv[1:]\n"
        "if any(a in args for a in %r):\n"
        "    sys.exit(1)\n"
        "pathlib.Path(args[args.index('-o') + 1]).write_text(' '.join(args[:4]))\n")

    def test_the_runtime_corpus_knows_its_firmware_refusals(self):
        #  The firmware corpus executes runtime/r on its reference and
        #  records that rv32's default level and Xtensa refuse it.  Those
        #  refusals are what the manifest should hold, at both Xtensa
        #  configurations and with debug information.
        refusing = {"mode": "refuse", "codes": ["L0346"]}
        inventory = {"runtime/r": {"mode": "execute",
                                   "lanes": {"esp32c3": refusing},
                                   "targets": {"xtensa": refusing}}}
        options = ("linux-x86-64,cortex-m0,rv32,xtensa", "--corpus=runtime",
                   "--profile=size-auto", "--debug-info")
        result, manifest = selected(
            self.REFUSES_ON % (("--target=rv32", "--target=xtensa"),),
            *options, inventory=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        refused = sorted(key for key, value in manifest.items()
                         if value == "refused:1")
        self.assertEqual(len(refused), 3 * 2 * 2)
        self.assertEqual({key.split("|")[1] for key in refused},
                         {"rv32", "xtensa"})
        #  One the inventory does not record is still a fault, and named.
        result, manifest = selected(
            self.REFUSES_ON % (("--target=rv32", "--target=xtensa",
                                "--target=cortex-m0"),),
            *options, inventory=inventory)
        self.assertEqual(result.returncode, 1)
        self.assertIn("manifest lacks required assembly evidence: 4 fault(s)",
                      result.stderr)
        self.assertIn("runtime/r|cortex-m0|", result.stderr)
        self.assertNotIn("runtime/r|rv32|", result.stderr)

    def test_debug_information_is_each_targets_own(self):
        result, manifest = selected(
            SAYS_ITS_CONTROLS, "linux-x86-64,cortex-m0", "--fixture=positive/b",
            "--profile=none-off", "--mode=debug", "--debug-info")
        self.assertEqual(result.returncode, 0, result.stderr)
        for target, debug in (("linux-x86-64", "full"), ("cortex-m0", "lines")):
            base = "b|%s|debug|optimize=none|specialize=off" % target
            controls = ("--target=" + target, "--build-mode=debug",
                        "--optimize=none", "--specialize=off")
            self.assertEqual(manifest[base], controls_digest(*controls))
            self.assertEqual(manifest[base + "|debug=" + debug],
                             controls_digest(*controls, "--debug=" + debug))
        self.assertEqual(len(manifest), 4)

    def test_an_unexpected_refusal_says_its_first_diagnostic(self):
        stub = ("#!/bin/sh\n"
                "printf 'error[L0500]: no library was found\\n"
                "  --> main.ldn:1:1\\n  |\\n1 | quoted source\\n  | ^^^\\n"
                "  = note: name it with --library=PATH\\n"
                "error[L0001]: a second refusal\\n' >&2\n"
                "exit 1\n")
        result, manifest = selected(stub, "linux-x86-64", "--fixture=positive/a",
                                    "--profile=none-off", "--mode=debug")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(set(manifest.values()), {"refused:1"})
        self.assertIn("'refused:1': error[L0500]: no library was found"
                      " --> main.ldn:1:1 = note: name it with --library=PATH\n",
                      result.stderr)
        self.assertNotIn("quoted source", result.stderr)
        self.assertNotIn("L0001", result.stderr)

    def test_a_runtime_fixture_links_as_its_record_says_where_it_is_hosted(self):
        with tempfile.TemporaryDirectory() as tmp:
            area = Path(tmp)
            fixture = area / "compiler/tests/fixtures/runtime/r"
            fixture.mkdir(parents=True)
            (fixture / "fixture.meta").write_text(
                "program: main.ldn\nlink: libc\ntargets: linux-x86-64\n")
            refine = area / "refine"
            refine.write_text(
                "#!" + sys.executable + "\n"
                "import pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "said = [a for a in args if a.startswith(('--target=', '--link='))]\n"
                "pathlib.Path(args[args.index('-o') + 1]).write_text(' '.join(said))\n")
            refine.chmod(0o755)
            out = area / "manifest.json"
            result = subprocess.run(
                [sys.executable, str(CHECK), "emit", str(refine), str(area), str(out),
                 "linux-x86-64", "--corpus=runtime", "--profile=none-off",
                 "--mode=debug"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(out.read_text()), {
                "runtime/r|linux-x86-64|debug|optimize=none|specialize=off":
                    controls_digest("--target=linux-x86-64", "--link=libc")})

    def test_a_debug_entry_refuses_where_its_entry_without_does(self):
        other = dict(BASE)
        other["r440-c-signatures|cortex-m0|debug|optimize=size"
              "|specialize=auto|debug=lines"] = "refused:1"
        result = compare(other, dict(other))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_unknown_selection_is_refused(self):
        for options in (("--fixture=a",), ("--fixture=negative/a",),
                        ("--profile=fast-off",), ("--corpus=negative",),
                        ("--jobs=0",)):
            with self.subTest(options=options):
                result, _ = selected(SAYS_ITS_CONTROLS, "linux-x86-64", *options)
                self.assertEqual(result.returncode, 2, result.stderr)


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
            for level in ("xtensa-esp32", "xtensa-esp32s3"):
                key = ("example|xtensa|release|optimize=size|specialize=auto|level=" + level)
                said = "--target=xtensa --level=" + level
                self.assertEqual(manifest[key], hashlib.sha256(said.encode()).hexdigest())


class OwnTarget(unittest.TestCase):
    """A fixture of one target is compiled for it alone (D740)."""

    def emitted(self, meta):
        with tempfile.TemporaryDirectory() as tmp:
            area = Path(tmp)
            fixture = area / "compiler/tests/fixtures/positive/example"
            fixture.mkdir(parents=True)
            (fixture / "fixture.meta").write_text("program: main.ldn\n" + meta)
            refine = area / "refine"
            #  Every other target refuses it, as rv32's descriptions are.
            refine.write_text(
                "#!" + sys.executable + "\n"
                "import pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "if '--target=rv32' not in args:\n"
                "    sys.exit(1)\n"
                "pathlib.Path(args[args.index('-o') + 1]).write_text('asm')\n")
            refine.chmod(0o755)
            out = area / "manifest.json"
            result = subprocess.run(
                [sys.executable, str(CHECK), "emit", str(refine), str(area), str(out)],
                capture_output=True, text=True)
            return result, (json.loads(out.read_text()) if out.exists() else {})

    def test_a_fixture_of_one_target_needs_no_listed_refusals(self):
        result, manifest = self.emitted("targets: rv32\nargs: --target=rv32\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({key.split("|")[1] for key in manifest}, {"rv32"})
        self.assertEqual(len(manifest), 2 * 3 * 3)

    def test_args_alone_do_not_make_a_fixture_one_targets(self):
        #  `range-subtypes` chooses cortex-m0 in its `args` and names seven
        #  targets: every target compiles it, and a refusal is a fault.
        result, manifest = self.emitted(
            "targets: rv32, cortex-m0\nargs: --target=rv32\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected emission result", result.stderr)
        self.assertEqual(len(manifest), 10 * 2 * 3 * 3)

    def test_the_build_modes_compare_it_on_its_target_alone(self):
        sys.path.insert(0, str(CHECK.parent))
        self.addCleanup(sys.path.remove, str(CHECK.parent))
        import emit_manifest
        with tempfile.TemporaryDirectory() as tmp:
            positive = Path(tmp) / "compiler/tests/fixtures/positive"
            for name, meta in (("shared", ""),
                               ("own", "targets: linux-arm64\n"
                                       "args: --target=linux-arm64\n")):
                (positive / name).mkdir(parents=True)
                (positive / name / "fixture.meta").write_text(
                    "program: main.ldn\n" + meta)
            (Path(tmp) / "compiler/tests/fixtures/runtime").mkdir()
            entries = emit_manifest.mode_entries(
                tmp, ("linux-x86-64", "linux-arm64"))
        self.assertEqual({name: wanted for name, _, _, wanted, _ in entries},
                         {"positive/shared": ("linux-x86-64", "linux-arm64"),
                          "positive/own": ("linux-arm64",)})


def modes(debug_body, release_body, executed_row=None):
    """Run `modes` over a small corpus with two stub compilers.

    EXECUTED_ROW adds to the inventory's row of `runtime/executed`."""
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
            "program: main.ldn\ntargets: linux-x86-64, linux-rv64\nlink: libc\n")
        #  The firmware corpus executes one runtime fixture its `targets:`
        #  does not name, and one only through its counterpart.
        (executed / "fixture.meta").write_text(
            "program: main.ldn\ntargets: linux-x86-64\n")
        (replaced / "fixture.meta").write_text(
            "program: main.ldn\ntargets: linux-x86-64\n")
        (tests / "cortex-m/corpus.json").write_text(json.dumps({"fixtures": {
            "runtime/executed": dict({"mode": "execute"}, **(executed_row or {})),
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

    def test_runtime_link_policy_is_carried_into_both_build_modes(self):
        debug = ("out.write_text('asm' + ('libc' if where == 'hosted' "
                 "and '--link=libc' in args else ''))\n")
        release = "out.write_text('asm' + ('libc' if where == 'hosted' else ''))\n"
        result = modes(debug, release)
        self.assertEqual(result.returncode, 0, result.stderr)

    SAME = "out.write_text(' '.join(args[:4]) + where)\n"

    def test_agreeing_builds_pass_over_every_source_and_profile(self):
        result = modes(self.SAME, self.SAME)
        self.assertEqual(result.returncode, 0, result.stderr)
        #  The positive fixture on four targets; each runtime fixture on
        #  the one of them its record names, and the one the firmware
        #  corpus executes on both firmware targets too; the counterpart on
        #  both firmware targets; each at the four standard profiles.
        self.assertIn("sources 5  requests 68  emitted 68", result.stdout)

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

    #  The inventory records `runtime/executed` as refused on the RV32 lane
    #  whose level `--target=rv32` builds, and on Xtensa.
    REFUSED_ON = {"lanes": {"esp32c3": {"mode": "refuse", "codes": ["L0346"]},
                            "sifive-e": {"mode": "execute"}},
                  "targets": {"xtensa": {"mode": "refuse", "codes": ["L0346"]}}}
    REFUSE = ("if where == 'executed' and (%s):\n"
              "    print('%s'); sys.exit(1)\n")
    THERE = "'--target=rv32' in args or '--target=xtensa' in args"

    def test_a_refusal_the_inventory_records_must_be_said_the_same_way(self):
        refuse = self.REFUSE % (self.THERE, "%s")
        result = modes(refuse % "no" + self.SAME, refuse % "no" + self.SAME,
                       self.REFUSED_ON)
        self.assertEqual(result.returncode, 0, result.stderr)
        #  rv32 once and both Xtensa configurations, at four profiles.
        self.assertIn("refused as expected 12  unexpected 0", result.stdout)
        result = modes(refuse % "no" + self.SAME, refuse % "not so" + self.SAME,
                       self.REFUSED_ON)
        self.assertEqual(result.returncode, 1)
        self.assertIn("runtime/executed|rv32|", result.stderr)

    def test_a_refusal_both_builds_share_is_not_agreement(self):
        #  Both builds refusing a program the corpus expects to compile
        #  agree with each other, and that passed as "refused alike".
        refuse = "if where == 'counterpart':\n    print('no'); sys.exit(1)\n"
        result = modes(refuse + self.SAME, refuse + self.SAME)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected 16", result.stdout)
        self.assertIn("cortex-m/counterpart|cortex-m0|optimize=none|specialize=off: "
                      "both compilers refuse it, and it is not in the expected refusals",
                      result.stderr)
        #  The reference target executes the fixture: a refusal there is
        #  never the one its row records for another target.
        refuse = self.REFUSE % ("'--target=cortex-m0' in args", "no")
        result = modes(refuse + self.SAME, refuse + self.SAME, self.REFUSED_ON)
        self.assertEqual(result.returncode, 1)
        self.assertIn("runtime/executed|cortex-m0|", result.stderr)

    def test_two_builds_that_crash_alike_do_not_agree(self):
        #  A compiler killed by a signal has refused nothing, even where a
        #  refusal is expected.
        crash = ("if where == 'executed' and (%s):\n"
                 "    import os, signal\n"
                 "    os.kill(os.getpid(), signal.SIGSEGV)\n" % self.THERE)
        result = modes(crash + self.SAME, crash + self.SAME, self.REFUSED_ON)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected 12", result.stdout)
        self.assertIn("both compilers ended with status -11, which is no refusal",
                      result.stderr)

    def test_builds_that_refuse_everything_alike_fail(self):
        result = modes("sys.exit(1)\n", "sys.exit(1)\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no assembly digest was emitted", result.stderr)


if __name__ == "__main__":
    unittest.main()
