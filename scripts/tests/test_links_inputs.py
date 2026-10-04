"""The link workflow selects only documents changed by a push."""

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "links_inputs.py"
spec = importlib.util.spec_from_file_location("links_inputs", SCRIPT)
links_inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(links_inputs)


class LinkInputsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.previous = Path.cwd()
        os.chdir(self.temp.name)
        self.addCleanup(os.chdir, self.previous)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        Path("changed.md").write_text("old\n")
        Path("untouched.md").write_text("untouched\n")
        Path("lychee.toml").write_text("old\n")
        self.commit()
        self.before = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        return subprocess.check_output(("git", *args), text=True)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "test")

    def test_push_checks_only_changed_documents(self):
        Path("changed.md").write_text("new\n")
        Path("code.txt").write_text("new\n")
        self.commit()
        self.assertEqual(links_inputs.inputs("push", self.before),
                         ("./changed.md\n", "changed"))

    def test_non_document_change_or_deletion_skips_lychee(self):
        Path("changed.md").unlink()
        self.commit()
        self.assertEqual(links_inputs.inputs("push", self.before), ("", "none"))

    def test_config_change_and_periodic_run_check_every_document(self):
        Path("lychee.toml").write_text("new\n")
        self.commit()
        self.assertEqual(links_inputs.inputs("push", self.before),
                         (links_inputs.FULL, "full"))
        self.assertEqual(links_inputs.inputs("schedule", ""),
                         (links_inputs.FULL, "full"))

    def test_unavailable_base_falls_back_to_full_scan(self):
        self.assertEqual(links_inputs.inputs("push", "0" * 40),
                         (links_inputs.FULL, "full"))
        self.assertEqual(links_inputs.inputs("push", "f" * 40),
                         (links_inputs.FULL, "full"))

    def test_unrepresentable_filename_falls_back_to_full_scan(self):
        Path("[draft].md").write_text("new\n")
        self.commit()
        self.assertEqual(links_inputs.inputs("push", self.before),
                         (links_inputs.FULL, "full"))


if __name__ == "__main__":
    unittest.main()
