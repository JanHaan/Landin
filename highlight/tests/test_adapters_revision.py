#!/usr/bin/env python3
"""Regression tests for editor grammar pins in checkouts and source archives."""

from __future__ import annotations

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_adapters


def git(directory: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(directory), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def sources(revision: str) -> tuple[dict, dict, str]:
    helix = {"grammar": [{"source": {
        "git": "https://example.invalid/Landin", "subpath": "highlight/tree-sitter",
        "rev": revision,
    }}]}
    zed = {"grammars": {"landin": {
        "repository": "https://example.invalid/Landin",
        "path": "highlight/tree-sitter", "rev": revision,
    }}}
    emacs = f'(defcustom landin-treesit-revision "{revision}" "")'
    return helix, zed, emacs


class GrammarRevision(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="landin-grammar-pin-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "source"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        grammar = self.repo / "highlight/tree-sitter/grammar.js"
        grammar.parent.mkdir(parents=True)
        grammar.write_text("original grammar\n", encoding="utf-8")
        query = self.repo / "highlight/helix/runtime/queries/landin/highlights.scm"
        query.parent.mkdir(parents=True)
        query.write_text("original query\n", encoding="utf-8")
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "-qm", "Grammar and queries")
        self.revision = git(self.repo, "rev-parse", "HEAD")
        (self.repo / "later.txt").write_text("later\n", encoding="utf-8")
        git(self.repo, "add", "later.txt")
        git(self.repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "-qm", "Later change")

    def check(self, root: Path, revision: str | None = None) -> None:
        with patch.object(test_adapters, "ROOT", root / "highlight"):
            test_adapters.check_grammar_revision(*sources(revision or self.revision))

    def test_full_checkout_compares_grammar_and_queries(self) -> None:
        self.check(self.repo)
        query = self.repo / "highlight/helix/runtime/queries/landin/highlights.scm"
        query.write_text("changed query\n", encoding="utf-8")
        with self.assertRaisesRegex(AssertionError, "shipped grammar or queries differ"):
            self.check(self.repo)

    def test_full_checkout_rejects_missing_pin(self) -> None:
        with self.assertRaisesRegex(AssertionError, "pinned grammar commit .* unavailable"):
            self.check(self.repo, "0" * 40)

    def test_shallow_checkout_reports_unavailable_pin(self) -> None:
        shallow = Path(self.tmp.name) / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth=1", self.repo.as_uri(),
                        str(shallow)], check=True)
        self.assertEqual(git(shallow, "rev-parse", "--is-shallow-repository"), "true")
        self.assertNotEqual(subprocess.run(
            ["git", "-C", str(shallow), "cat-file", "-e",
             f"{self.revision}^{{commit}}"], capture_output=True).returncode, 0)
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.check(shallow)
        self.assertIn("comparison skipped", output.getvalue())
        with patch.object(test_adapters, "ROOT", shallow / "highlight"):
            helix, zed, emacs = sources(self.revision)
            zed["grammars"]["landin"]["rev"] = "0" * 40
            with self.assertRaisesRegex(AssertionError, "revisions differ"):
                test_adapters.check_grammar_revision(helix, zed, emacs)
            with self.assertRaisesRegex(AssertionError, "full commit ID"):
                test_adapters.check_grammar_revision(*sources("main"))

    def test_source_archive_without_git(self) -> None:
        archive = Path(self.tmp.name) / "archive"
        adapter = archive / "highlight/test_adapters.py"
        shutil.copytree(Path(test_adapters.__file__).resolve().parent,
                        adapter.parent, ignore=shutil.ignore_patterns("__pycache__"))
        with patch.dict(os.environ, {"PATH": ""}):
            result = subprocess.run([sys.executable, str(adapter)], cwd=archive,
                                    capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("editor manifests", result.stdout)


if __name__ == "__main__":
    unittest.main()
