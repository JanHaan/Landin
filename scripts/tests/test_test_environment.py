#!/usr/bin/env python3
"""Observe actual test launchers without building the Ada test program."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
HANG = 300
PASS = "memory\n  pass  probe\n\ncases 1, passed 1, failed 0, checks 1\n"


class TestEnvironment(unittest.TestCase):
    def launch(self, launcher, tunables, host="Linux", arguments=(), status=0):
        with tempfile.TemporaryDirectory(prefix="landin-test-environment-") as tmp:
            root = Path(tmp)
            scripts = root / "scripts"
            scripts.mkdir()
            (root / "compiler/ada").mkdir(parents=True)
            for name in ("env.sh", "build_lock.py", "test.sh",
                         "parallel-equivalence.sh"):
                shutil.copy2(SCRIPTS / name, scripts / name)
            tools = root / "tools"
            tools.mkdir()
            uname = tools / "uname"
            uname.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_OS"\n')
            uname.chmod(0o755)
            observations = root / "observations.jsonl"
            harness = root / "fake-tests"
            harness.write_text(
                "#!" + sys.executable + "\n"
                "import json, os, sys\n"
                f"with open({str(observations)!r}, 'a') as stream:\n"
                "    stream.write(json.dumps(dict(kind='test', pid=os.getpid(), "
                "tunables=os.environ.get('GLIBC_TUNABLES'), "
                "arguments=sys.argv[1:])) + '\\n')\n"
                f"print({PASS!r}, end='')\n"
                f"sys.exit({status})\n")
            harness.chmod(0o755)
            build = scripts / "build.sh"
            build.write_text(
                "#!" + sys.executable + "\n"
                "import json, os, pathlib, shutil\n"
                f"with open({str(observations)!r}, 'a') as stream:\n"
                "    stream.write(json.dumps(dict(kind='build', "
                "tunables=os.environ.get('GLIBC_TUNABLES'))) + '\\n')\n"
                "binary = pathlib.Path(os.environ['LANDIN_BUILD_DIR']) / 'bin/landin_tests'\n"
                "binary.parent.mkdir(parents=True, exist_ok=True)\n"
                f"shutil.copy2({str(harness)!r}, binary)\n")
            build.chmod(0o755)
            env = {**os.environ, "LANDIN_BUILD_TAG": "test",
                   "LANDIN_BUILD_MODE": "debug", "TEST_OS": host,
                   "PATH": str(tools) + os.pathsep + os.environ["PATH"]}
            env.pop("GLIBC_TUNABLES", None)
            if tunables is not None:
                env["GLIBC_TUNABLES"] = tunables
            evidence = root / "evidence"
            if launcher == "parallel-equivalence.sh":
                arguments = ("--suite=memory", "--output=" + str(evidence))
            result = subprocess.run([str(scripts / launcher), *arguments],
                                    capture_output=True, text=True,
                                    timeout=HANG, env=env)
            result.observations = [json.loads(line) for line in
                                   observations.read_text().splitlines()]
            result.commands = ([path.read_text() for path in
                                (evidence / "one-job.command",
                                 evidence / "many-jobs.command")]
                               if evidence.exists() else [])
            return result

    def check_launch(self, launcher, inherited, expected, host="Linux"):
        result = self.launch(launcher, inherited, host)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.observations[0],
                         dict(kind="build", tunables=inherited))
        children = result.observations[1:]
        self.assertEqual(len(children), 2 if result.commands else 1)
        for child in children:
            self.assertEqual(child["tunables"], expected)
        # Compare the retained command's setting with the actual child,
        # rather than recomputing the launcher's normalization in this test.
        for command, child in zip(result.commands, children):
            assignments = dict(token.split("=", 1) for token in
                               shlex.split(command.splitlines()[-1])
                               if token.startswith("GLIBC_TUNABLES="))
            self.assertEqual(assignments.get("GLIBC_TUNABLES"),
                             child["tunables"])
            if child["tunables"] is None:
                self.assertIn("unset GLIBC_TUNABLES", command)

    def test_linux_overrides_only_exact_cache_keys_after_build(self):
        cases = (
            (None, "glibc.malloc.tcache_count=0"),
            ("", "glibc.malloc.tcache_count=0"),
            ("glibc.malloc.trim_threshold=32768:glibc.malloc.tcache_count=9:"
             "glibc.malloc.tcache_count:glibc.malloc.tcache_count=3:"
             "other.key=keep=equals:glibc.malloc.tcache_count_extra=4",
             "glibc.malloc.trim_threshold=32768:other.key=keep=equals:"
             "glibc.malloc.tcache_count_extra=4:glibc.malloc.tcache_count=0"),
        )
        for launcher in ("test.sh", "parallel-equivalence.sh"):
            for inherited, expected in cases:
                with self.subTest(launcher=launcher, inherited=inherited):
                    self.check_launch(launcher, inherited, expected)

    def test_darwin_keeps_the_inherited_environment(self):
        for launcher in ("test.sh", "parallel-equivalence.sh"):
            for inherited in (None, "", "glibc.malloc.tcache_count=7:other.key=keep"):
                with self.subTest(launcher=launcher, inherited=inherited):
                    self.check_launch(launcher, inherited, inherited, "Darwin")

    def test_tunable_values_are_never_evaluated_by_the_shell(self):
        with tempfile.TemporaryDirectory(prefix="landin-test-no-eval-") as tmp:
            marker = Path(tmp) / "executed"
            value = "other.literal=$(touch " + str(marker) + "):other.tick=`touch " + str(marker) + "`"
            for launcher in ("test.sh", "parallel-equivalence.sh"):
                with self.subTest(launcher=launcher):
                    self.check_launch(launcher, value,
                                      value + ":glibc.malloc.tcache_count=0")
                    self.assertFalse(marker.exists())

    def test_record_and_run_start_distinct_configured_processes(self):
        result = self.launch("test.sh", None, arguments=("--record-and-run",))
        self.assertEqual(result.returncode, 0, result.stderr)
        first, second = result.observations[1:]
        self.assertNotEqual(first["pid"], second["pid"])
        self.assertEqual(first["arguments"], ["--record"])
        self.assertEqual(second["arguments"], [])
        self.assertEqual(first["tunables"], "glibc.malloc.tcache_count=0")
        self.assertEqual(second["tunables"], first["tunables"])

    def test_test_launcher_preserves_arguments_and_exit_status(self):
        arguments = ("--case=memory/a gate sees small allocation lifetimes",
                     "literal space", "$(literal)")
        result = self.launch("test.sh", None, arguments=arguments, status=23)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(result.observations[-1]["arguments"], list(arguments))


if __name__ == "__main__":
    unittest.main()
