#!/usr/bin/env python3
"""Exercise build.sh's real invalidation decision, without invoking a builder."""
import hashlib
import os
import re
import tarfile
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
                            SCRIPT.index("\n#  Only quiet output and a job count")]
BASE = ["source 1 compiler/ada/src/main.adb", "source 2 compiler/ada/src/host.c",
        "source 3 compiler/ada/src/host.h", "project 4 compiler/ada/lib.gpr",
        "project 5 compiler/ada/landin.adc", "identity 6 0123abc clean",
        "mode debug tag test", "switches ",
        "gnat pinned", "gprbuild pinned", "toolchain configuration selected",
        'toolchain c-driver {"path": "/tools/selected-cc", "sha256": "123"}',
        'toolchain gprbuild {"path": "/tools/builder", "sha256": "456"}']
FIXED = [row for row in BASE if row.split(" ", 1)[0]
         in ("project", "mode", "switches", "gnat", "gprbuild", "toolchain")]


def changed(row):
    """ROW with its content, not its path, changed."""
    words = row.split(" ")
    if words[0] in ("source", "project", "identity"):
        words[1] = "9" + words[1]
        return " ".join(words)
    return row + " changed"


class BuildInventory(unittest.TestCase):
    def decision(self, old, new, incremental="yes", fail_tool=None,
                 unfinished=None):
        # This is deliberately the production branch including both inventory
        # and fixed-identity comparisons, not a copy of its regexes. Its only
        # destructive operation addresses our disposable fixture directory.
        # It returns whether an object and the published compiler survived.
        with tempfile.TemporaryDirectory(prefix="landin-inventory-") as tmp:
            build = Path(tmp) / "build"
            (build / "bin").mkdir(parents=True)
            published = build / "bin" / "refine"
            published.write_text("published compiler\n")
            obj = build / "refine-obj" / "main.o"
            obj.parent.mkdir()
            obj.write_text("object\n")
            manifest = build / "source-manifest.txt"
            attempt = build / "attempt-manifest.txt"
            state = build / "build-state"
            if unfinished is None:
                manifest.write_text("\n".join(sorted(old)) + "\n")
            else:
                attempt.write_text("\n".join(sorted(old)) + "\n")
                state.write_text(unfinished + "\n")
            env = dict(os.environ)
            if fail_tool:
                fake = Path(tmp) / fail_tool
                fake.write_text("#!/bin/sh\nexit 23\n")
                fake.chmod(0o755)
                env["PATH"] = tmp + os.pathsep + env["PATH"]
            result = subprocess.run(
                ["sh", "-eu", "-c", DECISION], text=True, capture_output=True,
                env={**env, "Manifest": str(manifest),
                     "Attempt": str(attempt), "State": str(state),
                     "LANDIN_BUILD_DIR": str(build),
                     "LANDIN_BUILD_TAG": "test", "LANDIN_BUILD_MODE": "debug",
                     "Current": "\n".join(sorted(new)),
                     "Incremental": incremental}, check=True, timeout=5)
            self.assertEqual(published.read_text(), "published compiler\n",
                             "a rebuild removed the published compiler")
            return obj.exists(), result.stdout

    def test_inventory_add_remove_rename(self):
        for extension in ("c", "h", "adb", "ads"):
            row = f"source 7 compiler/ada/src/member.{extension}"
            for operation, old, new in (
                ("add", BASE, BASE + [row]),
                ("remove", BASE + [row], BASE),
                ("rename", BASE + [row],
                 BASE + [f"source 7 compiler/ada/src/renamed.{extension}"]),
            ):
                with self.subTest(extension=extension, operation=operation):
                    exists, text = self.decision(old, new)
                    self.assertFalse(exists)
                    self.assertIn("inventory or project changed", text)

    def test_source_content_is_incremental(self):
        for extension in ("adb", "c", "h"):
            old = BASE + [f"source 0 compiler/ada/src/member.{extension}"]
            new = BASE + [f"source 999 compiler/ada/src/member.{extension}"]
            with self.subTest(extension=extension):
                exists, text = self.decision(old, new)
                self.assertTrue(exists)
                self.assertIn("using checksum recompilation", text)

    def test_fixed_identity_changes_are_clean(self):
        for row in FIXED:
            with self.subTest(row=row):
                new = [changed(entry) if entry == row else entry
                       for entry in BASE]
                exists, text = self.decision(BASE, new)
                self.assertFalse(exists)
                self.assertIn("inventory or project changed", text)

    def test_provenance_change_is_incremental(self):
        # An edit to a build script reaches the objects only through the
        # provenance unit, so it recompiles that rather than everything.
        new = [changed(row) if row.startswith("identity ") else row
               for row in BASE]
        exists, text = self.decision(BASE, new)
        self.assertTrue(exists)
        self.assertIn("using checksum recompilation", text)

    def test_unchanged_does_nothing(self):
        self.assertEqual(self.decision(BASE, BASE), (True, ""))

    def test_failed_developer_build_keeps_what_it_compiled(self):
        exists, text = self.decision(BASE, BASE, unfinished="failed")
        self.assertTrue(exists)
        self.assertIn("did not finish (it failed); keeping what it compiled",
                      text)
        edited = [changed(BASE[0])] + BASE[1:]
        exists, text = self.decision(BASE, edited, unfinished="failed")
        self.assertTrue(exists)
        self.assertIn("using checksum recompilation", text)
        added = BASE + ["source 7 compiler/ada/src/member.adb"]
        exists, text = self.decision(BASE, added, unfinished="failed")
        self.assertFalse(exists)
        self.assertIn("inventory or project changed", text)

    def test_interrupted_developer_build_announces_its_discard(self):
        _, text = self.decision(BASE, BASE, unfinished="running")
        self.assertIn("(it was interrupted); discarding only what it wrote",
                      text)

    def test_unfinished_ordinary_build_is_clean_but_keeps_bin(self):
        for state in ("failed", "running"):
            with self.subTest(state=state):
                exists, text = self.decision(BASE, BASE, incremental="no",
                                             unfinished=state)
                self.assertFalse(exists)
                self.assertIn("rebuilding from clean, keeping bin/", text)

    def test_ordinary_gate_still_cleans_content_changes(self):
        new = [changed(BASE[0])] + BASE[1:]
        exists, text = self.decision(BASE, new, incremental="no")
        self.assertFalse(exists)
        self.assertIn("sources changed since the last build", text)

    def test_failed_inventory_producers_abort(self):
        edited = [changed(BASE[0])] + BASE[1:]
        for tool in ("awk", "sort", "grep", "sed"):
            with self.subTest(tool=tool):
                with self.assertRaises(subprocess.CalledProcessError):
                    self.decision(BASE, edited, fail_tool=tool)

    def test_linked_rows_are_not_what_was_requested(self):
        # The manifest as written also names what was linked; the decision
        # compares only what the build was asked to build.
        exists, text = self.decision(BASE + ["linked refine 0123"], BASE)
        self.assertEqual((exists, text), (True, ""))


class ManifestFailures(unittest.TestCase):
    def manifest(self, failure=None):
        with tempfile.TemporaryDirectory(prefix="landin-manifest-") as tmp:
            root = Path(tmp)
            ada = root / "compiler/ada"
            files = {
                "compiler/ada/src/main.adb": "main\n",
                "compiler/ada/src/host.c": "host\n",
                "compiler/ada/tests/src/test.adb": "test\n",
                "compiler/ada/refine.gpr":
                    'with "common.gpr";\nproject Refine is\n'
                    '   for Languages use ("Ada", "C");\n'
                    '   for Source_Dirs use ("src");\nend Refine;\n',
                "compiler/ada/landin_tests.gpr":
                    'project Landin_Tests is\n'
                    '   for Source_Dirs use ("tests/src");\n'
                    'end Landin_Tests;\n',
                "compiler/ada/common.gpr":
                    'abstract project Common is\n   package Compiler is\n'
                    '      for Local_Configuration_Pragmas use "local.adc";\n'
                    '   end Compiler;\nend Common;\n',
                "compiler/ada/local.adc": "pragma Ada_2022;\n",
                "scripts/build.sh": "build\n", "scripts/env.sh": "env\n",
                "scripts/build_lock.py": "lock\n",
            }
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            shutil.copyfile(ROOT / "scripts/build_identity.py",
                            root / "scripts/build_identity.py")
            if failure == "inputs":
                (root / "compiler/ada/refine.gpr").write_text(
                    'project Refine is\n   for Languages use ("Rust");\n'
                    'end Refine;\n')
            identity_source = root / "generated/landin-build_identity.ads"
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
            if failure and failure not in ("configuration", "inputs"):
                (fake / failure).write_text("#!/bin/sh\nexit 23\n")
                (fake / failure).chmod(0o755)
            written = root / "saved-manifest"
            written.write_text("previous successful manifest\n")
            result = subprocess.run(
                ["sh", "-eu", "-c", MANIFEST
                 + 'printf \'%s\\n\' "$Current" > "$WRITTEN"\n'],
                text=True, capture_output=True, timeout=10,
                env={**os.environ, "PATH": str(fake) + os.pathsep
                     + os.environ["PATH"], "LANDIN_ROOT": str(root),
                     "LANDIN_ADA_DIR": str(ada), "LANDIN_BUILD_MODE": "debug",
                     "LANDIN_BUILD_TAG": "test", "WRITTEN": str(written),
                     "Switches": "-R",
                     "Configuration": str(root / "native.cgpr"),
                     "Identity_Source": str(identity_source)})
            text = written.read_text()
            if not failure:
                rows = subprocess.check_output(
                    ["python3", str(root / "scripts/build_identity.py"),
                     "--root", str(root), "--mode", "debug", "--output",
                     str(identity_source), "--manifest"],
                    text=True).splitlines()
                self.assertEqual(
                    [row.split()[0] + " " + row.split()[-1]
                     for row in rows[:-1]],
                    ["project compiler/ada/common.gpr",
                     "project compiler/ada/landin_tests.gpr",
                     "project compiler/ada/local.adc",
                     "project compiler/ada/refine.gpr",
                     "source compiler/ada/src/host.c",
                     "source compiler/ada/src/main.adb",
                     "source compiler/ada/tests/src/test.adb"])
                self.assertTrue(rows[-1].startswith("identity "))
                expected = rows + ["mode debug tag test", "switches -R",
                                   "gnat pinned banner",
                                   "gprbuild pinned banner",
                                   "toolchain configuration selected"]
                self.assertEqual(text.splitlines(), expected)
                # The scripts that run the build are not inputs of it.
                self.assertNotIn("scripts/", text)
            return result.returncode, text

    def test_manifest_format_is_preserved(self):
        self.assertEqual(self.manifest()[0], 0)

    def test_failed_manifest_producer_preserves_previous_manifest(self):
        for failure in ("python3", "inputs", "gnat", "gprbuild", "sed",
                        "configuration"):
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
        for name in ("build.sh", "build_config.py", "build_identity.py",
                     "build_lock.py", "build_link.py"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        (scripts / "env.sh").write_text('''set -eu
LANDIN_ROOT="$FAKE_ROOT"
LANDIN_ADA_DIR="$LANDIN_ROOT/compiler/ada"
LANDIN_BUILD_TAG=test
LANDIN_BUILD_MODE=debug
LANDIN_BUILD_DIR="$LANDIN_ADA_DIR/build/test/debug"
export LANDIN_BUILD_DIR LANDIN_BUILD_TAG LANDIN_BUILD_MODE
landin_build_lock() { :; }
landin_require() { command -v "$1" >/dev/null; }
''')
        self.executable(scripts / "toolchain.sh", "#!/bin/sh\nexit 0\n")
        ada = self.root / "compiler/ada"
        for name in ("src/main.adb", "src/host.c", "tests/src/test.adb"):
            path = ada / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name + "\n")
        (ada / "refine.gpr").write_text(
            'project Refine is\n   for Languages use ("Ada", "C");\n'
            '   for Source_Dirs use ("src");\nend Refine;\n')
        (ada / "landin_tests.gpr").write_text(
            'project Landin_Tests is\n   for Source_Dirs use ("tests/src");\n'
            'end Landin_Tests;\n')
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
        self.builder = fake / "gprbuild"
        self.executable(self.builder, '''#!/usr/bin/env python3
import json, os, pathlib, sys
artifact = "old"
if sys.argv[1:] == ["--version"]:
    print("pinned builder")
    raise SystemExit(0)
root = pathlib.Path(os.environ["FAKE_ROOT"])
with (root / "calls").open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
configs = [arg.split("=", 1)[1] for arg in sys.argv[1:]
           if arg.startswith("--config=")]
assert len(configs) == 1 and pathlib.Path(configs[0]).is_file()
project = sys.argv[sys.argv.index("-P") + 1]
failure = os.environ.get("FAKE_BUILD_FAILURE")
if failure:
    print("compiling " + project)
    print({"disk": "error: disk full writing b__refine.ads",
           "compile": "main.adb:1:01: error: missing \\";\\""}[failure],
          file=sys.stderr)
    raise SystemExit(4)
if os.environ.get("FAKE_EDIT_ON_PROJECT") == project:
    source = root / "compiler/ada/src/main.adb"
    source.write_text(source.read_text() + "edited during build\\n")
build = pathlib.Path(os.environ["LANDIN_BUILD_DIR"])
exec_dir = build / next(arg.split("=", 1)[1] for arg in sys.argv[1:]
                        if arg.startswith("-XLANDIN_EXEC_SUBDIR="))
exec_dir.mkdir(parents=True, exist_ok=True)
(build / "refine-obj").mkdir(exist_ok=True)
(build / "refine-obj" / "built.o").write_text(
    "object " + os.environ.get("FAKE_OBJECT", ""))
project = sys.argv[sys.argv.index("-P") + 1]
name = {"refine.gpr": "refine", "landin_tests.gpr": "landin_tests"}[project]
path = exec_dir / name
# As GPRbuild can: an executable judged current by time stamps is kept.
if not (os.environ.get("FAKE_KEEP_EXECUTABLE") and path.exists()):
    path.write_text("#!/bin/sh\\necho " + artifact + "\\n")
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
        self.tests_manifest = self.build / "tests-manifest.txt"
        self.configuration = ada / ".build-locks/test-debug.cgpr"

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    @staticmethod
    def requested(manifest):
        """What a manifest says was asked for, without what was linked."""
        return [row for row in manifest.read_text().splitlines()
                if not row.startswith("linked ")]

    def linked(self, manifest):
        return [row for row in manifest.read_text().splitlines()
                if row.startswith("linked ")]

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

    def test_same_version_builder_replacement_rebuilds(self):
        first = self.run_build()
        self.assertEqual(first.returncode, 0, first.stderr)
        executable = self.build / "bin/refine"
        self.assertEqual(subprocess.check_output([executable], text=True), "old\n")
        previous = self.manifest.read_text()
        builder_identity = json.loads(next(
            line.removeprefix("toolchain gprbuild ")
            for line in previous.splitlines()
            if line.startswith("toolchain gprbuild ")))
        self.assertEqual(builder_identity["path"], str(self.builder))
        marker = self.build / "stale-object"
        marker.write_text("old object")
        old_builder = self.builder.read_text()
        self.assertIn('artifact = "old"', old_builder)
        self.executable(self.builder, old_builder.replace(
            'artifact = "old"', 'artifact = "new"'))

        second = self.run_build()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("rebuilding from clean", second.stdout)
        self.assertFalse(marker.exists())
        self.assertEqual(subprocess.check_output([executable], text=True), "new\n")
        self.assertEqual(len(self.calls()), 4)
        self.assertNotEqual(self.manifest.read_text(), previous)

    def test_compiler_only_then_full_builds_test_project(self):
        first = self.run_build("--compiler-only", "-j4")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual([call[call.index("-P") + 1]
                          for call in self.calls()], ["refine.gpr"])
        self.assertIn("-j4", self.calls()[0])
        self.assertNotIn("--compiler-only", self.calls()[0])
        self.assertFalse(self.tests_manifest.exists())

        current = self.run_build("--compiler-only")
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertIn("developer build is current", current.stdout)
        self.assertEqual(len(self.calls()), 1)

        full = self.run_build()
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertEqual([call[call.index("-P") + 1]
                          for call in self.calls()],
                         ["refine.gpr", "refine.gpr", "landin_tests.gpr"])
        self.assertEqual(self.requested(self.tests_manifest),
                         self.requested(self.manifest))
        current = self.run_build()
        self.assertIn("developer build is current", current.stdout)
        self.assertEqual(len(self.calls()), 3)

    def test_compiler_only_change_invalidates_old_test_executable(self):
        self.assertEqual(self.run_build().returncode, 0)
        old = self.tests_manifest.read_text()
        source = self.root / "compiler/ada/src/main.adb"
        source.write_text("updated compiler\n")
        only = self.run_build("--compiler-only")
        self.assertEqual(only.returncode, 0, only.stderr)
        self.assertTrue((self.build / "bin/landin_tests").exists())
        self.assertEqual(self.tests_manifest.read_text(), old)
        self.assertNotEqual(self.manifest.read_text(), old)
        full = self.run_build()
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertEqual(self.calls()[-1][self.calls()[-1].index("-P") + 1],
                         "landin_tests.gpr")
        self.assertEqual(self.requested(self.tests_manifest),
                         self.requested(self.manifest))

    def test_imported_build_requires_matching_source_and_executables(self):
        first = self.run_build()
        self.assertEqual(first.returncode, 0, first.stderr)
        calls = self.calls()
        reuse = {"LANDIN_BUILD_REUSE": "yes", "LANDIN_BUILD_INCREMENTAL": "no"}
        current = self.run_build("-q", extra=reuse)
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertIn("imported build matches", current.stdout)
        self.assertEqual(self.calls(), calls)

        source = self.root / "compiler/ada/src/main.adb"
        source.write_text("changed source\n")
        stale = self.run_build("-q", extra=reuse)
        self.assertEqual(stale.returncode, 1)
        self.assertIn("does not match", stale.stderr)
        self.assertEqual(self.calls(), calls)
        source.write_text("src/main.adb\n")

        (self.build / "bin/landin_tests").unlink()
        missing = self.run_build("-q", extra=reuse)
        self.assertEqual(missing.returncode, 1)
        self.assertEqual(self.calls(), calls)
        invalid = self.run_build(extra=reuse)
        self.assertEqual(invalid.returncode, 2)

    def test_imported_full_build_rejects_missing_or_stale_test_stamp(self):
        self.assertEqual(self.run_build().returncode, 0)
        calls = self.calls()
        manifest = self.manifest.read_text()
        tests = self.tests_manifest.read_text()
        reuse = {"LANDIN_BUILD_REUSE": "yes", "LANDIN_BUILD_INCREMENTAL": "no"}
        for stamp in (None, "", "different source and toolchain\n",
                      manifest):
            with self.subTest(stamp=stamp):
                if stamp is None:
                    self.tests_manifest.unlink()
                else:
                    self.tests_manifest.write_text(stamp)
                result = self.run_build("-q", extra=reuse)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("imported", result.stderr)
                self.assertEqual(self.calls(), calls)
                self.assertEqual(self.manifest.read_text(), manifest)
        self.tests_manifest.write_text(tests)
        self.assertEqual(self.run_build("-q", extra=reuse).returncode, 0)
        self.assertEqual(self.calls(), calls)

    def test_imported_compiler_only_build_does_not_require_tests(self):
        first = self.run_build("--compiler-only")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertFalse(self.tests_manifest.exists())
        self.assertFalse((self.build / "bin/landin_tests").exists())
        calls = self.calls()
        reuse = {"LANDIN_BUILD_REUSE": "yes", "LANDIN_BUILD_INCREMENTAL": "no"}
        current = self.run_build("--compiler-only", "-q", extra=reuse)
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertEqual(self.calls(), calls)
        full = self.run_build("-q", extra=reuse)
        self.assertEqual(full.returncode, 1)
        self.assertEqual(self.calls(), calls)

        # A compiler-only rebuild must not bless an older test executable.
        self.assertEqual(self.run_build().returncode, 0)
        source = self.root / "compiler/ada/src/main.adb"
        source.write_text("updated compiler\n")
        self.assertEqual(self.run_build("--compiler-only").returncode, 0)
        self.assertTrue((self.build / "bin/landin_tests").exists())
        calls = self.calls()
        current = self.run_build("--compiler-only", "-q", extra=reuse)
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertEqual(self.run_build("-q", extra=reuse).returncode, 1)
        self.assertEqual(self.calls(), calls)

    def test_imported_compiler_identity_and_executable_are_required(self):
        self.assertEqual(self.run_build("--compiler-only").returncode, 0)
        calls = self.calls()
        reuse = {"LANDIN_BUILD_REUSE": "yes", "LANDIN_BUILD_INCREMENTAL": "no"}
        executable = self.build / "bin/refine"
        executable.chmod(0o644)
        result = self.run_build("--compiler-only", "-q", extra=reuse)
        self.assertEqual(result.returncode, 1)
        executable.chmod(0o755)
        self.manifest.unlink()
        result = self.run_build("--compiler-only", "-q", extra=reuse)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no successful source manifest", result.stderr)
        self.assertEqual(self.calls(), calls)

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

    def test_source_edit_during_either_project_does_not_publish_manifest(self):
        for incremental in ("yes", "no"):
            for project in ("refine.gpr", "landin_tests.gpr"):
                with self.subTest(incremental=incremental, project=project):
                    extra = {"LANDIN_BUILD_INCREMENTAL": incremental}
                    first = self.run_build(extra=extra)
                    self.assertEqual(first.returncode, 0, first.stderr)
                    changed = self.run_build(
                        "-k", extra={**extra, "FAKE_EDIT_ON_PROJECT": project})
                    self.assertEqual(changed.returncode, 1, changed.stderr)
                    self.assertIn("sources changed while this build ran",
                                  changed.stderr)
                    self.assertIn("compiler/ada/src/main.adb changed",
                                  changed.stderr)
                    self.assertIn("run the build again", changed.stderr)
                    self.assertFalse(self.manifest.exists())
                    marker = self.build / "stale-object"
                    marker.write_text("old object")
                    retried = self.run_build(extra=extra)
                    self.assertEqual(retried.returncode, 0, retried.stderr)
                    self.assertIn("last build did not finish (it failed)",
                                  retried.stdout)
                    # The checksum mode recompiles what the edit changed;
                    # only the ordinary build starts from clean.
                    self.assertEqual(marker.exists(), incremental == "yes")
                    self.assertTrue(self.manifest.is_file())

    def test_failed_build_keeps_the_published_compiler(self):
        first = self.run_build()
        self.assertEqual(first.returncode, 0, first.stderr)
        published = self.build / "bin/refine"
        self.assertEqual(published.read_bytes(),
                         (self.build / "link/refine").read_bytes())
        identity = published.stat().st_ino
        # -k, unlike a job count, is an argument a current build still runs.
        failed = self.run_build("-k", extra={"FAKE_BUILD_FAILURE": "compile"})
        self.assertEqual(failed.returncode, 4, failed.stderr)
        self.assertEqual(published.stat().st_ino, identity)
        self.assertEqual((self.build / "build-state").read_text(), "failed\n")
        for incremental in ("yes", "no"):
            with self.subTest(incremental=incremental):
                failed = self.run_build("-k", extra={
                    "FAKE_BUILD_FAILURE": "compile",
                    "LANDIN_BUILD_INCREMENTAL": incremental})
                self.assertEqual(failed.returncode, 4, failed.stderr)
                self.assertTrue(os.access(published, os.X_OK))
                self.assertEqual(published.stat().st_ino, identity)

    def test_interrupted_build_discards_only_what_it_wrote(self):
        first = self.run_build()
        self.assertEqual(first.returncode, 0, first.stderr)
        earlier = self.build / "refine-obj/earlier.o"
        earlier.write_text("whole object")
        half = self.build / "refine-obj/half.o"
        half.write_text("half-writ")
        state = self.build / "build-state"
        (self.build / "attempt-manifest.txt").write_text(
            self.manifest.read_text())
        state.write_text("running\n")
        self.manifest.unlink()
        began = state.stat().st_mtime
        os.utime(earlier, (began - 10, began - 10))
        os.utime(half, (began + 1, began + 1))
        published = self.build / "bin/refine"
        identity = published.stat().st_ino
        os.utime(published, (began + 1, began + 1))
        retried = self.run_build()
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertIn("(it was interrupted); discarding only what it wrote",
                      retried.stdout)
        self.assertTrue(earlier.exists())
        self.assertFalse(half.exists())
        self.assertEqual(published.stat().st_ino, identity)
        self.assertFalse(state.exists())
        self.assertTrue(self.manifest.is_file())

    def test_changed_executable_is_published_by_rename(self):
        first = self.run_build()
        self.assertEqual(first.returncode, 0, first.stderr)
        published = self.build / "bin/refine"
        identity = published.stat().st_ino
        # Unchanged content is not republished.
        self.manifest.unlink()
        again = self.run_build()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(published.stat().st_ino, identity)
        self.executable(self.builder, self.builder.read_text().replace(
            'artifact = "old"', 'artifact = "new"'))
        rebuilt = self.run_build()
        self.assertEqual(rebuilt.returncode, 0, rebuilt.stderr)
        self.assertNotEqual(published.stat().st_ino, identity)
        self.assertEqual(subprocess.check_output([published], text=True),
                         "new\n")
        self.assertEqual(sorted(p.name for p in published.parent.iterdir()),
                         ["landin_tests", "refine"])

    def test_executable_not_relinked_from_changed_objects_is_relinked(self):
        first = self.run_build()
        self.assertEqual(first.returncode, 0, first.stderr)
        linked = self.linked(self.manifest)
        # GPRbuild judged the executable current by its time stamps although
        # an object it links changed: the build relinks it.
        again = self.run_build("-k", extra={"FAKE_KEEP_EXECUTABLE": "yes",
                                            "FAKE_OBJECT": "changed"})
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("link/refine was not relinked and refine-obj/built.o"
                      " changed since it was linked; relinking it",
                      again.stderr)
        projects = [call[call.index("-P") + 1] for call in self.calls()]
        self.assertEqual(projects[2:], ["refine.gpr", "refine.gpr",
                                        "landin_tests.gpr"])
        self.assertEqual(self.linked(self.manifest), linked)
        record = json.loads((self.build / "link/.refine.linked").read_text())
        self.assertEqual(record["inputs"]["refine-obj/built.o"],
                         hashlib.sha256(b"object changed").hexdigest())

    def test_executable_with_no_link_record_is_relinked(self):
        self.assertEqual(self.run_build().returncode, 0)
        (self.build / "link/.landin_tests.linked").unlink()
        again = self.run_build("-k", extra={"FAKE_KEEP_EXECUTABLE": "yes"})
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("link/landin_tests was not relinked and nothing records"
                      " what it was linked from", again.stderr)

    def test_published_executable_must_be_the_one_linked(self):
        self.assertEqual(self.run_build().returncode, 0)
        published = self.build / "bin/refine"
        linked = published.read_text()
        published.write_text("#!/bin/sh\necho replaced\n")
        reuse = {"LANDIN_BUILD_REUSE": "yes", "LANDIN_BUILD_INCREMENTAL": "no"}
        imported = self.run_build("-q", extra=reuse)
        self.assertEqual(imported.returncode, 1)
        self.assertIn("bin/refine is not the executable the last build linked",
                      imported.stderr)
        calls = len(self.calls())
        current = self.run_build()
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertNotIn("developer build is current", current.stdout)
        self.assertIn("bin/refine is not the executable the last build linked",
                      current.stderr)
        self.assertEqual(len(self.calls()), calls + 2)
        self.assertEqual(published.read_text(), linked)
        self.assertIn("developer build is current", self.run_build().stdout)

    def test_job_count_alone_leaves_a_current_build_alone(self):
        self.assertEqual(self.run_build().returncode, 0)
        calls = self.calls()
        result = self.run_build("-j6", "-q")
        self.assertIn("developer build is current", result.stdout)
        self.assertEqual(self.calls(), calls)

    def test_disk_full_reports_what_was_free(self):
        for failure in ("disk", "compile"):
            with self.subTest(failure=failure):
                result = self.run_build(extra={"FAKE_BUILD_FAILURE": failure})
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertIn("compiling refine.gpr", result.stdout)
                self.assertNotIn("error", result.stdout)
                self.assertFalse(self.manifest.exists())
                if failure == "disk":
                    self.assertIn("error: disk full writing", result.stderr)
                    self.assertRegex(
                        result.stderr,
                        r'landin: GNAT says "disk full" for any short write; '
                        r"[0-9]+ MiB were free under .+ and the open-file "
                        r"limit is [0-9]+")
                else:
                    self.assertIn("missing", result.stderr)
                    self.assertNotIn("short write", result.stderr)

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


class DeveloperScripts(unittest.TestCase):
    """What the developer wrappers do before any build or interpreter."""

    def bare_path(self, directory):
        # The tools env.sh and the usage need, without python3.
        for tool in ("sh", "dirname", "uname", "tr", "sed", "awk", "cat"):
            os.symlink(shutil.which(tool), directory / tool)
        return str(directory)

    def test_help_needs_no_build_and_no_python(self):
        with tempfile.TemporaryDirectory(prefix="landin-help-") as tmp:
            path = self.bare_path(Path(tmp))
            for script, name in (("test.sh", "scripts/test.sh"),
                                 ("dev-test.sh", "scripts/dev-test.sh")):
                with self.subTest(script=script):
                    result = subprocess.run(
                        ["sh", str(ROOT / "scripts" / script), "--help"],
                        env={"PATH": path}, capture_output=True, text=True,
                        timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(
                        "usage: " + name + " [--record | --fixture=CLASS/NAME"
                        " | --suite=NAME ... --case=SUITE/NAME ...]",
                        result.stdout)
                    self.assertIn("--shard=I/N", result.stdout)
        source = (ROOT / "compiler/ada/tests/src/landin_tests.adb").read_text()
        declared = source[source.index("Expected_Suites : constant"):]
        declared = declared[:declared.index("];")]
        suites = [name.strip() for name in re.findall(r'"([^"]*)"', declared)]
        self.assertGreater(len(suites), 10)
        listed = result.stdout.split("Suites, for --suite=NAME and"
                                     " --case=SUITE/NAME:\n")[1]
        self.assertEqual([line.strip() for line in listed.splitlines()], suites)

    def test_missing_python_names_the_development_shell(self):
        with tempfile.TemporaryDirectory(prefix="landin-python-") as tmp:
            path = self.bare_path(Path(tmp))
            for script in ("dev-build.sh", "dev-test.sh", "build.sh"):
                with self.subTest(script=script):
                    result = subprocess.run(
                        ["sh", str(ROOT / "scripts" / script)],
                        env={"PATH": path}, capture_output=True, text=True,
                        timeout=10)
                    self.assertEqual(result.returncode, 127)
                    self.assertIn("landin: python3 is not on PATH",
                                  result.stderr)
                    self.assertIn("nix develop", result.stderr)

    def test_variant_has_a_tree_of_its_own(self):
        with tempfile.TemporaryDirectory(prefix="landin-variant-") as tmp:
            scripts = Path(tmp) / "scripts"
            scripts.mkdir()
            shutil.copyfile(ROOT / "scripts/env.sh", scripts / "env.sh")
            (scripts / "probe.sh").write_text(
                '. "$(dirname -- "$0")/env.sh"\n'
                'echo "$LANDIN_BUILD_TAG $LANDIN_BUILD_DIR"\n'
                'sh -c \'echo "inherited ${LANDIN_BUILD_VARIANT:-none}'
                ' $LANDIN_BUILD_TAG"\'\n')
            def probe(**extra):
                return subprocess.run(
                    ["sh", str(scripts / "probe.sh")], capture_output=True,
                    text=True, timeout=10,
                    env={"PATH": os.environ["PATH"],
                         "LANDIN_BUILD_TAG": "nix-x86_64-linux", **extra})
            plain = probe().stdout.split()
            self.assertEqual(plain[0], "nix-x86_64-linux")
            variant = probe(LANDIN_BUILD_VARIANT="inliner")
            self.assertEqual(variant.returncode, 0, variant.stderr)
            words = variant.stdout.split()
            self.assertEqual(words[0], "nix-x86_64-linux.inliner")
            self.assertTrue(words[1].endswith(
                "compiler/ada/build/nix-x86_64-linux.inliner/debug"))
            # Applied once: a nested command keeps the tree and adds nothing.
            self.assertEqual(words[2:], ["inherited", "none",
                                         "nix-x86_64-linux.inliner"])
            refused = probe(LANDIN_BUILD_VARIANT="../escape")
            self.assertEqual(refused.returncode, 2)
            self.assertIn("LANDIN_BUILD_VARIANT must match", refused.stderr)


class BuildArchives(unittest.TestCase):
    def test_workflow_archives_preserve_their_stamps_and_executables(self):
        workflow = (ROOT / ".github/workflows/gate.yml").read_text()
        commands = [" ".join(block.split()) for block in re.findall(
            r"run: >-\n((?: {10}.+\n)+)", workflow)]
        packages = [command for command in commands
                    if command.startswith("tar -czf ")]
        #  Debug builds supply their host's suite as well as determinism,
        #  so they carry the test program and its stamp as release does.
        build = ("bin", "bin/refine", "bin/landin_tests",
                 "source-manifest.txt", "tests-manifest.txt")
        expected = {
            "compiler/ada/build/linux-amd64/release": build,
            "compiler/ada/build/darwin-arm64/release": build,
            "compiler/ada/build/linux-amd64/debug": build,
            "compiler/ada/build/linux-arm64/debug": build,
            "compiler/ada/build/darwin-arm64/debug": build,
        }
        self.assertEqual(len(packages), len(expected))
        self.assertEqual({shlex.split(command)[shlex.split(command).index("-C") + 1]
                          for command in packages}, set(expected))
        for command in packages:
            with self.subTest(command=command):
                with tempfile.TemporaryDirectory(prefix="landin-archive-") as tmp:
                    root = Path(tmp)
                    words = shlex.split(command)
                    build_path = words[words.index("-C") + 1]
                    build = root / build_path
                    (build / "bin").mkdir(parents=True)
                    for name in ("refine", "landin_tests"):
                        executable = build / "bin" / name
                        executable.write_text("#!/bin/sh\nexit 0\n")
                        executable.chmod(0o755)
                    manifest = "checked source and toolchain identity\n"
                    for name in ("source-manifest.txt", "tests-manifest.txt"):
                        (build / name).write_text(manifest)
                    result = subprocess.run(
                        ["sh", "-eu", "-c", command], cwd=root,
                        env={**os.environ, "RUNNER_TEMP": tmp},
                        capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    archive_path = Path(words[2].replace("$RUNNER_TEMP", tmp))
                    with tarfile.open(archive_path) as archive:
                        self.assertEqual(set(archive.getnames()), set(expected[build_path]))
                        for name in expected[build_path]:
                            if name == "bin":
                                self.assertTrue(archive.getmember(name).isdir())
                            elif name.endswith("manifest.txt"):
                                self.assertEqual(archive.extractfile(name).read(),
                                                 manifest.encode())
                            else:
                                self.assertTrue(archive.getmember(name).mode & 0o111)


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
