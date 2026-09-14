#!/usr/bin/env python3
"""Exercise build.sh's real invalidation decision, without invoking a builder."""
import os
import json
from pathlib import Path
import subprocess
import tempfile
import shutil
import shlex
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/build.sh").read_text()
START = "Previous=''\n"
HELPERS = SCRIPT[SCRIPT.index("landin_paths() {"):
                 SCRIPT.index('Current="$(landin_manifest)"')]
MANIFEST = SCRIPT[SCRIPT.index("landin_manifest() {"):
                  SCRIPT.index('Incremental=')]
DECISION = HELPERS + SCRIPT[SCRIPT.index(START):
                            SCRIPT.index("\nNoop_Arguments=no")]
BASE = ["1 10 /src/main.adb", "2 20 /src/host.c", "3 30 /src/host.h",
        "4 40 /src/lib.gpr", "5 50 /scripts/build.sh",
        "6 60 /scripts/build_lock.py", "mode debug tag test",
        "gnat pinned", "gprbuild pinned", "toolchain configuration selected",
        'toolchain c-driver {"path": "/tools/selected-cc", "sha256": "123"}']


class BuildInventory(unittest.TestCase):
    def decision(self, old, new, incremental="yes", fail_tool=None):
        # This is deliberately the production branch including both inventory
        # and fixed-identity comparisons, not a copy of its regexes. Its only
        # destructive operation addresses our disposable fixture directory.
        with tempfile.TemporaryDirectory(prefix="landin-inventory-") as tmp:
            build = Path(tmp) / "build"
            build.mkdir()
            manifest = build / "source-manifest.txt"
            manifest.write_text("\n".join(sorted(old)) + "\n")
            env = dict(os.environ)
            if fail_tool:
                fake = Path(tmp) / fail_tool
                fake.write_text("#!/bin/sh\nexit 23\n")
                fake.chmod(0o755)
                env["PATH"] = tmp + os.pathsep + env["PATH"]
            result = subprocess.run(
                ["sh", "-eu", "-c", DECISION], text=True, capture_output=True,
                env={**env, "Manifest": str(manifest),
                     "LANDIN_BUILD_DIR": str(build),
                     "Current": "\n".join(sorted(new)),
                     "Incremental": incremental}, check=True, timeout=5)
            return build.exists(), result.stdout

    def test_inventory_add_remove_rename(self):
        for extension in ("c", "h", "adb", "ads"):
            row = f"7 70 /src/member.{extension}"
            for operation, old, new in (
                ("add", BASE, BASE + [row]),
                ("remove", BASE + [row], BASE),
                ("rename", BASE + [row],
                 BASE + [f"7 70 /src/renamed.{extension}"]),
            ):
                with self.subTest(extension=extension, operation=operation):
                    exists, text = self.decision(old, new)
                    self.assertFalse(exists)
                    self.assertIn("inventory or project changed", text)

    def test_source_content_is_incremental(self):
        for extension in ("adb", "c", "h"):
            old = BASE + [f"0 70 /src/member.{extension}"]
            new = BASE + [f"999 71 /src/member.{extension}"]
            with self.subTest(extension=extension):
                exists, text = self.decision(old, new)
                self.assertTrue(exists)
                self.assertIn("using checksum recompilation", text)

    def test_fixed_identity_changes_are_clean(self):
        for row in BASE[3:]:
            with self.subTest(row=row):
                new = ["9" + entry if entry == row else entry for entry in BASE]
                exists, text = self.decision(BASE, new)
                self.assertFalse(exists)
                self.assertIn("inventory or project changed", text)

    def test_unchanged_does_nothing(self):
        self.assertEqual(self.decision(BASE, BASE), (True, ""))

    def test_ordinary_gate_still_cleans_content_changes(self):
        new = ["9 10 /src/main.adb"] + BASE[1:]
        exists, text = self.decision(BASE, new, incremental="no")
        self.assertFalse(exists)
        self.assertIn("sources changed since the last build", text)

    def test_failed_inventory_producers_abort(self):
        changed = ["9 10 /src/main.adb"] + BASE[1:]
        for tool in ("awk", "sort", "grep", "cat"):
            with self.subTest(tool=tool):
                with self.assertRaises(subprocess.CalledProcessError):
                    self.decision(BASE, changed, fail_tool=tool)


class ManifestFailures(unittest.TestCase):
    def manifest(self, failure=None):
        with tempfile.TemporaryDirectory(prefix="landin-manifest-") as tmp:
            root = Path(tmp)
            ada = root / "compiler/ada"
            files = ("compiler/ada/src/main.adb",
                     "compiler/ada/tests/src/test.adb",
                     "compiler/ada/library.gpr", "scripts/build.sh",
                     "scripts/env.sh", "scripts/build_lock.py",
                     "scripts/build_config.py")
            for name in files:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name + "\n")
            (root / "scripts/build_config.py").write_text(
                "raise SystemExit(23)\n" if failure == "configuration" else
                "print('toolchain configuration selected')\n")
            fake = root / "fake"
            fake.mkdir()
            for tool in ("gnat", "gprbuild"):
                path = fake / tool
                path.write_text("#!/bin/sh\nprintf '%s\\n' 'pinned banner' "
                                "'additional version line'\n")
                path.chmod(0o755)
            if failure in ("source", "project", "script"):
                pattern = {"source": "*.adb", "project": "*.gpr",
                           "script": "*/scripts/build.sh"}[failure]
                body = ("#!/bin/sh\ncase \"$1\" in " + pattern
                        + ") exit 23 ;; esac\nexec "
                        + shlex.quote(shutil.which("cksum")) + ' "$@"\n')
                (fake / "cksum").write_text(body)
                (fake / "cksum").chmod(0o755)
            elif failure and failure != "configuration":
                (fake / failure).write_text("#!/bin/sh\nexit 23\n")
                (fake / failure).chmod(0o755)
            written = root / "saved-manifest"
            written.write_text("previous successful manifest\n")
            result = subprocess.run(
                ["sh", "-eu", "-c", MANIFEST
                 + 'printf \'%s\\n\' "$Current" > "$WRITTEN"\n'],
                text=True, capture_output=True, timeout=5,
                env={**os.environ, "PATH": str(fake) + os.pathsep
                     + os.environ["PATH"], "LANDIN_ROOT": str(root),
                     "LANDIN_ADA_DIR": str(ada), "LANDIN_BUILD_MODE": "debug",
                     "LANDIN_BUILD_TAG": "test", "WRITTEN": str(written),
                     "Configuration": str(root / "native.cgpr")})
            text = written.read_text()
            if not failure:
                rows = subprocess.check_output(
                    ["cksum", *[str(root / name) for name in files]],
                    text=True, timeout=5).splitlines()
                expected = (sorted(rows[:2]) + rows[2:3] + sorted(rows[3:])
                            + ["mode debug tag test", "gnat pinned banner",
                               "gprbuild pinned banner",
                               "toolchain configuration selected"])
                self.assertEqual(text.splitlines(), expected)
            return result.returncode, text

    def test_manifest_format_is_preserved(self):
        self.assertEqual(self.manifest()[0], 0)

    def test_failed_manifest_producer_preserves_previous_manifest(self):
        for failure in ("find", "source", "project", "script", "sort",
                        "gnat", "gprbuild", "sed", "configuration"):
            with self.subTest(failure=failure):
                code, text = self.manifest(failure)
                self.assertNotEqual(code, 0)
                self.assertEqual(text, "previous successful manifest\n")


class ConfiguredBuild(unittest.TestCase):
    """Run the real wrapper/configuration helper with disposable fake tools."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="landin configured ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("build.sh", "build_config.py"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        (scripts / "build_lock.py").write_text("# fixture lock identity\n")
        (scripts / "env.sh").write_text('''set -eu
LANDIN_ROOT="$FAKE_ROOT"
LANDIN_ADA_DIR="$LANDIN_ROOT/compiler/ada"
LANDIN_BUILD_TAG=test
LANDIN_BUILD_MODE=debug
LANDIN_BUILD_DIR="$LANDIN_ADA_DIR/build/test/debug"
export LANDIN_BUILD_DIR
landin_build_lock() { :; }
landin_require() { command -v "$1" >/dev/null; }
''')
        self.executable(scripts / "toolchain.sh", "#!/bin/sh\nexit 0\n")
        ada = self.root / "compiler/ada"
        for name in ("src/main.adb", "src/host.c", "tests/src/test.adb",
                     "refine.gpr", "landin_tests.gpr"):
            path = ada / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name + "\n")
        fake = self.root / "fake"
        fake.mkdir()
        self.driver = fake / "selected cc"
        self.alternative = fake / "another cc"
        for path in (self.driver, self.alternative):
            self.executable(path, "#!/bin/sh\nprintf '%s\\n' 'selected version'\n")
        self.selection = self.root / "selection"
        self.selection.write_text(str(self.driver))
        self.executable(fake / "gcc", "#!/bin/sh\necho 'unselected version'\n")
        self.executable(fake / "gnat", "#!/bin/sh\necho 'pinned Ada'\n")
        # This prints commands instead of compiling anything. The only invoked
        # C-driver action is --version from the production configuration helper.
        self.executable(fake / "gprbuild", '''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1:] == ["--version"]:
    print("pinned builder")
    raise SystemExit(0)
root = pathlib.Path(os.environ["FAKE_ROOT"])
with (root / "calls").open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
configs = [arg.split("=", 1)[1] for arg in sys.argv[1:]
           if arg.startswith("--config=")]
assert len(configs) == 1 and pathlib.Path(configs[0]).is_file()
build = pathlib.Path(os.environ["LANDIN_BUILD_DIR"])
(build / "bin").mkdir(parents=True, exist_ok=True)
for name in ("refine", "landin_tests"):
    path = build / "bin" / name
    path.write_text("#!/bin/sh\\nexit 0\\n")
    path.chmod(0o755)
''')
        self.executable(fake / "gprconfig", '''#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ["FAKE_ROOT"])
mode = os.environ.get("CONFIG_FAILURE", "")
if mode == "process":
    raise SystemExit(23)
driver = (root / "selection").read_text()
if mode == "relative":
    driver = "gcc"
declaration = 'for Driver ("C") use "' + driver.replace('"', '""') + '";'
if mode == "missing":
    declaration = ""
elif mode == "duplicate":
    declaration += "\\n" + declaration
path = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
path.write_text("-- generated at " + str(path) + "\\n"
                + "configuration project Default is\\n"
                + "for Target use \\\"" + os.environ.get("CONFIG_TARGET", "native")
                + "\\\";\\npackage Compiler is\\n" + declaration
                + "\\nend Compiler;\\nend Default;\\n")
''')
        self.env = {**os.environ, "FAKE_ROOT": str(self.root),
                    "PATH": str(fake) + os.pathsep + os.environ["PATH"],
                    "LANDIN_BUILD_INCREMENTAL": "yes"}
        self.build = ada / "build/test/debug"
        self.manifest = self.build / "source-manifest.txt"
        self.configuration = ada / ".build-locks/test-debug.cgpr"

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_build(self, *arguments, extra=None):
        return subprocess.run(
            ["sh", str(self.root / "scripts/build.sh"), *arguments],
            env={**self.env, **(extra or {})}, text=True, capture_output=True,
            timeout=5)

    def calls(self):
        return [json.loads(line) for line in
                (self.root / "calls").read_text().splitlines()]

    def test_snapshot_is_used_and_unchanged_configuration_is_current(self):
        first = self.run_build()
        self.assertEqual(first.returncode, 0, first.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual([call[call.index("-P") + 1] for call in calls],
                         ["refine.gpr", "landin_tests.gpr"])
        for call in calls:
            self.assertIn("--config=" + str(self.configuration), call)
        manifest = self.manifest.read_text()
        identity = json.loads(next(line.removeprefix("toolchain c-driver ")
                                   for line in manifest.splitlines()
                                   if line.startswith("toolchain c-driver ")))
        self.assertEqual(identity["path"], str(self.driver))
        self.assertEqual(identity["version"], "selected version")
        self.assertNotIn("unselected version", manifest)
        stamp = self.configuration.stat().st_mtime_ns
        second = self.run_build()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("developer build is current", second.stdout)
        self.assertEqual(self.calls(), calls)
        self.assertEqual(self.configuration.stat().st_mtime_ns, stamp)
        self.assertEqual(self.manifest.read_text(), manifest)

    def test_selected_identity_changes_clean_both_build_modes(self):
        for incremental in ("yes", "no"):
            extra = {"LANDIN_BUILD_INCREMENTAL": incremental}
            self.selection.write_text(str(self.driver))
            result = self.run_build(extra=extra)
            self.assertEqual(result.returncode, 0, result.stderr)
            for change in ("path", "version", "binary", "configuration"):
                with self.subTest(incremental=incremental, change=change):
                    marker = self.build / "stale-object"
                    marker.write_text("old C object")
                    old = self.manifest.read_text()
                    if change == "path":
                        self.selection.write_text(str(self.alternative))
                    elif change == "version":
                        self.executable(self.alternative,
                                        "#!/bin/sh\necho 'new version'\n")
                    elif change == "binary":
                        with self.alternative.open("a") as stream:
                            stream.write("# changed driver, same version\n")
                    else:
                        extra["CONFIG_TARGET"] = "another-native-target"
                    result = self.run_build(extra=extra)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("rebuilding from clean", result.stdout)
                    self.assertFalse(marker.exists())
                    self.assertNotEqual(self.manifest.read_text(), old)

    def test_failed_configuration_keeps_successful_build(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        old = self.manifest.read_text()
        snapshot = self.configuration.read_text()
        calls = self.calls()
        for failure in ("process", "missing", "duplicate", "relative",
                        "version", "empty"):
            with self.subTest(failure=failure):
                self.executable(self.driver,
                                "#!/bin/sh\necho 'selected version'\n")
                if failure in ("version", "empty"):
                    self.executable(self.driver, "#!/bin/sh\nexit "
                                    + ("23" if failure == "version" else "0")
                                    + "\n")
                result = self.run_build(extra={"CONFIG_FAILURE": failure})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.manifest.read_text(), old)
                self.assertEqual(self.configuration.read_text(), snapshot)
                self.assertEqual(self.calls(), calls)

    def test_configuration_override_is_refused_before_build(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        old = self.manifest.read_text()
        calls = self.calls()
        for argument in ("--config=other.cgpr", "--autoconf=other.cgpr"):
            with self.subTest(argument=argument):
                result = self.run_build(argument)
                self.assertEqual(result.returncode, 2)
                self.assertIn("owns the native GPR configuration", result.stderr)
                self.assertEqual(self.manifest.read_text(), old)
                self.assertEqual(self.calls(), calls)


class RecipeChecksum(unittest.TestCase):
    def test_recipe_failure_stops_before_container(self):
        for fails, override in ((False, ""), (False, "test:override"),
                                (True, "test:override"), ("empty", "")):
            with self.subTest(fails=fails, override=override):
                with tempfile.TemporaryDirectory(prefix="landin-recipe-") as tmp:
                    root = Path(tmp)
                    scripts = root / "scripts"
                    scripts.mkdir()
                    shutil.copyfile(ROOT / "scripts/linux-loop.sh",
                                    scripts / "linux-loop.sh")
                    (scripts / "env.sh").write_text(
                        "set -eu\nLANDIN_ROOT=" + shlex.quote(tmp)
                        + "\nLANDIN_BUILD_MODE=debug\n")
                    recipe = root / "environments/linux-amd64/Containerfile"
                    recipe.parent.mkdir(parents=True)
                    recipe.write_text("FROM scratch\n")
                    fake = root / "fake"
                    fake.mkdir()
                    calls = root / "container-calls"
                    (fake / "container").write_text(
                        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CALLS\"\n")
                    (fake / "container").chmod(0o755)
                    if fails:
                        (fake / "cksum").write_text(
                            "#!/bin/sh\nexit "
                            + ("0" if fails == "empty" else "23") + "\n")
                        (fake / "cksum").chmod(0o755)
                    result = subprocess.run(
                        ["sh", str(scripts / "linux-loop.sh"), "true"],
                        text=True, capture_output=True, timeout=5,
                        env={**os.environ, "PATH": str(fake) + os.pathsep
                             + os.environ["PATH"], "CALLS": str(calls),
                             "LANDIN_LINUX_IMAGE": override,
                             "LANDIN_LINUX_REBUILD": "no"})
                    if fails:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertFalse(calls.exists())
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        rows = calls.read_text().splitlines()
                        self.assertEqual(len(rows), 2)
                        checksum = subprocess.check_output(
                            ["cksum", str(recipe)], text=True,
                            timeout=5).split()[0]
                        expected = override or "landin-linux-amd64:" + checksum
                        self.assertEqual(rows[0], "image inspect " + expected)
                        self.assertIn(expected + " true", rows[1])


if __name__ == "__main__":
    unittest.main()
