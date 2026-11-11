#!/usr/bin/env python3
"""Hold every script test that commits to the shared git environment."""
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from temporary_git import SETTINGS, environment   # noqa: E402

TESTS = Path(__file__).resolve().parent

#  A commit handed to git as an argument: the word, then an option.
COMMITS = re.compile(r'''["']commit["'],\s*["']-''')


class TemporaryGit(unittest.TestCase):
    def test_the_environment_reaches_git(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(["git", "init", "-q"], cwd=directory, check=True,
                           env=environment())
            for key, value in SETTINGS:
                with self.subTest(key=key):
                    read = subprocess.run(
                        ["git", "config", "--get", key], cwd=directory,
                        env=environment(), check=True, text=True,
                        stdout=subprocess.PIPE).stdout.strip()
                    self.assertEqual(read, value)
            #  A commit needs no configured author.
            subprocess.run(["git", "commit", "-q", "--allow-empty", "-m",
                            "x"], cwd=directory, check=True,
                           env=environment(HOME=directory,
                                           GIT_CONFIG_GLOBAL="/dev/null"))

    def test_a_callers_own_settings_are_kept(self):
        given = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.abbrev",
                 "GIT_CONFIG_VALUE_0": "12", "PATH": "/nowhere"}
        made = environment(given, EXTRA="yes")
        self.assertEqual(made["GIT_CONFIG_KEY_0"], "core.abbrev")
        self.assertEqual(made["GIT_CONFIG_KEY_1"], "maintenance.auto")
        self.assertEqual(made["GIT_CONFIG_VALUE_1"], "false")
        self.assertEqual(made["GIT_CONFIG_COUNT"], str(1 + len(SETTINGS)))
        self.assertEqual(made["EXTRA"], "yes")
        self.assertEqual(given["GIT_CONFIG_COUNT"], "1")

    def test_every_test_that_commits_uses_it(self):
        committing = []
        for path in sorted(TESTS.glob("*.py")):
            if path.name in ("temporary_git.py", Path(__file__).name):
                continue
            text = path.read_text()
            if COMMITS.search(text):
                committing.append(path.name)
                self.assertIn(
                    "temporary_git", text,
                    f"{path.name} passes git a commit without"
                    " scripts/tests/temporary_git.py's environment")
        #  The pattern still finds the tests it was written for.
        self.assertIn("test_activations.py", committing)
        self.assertIn("test_build_inventory.py", committing)

    def test_the_pattern_reads_a_commit_and_not_a_key(self):
        self.assertTrue(COMMITS.search('git(root, "commit", "-q")'))
        self.assertTrue(COMMITS.search("['git', 'commit',\n  '--quiet']"))
        self.assertFalse(COMMITS.search("provenance['commit'], 'a' * 40"))


if __name__ == "__main__":
    unittest.main()
