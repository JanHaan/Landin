#!/usr/bin/env python3
"""The native session runner's inventory: a directory without a transcript
is a session nobody runs, and is said."""
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


if __name__ == "__main__":
    unittest.main()
