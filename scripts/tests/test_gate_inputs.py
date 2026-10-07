#!/usr/bin/env python3
"""The gate reuses a pass only for a declared explanatory change.

scripts/gate_inputs.py leaves the content of four top-level documents out
of the key.  That is sound only while no skippable lane reads them, so the
last class here names every tracked file that mentions one, and a new one
is a decision rather than an accident.  Key holds the key to every other
difference.  Decide holds reuse to GitHub's record of a push to main that
ran every lane, never to anything a branch writes, and to a trusted
`Gate: explanatory` on every commit since, so a semantic edit nobody
declared runs everything.  Verdict holds the gate to the one shape a
reused pass may have.
"""
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("gate_inputs", ROOT / "scripts/gate_inputs.py")
gate_inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate_inputs)


def git(cwd, *arguments):
    environment = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    return subprocess.run(["git", *arguments], cwd=cwd, env=environment, check=True,
                          stdout=subprocess.PIPE, text=True).stdout.strip()


class Key(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        git(self.root, "init", "-q")
        for name in gate_inputs.CONTENT_FREE:
            self.write(name, "the first text\n")
        self.write("spec.md", "a rule\n")
        self.write("docs/README.md", "a nested readme\n")
        self.write("compiler/main.adb", "procedure Main is begin null; end;\n")
        self.first = self.commit()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "--allow-empty", "-m", "x")
        return git(self.root, "rev-parse", "HEAD")

    def same(self):
        return (gate_inputs.key(self.first, self.root)
                == gate_inputs.key(self.commit(), self.root))

    def test_the_four_documents_contents_do_not_count(self):
        #  Review 2's counterexamples among them: a semantic claim in one of
        #  these files is checked by check.py and review, not by a lane.
        self.write("README.md", "Cortex-M4 with 512 KB of flash\n")
        self.write("ROADMAP.md", "a new acceptance claim\n")
        self.write("handoff.md", "Statements need terminators.\n")
        self.write("AGENTS.md", "")
        self.assertTrue(self.same())

    def test_any_other_content_counts(self):
        for name in ("spec.md", "docs/README.md", "compiler/main.adb"):
            with self.subTest(name=name):
                self.write(name, "changed\n")
                self.assertFalse(self.same())
                git(self.root, "reset", "-q", "--hard", self.first)

    def test_candidate_key_includes_the_four_documents(self):
        original = gate_inputs.key(self.first, self.root, content_free=())
        self.write("README.md", "changed explanation\n")
        self.assertNotEqual(original, gate_inputs.key(self.commit(), self.root,
                                                    content_free=()))

    def test_a_new_file_counts(self):
        self.write("compiler/extra.adb", "")
        self.assertFalse(self.same())

    def test_deleting_or_renaming_one_of_the_four_counts(self):
        (self.root / "AGENTS.md").unlink()
        self.assertFalse(self.same())
        git(self.root, "reset", "-q", "--hard", self.first)
        git(self.root, "mv", "ROADMAP.md", "ROADMAP2.md")
        self.assertFalse(self.same())

    def test_a_mode_counts(self):
        (self.root / "README.md").chmod(0o755)
        self.assertFalse(self.same())

    def test_a_tree_that_cannot_be_read_is_an_error(self):
        with self.assertRaises(subprocess.CalledProcessError):
            gate_inputs.key("0" * 40, self.root)


NOW = datetime(2026, 10, 4, 12, tzinfo=timezone.utc)
LANES = ("compiler", "darwin-host (debug)", "darwin-host (release)")
#  A main run at BASE; main has since moved to MAIN; the pull request's head
#  is HEAD; GitHub checked out MERGE, whose parents are MAIN and HEAD.
BASE, MAIN, HEAD, MERGE = "b" * 40, "m" * 40, "h" * 40, "e" * 40
EXPLANATORY = "Reword the introduction\n\nGate: explanatory\n"


class Decide(unittest.TestCase):
    """GitHub's API as a table, so each condition can be broken alone."""

    def setUp(self):
        self.run = {"id": 1, "head_sha": BASE, "event": "push",
                    "head_branch": "main", "conclusion": "success",
                    "html_url": "https://example/run/1",
                    "run_started_at": (NOW - timedelta(days=1)).isoformat()}
        self.jobs = [{"name": name, "conclusion": "success"} for name in LANES]
        self.total = None
        #  The commits from BASE to each tip, and how each tip relates to it.
        self.histories = {HEAD: [EXPLANATORY], MAIN: []}
        self.statuses = {HEAD: "ahead", MAIN: "identical"}
        self.keys = {BASE: "k", "HEAD": "k"}
        self.event_name = "pull_request"
        self.event = {"pull_request": {
            "author_association": "OWNER",
            "head": {"sha": HEAD, "repo": {"full_name": "JanHaan/Landin"}},
            "base": {"repo": {"full_name": "JanHaan/Landin"}}}}
        self.checked_out = (MERGE, [MAIN, HEAD])
        self.asked = []

    def api(self, path):
        self.asked.append(path)
        if path.startswith("actions/workflows/"):
            return {"workflow_runs": [self.run]}
        if path.startswith("actions/runs/"):
            total = len(self.jobs) if self.total is None else self.total
            return {"total_count": total, "jobs": self.jobs}
        for tip, messages in self.histories.items():
            if path == "compare/%s...%s" % (BASE, tip):
                commits = [{"sha": "%040d" % n, "commit": {"message": m}}
                           for n, m in enumerate(messages)]
                return {"status": self.statuses[tip],
                        "total_commits": len(commits), "commits": commits}
        raise AssertionError(path)

    def decide(self):
        return gate_inputs.decide(self.event_name, self.event, self.api,
                                  self.keys.get, self.checked_out, "gate.yml",
                                  LANES, NOW)[0]

    def test_a_declared_change_after_a_full_main_run_is_reused(self):
        self.assertTrue(self.decide())
        self.assertIn("actions/workflows/gate.yml/runs?branch=main&event=push"
                      "&status=success&per_page=30", self.asked)

    def test_a_push_to_main_is_trusted_by_having_happened(self):
        self.event_name = "push"
        self.event = {"ref": "refs/heads/main", "after": HEAD}
        self.checked_out = (HEAD, [BASE])
        self.assertTrue(self.decide())

    #  Review 1's first finding: a pull request could save the record its
    #  next run trusted.  The record is now a run, and only a push to main
    #  that ran and passed every lane is one.
    def test_a_pull_request_run_is_no_record(self):
        self.run["event"] = "pull_request"
        self.assertFalse(self.decide())

    def test_a_future_run_is_no_record(self):
        self.run["run_started_at"] = (NOW + timedelta(seconds=1)).isoformat()
        self.assertFalse(self.decide())

    def test_a_run_on_another_branch_is_no_record(self):
        self.run["head_branch"] = "topic"
        self.assertFalse(self.decide())

    def test_a_run_that_reused_is_no_record(self):
        for job in self.jobs:
            job["conclusion"] = "skipped"
        self.assertFalse(self.decide())

    def test_a_run_missing_one_lane_is_no_record(self):
        self.jobs = self.jobs[:1]
        self.assertFalse(self.decide())

    #  Review 2's second finding: one successful leg stood for its matrix.
    #  Each leg is now required by its exact name.
    def test_a_run_missing_one_matrix_leg_is_no_record(self):
        for leg in ("darwin-host (debug)", "darwin-host (release)"):
            with self.subTest(leg=leg):
                self.jobs = [{"name": name, "conclusion": "success"}
                             for name in LANES if name != leg]
                self.assertFalse(self.decide())

    def test_a_leg_is_not_its_matrix_prefix(self):
        self.jobs = [{"name": "compiler", "conclusion": "success"},
                     {"name": "darwin-host (debug, again)", "conclusion": "success"},
                     {"name": "darwin-host (release)", "conclusion": "success"}]
        self.assertFalse(self.decide())

    def test_a_truncated_job_listing_is_no_record(self):
        self.total = len(self.jobs) + 1
        self.assertFalse(self.decide())

    def test_a_listing_without_a_total_is_no_record(self):
        original = self.api

        def untotalled(path):
            answer = original(path)
            answer.pop("total_count", None)
            return answer
        self.api = untotalled
        self.assertFalse(self.decide())

    def test_a_job_named_twice_is_no_record(self):
        self.jobs.append({"name": "compiler", "conclusion": "success"})
        self.assertFalse(self.decide())

    def test_a_failed_matrix_leg_is_no_record(self):
        self.jobs[2]["conclusion"] = "failure"
        self.assertFalse(self.decide())

    def test_a_record_older_than_a_week_is_none(self):
        self.run["run_started_at"] = (NOW - timedelta(days=8)).isoformat()
        self.assertFalse(self.decide())

    #  Review 1's second finding: a semantic edit kept the key and was
    #  skipped.  Nothing reads the sentence; an edit nobody declared runs
    #  every lane, whatever it says.
    def test_an_undeclared_commit_runs_everything(self):
        self.histories[HEAD] = ["Make statements need terminators\n"]
        self.assertFalse(self.decide())

    def test_one_undeclared_commit_among_declared_ones_runs_everything(self):
        self.histories[HEAD] = [EXPLANATORY, "Target Cortex-M4 with 512 KB\n",
                                EXPLANATORY]
        self.assertFalse(self.decide())

    def test_the_declaration_is_a_line_of_its_own(self):
        for message in ("Gate: explanatory, mostly\n", "Say Gate: explanatory\n",
                        "x\n\ngate: Explanatory\n"):
            with self.subTest(message=message):
                self.histories[HEAD] = [message]
                self.assertFalse(self.decide())

    def test_a_comparison_longer_than_its_listing_runs_everything(self):
        original = self.api

        def truncated(path):
            answer = original(path)
            if path.startswith("compare/"):
                answer["total_commits"] += 1
            return answer
        self.api = truncated
        self.assertFalse(self.decide())

    def test_an_untrusted_author_cannot_declare(self):
        for association in ("CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "NONE"):
            with self.subTest(association=association):
                self.event["pull_request"]["author_association"] = association
                self.assertFalse(self.decide())
        self.assertEqual(self.asked, [])

    def test_a_branch_in_a_fork_is_never_reused(self):
        self.event["pull_request"]["head"]["repo"]["full_name"] = "someone/Landin"
        self.assertFalse(self.decide())
        self.assertEqual(self.asked, [])

    def test_other_events_are_never_reused(self):
        for name, event in (("workflow_dispatch", {}),
                            ("push", {"ref": "refs/heads/topic", "after": HEAD})):
            with self.subTest(name=name):
                self.event_name, self.event = name, event
                self.assertFalse(self.decide())

    #  Review 2's first finding: main moved past the run, by a semantic
    #  edit nobody declared, and the pull request's merge tree carries it.
    #  The head's history alone does not show it; the merge's first parent
    #  does.
    def test_an_undeclared_main_side_commit_runs_everything(self):
        self.histories[MAIN] = ["Make statements need terminators\n"]
        self.statuses[MAIN] = "ahead"
        self.assertFalse(self.decide())

    def test_declared_commits_on_both_sides_are_reused(self):
        self.histories[MAIN] = [EXPLANATORY]
        self.statuses[MAIN] = "ahead"
        self.assertTrue(self.decide())

    def test_a_tip_that_is_not_ahead_of_the_run_runs_everything(self):
        for status in ("behind", "diverged"):
            with self.subTest(status=status):
                self.statuses[MAIN] = status
                self.assertFalse(self.decide())

    def test_a_checkout_that_is_not_the_merge_runs_everything(self):
        for checked_out in ((HEAD, [BASE]), (MERGE, [MAIN, "x" * 40]),
                            (MERGE, [MAIN, HEAD, "x" * 40])):
            with self.subTest(checked_out=checked_out):
                self.checked_out = checked_out
                self.assertFalse(self.decide())

    def test_a_push_checkout_must_be_the_pushed_commit(self):
        self.event_name = "push"
        self.event = {"ref": "refs/heads/main", "after": HEAD}
        self.checked_out = (MERGE, [HEAD])
        self.assertFalse(self.decide())

    def test_more_than_the_four_documents_runs_everything(self):
        self.keys["HEAD"] = "other"
        self.assertFalse(self.decide())

    def test_an_error_says_reuse_false(self):
        environment = {"GITHUB_EVENT_PATH": "/nonexistent", "GITHUB_EVENT_NAME": "push"}
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/gate_inputs.py"), "reuse",
                 "gate.yml", "compiler"], cwd=directory, text=True,
                env=dict(os.environ, **environment), stdout=subprocess.PIPE,
                stderr=subprocess.PIPE)
        self.assertEqual((result.returncode, result.stdout), (0, "reuse=false\n"))


class Candidate(unittest.TestCase):
    def setUp(self):
        self.fixture = Decide()
        self.fixture.setUp()
        self.fixture.run["head_branch"] = "candidate"
        self.fixture.event_name = "push"
        self.fixture.event = {"ref": "refs/heads/main", "after": HEAD}
        self.fixture.checked_out = (HEAD, [BASE])
        # These keys represent complete trees, without document exclusions.
        self.fixture.keys = {"HEAD": "exact", BASE: "exact"}

    def decide(self):
        f = self.fixture
        return gate_inputs.decide_candidate(f.event_name, f.event, f.api,
                                            f.keys.get, f.checked_out,
                                            "gate.yml", LANES, NOW)[0]

    def test_full_branch_candidate_can_cover_main_promotion(self):
        self.assertTrue(self.decide())
        self.assertIn("actions/workflows/gate.yml/runs?event=push&status=success&per_page=30",
                      self.fixture.asked)

    def test_identical_tree_can_cover_a_trusted_pr_merge(self):
        f = self.fixture
        f.event_name = "pull_request"
        f.event = {"pull_request": {
            "author_association": "MEMBER",
            "head": {"sha": HEAD, "repo": {"full_name": "JanHaan/Landin"}},
            "base": {"repo": {"full_name": "JanHaan/Landin"}}}}
        f.checked_out = (MERGE, [MAIN, HEAD])
        self.assertTrue(self.decide())
        f.keys["HEAD"] = "changed merge tree"
        self.assertFalse(self.decide())
        f.event["pull_request"]["head"]["repo"]["full_name"] = "fork/Landin"
        f.asked.clear()
        self.assertFalse(self.decide())
        self.assertEqual(f.asked, [])

    def test_any_changed_tree_or_workflow_input_requires_a_full_run(self):
        self.fixture.keys[BASE] = "different"
        self.assertFalse(self.decide())
        self.assertFalse(any(p.startswith("actions/runs/") for p in self.fixture.asked))

    def test_reused_missing_failed_or_truncated_lanes_cannot_supply_a_pass(self):
        for failure in ("skipped", "failure", "cancelled"):
            with self.subTest(failure=failure):
                self.fixture.jobs[0]["conclusion"] = failure
                self.assertFalse(self.decide())
        self.fixture.jobs[0]["conclusion"] = "success"
        self.fixture.total = len(self.fixture.jobs) + 1
        self.assertFalse(self.decide())
        self.fixture.total = None
        self.fixture.jobs.pop()
        self.assertFalse(self.decide())

    def test_manual_tag_fork_event_and_wrong_checkout_do_not_reuse(self):
        f = self.fixture
        for name, event, checkout in (
                ("workflow_dispatch", {}, (HEAD, [BASE])),
                ("push", {"ref": "refs/tags/v1", "after": HEAD}, (HEAD, [BASE])),
                ("push", f.event, (MERGE, [HEAD]))):
            with self.subTest(event=name, checkout=checkout):
                f.event_name, f.event, f.checked_out = name, event, checkout
                f.asked.clear()
                self.assertFalse(self.decide())
                self.assertEqual(f.asked, [])

    def test_expired_future_and_non_push_records_are_rejected(self):
        for started in (NOW - timedelta(days=8), NOW + timedelta(seconds=1)):
            self.fixture.run["run_started_at"] = started.isoformat()
            self.assertFalse(self.decide())
        self.fixture.run["run_started_at"] = NOW.isoformat()
        self.fixture.run["event"] = "pull_request"
        self.assertFalse(self.decide())


def job(result, **outputs):
    return {"result": result, "outputs": outputs}


class Verdict(unittest.TestCase):
    ALWAYS = ("inputs", "documents", "scripts")

    def needs(self, reuse, lanes):
        return {"inputs": job("success", reuse=reuse),
                "documents": job("success"), "scripts": job("success"),
                "compiler": job(lanes), "cortex-m": job(lanes)}

    def test_every_lane_ran_and_passed(self):
        self.assertEqual(gate_inputs.verdict(self.needs("false", "success"), self.ALWAYS), [])

    def test_every_lane_skipped_for_a_reused_pass(self):
        self.assertEqual(gate_inputs.verdict(self.needs("true", "skipped"), self.ALWAYS), [])

    def test_a_skipped_lane_without_a_reuse_fails(self):
        self.assertTrue(gate_inputs.verdict(self.needs("false", "skipped"), self.ALWAYS))

    def test_a_failed_lane_fails(self):
        self.assertTrue(gate_inputs.verdict(self.needs("false", "failure"), self.ALWAYS))

    def test_a_lane_that_ran_under_a_reuse_fails(self):
        self.assertTrue(gate_inputs.verdict(self.needs("true", "success"), self.ALWAYS))

    def test_documents_and_scripts_are_never_excused(self):
        needs = self.needs("true", "skipped")
        needs["documents"] = job("skipped")
        self.assertTrue(gate_inputs.verdict(needs, self.ALWAYS))

    def test_a_failed_inputs_job_fails(self):
        needs = self.needs("true", "skipped")
        needs["inputs"]["result"] = "failure"
        self.assertTrue(gate_inputs.verdict(needs, self.ALWAYS))
        self.assertTrue(gate_inputs.verdict({}, self.ALWAYS))


#  Every tracked file that names one of the four documents or reads
#  Markdown by pattern, and why no lane gate_inputs lets skip runs it.  A
#  name is what this can see; a lane that walked the whole checkout would
#  read them without naming them, which is why the lanes were also run
#  with the four emptied and gave the same verdicts and bytes.
READERS = {
    "check.py": "the documents job",
    "scripts/tests/": "the scripts job",
    "docs/site/": "pages.yml and scripts/site.sh",
    "scripts/context_pack.py": "a developer tool; its test is in scripts/tests",
    "scripts/gate_inputs.py": "the inputs job",
    "flake.nix": "nix develop and nix build, not the gate",
    ".github/workflows/gate.yml": "a comment describing this policy",
    ".github/workflows/links.yml": "its own workflow",
    ".github/workflows/pages.yml": "its own publishing workflow",
    "scripts/links_inputs.py": "links.yml scope selection; controls always run",
    ".github/workflows/release.yml": "a v* tag",
    "lychee.toml": "links.yml",
    "highlight/pyproject.toml": "a comment naming ROADMAP.md",
    "highlight/textmate/package.json": "the extension's own README",
    "environments/cortex-m/validation.json": "names its own README",
    "environments/cortex-m/abi-validation.json": "names its own README",
    "environments/cortex-m/memory-validation.json": "names its own README",
    "environments/cortex-m/packed-validation.json": "names its own README",
}
MENTION = re.compile(r"(?<![\w./-])(?:README|ROADMAP|handoff|AGENTS)\.md"
                     r"|\*\*?\.md\b")


class Readers(unittest.TestCase):
    def test_no_lane_reads_the_four_documents(self):
        tracked = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True,
                                 stdout=subprocess.PIPE, text=True).stdout
        unexplained = []
        for name in tracked.split("\0"):
            path = ROOT / name
            if not name or name.endswith(".md") or not path.is_file():
                continue
            if any(name == known or (known.endswith("/") and name.startswith(known))
                   for known in READERS):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if MENTION.search(text):
                unexplained.append(name)
        self.assertEqual(unexplained, [],
                         "a lane gate_inputs.py may skip could read one of %s; "
                         "keep it out of the lane or take the file out of "
                         "CONTENT_FREE" % ", ".join(gate_inputs.CONTENT_FREE))


if __name__ == "__main__":
    unittest.main()
