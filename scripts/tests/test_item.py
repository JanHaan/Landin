#!/usr/bin/env python3
"""Controls for scripts/item.py, which runs a roadmap item's mechanical steps.

Each case builds a clone with a remote, a ROADMAP.md of invented items and
the pointer files, and runs the script against it.  GitHub is never asked:
the gate cases give the state the runs a listing would have produced.  The
items' identities are built at run time, so this file names none.
"""
import contextlib
import io
import json
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import item  # noqa: E402
import register_next  # noqa: E402
from temporary_git import environment  # noqa: E402

FIRST = "R%d.%d" % (0, 10)
SECOND = "R%d.%d" % (0, 20)
THIRD = "R%d.%d" % (0, 30)
ROADMAP = """\
# Roadmap

## R0 — A phase

### {first} — The first

Status: planned
Depends on: none

Exit evidence: x.

### {second} — The second

Status: planned
Depends on: none
Promotion: maintainer

Exit evidence: x.

### {third} — The third

Status: planned
Depends on: {first}

Exit evidence: x.
""".format(first=FIRST, second=SECOND, third=THIRD)
POINTER = "**Next roadmap item: %s — The first (planned).**\n" % FIRST


def git(root, *arguments):
    return subprocess.run(["git", *arguments], cwd=root, check=True,
                          env=environment(), text=True,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout.strip()


class Clone(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.top = Path(self.scratch.name)
        self.origin = self.top / "origin.git"
        self.clone = self.top / "Landin"
        git(self.top, "init", "-q", "--bare", "-b", "main", str(self.origin))
        git(self.top, "init", "-q", "-b", "main", str(self.clone))
        (self.clone / "ROADMAP.md").write_text(ROADMAP)
        (self.clone / "README.md").write_text(POINTER)
        (self.clone / "handoff.md").write_text(POINTER)
        (self.clone / "spec.md").write_text("D41 and D42 are decisions.\n")
        git(self.clone, "add", "-A")
        git(self.clone, "commit", "-q", "-m", "base")
        git(self.clone, "remote", "add", "origin", str(self.origin))
        git(self.clone, "push", "-q", "origin", "main")
        git(self.clone, "fetch", "-q", "origin")

    def tearDown(self):
        item.REPOSITORY[0] = item.ROOT
        self.scratch.cleanup()

    def item(self, *arguments):
        out, err = io.StringIO(), io.StringIO()
        if arguments[:1] != ("--repo",):
            arguments = ("--repo", str(self.clone)) + arguments
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                _environment(), _directory():
            status = item.main(list(arguments))
        item.REPOSITORY[0] = self.clone
        return status, out.getvalue() + err.getvalue()


@contextlib.contextmanager
def _directory():
    """The test's working directory back, whatever the script chdir'd to."""
    import os
    saved = os.getcwd()
    try:
        yield
    finally:
        os.chdir(saved)


@contextlib.contextmanager
def _environment():
    """Git's settings for a temporary repository, for the script's own git."""
    import os
    saved = dict(os.environ)
    os.environ.update(environment())
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(saved)


class Start(Clone):
    def test_start_makes_the_worktree_state_brief_and_active_status(self):
        status, out = self.item("start", FIRST)
        self.assertEqual(status, 0, out)
        worktree = self.top / ("Landin-" + item.slug(FIRST))
        self.assertTrue(worktree.is_dir())
        self.assertEqual(git(worktree, "rev-parse", "--abbrev-ref", "HEAD"),
                         item.slug(FIRST))
        self.assertIn("### %s — The first\n\nStatus: active\n" % FIRST,
                      (worktree / "ROADMAP.md").read_text())
        for name in item.POINTER_FILES:
            self.assertEqual((worktree / name).read_text(),
                             "**Current roadmap work: %s — The first.**\n"
                             % FIRST)
        self.assertIn(item.EXPLANATORY, git(worktree, "log", "-1",
                                            "--format=%B"))
        state = item.load(FIRST)
        self.assertEqual(state["phase"], "started")
        #  Past the specification's last decision and the second
        #  roadmap's last row.
        self.assertEqual(state["reserved"]["D"][0], 43)
        self.assertEqual(state["reserved"]["SR"][0],
                         register_next.SECOND_ROADMAP_LAST + 1)
        brief = (item.item_directory(FIRST) / "brief.md").read_text()
        self.assertIn(str(worktree), brief)
        self.assertIn("item.py resume %s" % FIRST, brief)
        self.assertIn("Authority paragraph", brief)

    def test_start_from_another_worktree_places_it_beside_the_main_one(self):
        elsewhere = self.top / "elsewhere" / "checkout"
        git(self.clone, "worktree", "add", "-q", "--detach", str(elsewhere))
        status, out = self.item("--repo", str(elsewhere), "start", FIRST)
        self.assertEqual(status, 0, out)
        worktree = self.top / ("Landin-" + item.slug(FIRST))
        self.assertTrue(worktree.is_dir(), out)
        self.assertIn(str(worktree.resolve()), out)

    def test_two_items_reserve_apart_and_register_next_honours_them(self):
        self.assertEqual(self.item("start", FIRST)[0], 0)
        self.assertEqual(self.item("start", SECOND)[0], 0)
        first, second = item.load(FIRST), item.load(SECOND)
        for kind in item.BLOCKS:
            self.assertLess(first["reserved"][kind][1],
                            second["reserved"][kind][0])
        #  From the second item's worktree, its own block comes first.
        worktree = Path(second["worktree"])
        self.assertEqual(register_next.allocate(worktree, 1),
                         ["SR-%d" % second["reserved"]["SR"][0]])
        #  From the main checkout, past both.
        self.assertEqual(register_next.allocate(self.clone, 1),
                         ["SR-%d" % (second["reserved"]["SR"][1] + 1)])
        brief = (item.item_directory(SECOND) / "brief.md").read_text()
        self.assertIn("Promotion: maintainer", brief)
        self.assertIn(FIRST + " on branch", brief)

    def test_an_unmet_dependency_refuses(self):
        status, out = self.item("start", THIRD)
        self.assertEqual(status, 2)
        self.assertIn("depends on %s" % FIRST, out)
        self.assertFalse((self.top / ("Landin-" + item.slug(THIRD))).exists())

    def test_starting_twice_refuses(self):
        self.item("start", FIRST)
        status, out = self.item("start", FIRST)
        self.assertEqual(status, 2)
        self.assertIn("already running", out)

    def test_adopt_takes_an_existing_worktree(self):
        worktree = self.top / "elsewhere"
        git(self.clone, "worktree", "add", "-q", "-b", "mine", str(worktree),
            "origin/main")
        status, out = self.item("start", FIRST, "--adopt", str(worktree))
        self.assertEqual(status, 0, out)
        self.assertEqual(item.load(FIRST)["branch"], "mine")


class Resume(Clone):
    def test_resume_reads_the_state_a_new_session_needs(self):
        self.item("start", FIRST)
        self.item("note", FIRST, "halfway", "through")
        worktree = Path(item.load(FIRST)["worktree"])
        (worktree / "new.txt").write_text("x")
        status, out = self.item("resume", FIRST)
        self.assertEqual(status, 0, out)
        self.assertIn("uncommitted changes", out)
        self.assertIn("halfway through", out)
        self.assertIn("next: the uncommitted changes listed above", out)
        self.assertIn("then continue the work", out)

    def test_a_running_run_is_the_next_step_and_a_lost_one_is_named(self):
        self.item("start", FIRST)
        state = item.load(FIRST)
        going = item.item_directory(FIRST) / "runs" / "suite"
        going.mkdir(parents=True)
        (going / "running.json").write_text(json.dumps({"pid": 1}))
        state["runs"].append({"name": "suite", "directory": str(going),
                              "command": "x", "started": item.stamp()})
        item.save(state)
        step = item.next_step(item.load(FIRST))
        self.assertIn("wait for run suite", step)
        self.assertIn("; then continue the work", step)
        (going / "result.json").write_text(json.dumps({"exit_status": 0}))
        self.assertEqual(item.run_state(going), "finished, exit 0")

    def test_stalled_names_an_item_nothing_moved(self):
        self.item("start", FIRST)
        status, out = self.item("stalled", "--minutes", "0")
        self.assertEqual(status, 1)
        self.assertIn("STALLED " + FIRST, out)
        status, out = self.item("stalled", "--minutes", "600")
        self.assertEqual(status, 0)
        self.assertIn("moving " + FIRST, out)

    def test_report_ends_with_the_open_questions_and_their_defaults(self):
        self.item("start", FIRST)
        worktree = Path(item.load(FIRST)["worktree"])
        questions = worktree / "roadmap" / "questions"
        questions.mkdir(parents=True)
        (questions / "Q-0.md").write_text(
            "# Q-0 — Which?\n\nAsked by %s on 2026-01-01.\n\nWhy.\n\n"
            "**Options:**\n\n1. this\n2. that\n\n**Recommendation:** this\n\n"
            "**Default until answered:** this one\n\n"
            "**What waits on the answer:** nothing\n" % FIRST)
        status, out = self.item("report", FIRST)
        self.assertEqual(status, 0, out)
        tail = out.split("NEEDS JAN:")[1]
        self.assertIn("Default taken: this one", tail)
        self.assertEqual(out.rstrip().splitlines()[-2], "NEEDS JAN:")


class Promote(Clone):
    def setUp(self):
        super().setUp()
        self.item("start", FIRST)
        self.state = item.load(FIRST)
        self.worktree = Path(self.state["worktree"])

    def commit(self, message):
        (self.worktree / "work.txt").write_text(message)
        git(self.worktree, "add", "-A")
        git(self.worktree, "commit", "-q", "-m", message)
        return git(self.worktree, "rev-parse", "HEAD")

    def gate(self, commit, kind):
        return {"run": len(self.state["gates"]) + 1, "commit": commit,
                "tree": git(self.worktree, "rev-parse", commit + "^{tree}"),
                "kind": kind, "status": "completed", "conclusion": "success"}

    def problems(self, commit):
        saved = item.complete_listing
        item.complete_listing = lambda run: None
        try:
            return item.evidence(self.state, commit)
        finally:
            item.complete_listing = saved

    def test_without_runs_both_passes_are_missing(self):
        head = self.commit("work")
        problems = self.problems(head)
        self.assertEqual(len(problems), 2, problems)

    def test_boards_on_the_same_tree_suffice(self):
        head = self.commit("work")
        self.state["gates"] += [self.gate(head, "software"),
                                self.gate(head, "boards")]
        self.assertEqual(self.problems(head), [])

    def test_an_explanatory_close_keeps_the_earlier_boards(self):
        work = self.commit("work")
        self.state["gates"].append(self.gate(work, "boards"))
        close = self.commit("Close\n\n" + item.EXPLANATORY)
        self.state["gates"].append(self.gate(close, "software"))
        self.assertEqual(self.problems(close), [])
        later = self.commit("more work")
        self.state["gates"].append(self.gate(later, "software"))
        self.assertEqual(len(self.problems(later)), 1)

    def test_a_boards_run_still_going_is_named_not_dispatched_again(self):
        head = self.commit("work")
        going = dict(self.gate(head, "boards"), status="in_progress",
                     conclusion="")
        self.state["gates"] += [self.gate(head, "software"), going]
        problems = self.problems(head)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("has not finished", problems[0])

    def test_run_takes_its_options_before_the_command(self):
        status, out = self.item("run", FIRST, "echo", "--limit", "60", "--",
                                sys.executable, "-c", "print('ran')",
                                "--limit")
        self.assertEqual(status, 0, out)
        directory = item.item_directory(FIRST) / "runs" / "echo"
        waited = subprocess.run(
            [sys.executable, str(item.ROOT / "scripts/run_logged.py"),
             "--wait", str(directory), "--timeout", "60"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(waited.returncode, 0, waited.stdout)
        self.assertIn("ran", (directory / "command.log").read_text())
        self.assertEqual(item.load(FIRST)["runs"][0]["command"],
                         shlex.join([sys.executable, "-c", "print('ran')",
                                     "--limit"]))

    def test_a_rerun_of_the_same_commit_is_watched_afresh(self):
        #  The watch is named by the run and its attempt: a finished watch
        #  of attempt 1 does not answer for attempt 2 of the same commit.
        head = self.commit("work")
        git(self.worktree, "push", "-q", "origin", self.state["branch"])
        listing = [{"databaseId": 5, "event": "push",
                    "headBranch": self.state["branch"], "status": "completed",
                    "conclusion": "failure", "displayTitle": "x",
                    "attempt": 1}]
        started = []

        def run(arguments):
            directory = item.item_directory(FIRST) / "runs" / arguments.name
            directory.mkdir(parents=True)
            (directory / "result.json").write_text('{"exit_status": 1}')
            started.append((arguments.name, arguments.command[-2:]))
            return 0

        saved = item.runs_of, item.run
        item.runs_of, item.run = (lambda commit: listing), run
        try:
            self.item("gate", FIRST, "--watch")
            status, out = self.item("gate", FIRST, "--watch")
            self.assertIn("already watched", out)
            listing[0].update(attempt=2, status="in_progress", conclusion="")
            status, out = self.item("gate", FIRST, "--watch")
        finally:
            item.runs_of, item.run = saved
        self.assertEqual(status, 0, out)
        prefix = "gate-branch-%s-run5-attempt" % head[:12]
        self.assertEqual(started, [(prefix + "1", ["--run", "5"]),
                                   (prefix + "2", ["--run", "5"])])

    def test_run_in_another_directory_is_kept_and_reported(self):
        elsewhere = self.top / "stream"
        elsewhere.mkdir()
        status, out = self.item("run", FIRST, "where", "--limit", "60",
                                "--cwd", str(elsewhere), "--",
                                sys.executable, "-c",
                                "import os; print(os.getcwd())")
        self.assertEqual(status, 0, out)
        directory = item.item_directory(FIRST) / "runs" / "where"
        subprocess.run([sys.executable,
                        str(item.ROOT / "scripts/run_logged.py"),
                        "--wait", str(directory), "--timeout", "60"],
                       check=True, stdout=subprocess.DEVNULL)
        self.assertIn(str(elsewhere.resolve()),
                      (directory / "command.log").read_text())
        self.assertEqual(item.load(FIRST)["runs"][0]["cwd"],
                         str(elsewhere.resolve()))
        status, out = self.item("resume", FIRST)
        self.assertIn("in %s" % elsewhere.resolve(), out)

    def test_passed_runs_move_the_phase_on(self):
        head = self.commit("work")
        self.state["gates"].append(self.gate(head, "software"))
        item.advance(self.state, head)
        self.assertEqual(self.state["phase"], "gate-passed")
        self.state["gates"].append(self.gate(head, "boards"))
        item.advance(self.state, head)
        self.assertEqual(self.state["phase"], "boards-passed")
        self.assertIn("promote", item.phase_step(self.state))

    def test_a_maintainer_item_is_not_promoted(self):
        self.item("start", SECOND)
        status, out = self.item("promote", SECOND)
        self.assertEqual(status, 2)
        self.assertIn("Promotion: maintainer", out)

    def test_finish_from_the_items_own_worktree(self):
        #  As an item's agent runs it: the script's checkout is the one
        #  it removes.
        status, out = self.item("--repo", str(self.worktree), "finish",
                                FIRST, "--unpromoted")
        self.assertEqual(status, 0, out)
        self.assertFalse(self.worktree.exists())
        self.assertEqual(git(self.clone, "branch", "--list",
                             self.state["branch"]), "")

    def test_finish_when_the_worktree_is_already_gone(self):
        self.state["promoted"] = git(self.clone, "rev-parse", "HEAD")
        self.state["gates"].append(
            self.gate(self.state["promoted"], "main"))
        item.save(self.state)
        git(self.clone, "worktree", "remove", str(self.worktree))
        saved = item.record_gates
        item.record_gates = lambda state, commit: (
            item.place(state), state)[1]
        try:
            status, out = self.item("finish", FIRST)
        finally:
            item.record_gates = saved
        self.assertEqual(status, 0, out)
        self.assertTrue((item.state_root() / item.DONE_DIRECTORY
                         / FIRST).is_dir())

    def test_finish_unpromoted_removes_worktree_and_branch(self):
        status, out = self.item("finish", FIRST)
        self.assertEqual(status, 2)
        self.assertIn("not promoted", out)
        status, out = self.item("finish", FIRST, "--unpromoted")
        self.assertEqual(status, 0, out)
        self.assertFalse(self.worktree.exists())
        self.assertEqual(git(self.clone, "branch", "--list",
                             self.state["branch"]), "")
        self.assertTrue((item.state_root() / item.DONE_DIRECTORY / FIRST
                         / "journal.md").exists())
        status, out = self.item("resume", FIRST)
        self.assertIn("is finished", out)


if __name__ == "__main__":
    unittest.main()
