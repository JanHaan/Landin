#!/usr/bin/env python3
"""scripts/activations.py names the register rows an item's changes activate.

A temporary repository holds a register and a few files, so each way an
activation names a path -- backticks, a bare path, a base name, an Ada
unit, an area's name, a directory -- can be met or missed alone, and the
statuses that wait for nothing are left out.  The real ROADMAP.md is read
too, so a change to the register's form fails here rather than silently
matching no row.
"""
import importlib.util
import io
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("activations", ROOT / "scripts/activations.py")
activations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activations)

REGISTER = """# Roadmap

| Record | Family | What stands | Activation | Completion | Status |
| --- | --- | --- | --- | --- | --- |
| R8 | not the register | a | b | c | d |

## Register

| Record | Family | What stands | Activation | Completion | Status |
| --- | --- | --- | --- | --- | --- |
| SR-1 | Usability | quoted | The next change to `scripts/debug.sh`. | x | open |
| SR-2 | Usability | bare | The next change to environments/cortex-m/run.py's lanes. | x | scheduled elsewhere |
| SR-3 | Usability | base name | The next change to `run.py`. | x | open |
| SR-4 | Usability | unit | The next change to Landin.Driver.Usage. | x | open |
| SR-5 | Usability | area | The next change to the development shell. | x | open |
| SR-6 | Usability | directory | The next change to `environments/cortex-m`. | x | open |
| SR-7 | Usability | words | The next change to the Cortex-M lane runner. | x | open |
| SR-8 | Usability | retired | The next change to `scripts/debug.sh`. | x | retired: done |
| SR-9 | Usability | watched | The next change to `scripts/debug.sh`. | x | watch |
| SR-0 | Usability | not a path | The next change to `else` or `refine check`. | x | open |

## After the register

| Q9 | Usability | outside | The next change to `scripts/debug.sh`. | x | open |
"""

FILES = ("scripts/debug.sh", "environments/cortex-m/run.py",
         "environments/cortex-m/setup.py", "compiler/ada/src/landin-driver-usage.adb",
         "compiler/ada/src/landin-driver-usage.ads", "flake.nix", "spec.md", "core/io/io.ldn")


def git(cwd, *arguments):
    #  No detached maintenance.  Git 2.54 starts `git maintenance run
    #  --auto --detach` after every commit, and on a loaded host one was
    #  still at work under .git when a case's cleanup removed the
    #  repository, which then failed with "Directory not empty".
    environment = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t",
                       GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="gc.auto",
                       GIT_CONFIG_VALUE_0="0",
                       GIT_CONFIG_KEY_1="maintenance.auto",
                       GIT_CONFIG_VALUE_1="false")
    return subprocess.run(["git", *arguments], cwd=cwd, env=environment, check=True,
                          stdout=subprocess.PIPE, text=True).stdout.strip()


class Activations(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        git(self.root, "init", "-q", "-b", "main")
        (self.root / "ROADMAP.md").write_text(REGISTER)
        for name in FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("first\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "base")
        git(self.root, "checkout", "-q", "-b", "item")

    def listed(self, *arguments):
        out = io.StringIO()
        status = activations.main(list(arguments), root=self.root, out=out)
        self.assertEqual(status, 0)
        text = out.getvalue()
        return {line.split(" ", 1)[0] for line in text.splitlines()
                if re.match(r"(?:SR-|T)\d+ \(", line)}, text

    def test_each_way_of_naming_a_path_is_met(self):
        cases = {
            "scripts/debug.sh": {"SR-1"},
            "environments/cortex-m/run.py": {"SR-2", "SR-3", "SR-6"},
            "environments/cortex-m/setup.py": {"SR-6"},
            "compiler/ada/src/landin-driver-usage.ads": {"SR-4"},
            "flake.nix": {"SR-5"},
            "core/io/io.ldn": set(),
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(self.listed(path)[0], expected)

    def test_retired_watched_and_outside_rows_are_not_listed(self):
        listed, text = self.listed("scripts/debug.sh")
        self.assertEqual(listed, {"SR-1"})
        self.assertNotIn("Q9", text)

    def test_rows_naming_no_path_are_counted_and_listed_on_request(self):
        listed, text = self.listed("--unmatched", "spec.md")
        self.assertIn("2 open or scheduled rows name no path", text)
        self.assertIn("  SR-7 (open): The next change to the Cortex-M lane runner.", text)
        self.assertIn("  SR-0 (open):", text)
        self.assertNotIn("--unmatched lists them", text)

    def test_committed_staged_and_untracked_changes_count(self):
        (self.root / "scripts/debug.sh").write_text("changed\n")
        git(self.root, "commit", "-q", "-am", "item")
        git(self.root, "rm", "-q", "environments/cortex-m/setup.py")
        (self.root / "compiler/ada/src/landin-driver-usage.adb").write_text("changed\n")
        (self.root / "highlight/tree-sitter").mkdir(parents=True)
        (self.root / "highlight/tree-sitter/grammar.js").write_text("new\n")
        listed, text = self.listed()
        self.assertEqual(listed, {"SR-1", "SR-4", "SR-6"})
        self.assertIn("4 changed paths (changes since main)", text)
        self.assertIn("./highlight/test.sh --integration", text)
        self.assertNotIn("nix build", text)

    def test_commits_main_made_after_the_item_left_it_do_not_count(self):
        git(self.root, "checkout", "-q", "main")
        (self.root / "scripts/debug.sh").write_text("on main\n")
        git(self.root, "commit", "-q", "-am", "main moves")
        git(self.root, "checkout", "-q", "item")
        self.assertEqual(self.listed()[0], set())

    def commit(self, message, **files):
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", message)
        return git(self.root, "rev-parse", "HEAD")

    def roadmap_with(self, row):
        return REGISTER.replace("\n\n## After the register",
                                "\n" + row + "\n\n## After the register")

    def test_a_change_before_the_row_was_written_does_not_count(self):
        #  The row's writer had seen the change it names: it is what the
        #  row was written about, not the next change to the file.
        self.commit("change setup", **{"environments/cortex-m/setup.py": "a\n"})
        row = ("| T1 | Usability | late | The next change to"
               " `environments/cortex-m/setup.py`. | x | open |")
        stated = self.commit("add the row", **{"ROADMAP.md": self.roadmap_with(row)})
        listed, text = self.listed()
        self.assertNotIn("T1", listed)
        self.assertIn("T1 (stated in %s)" % stated[:12], text)
        self.assertIn("--whole-window lists them", text)
        #  The old reading is still asked for by name.
        self.assertIn("T1", self.listed("--whole-window")[0])
        #  The next change after the row meets it, and names its commit.
        met = self.commit("change setup again",
                          **{"environments/cortex-m/setup.py": "b\n"})
        listed, text = self.listed()
        self.assertIn("T1", listed)
        self.assertIn("met by: " + met[:12], text)
        self.assertNotIn(stated[:12], text.split("T1 (open)", 1)[1])

    def test_a_restated_activation_starts_the_row_again(self):
        row = ("| T2 | Usability | restated | The next change to"
               " `scripts/debug.sh`. | x | open |")
        self.commit("add the row", **{"ROADMAP.md": self.roadmap_with(row)})
        self.commit("change debug", **{"scripts/debug.sh": "a\n"})
        self.assertIn("T2", self.listed()[0])
        #  Restating its activation after that change starts it again;
        #  a change to another cell does not.
        restated = row.replace("`scripts/debug.sh`.", "`scripts/debug.sh` again.")
        self.commit("restate", **{"ROADMAP.md": self.roadmap_with(restated)})
        self.assertNotIn("T2", self.listed()[0])
        reworded = restated.replace("| restated |", "| reworded |")
        self.commit("reword", **{"ROADMAP.md": self.roadmap_with(reworded)})
        self.assertNotIn("T2", self.listed()[0])
        #  An uncommitted change is always after the row.
        (self.root / "scripts/debug.sh").write_text("b\n")
        self.assertIn("T2", self.listed()[0])

    def test_a_base_name_several_files_share_is_ambiguous_not_matched(self):
        #  SR-3 says `run.py`.  With a second run.py tracked, a change to
        #  either is no longer SR-3's, and the name is reported.
        self.commit("a second run.py", **{"environments/boards/run.py": "a\n"})
        for path in ("environments/cortex-m/run.py", "environments/boards/run.py"):
            with self.subTest(path=path):
                listed, text = self.listed(path)
                self.assertNotIn("SR-3", listed)
                self.assertIn("1 activations name a file by a base name "
                              "several tracked", text)
                self.assertIn("  SR-3: `run.py` could be environments/boards/"
                              "run.py, environments/cortex-m/run.py", text)
        #  A row naming nothing else is among those to read by hand.
        self.assertIn("  SR-3 (open):", self.listed("--unmatched", "spec.md")[1])
        #  The spelled path, SR-2's, still matches.
        self.assertIn("SR-2", self.listed("environments/cortex-m/run.py")[0])

    def test_a_directory_named_as_an_owner_is_listed_apart(self):
        rows = ("| T3 | Usability | owner | The next change to `core/io`'s"
                " `make_temporary`. | x | open |\n"
                "| T4 | Usability | bare owner | The next change to"
                " environments/cortex-m's own module. | x | open |\n"
                "| T5 | Usability | both | The next change to `core/io`'s"
                " reader or to `core/io/io.ldn`. | x | open |")
        self.commit("rows", **{"ROADMAP.md": self.roadmap_with(rows)})
        self.commit("change io", **{"core/io/io.ldn": "a\n",
                                    "environments/cortex-m/setup.py": "a\n"})
        listed, text = self.listed()
        self.assertEqual(listed, {"SR-6", "T3", "T4", "T5"})
        direct, _, owned = text.partition(
            "Rows whose activation names a changed directory only as the owner")
        self.assertTrue(owned, text)
        #  The directory named outright, and the row that also names the
        #  changed file, are met; the two owner-only rows are to be read.
        self.assertIn("SR-6 (open)", direct)
        self.assertIn("T5 (open)", direct)
        self.assertNotIn("T3 (open)", direct)
        self.assertNotIn("T4 (open)", direct)
        self.assertIn("T3 (open): core/io/io.ldn", owned)
        self.assertIn("    owner only: core/io/", owned)
        self.assertIn("T4 (open): environments/cortex-m/setup.py", owned)
        self.assertNotIn("T5 (open)", owned)

    def test_a_parallel_commit_merged_after_the_row_is_marked(self):
        #  A stream changes the file; the row recording that change is
        #  written on the integration branch; the stream is merged after.
        #  The change is not an ancestor of the statement, so it counts,
        #  and the reader is told it was made beside the row.
        git(self.root, "checkout", "-q", "-b", "stream")
        beside = self.commit("the change the row records",
                             **{"environments/cortex-m/setup.py": "a\n"})
        git(self.root, "checkout", "-q", "item")
        row = ("| T6 | Usability | recorded | The next change to"
               " `environments/cortex-m/setup.py`. | x | open |")
        self.commit("add the row", **{"ROADMAP.md": self.roadmap_with(row)})
        git(self.root, "merge", "-q", "--no-ff", "-m", "merge the stream", "stream")
        merge = git(self.root, "rev-parse", "HEAD")
        listed, text = self.listed()
        self.assertIn("T6", listed)
        self.assertIn("met by: %s [beside the row's statement, merged in %s]"
                      % (beside[:12], merge[:12]), text)
        self.assertIn("it may be the change the row\nrecords, merged afterwards",
                      text)
        #  A change made on top of the statement carries no mark.
        after = self.commit("the next change",
                            **{"environments/cortex-m/setup.py": "b\n"})
        text = self.listed()[1]
        met = text.split("T6 (open)", 1)[1].split("met by: ", 1)[1].split("\n")[0]
        self.assertIn("%s [beside" % beside[:12], met)
        self.assertRegex(met, r"%s(?! \[)" % after[:12])

    def test_a_row_stated_before_the_window_counts_every_change(self):
        self.commit("change debug", **{"scripts/debug.sh": "a\n"})
        self.assertEqual(self.listed()[0], {"SR-1"})

    def test_the_gate_only_passes_follow_their_inputs(self):
        for path, wanted in (("compiler/tests/fixtures/positive/x/program.ldn", "editor grammar"),
                             ("spec.md", "editor grammar"),
                             ("environments/pins.sh", "the flake"),
                             ("flake.lock", "the flake")):
            with self.subTest(path=path):
                self.assertIn(wanted, self.listed(path)[1])
        self.assertNotIn("The changes reach", self.listed("scripts/debug.sh")[1])

    def test_run_reports_a_failed_pass(self):
        out = io.StringIO()
        original = activations.PASSES
        activations.PASSES = (("a failing pass", ("flake.nix",), (("false",),)),)
        try:
            status = activations.main(["--run", "flake.nix"], root=self.root, out=out)
        finally:
            activations.PASSES = original
        self.assertEqual(status, 1)
        self.assertIn("activations: a failing pass failed", out.getvalue())

    def test_a_malformed_row_is_an_error(self):
        with self.assertRaises(ValueError):
            activations.register("## Register\n\n| SR-1 | only | three |\n")
        with self.assertRaises(ValueError):
            activations.register("no register here\n")


class TheRegister(unittest.TestCase):
    def test_the_roadmap_register_is_read(self):
        rows = activations.register((ROOT / "ROADMAP.md").read_text(encoding="utf-8"))
        statuses = {status.split(" ", 1)[0].rstrip(":") for _, _, status in rows}
        self.assertGreater(len(rows), 100)
        self.assertLessEqual(statuses, {"open", "scheduled", "retired", "watch", "limit"})
        self.assertTrue(any(identity.startswith("SR-") for identity, _, _ in rows))
        self.assertTrue(any(identity.startswith("R551-") for identity, _, _ in rows))

    def test_every_pass_input_is_tracked(self):
        tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, check=True,
                                 stdout=subprocess.PIPE, text=True).stdout.splitlines()
        for description, prefixes, unused_commands in activations.PASSES:
            for prefix in prefixes:
                with self.subTest(prefix=prefix):
                    self.assertTrue(any(path == prefix or path.startswith(prefix)
                                        for path in tracked), description)


if __name__ == "__main__":
    unittest.main()
