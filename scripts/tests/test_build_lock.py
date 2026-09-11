#!/usr/bin/env python3
"""Exercise command lock lifetimes in a disposable fake build tree."""
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildLocks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="landin-lock-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("env.sh", "build_lock.py", "test.sh", "clean.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        self.script("worker.sh", '''#!/bin/sh
. "$(dirname -- "$0")/env.sh"
landin_build_lock "${TEST_SCOPE:-mode}" "$@"
echo ready
read -r Finish
''')
        self.script("build.sh", '''#!/bin/sh
. "$(dirname -- "$0")/env.sh"
landin_build_lock mode "$@"
echo built
''')
        self.script("validate.sh", '''#!/bin/sh
. "$(dirname -- "$0")/env.sh"
echo "$LANDIN_BUILD_MODE"
''')

    def script(self, name, content):
        path = self.root / "scripts" / name
        path.write_text(content)
        path.chmod(0o755)

    def start(self, script="worker.sh", arguments=(), **environment):
        process = subprocess.Popen(
            [str(self.root / "scripts" / script), *arguments],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
            env={**os.environ, "LANDIN_BUILD_TAG": "test",
                 "LANDIN_BUILD_MODE": "debug", **environment})

        def finish():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

        self.addCleanup(finish)
        return process

    def line(self, stream):
        result = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(stream, selectors.EVENT_READ)
            while True:
                self.assertTrue(selector.select(10), "command produced no event")
                byte = os.read(stream.fileno(), 1)
                if byte in (b"", b"\n"):
                    return result.decode()
                result.extend(byte)

    def ready(self, process):
        self.assertEqual(self.line(process.stdout), "ready")

    def waiting(self, process):
        self.assertIn("waiting for build lock", self.line(process.stderr))
        self.assertIsNone(process.poll())

    def release(self, process):
        stdout, stderr = process.communicate("finish\n", timeout=10)
        self.assertEqual(process.returncode, 0, (stdout, stderr))

    def test_same_mode_waits_but_other_modes_and_tags_can_run(self):
        first = self.start()
        self.ready(first)
        waiting = self.start()
        self.waiting(waiting)
        release = self.start(LANDIN_BUILD_MODE="release")
        self.ready(release)
        other = self.start(LANDIN_BUILD_TAG="other")
        self.ready(other)
        self.release(first)
        self.ready(waiting)
        for process in (waiting, release, other):
            self.release(process)

    def test_tag_cleanup_waits_for_both_modes(self):
        debug = self.start()
        release = self.start(LANDIN_BUILD_MODE="release")
        self.ready(debug)
        self.ready(release)
        cleanup = self.start(TEST_SCOPE="tag")
        self.waiting(cleanup)
        self.release(debug)
        self.waiting(cleanup)
        self.release(release)
        self.ready(cleanup)
        self.release(cleanup)

    def test_cleanup_scope_excludes_new_builds(self):
        for scope in ("tag", "all"):
            with self.subTest(scope=scope):
                cleanup = self.start(TEST_SCOPE=scope)
                self.ready(cleanup)
                builder = self.start()
                self.waiting(builder)
                self.release(cleanup)
                self.ready(builder)
                self.release(builder)

    def test_clean_all_waits_across_tags_and_keeps_lock_inodes(self):
        first = self.start()
        second = self.start(LANDIN_BUILD_TAG="other")
        self.ready(first)
        self.ready(second)
        build = self.root / "compiler/ada/build"
        build.mkdir()
        marker = build / "test-artifact"
        marker.write_text("retained while in use")
        lock = self.root / "compiler/ada/.build-locks/all"
        identity = lock.stat().st_ino
        cleanup = self.start("clean.sh", ("--all",))
        self.waiting(cleanup)
        self.release(first)
        self.assertTrue(marker.exists())
        self.assertIsNone(cleanup.poll())
        self.release(second)
        stdout, stderr = cleanup.communicate(timeout=10)
        self.assertEqual(cleanup.returncode, 0, (stdout, stderr))
        self.assertFalse(build.exists())
        self.assertEqual(lock.stat().st_ino, identity)
        subsequent = self.start()
        self.ready(subsequent)
        self.release(subsequent)

    def test_test_command_holds_lock_after_nested_build(self):
        binary = self.root / "compiler/ada/build/test/debug/bin/landin_tests"
        binary.parent.mkdir(parents=True)
        binary.write_text('#!/bin/sh\necho ready\nread -r Finish\nexit 23\n')
        binary.chmod(0o755)
        testing = self.start("test.sh")
        self.assertEqual(self.line(testing.stdout), "built")
        self.ready(testing)
        builder = self.start()
        self.waiting(builder)
        testing.communicate("finish\n", timeout=10)
        self.assertEqual(testing.returncode, 23)
        self.ready(builder)
        self.release(builder)

    def test_terminated_holder_releases_lock(self):
        first = self.start()
        self.ready(first)
        waiting = self.start()
        self.waiting(waiting)
        first.terminate()
        first.communicate(timeout=10)
        self.ready(waiting)
        self.release(waiting)

    def test_stale_inherited_context_does_not_bypass_lock(self):
        worker = self.start(LANDIN_BUILD_LOCK_CONTEXT='[["missing", 2, 999]]')
        self.ready(worker)
        waiting = self.start()
        self.waiting(waiting)
        self.release(worker)
        self.ready(waiting)
        self.release(waiting)

    def test_mode_is_validated_by_environment_loading_alone(self):
        # Never invoke a build or cleanup with a rejected mode.
        for mode in ("debug", "release", "", "unknown", "../other", "a/b"):
            with self.subTest(mode=mode):
                process = self.start("validate.sh", LANDIN_BUILD_MODE=mode)
                stdout, stderr = process.communicate(timeout=10)
                if mode in ("debug", "release", ""):
                    self.assertEqual(process.returncode, 0, stderr)
                    self.assertEqual(stdout.strip(), mode or "debug")
                else:
                    self.assertEqual(process.returncode, 2)
                    self.assertIn("must be debug or release", stderr)
                self.assertFalse((self.root / "compiler").exists())


if __name__ == "__main__":
    unittest.main()
