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
import grammar_pin
import test_adapters


def git(directory: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(directory), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def commit(directory: Path, message: str) -> None:
    git(directory, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "commit", "-qm", message)


def manifests(root: Path, revision: str) -> None:
    """The three editor manifests, in the shape grammar_pin.py rewrites."""
    files = {
        "helix/languages.toml": '[[grammar]]\nname = "landin"\nsource = { git = '
            '"https://example.invalid/Landin", rev = "%s", subpath = '
            '"highlight/tree-sitter" }\n',
        "zed/extension.toml": '[grammars.landin]\nrepository = '
            '"https://example.invalid/Landin"\nrev = "%s"\npath = '
            '"highlight/tree-sitter"\n\n[language_servers.refine]\nname = "x"\n',
        "emacs/landin-mode.el": '(defcustom landin-treesit-revision "%s"\n  "")\n',
    }
    for relative, text in files.items():
        path = root / "highlight" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text % revision, encoding="utf-8")


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
        with self.assertRaisesRegex(AssertionError, "shipped grammar or queries differ.*"
                                    "to the commit that holds them"):
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

    def rebase(self) -> str:
        """Replay both commits onto a new root, as a rebase rewrites them."""
        git(self.repo, "checkout", "-q", "--orphan", "rebased")
        git(self.repo, "rm", "-rqf", ".")
        (self.repo / "base.txt").write_text("base\n", encoding="utf-8")
        git(self.repo, "add", "base.txt")
        commit(self.repo, "New base")
        git(self.repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "cherry-pick", self.revision, "main")
        rewritten = git(self.repo, "rev-parse", "HEAD~1")
        self.assertNotEqual(rewritten, self.revision)
        return rewritten

    def test_rebased_pin_is_refused_and_moved(self) -> None:
        rewritten = self.rebase()
        #  The old commit is still in the object store, with the same grammar,
        #  but no longer on the branch the editors would fetch.
        with self.assertRaisesRegex(AssertionError,
                                    f"not on this branch.*grammar_pin.py.*{rewritten}"):
            self.check(self.repo)
        manifests(self.repo, self.revision)
        root = self.repo / "highlight"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(grammar_pin.move(root), 0)
        self.assertEqual(set(grammar_pin.pins(root).values()), {rewritten})
        self.check(self.repo, rewritten)

    def test_unavailable_pin_names_the_repair(self) -> None:
        rewritten = self.rebase()
        with self.assertRaisesRegex(AssertionError,
                                    f"unavailable.*rebase.*grammar_pin.py.*{rewritten}"):
            self.check(self.repo, "0" * 40)

    def test_move_refuses_an_uncommitted_grammar(self) -> None:
        manifests(self.repo, "1" * 40)
        (self.repo / "highlight/tree-sitter/grammar.js").write_text(
            "edited grammar\n", encoding="utf-8")
        root = self.repo / "highlight"
        with contextlib.redirect_stderr(io.StringIO()) as said:
            self.assertEqual(grammar_pin.move(root), 1)
        self.assertIn("uncommitted", said.getvalue())
        self.assertEqual(set(grammar_pin.pins(root).values()), {"1" * 40})

    def test_move_names_the_last_grammar_commit(self) -> None:
        manifests(self.repo, "1" * 40)
        root = self.repo / "highlight"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(grammar_pin.move(root), 0)
        #  The later commit touched no grammar path, so the pin stays on the
        #  commit that did.
        self.assertEqual(set(grammar_pin.pins(root).values()), {self.revision})

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
