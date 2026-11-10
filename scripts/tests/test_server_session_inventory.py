#!/usr/bin/env python3
"""The native session runner's inventory: a directory without a transcript
is a session nobody runs, and is said; and a session whose tree holds an
empty directory, which a clone would not have, is refused."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "native_session", ROOT / "compiler/tests/server/native_session.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class Inventory(unittest.TestCase):
    def tree(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for name in ("lifecycle", "hover"):
            (root / name).mkdir()
            (root / name / "session.lsp").write_text("exit: 0\n")
        (root / "native_session.py").write_text("")
        (root / "__pycache__").mkdir()
        return root

    def test_files_and_the_interpreter_s_cache_are_no_sessions(self):
        self.assertEqual(RUNNER.inventory(self.tree()), (["hover", "lifecycle"], []))

    def test_the_real_tree_holds_only_sessions(self):
        names, missing = RUNNER.inventory(ROOT / "compiler/tests/server")
        self.assertEqual(missing, [])
        self.assertGreater(len(names), 40)

    def test_a_directory_without_a_transcript_fails_the_run(self):
        root = self.tree()
        (root / "renamed").mkdir()
        (root / "renamed" / "session.lsp.orig").write_text("exit: 0\n")
        (root / "emptied" / "workspace").mkdir(parents=True)
        self.assertEqual(RUNNER.inventory(root),
                         (["hover", "lifecycle"], ["emptied", "renamed"]))
        # Every session that is there passes, and the run still fails.
        said = io.StringIO()
        with mock.patch.object(RUNNER, "HERE", root), \
                mock.patch.object(RUNNER, "run", return_value=""), \
                mock.patch.object(sys, "argv", ["native_session.py", "--refine", "refine"]), \
                contextlib.redirect_stdout(said):
            status = RUNNER.main()
        self.assertEqual(status, 1)
        self.assertIn("renamed holds no session.lsp, so the session is not run", said.getvalue())
        self.assertIn("2 sessions, 2 failed", said.getvalue())


class Hollow(unittest.TestCase):
    """Git keeps no empty directory, so a session's tree holds none."""

    OPENING = ('-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":'
               '{"textDocument":{"uri":"file:///workspace/app/main.ldn",'
               '"languageId":"landin","version":1,"text":""}}}\nexit: 0\n')

    def session(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name)

    def test_the_file_the_transcript_opens_there_is_the_one_to_add(self):
        root = self.session()
        (root / "workspace/app").mkdir(parents=True)
        said = RUNNER.hollow(root, self.OPENING)
        self.assertIn("an empty directory, served as /workspace/app,", said)
        self.assertIn("add %s, which the transcript names"
                      % (root / "workspace/app/main.ldn"), said)
        (root / "workspace/app/main.ldn").write_text("")
        self.assertEqual(RUNNER.hollow(root, self.OPENING), "")

    def test_a_directory_nothing_is_named_in_is_named_itself(self):
        root = self.session()
        (root / "library/core/panic").mkdir(parents=True)
        said = RUNNER.hollow(root, "exit: 0\n")
        self.assertIn("served as /opt/landin/lib/landin/core/panic,", said)
        self.assertIn("add a file in %s, or remove the directory"
                      % (root / "library/core/panic"), said)

    def test_an_empty_tree_root_is_refused_and_a_missing_one_is_not(self):
        root = self.session()
        self.assertEqual(RUNNER.hollow(root, self.OPENING), "")
        (root / "workspace").mkdir()
        self.assertIn("served as /workspace,",
                      RUNNER.hollow(root, self.OPENING))

    def test_the_run_refuses_before_the_server_starts(self):
        root = self.session()
        (root / "opened/workspace/app").mkdir(parents=True)
        (root / "opened/session.lsp").write_text(self.OPENING)
        with mock.patch.object(RUNNER, "HERE", root), \
                mock.patch.object(RUNNER.subprocess, "Popen") as started:
            said = RUNNER.run("refine", "opened")
        self.assertIn("an empty directory", said)
        started.assert_not_called()

    def test_no_session_of_the_tree_holds_one(self):
        directory = ROOT / "compiler/tests/server"
        for name in RUNNER.inventory(directory)[0]:
            transcript = (directory / name / "session.lsp").read_text(
                encoding="utf-8")
            self.assertEqual(RUNNER.hollow(directory / name, transcript), "",
                             name)


if __name__ == "__main__":
    unittest.main()
