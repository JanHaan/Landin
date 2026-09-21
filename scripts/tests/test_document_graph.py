#!/usr/bin/env python3
"""Controls for the document-reachability check.

The property is that every tracked document is reachable from README.md.
A check that cannot fail is worse than none, so this exercises each way a
document is reached -- a Markdown link, a backticked name, a bare path and
a directory standing for its README -- and the case where it is not
reached at all.
"""
import importlib.util
import io
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("landin_document_checker", ROOT / "check.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class Reachability(unittest.TestCase):
    def build(self, tree):
        """A throwaway repository of Markdown files, given name -> text."""
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        for name, text in tree.items():
            path = Path(self.tmp) / name
            path.parent.mkdir(parents=True, exist_ok=True)
            io.open(path, "w", encoding="utf-8").write(text)
        return self.tmp

    def faults(self, tree):
        root = self.build(tree)
        with patch.object(checker, "ROOT", root):
            return [name for name, _, _ in checker.check_document_reachability(True)]

    def test_a_markdown_link_reaches(self):
        self.assertEqual(self.faults({
            "README.md": "see [the guide](docs/guide.md)\n",
            "docs/guide.md": "# Guide\n"}), [])

    def test_a_backticked_name_reaches(self):
        #  Most of this repository's cross-references are this shape.
        self.assertEqual(self.faults({
            "README.md": "see `docs/guide.md` for more\n",
            "docs/guide.md": "# Guide\n"}), [])

    def test_a_bare_path_reaches(self):
        self.assertEqual(self.faults({
            "README.md": "see docs/guide.md for more\n",
            "docs/guide.md": "# Guide\n"}), [])

    def test_naming_a_directory_reaches_its_readme(self):
        self.assertEqual(self.faults({
            "README.md": "the editors live in `highlight/emacs`\n",
            "highlight/emacs/README.md": "# Emacs\n"}), [])

    def test_reachability_is_indirect(self):
        #  README.md is the root, not an index: it need not name everything.
        self.assertEqual(self.faults({
            "README.md": "start at [one](one.md)\n",
            "one.md": "then [two](two.md)\n",
            "two.md": "then [three](three.md)\n",
            "three.md": "# Three\n"}), [])

    def test_an_unlinked_document_is_reported(self):
        self.assertEqual(self.faults({
            "README.md": "# Root\n",
            "docs/orphan.md": "# Orphan\n"}), ["docs/orphan.md"])

    def test_a_cycle_that_the_readme_cannot_reach_is_reported(self):
        #  Two documents naming each other are not thereby reachable.
        self.assertEqual(sorted(self.faults({
            "README.md": "# Root\n",
            "a.md": "see [b](b.md)\n",
            "b.md": "see [a](a.md)\n"})), ["a.md", "b.md"])

    def test_an_external_link_does_not_reach(self):
        self.assertEqual(self.faults({
            "README.md": "see <https://example.com/docs/guide.md>\n",
            "docs/guide.md": "# Guide\n"}), ["docs/guide.md"])

    def test_a_missing_readme_says_so_rather_than_passing(self):
        faults = self.faults({"docs/guide.md": "# Guide\n"})
        self.assertEqual(faults, ["README.md"])


if __name__ == "__main__":
    unittest.main()
