#!/usr/bin/env python3
"""The gate reuses a pass only for a declared explanatory change.

scripts/gate_inputs.py leaves the content of four top-level documents out
of the key.  That is sound only while no skippable lane reads them, so the
last class here names every tracked file that mentions one, and a new one
is a decision rather than an accident.  Key holds the key to every other
difference.  Decide holds reuse to GitHub's record of a push run, of main
or of another branch, that ran every lane, never to anything a pull
request writes, and to a trusted `Gate: explanatory` on every commit
since, so a semantic edit nobody declared runs everything.  Workflow
holds the reuse list to every job the aggregate needs but the physical
ones, which are never reused, and every job's condition to the event's
scope.  Scope holds which events reach the boards.  Verdict holds the gate
to the shapes a reused pass, a boards-only run and a board-scope event may
have, and Bundles the provenance the rig checks before a board runs.
"""
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

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
        # Git's own refusal is the evidence; it is kept out of a passing
        # run's output rather than printed as if a control had failed.
        run = subprocess.run

        def quiet(*arguments, **options):
            return run(*arguments, **dict(options, stderr=subprocess.PIPE))
        with mock.patch.object(gate_inputs.subprocess, "run", quiet), \
                self.assertRaises(subprocess.CalledProcessError) as raised:
            gate_inputs.key("0" * 40, self.root)
        self.assertIn(b"not a tree object", raised.exception.stderr)


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
            #  Only every attempt's listing is read, a page at a time: the
            #  latest filter once answered three of a run's 47 jobs.
            self.assertIn("filter=all", path)
            total = len(self.jobs) if self.total is None else self.total
            page = int(path.rsplit("page=", 1)[1])
            return {"total_count": total,
                    "jobs": self.jobs[(page - 1) * 100:page * 100]}
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
        self.assertIn("actions/workflows/gate.yml/runs?event=push"
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

    #  A documents-only commit that closes an item after its branch's
    #  full gate takes that run as its base, as it would main's.
    def test_a_full_run_of_another_branch_is_a_record(self):
        self.run["head_branch"] = "topic"
        self.assertTrue(self.decide())

    def test_a_run_of_no_branch_is_no_record(self):
        self.run["head_branch"] = None
        self.assertFalse(self.decide())

    def test_a_branch_push_may_use_the_exception(self):
        self.run["head_branch"] = "topic"
        self.event_name = "push"
        self.event = {"ref": "refs/heads/topic", "after": HEAD}
        self.checked_out = (HEAD, [BASE])
        self.assertTrue(self.decide())
        #  Ancestry and the declarations hold it as they hold main.
        self.statuses[HEAD] = "diverged"
        self.assertFalse(self.decide())
        self.statuses[HEAD] = "ahead"
        self.histories[HEAD] = [EXPLANATORY, "Make statements need terminators\n"]
        self.assertFalse(self.decide())
        #  And a weakened workflow only by a tree that still carries it.
        self.histories[HEAD] = [EXPLANATORY]
        self.keys["HEAD"] = "a tree whose workflow differs"
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

    def test_a_listing_longer_than_a_page_is_read_whole(self):
        self.jobs += [{"name": "lane %d" % n, "conclusion": "success"}
                      for n in range(150)]
        self.assertTrue(self.decide())
        self.assertTrue(any(path.endswith("page=2") for path in self.asked))

    def test_a_job_counts_by_its_latest_attempt(self):
        #  A leg that failed and passed on its rerun is a pass, and one
        #  that passed and then failed is not.
        self.jobs = ([{"name": name, "conclusion": "failure", "run_attempt": 1}
                      for name in LANES]
                     + [{"name": name, "conclusion": "success", "run_attempt": 2}
                        for name in LANES])
        self.assertTrue(self.decide())
        for job in self.jobs:
            job["conclusion"] = ("success" if job["run_attempt"] == 1
                                 else "failure")
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
                            ("push", {"ref": "refs/tags/v1", "after": HEAD})):
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


def workflow_jobs(workflow):
    """Read job boundaries, not general YAML; unfamiliar shapes fail closed."""
    sections = re.split(r"^jobs:[ \t]*$", workflow, flags=re.M)
    if len(sections) != 2:
        raise ValueError("expected one top-level jobs mapping")
    jobs, current = {}, None
    for line in sections[1].splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"  ([\w-]+):", line)
        if match:
            current = match[1]
            if current in jobs:
                raise ValueError("duplicate job: " + current)
            jobs[current] = []
        elif current and line.startswith("    "):
            jobs[current].append(line)
        else:
            raise ValueError("unsupported jobs mapping line: " + line)
    return jobs


def job_field(body, field):
    matches = [line.split(":", 1)[1].strip() for line in body
               if line.startswith("    " + field + ":")]
    if len(matches) > 1:
        raise ValueError("duplicate job field: " + field)
    return matches[0] if matches else None


def matrix_scalar(value):
    value = value.strip()
    # Deliberately exclude YAML aliases, tags, nulls and expressions. These
    # values reach job names, so accepting an unknown conversion is unsafe.
    if re.fullmatch(r"[\w./,-]+", value) and value not in ("null", "true", "false"):
        return value
    if re.fullmatch(r"'[^'\\]*'|\"[^\"\\]*\"", value):
        return value[1:-1]
    raise ValueError("unsupported matrix scalar: " + value)


def matrix_rows(body):
    starts = [n for n, line in enumerate(body) if line == "      matrix:"]
    if not starts:
        if job_field(body, "strategy") is not None:
            raise ValueError("strategy has no supported matrix")
        return None
    if len(starts) != 1 or job_field(body, "strategy") != "":
        raise ValueError("unsupported matrix declaration")
    lines = []
    for line in body[starts[0] + 1:]:
        if len(line) - len(line.lstrip()) <= 6:
            break
        lines.append(line)
    axes, included, row = {}, [], None
    for line in lines:
        axis = re.fullmatch(r"        ([\w-]+): \[(.*)\]", line)
        if axis:
            if included or axis[1] in axes or axis[1] in ("include", "exclude"):
                raise ValueError("mixed or duplicate matrix axes")
            axes[axis[1]] = [matrix_scalar(v) for v in axis[2].split(",")]
        elif line == "        include:":
            if axes or included:
                raise ValueError("mixed or repeated matrix include")
            included.append(None)  # Distinguish an empty include from no matrix.
        elif included and line.startswith("          - {") and line.endswith("}"):
            row = {}
            for pair in line[len("          - {"):-1].split(","):
                key, separator, value = pair.strip().partition(":")
                if not separator or not re.fullmatch(r"[\w-]+", key) or key in row:
                    raise ValueError("unsupported inline matrix row: " + line)
                row[key] = matrix_scalar(value)
            included.append(row)
        elif included:
            match = re.fullmatch(r"(          - |            )([\w-]+): (.+)", line)
            if not match:
                raise ValueError("unsupported matrix include: " + line)
            if match[1] == "          - ":
                row = {}
                included.append(row)
            if row is None or match[2] in row:
                raise ValueError("missing or duplicate matrix row field")
            row[match[2]] = matrix_scalar(match[3])
        else:
            raise ValueError("unsupported matrix line: " + line)
    if included:
        if len(included) == 1:
            raise ValueError("empty matrix include")
        return included[1:]
    if not axes or any(not values for values in axes.values()):
        raise ValueError("empty matrix")
    return [dict(zip(axes, values)) for values in itertools.product(*axes.values())]


def rendered_job_name(name, row):
    def expression(match):
        text = match[1].strip()
        variable = re.fullmatch(r"matrix\.([\w-]+)", text)
        if variable:
            if variable[1] not in row:
                raise ValueError("missing matrix name field: " + variable[1])
            return row[variable[1]]
        # gate.yml's FreeBSD suffix: absent part omits the entire suffix.
        if text == "matrix.part && format('-{0}', matrix.part) || ''":
            part = row.get("part", "")
            if part and not re.fullmatch(r"[1-9][0-9]*", part):
                raise ValueError("unsupported conditional matrix part: " + part)
            return "-" + part if part else ""
        raise ValueError("unsupported job-name expression: " + text)

    result = re.sub(r"\$\{\{(.*?)\}\}", expression, name)
    if "${" in result or not result:
        raise ValueError("unsupported job name: " + name)
    return result


def job_needs(body):
    value = job_field(body, "needs")
    if value is None:
        return []
    if value.startswith("["):
        # The aggregate's inline list wraps across source lines.
        start = next(n for n, line in enumerate(body) if line.startswith("    needs:"))
        text = body[start].split(":", 1)[1].strip()
        for line in body[start + 1:]:
            if text.endswith("]"):
                break
            if not line.startswith("      "):
                raise ValueError("unsupported multiline needs")
            text += " " + line.strip()
        if not text.endswith("]"):
            raise ValueError("unterminated needs list")
        values = text[1:-1].split(",")
    else:
        values = [value]
    needs = [name.strip() for name in values]
    if not needs or any(not re.fullmatch(r"[\w-]+", name) for name in needs):
        raise ValueError("unsupported needs list: " + str(needs))
    if len(set(needs)) != len(needs):
        raise ValueError("duplicate needed job")
    return needs


def required_workflow_names(workflow, called, physical=()):
    """Every job name the aggregate needs; with PHYSICAL, also those jobs' names apart."""
    jobs = workflow_jobs(workflow)
    names, physical_names = [], []

    def expand(identity, body, prefix="", stack=()):
        name = job_field(body, "name")
        rows = matrix_rows(body)
        if rows is not None and name is None:
            raise ValueError("matrix jobs must explicitly name their legs: " + identity)
        uses = job_field(body, "uses")
        for row in rows if rows is not None else [{}]:
            rendered = prefix + rendered_job_name(name if name is not None else identity, row)
            if uses is None:
                names.append(rendered)
                if not prefix and identity in physical:
                    physical_names.append(rendered)
            else:
                if not re.fullmatch(r"\./\.github/workflows/[\w-]+\.yml", uses):
                    raise ValueError("unsupported called workflow: " + uses)
                path = uses[2:]
                if path not in called or path in stack:
                    raise ValueError("missing or cyclic called workflow: " + path)
                for child, source in workflow_jobs(called[path]).items():
                    expand(child, source, rendered + " / ", stack + (path,))

    # Only aggregate dependencies count. Suspended physical jobs outside
    # this closure must not become mandatory reuse evidence.
    needed, seen = ["gate"], set()
    while needed:
        identity = needed.pop()
        if identity in seen or identity == "inputs":
            continue
        seen.add(identity)
        if identity not in jobs:
            raise ValueError("aggregate needs an absent job: " + identity)
        body = jobs[identity]
        expand(identity, body)
        needed.extend(job_needs(body))
    if len(set(names)) != len(names):
        raise ValueError("matrix legs have duplicate job names")
    if physical:
        return set(names), set(physical_names)
    return set(names)


def workflow_reuse_gaps(workflow, called, physical=gate_inputs.PHYSICAL):
    """(missing, extra): reuse names the aggregate needs and the list lacks,
    and names the list has that the aggregate does not need or that are
    physical, which are never reused."""
    inputs = "\n".join(workflow_jobs(workflow)["inputs"])
    commands = re.findall(r"gate_inputs\.py reuse gate\.yml(.*?)>>", inputs, re.S)
    if len(commands) != 1:
        raise ValueError("expected one literal gate reuse command")
    required = shlex.split(commands[0].replace("\\\n", " "))
    if len(set(required)) != len(required) or any("${" in name for name in required):
        raise ValueError("reuse names must be unique literals")
    expected, never = required_workflow_names(workflow, called, physical or ("",))
    expected -= never
    return expected - set(required), set(required) - expected


class Workflow(unittest.TestCase):
    """Hold every required matrix leg to the literal reuse inventory."""

    def test_every_needed_job_is_required_for_reuse(self):
        directory = ROOT / ".github/workflows"
        called = {".github/workflows/" + path.name: path.read_text()
                  for path in directory.glob("*.yml")}
        self.assertEqual(workflow_reuse_gaps((directory / "gate.yml").read_text(), called),
                         (set(), set()))

    def test_each_actual_reuse_name_is_independently_required(self):
        directory = ROOT / ".github/workflows"
        source = (directory / "gate.yml").read_text()
        called = {".github/workflows/" + path.name: path.read_text()
                  for path in directory.glob("*.yml")}
        commands = list(re.finditer(r"gate_inputs\.py reuse gate\.yml(.*?)>>", source, re.S))
        self.assertEqual(len(commands), 1)
        command = commands[0]
        arguments = shlex.split(command[1].replace("\\\n", " "))
        for name in arguments:
            with self.subTest(name=name):
                changed = (source[:command.start(1)] + " "
                           + shlex.join([other for other in arguments if other != name])
                           + " " + source[command.end(1):])
                self.assertEqual(workflow_reuse_gaps(changed, called), ({name}, set()))

    @staticmethod
    def sample(names="compiler-1 compiler-2"):
        return """jobs:
  inputs:
    steps:
      - run: |
          python3 scripts/gate_inputs.py reuse gate.yml \
            %s gate >> "$GITHUB_OUTPUT"
  compiler:
    name: compiler-${{ matrix.shard }}
    strategy:
      matrix:
        shard: [1, 2]
  suspended:
    if: false
    strategy:
      matrix: ${{ fromJSON(inputs.dynamic) }}
  gate:
    needs: [inputs, compiler]
""" % names

    def test_removing_one_reuse_leg_cannot_hide_behind_the_other(self):
        self.assertEqual(workflow_reuse_gaps(self.sample("compiler-1"), {}),
                         ({"compiler-2"}, set()))

    def test_adding_a_matrix_leg_requires_its_exact_name(self):
        source = self.sample().replace("shard: [1, 2]", "shard: [1, 2, 3]")
        self.assertEqual(workflow_reuse_gaps(source, {}), ({"compiler-3"}, set()))

    def test_removing_a_matrix_leg_or_changing_its_name_exposes_stale_reuse(self):
        source = self.sample().replace("shard: [1, 2]", "shard: [1]")
        self.assertEqual(workflow_reuse_gaps(source, {}), (set(), {"compiler-2"}))
        source = self.sample().replace("name: compiler-", "name: renamed-")
        self.assertEqual(workflow_reuse_gaps(source, {}),
                         ({"renamed-1", "renamed-2"}, {"compiler-1", "compiler-2"}))

    def test_ordinary_and_transitively_needed_jobs_count(self):
        source = self.sample().replace("  compiler:\n", "  build:\n    runs-on: ubuntu-24.04\n  compiler:\n    needs: build\n")
        self.assertEqual(workflow_reuse_gaps(source, {}), ({"build"}, set()))

    def test_unknown_matrix_shapes_and_name_expressions_fail_closed(self):
        for source in (
                self.sample().replace("shard: [1, 2]", "shard: ${{ fromJSON(inputs.parts) }}"),
                self.sample().replace("matrix.shard", "matrix.unknown"),
                self.sample().replace("matrix.shard", "format('leg-{0}', matrix.shard)"),
                self.sample().replace("        shard: [1, 2]", "        exclude: [{shard: 2}]"),
                self.sample().replace("    name: compiler-${{ matrix.shard }}\n", ""),
                self.sample().replace("shard: [1, 2]", "shard: [1, 1]")):
            with self.subTest(source=source), self.assertRaises(ValueError):
                workflow_reuse_gaps(source, {})

    def test_cartesian_axes_enumerate_every_combination(self):
        source = self.sample().replace("name: compiler-${{ matrix.shard }}",
            "name: compiler-${{ matrix.shard }}-${{ matrix.mode }}").replace(
            "        shard: [1, 2]", "        shard: [1, 2]\n        mode: [debug, release]")
        missing, extra = workflow_reuse_gaps(source, {})
        self.assertEqual(missing, {"compiler-1-debug", "compiler-1-release",
                                   "compiler-2-debug", "compiler-2-release"})
        self.assertEqual(extra, {"compiler-1", "compiler-2"})

    def test_inline_include_and_optional_freebsd_part_are_exact(self):
        source = self.sample("'freebsd-amd64-runtime' 'freebsd-arm64-runtime-1'").replace(
            "name: compiler-${{ matrix.shard }}",
            "name: freebsd-${{ matrix.arch }}-${{ matrix.kind }}"
            "${{ matrix.part && format('-{0}', matrix.part) || '' }}").replace(
            "        shard: [1, 2]", """        include:
          - {arch: amd64, kind: runtime}
          - {arch: arm64, kind: runtime, part: 1}""")
        self.assertEqual(workflow_reuse_gaps(source, {}), (set(), set()))
        source = source.replace("part: 1}", "part: 2}")
        self.assertEqual(workflow_reuse_gaps(source, {}),
                         ({"freebsd-arm64-runtime-2"}, {"freebsd-arm64-runtime-1"}))

    def test_called_workflow_names_every_manifest_leg_and_aggregate(self):
        source = self.sample("'compiler / manifest (linux 1)' 'compiler / agree'").replace(
            "    name: compiler-${{ matrix.shard }}\n    strategy:\n      matrix:\n        shard: [1, 2]",
            "    uses: ./.github/workflows/determinism.yml")
        path = ".github/workflows/determinism.yml"
        called = {path: """jobs:
  manifest:
    name: manifest (${{ matrix.platform }} ${{ matrix.part }})
    strategy:
      matrix:
        include:
          - platform: linux
            part: 1
  agree:
    needs: manifest
"""}
        self.assertEqual(workflow_reuse_gaps(source, called), (set(), set()))
        called[path] = called[path].replace("            part: 1", "            part: 1\n          - platform: linux\n            part: 2")
        self.assertEqual(workflow_reuse_gaps(source, called),
                         ({"compiler / manifest (linux 2)"}, set()))
        with self.assertRaises(ValueError):
            workflow_reuse_gaps(source, {})


GATE = ROOT / ".github/workflows/gate.yml"
SOFTWARE_IF = ("needs.inputs.outputs.software == 'true'",
               "needs.inputs.outputs.reuse != 'true'")
BOARDS_IF = "needs.inputs.outputs.boards == 'true'"
ALWAYS_RUN = ("documents", "scripts")


def gate_closure(workflow):
    """The aggregate's needed job identities, `inputs` and `gate` among them."""
    jobs = workflow_jobs(workflow)
    needed, seen = ["gate"], set()
    while needed:
        identity = needed.pop()
        if identity not in seen:
            seen.add(identity)
            needed.extend(job_needs(jobs[identity]))
    return jobs, seen


def scope_gaps(workflow):
    """Jobs whose condition does not follow the event's scope, with why."""
    jobs, needed = gate_closure(workflow)
    gaps = []
    for identity in sorted(needed):
        body = jobs[identity]
        condition = job_field(body, "if") or ""
        text = "\n".join(body)
        if identity in ("inputs", "gate") + ALWAYS_RUN:
            wanted = "always()" if identity == "gate" else ""
            if condition != wanted:
                gaps.append("%s: if is %r, not %r" % (identity, condition, wanted))
        elif identity in gate_inputs.PHYSICAL:
            if BOARDS_IF not in condition or "reuse" in condition or "software" in condition:
                gaps.append("%s: a physical job runs by the boards scope alone" % identity)
            if "secrets." in text:
                gaps.append("%s: a physical job reads a secret" % identity)
        elif not all(part in condition for part in SOFTWARE_IF):
            gaps.append("%s: a software lane must skip for a reused pass and a "
                        "boards-only event" % identity)
    for identity in gate_inputs.PHYSICAL:
        if identity not in needed:
            gaps.append("%s: the aggregate does not need a physical job" % identity)
    for identity, body in jobs.items():
        on_rig = any("landin-rig" in line for line in body)
        if on_rig and (identity not in gate_inputs.PHYSICAL
                       or job_field(body, "runs-on") != "[landin-rig]"):
            gaps.append("%s: only a physical job runs on the rig" % identity)
    return gaps


class Physical(unittest.TestCase):
    """Hold the physical jobs to their own category: never reused, by scope."""

    def setUp(self):
        self.source = GATE.read_text()

    def test_every_job_follows_the_events_scope(self):
        self.assertEqual(scope_gaps(self.source), [])

    def test_a_software_lane_without_the_scope_is_refused(self):
        source = self.source.replace(
            "  scaling:\n    needs: [inputs, linux-release-build]\n"
            "    if: needs.inputs.outputs.software == 'true' && needs.inputs.outputs.reuse != 'true'\n",
            "  scaling:\n    needs: [inputs, linux-release-build]\n"
            "    if: needs.inputs.outputs.reuse != 'true'\n")
        self.assertNotEqual(source, self.source)
        self.assertEqual(scope_gaps(source), [
            "scaling: a software lane must skip for a reused pass and a boards-only event"])

    def test_a_board_job_skipped_by_reuse_is_refused(self):
        source = self.source.replace(
            "    if: needs.inputs.outputs.boards == 'true'\n    runs-on: ubuntu-24.04\n",
            "    if: needs.inputs.outputs.boards == 'true' && needs.inputs.outputs.reuse != 'true'\n"
            "    runs-on: ubuntu-24.04\n")
        self.assertNotEqual(source, self.source)
        self.assertEqual(scope_gaps(source),
                         ["board-bundles: a physical job runs by the boards scope alone"])

    def test_a_secret_on_the_rig_is_refused(self):
        source = self.source.replace(
            "          PORT: ${{ matrix.port }}\n          MANIFEST:",
            "          PORT: ${{ matrix.port }}\n          TOKEN: ${{ secrets.RIG }}\n          MANIFEST:")
        self.assertNotEqual(source, self.source)
        self.assertEqual(scope_gaps(source), ["board: a physical job reads a secret"])

    def test_the_rig_runs_physical_jobs_alone(self):
        source = self.source.replace("  scaling:\n    needs: [inputs, linux-release-build]\n",
                                     "  scaling:\n    needs: [inputs, linux-release-build]\n"
                                     "    runs-on: [landin-rig]\n", 1)
        self.assertIn("scaling: only a physical job runs on the rig", scope_gaps(source))

    def test_the_physical_names_are_every_board_leg_and_never_in_the_reuse_list(self):
        called = {".github/workflows/" + path.name: path.read_text()
                  for path in GATE.parent.glob("*.yml")}
        _, never = required_workflow_names(self.source, called, gate_inputs.PHYSICAL)
        self.assertEqual(never, {"board-bundles"} | {"board-" + port
                                                     for port in gate_inputs.BOARD_PORTS})
        inputs = "\n".join(workflow_jobs(self.source)["inputs"])
        command = re.search(r"gate_inputs\.py reuse gate\.yml(.*?)>>", inputs, re.S)
        for name in sorted(never):
            with self.subTest(name=name):
                changed = self.source.replace(command[1], " " + name + command[1], 1)
                self.assertEqual(workflow_reuse_gaps(changed, called), (set(), {name}))

    def test_the_board_matrix_is_every_port_once(self):
        rows = matrix_rows(workflow_jobs(self.source)["board"])
        self.assertEqual(tuple(row["port"] for row in rows), gate_inputs.BOARD_PORTS)
        self.assertEqual({row["port"]: row["timeout"] for row in rows if row["timeout"] != "50"},
                         {"pico2": "70"})

    def test_the_board_legs_need_no_host_tool_the_rig_runner_lacks(self):
        # The rig's runner carries git, python3, coreutils, findutils, sed and
        # the board tools; a missing diffutils once made a leg's file-list
        # check report a mismatch for a command it could not find.
        board = "\n".join(workflow_jobs(self.source)["board"])
        for tool in ("cmp", "diff", "jq", "curl", "wget"):
            with self.subTest(tool=tool):
                self.assertIsNone(re.search(r"(^|[\s|;(!])%s\s" % tool, board), tool)

    def test_a_busy_rig_ends_in_its_own_outcome_inside_every_timeout(self):
        # A lock wait the job's timeout cuts short would be a killed job,
        # not the board gate's rig-busy outcome; exec lets the runner's
        # cancel signal reach the board gate rather than its shell.
        board = "\n".join(workflow_jobs(self.source)["board"])
        step = re.search(r"exec python3 environments/boards/gate\.py .*?--lock-wait=(\d+)", board, re.S)
        self.assertIsNotNone(step, "the board step must exec gate.py with an explicit --lock-wait")
        for row in matrix_rows(workflow_jobs(self.source)["board"]):
            with self.subTest(port=row["port"]):
                self.assertLessEqual(int(step[1]) + 20 * 60, int(row["timeout"]) * 60)

    def test_the_aggregate_keeps_documents_and_scripts_always(self):
        gate = "\n".join(workflow_jobs(self.source)["gate"])
        self.assertIn("verdict", gate)
        self.assertIn("--always documents scripts", gate)

    def test_the_events_and_their_concurrency(self):
        head = self.source.split("\njobs:\n", 1)[0]
        self.assertIn("    - cron: '0 4 * * 1'", head)
        self.assertIn("        options: [full, boards]\n        default: full", head)
        self.assertIn("cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}", head)
        self.assertIn("format('main-{0}', github.run_id)", head)


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


PASSED = {port: "passed" for port in gate_inputs.BOARD_PORTS}


class BoardVerdict(unittest.TestCase):
    """The verdict on each event's scope, its board jobs and their outcomes."""
    ALWAYS = ("inputs", "documents", "scripts")
    MAIN = gate_inputs.scope("push", "refs/heads/main", "JanHaan/Landin", {})
    BRANCH = gate_inputs.scope("push", "refs/heads/topic", "JanHaan/Landin", {})
    BOARDS = gate_inputs.scope("workflow_dispatch", "refs/heads/topic", "JanHaan/Landin",
                               {"inputs": {"scope": "boards"}})
    SCHEDULE = gate_inputs.scope("schedule", "refs/heads/main", "JanHaan/Landin", {})

    def needs(self, scope, lanes, boards, reuse="false"):
        outputs = {"reuse": reuse, "software": gate_inputs.flag(scope["software"]),
                   "boards": gate_inputs.flag(scope["boards"])}
        return {"inputs": {"result": "success", "outputs": outputs},
                "documents": job("success"), "scripts": job("success"),
                "compiler": job(lanes), "cortex-m": job(lanes),
                "board-bundles": job(boards), "board": job(boards)}

    def verdict(self, scope, lanes, boards, reuse="false", evidence=PASSED):
        return gate_inputs.verdict(self.needs(scope, lanes, boards, reuse), self.ALWAYS,
                                   scope, evidence)

    def test_a_main_push_with_every_board_passed(self):
        self.assertEqual(self.verdict(self.MAIN, "success", "success"), [])

    def test_a_main_push_whose_boards_did_not_pass_fails(self):
        for result in ("failure", "skipped", "cancelled"):
            with self.subTest(result=result):
                problems = self.verdict(self.MAIN, "success", result)
                self.assertTrue(problems)
                self.assertTrue(all("physical evidence missing is not a pass" in problem
                                    for problem in problems), problems)

    def test_a_main_push_with_one_leg_not_passed_fails(self):
        for label in ("rig-busy", "needs-setup: power-only port", "no outcome"):
            with self.subTest(label=label):
                evidence = dict(PASSED, pico2=label)
                self.assertEqual(self.verdict(self.MAIN, "success", "success", evidence=evidence),
                                 ["board-pico2: %s: physical evidence missing is not a pass"
                                  % label])

    def test_a_main_push_reusing_software_still_needs_fresh_boards(self):
        self.assertEqual(self.verdict(self.MAIN, "skipped", "success", reuse="true"), [])
        self.assertTrue(self.verdict(self.MAIN, "skipped", "skipped", reuse="true"))

    def test_a_branch_push_skips_the_boards(self):
        self.assertEqual(self.verdict(self.BRANCH, "success", "skipped", evidence={}), [])
        self.assertEqual(self.verdict(self.BRANCH, "skipped", "skipped", reuse="true",
                                      evidence={}), [])

    def test_boards_that_ran_for_a_branch_push_fail(self):
        problems = self.verdict(self.BRANCH, "success", "success", evidence={})
        self.assertEqual(problems, [
            "board is success, not skipped: a board job ran for an event outside board scope",
            "board-bundles is success, not skipped: a board job ran for an event outside board scope"])

    def test_a_boards_only_dispatch_runs_no_software_lane(self):
        self.assertEqual(self.verdict(self.BOARDS, "skipped", "success"), [])
        self.assertTrue(self.verdict(self.BOARDS, "success", "success"))
        self.assertTrue(self.verdict(self.BOARDS, "skipped", "failure"))
        needs = self.needs(self.BOARDS, "skipped", "success")
        needs["scripts"] = job("skipped")
        self.assertTrue(gate_inputs.verdict(needs, self.ALWAYS, self.BOARDS, PASSED))

    def test_a_full_dispatch_runs_both(self):
        full = gate_inputs.scope("workflow_dispatch", "refs/heads/topic", "JanHaan/Landin",
                                 {"inputs": {"scope": "full"}})
        self.assertEqual(self.verdict(full, "success", "success"), [])
        self.assertTrue(self.verdict(full, "skipped", "success"))

    def test_the_schedule_is_boards_only(self):
        self.assertEqual(self.verdict(self.SCHEDULE, "skipped", "success"), [])
        self.assertTrue(self.verdict(self.SCHEDULE, "success", "success"))
        self.assertTrue(self.verdict(self.SCHEDULE, "skipped", "cancelled"))

    def test_inputs_must_agree_with_the_event(self):
        needs = self.needs(self.BRANCH, "success", "skipped")
        self.assertEqual(gate_inputs.verdict(needs, self.ALWAYS, self.MAIN, PASSED)[0],
                         "inputs says boards=false, but this event's scope is boards=true")

    def test_a_boards_only_run_in_a_fork_has_nothing_to_pass(self):
        fork = gate_inputs.scope("schedule", "refs/heads/main", "someone/Landin", {})
        self.assertTrue(self.verdict(fork, "skipped", "skipped", evidence={}))

    def test_the_summary_names_the_scope_and_every_leg(self):
        needs = self.needs(self.BOARDS, "skipped", "success")
        text = gate_inputs.report(needs, [], self.BOARDS, dict(PASSED, esp32="rig-busy"))
        self.assertIn("boards only: no software lanes", text)
        self.assertIn("board-esp32: rig-busy", text)
        self.assertIn("board-rp2040: passed", text)
        text = gate_inputs.report(self.needs(self.BRANCH, "success", "skipped"), [],
                                  self.BRANCH, None)
        self.assertIn("physical boards: not run for this event", text)

    def test_the_command_writes_the_summary_and_judges_the_event(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        event = directory / "event.json"
        event.write_text('{"inputs": {"scope": "boards"}}')
        summary = directory / "summary.md"
        needs = self.needs(self.BOARDS, "skipped", "success")
        environment = dict(os.environ, NEEDS=json.dumps(needs), GITHUB_EVENT_PATH=str(event),
                           GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/heads/topic",
                           GITHUB_REPOSITORY="JanHaan/Landin", GITHUB_STEP_SUMMARY=str(summary))
        evidence = directory / "evidence"
        for port in gate_inputs.BOARD_PORTS:
            leg = evidence / ("board-evidence-" + port) / port
            (leg / "evidence").mkdir(parents=True)
            (leg / "transfer.json").write_text("{}")
            (leg / "evidence/outcome.json").write_text('{"outcome": "passed"}')
        command = [sys.executable, str(ROOT / "scripts/gate_inputs.py"), "verdict",
                   "--evidence", str(evidence), "--always", "documents", "scripts"]
        done = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("boards only: no software lanes", summary.read_text())
        (evidence / "board-evidence-esp32/esp32/evidence/outcome.json").write_text(
            '{"outcome": "rig-busy"}')
        done = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertEqual(done.returncode, 1)
        self.assertIn("board-esp32: rig-busy: physical evidence missing is not a pass",
                      done.stderr)


class Scope(unittest.TestCase):
    def scope(self, event_name, ref="refs/heads/main", repository="JanHaan/Landin", event=None):
        found = gate_inputs.scope(event_name, ref, repository, event or {})
        return found["software"], found["boards"]

    def test_main_pushes_run_both(self):
        self.assertEqual(self.scope("push"), (True, True))

    def test_branches_tags_and_pull_requests_run_software_only(self):
        self.assertEqual(self.scope("push", "refs/heads/topic"), (True, False))
        self.assertEqual(self.scope("push", "refs/tags/v1"), (True, False))
        self.assertEqual(self.scope("pull_request", "refs/pull/7/merge"), (True, False))

    def test_dispatch_runs_boards_with_or_without_software(self):
        self.assertEqual(self.scope("workflow_dispatch", "refs/heads/topic"), (True, True))
        self.assertEqual(self.scope("workflow_dispatch", "refs/heads/topic",
                                    event={"inputs": {"scope": "full"}}), (True, True))
        self.assertEqual(self.scope("workflow_dispatch", "refs/heads/topic",
                                    event={"inputs": {"scope": "boards"}}), (False, True))

    def test_the_schedule_is_boards_only(self):
        self.assertEqual(self.scope("schedule"), (False, True))

    def test_a_fork_never_reaches_the_boards(self):
        self.assertEqual(self.scope("push", repository="someone/Landin"), (True, False))
        self.assertEqual(self.scope("workflow_dispatch", repository="someone/Landin"),
                         (True, False))

    def test_dispatch_and_schedule_never_reuse(self):
        for event_name in ("workflow_dispatch", "schedule"):
            with self.subTest(event_name=event_name):
                self.assertIsNone(gate_inputs.tips_of(event_name, {}, ("a", []))[0])


class Outcomes(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)

    def leg(self, base, port, outcome=None):
        leg = base / port
        leg.mkdir(parents=True)
        (leg / "transfer.json").write_text("{}")
        if outcome is not None:
            (leg / "evidence").mkdir()
            (leg / "evidence/outcome.json").write_text(outcome)

    def test_each_port_is_read_from_its_own_artifact(self):
        self.leg(self.root / "board-evidence-rp2040", "rp2040", '{"outcome": "passed"}')
        self.leg(self.root / "board-evidence-pico2", "pico2", '{"outcome": "needs-setup"}')
        self.leg(self.root / "board-evidence-esp32", "esp32")
        self.leg(self.root / "board-evidence-esp32s3", "esp32s3", "not json")
        found = gate_inputs.outcomes(self.root)
        self.assertEqual(found["rp2040"], "passed")
        self.assertEqual(found["pico2"], "needs-setup")
        self.assertTrue(found["esp32"].startswith("no outcome"))
        self.assertTrue(found["esp32s3"].startswith("no outcome"))
        self.assertTrue(found["stm32h753"].startswith("no evidence"))

    def test_a_single_artifact_downloads_without_its_directory(self):
        self.leg(self.root, "esp32c3", '{"outcome": "passed"}')
        self.assertEqual(gate_inputs.outcomes(self.root)["esp32c3"], "passed")

    def test_two_evidence_directories_for_one_port_are_ambiguous(self):
        self.leg(self.root, "esp32c3", '{"outcome": "passed"}')
        self.leg(self.root / "board-evidence-esp32c3", "esp32c3", '{"outcome": "passed"}')
        self.assertTrue(gate_inputs.outcomes(self.root)["esp32c3"].startswith("ambiguous"))

    def test_an_absent_directory_has_no_evidence_for_any_port(self):
        found = gate_inputs.outcomes(self.root / "absent")
        self.assertEqual(set(found), set(gate_inputs.BOARD_PORTS))
        self.assertTrue(all(label.startswith("no evidence") for label in found.values()))


class Bundles(unittest.TestCase):
    """The provenance and file list the rig checks before a board runs."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        git(self.checkout, "init", "-q")
        (self.checkout / "a").write_text("a\n")
        git(self.checkout, "add", "a")
        git(self.checkout, "commit", "-q", "-m", "a")
        self.commit = git(self.checkout, "rev-parse", "HEAD")
        self.refine = self.root / "refine"
        self.refine.write_bytes(b"compiler")
        self.compiler = gate_inputs.sha256_file(self.refine)
        self.bundles = self.root / "bundles"
        rows = []
        for board, mode in (("rp2040", "boot"), ("rp2040", "ram"), ("esp32", "boot")):
            directory = self.bundles / board / mode
            directory.mkdir(parents=True)
            (directory / "board.elf").write_bytes(board.encode() + mode.encode())
            self.manifest(board, mode, "source", self.compiler)
            rows.append({"board": board, "mode": mode, "status": "matches",
                         "differences": [], "bundle": str(directory)})
        self.summary(rows)
        self.environ = {"GITHUB_SHA": self.commit, "GITHUB_RUN_ID": "41",
                        "GITHUB_RUN_ATTEMPT": "1", "GITHUB_EVENT_NAME": "push",
                        "GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "JanHaan/Landin"}

    def manifest(self, board, mode, source, compiler):
        (self.bundles / board / mode / "bundle.json").write_text(json.dumps({
            "source_identity": {"sha256": source, "files": {}},
            "compiler_identity": {"name": "refine", "sha256": compiler}}))

    def summary(self, rows):
        (self.bundles / "summary.json").write_text(json.dumps(rows))

    def provenance(self, environ=None):
        return gate_inputs.bundle_provenance(self.bundles, self.refine,
                                             environ or self.environ, self.checkout)

    def test_the_list_covers_every_file_and_checks_with_coreutils(self):
        digest = self.provenance()
        listing = (self.bundles / "files.sha256").read_bytes()
        self.assertEqual(digest, hashlib.sha256(listing).hexdigest())
        names = [line.split("  ", 1)[1] for line in listing.decode().splitlines()]
        self.assertEqual(names, sorted(names))
        self.assertIn("provenance.json", names)
        self.assertIn("rp2040/ram/board.elf", names)
        self.assertIn("summary.json", names)
        if shutil.which("sha256sum"):
            subprocess.run(["sha256sum", "--check", "--strict", "--quiet", "files.sha256"],
                           cwd=self.bundles, check=True)
        provenance = json.loads((self.bundles / "provenance.json").read_text())
        self.assertEqual((provenance["commit"], provenance["run_id"], provenance["source_identity"],
                          provenance["compiler"]["sha256"]),
                         (self.commit, "41", "source", self.compiler))
        self.assertEqual(provenance["tree"], git(self.checkout, "rev-parse", "HEAD^{tree}"))
        self.assertEqual(len(provenance["bundles"]), 3)

    def test_a_record_mismatch_is_refused(self):
        rows = json.loads((self.bundles / "summary.json").read_text())
        rows[1]["status"] = "mismatch"
        self.summary(rows)
        with self.assertRaisesRegex(ValueError, "rp2040 ram is mismatch"):
            self.provenance()

    def test_another_compiler_or_a_second_source_is_refused(self):
        self.manifest("esp32", "boot", "source", "0" * 64)
        with self.assertRaisesRegex(ValueError, "another compiler"):
            self.provenance()
        self.manifest("esp32", "boot", "other", self.compiler)
        with self.assertRaisesRegex(ValueError, "one source identity"):
            self.provenance()

    def test_a_checkout_that_is_not_the_runs_commit_is_refused(self):
        with self.assertRaisesRegex(ValueError, "not this run's commit"):
            self.provenance(dict(self.environ, GITHUB_SHA="0" * 40))

    def test_no_bundle_is_refused(self):
        self.summary([])
        with self.assertRaisesRegex(ValueError, "one source identity"):
            self.provenance()


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
    "scripts/activations.py": "a developer tool for closing an item; its test is in scripts/tests",
    "scripts/gate_inputs.py": "the inputs job",
    #  The gate's flake job builds it, skipped with the other lanes under
    #  reuse; README.md's status line gives the package only its version
    #  string, which falls back to 0 rather than failing.
    "flake.nix": "nix develop, nix build and the gate's flake job",
    ".github/workflows/gate.yml": "a comment describing this policy",
    ".github/workflows/links.yml": "its own workflow",
    ".github/workflows/pages.yml": "its own publishing workflow",
    "scripts/links_inputs.py": "links.yml scope selection; controls always run",
    ".github/workflows/release.yml": "a v* tag",
    ".github/DISCUSSION_TEMPLATE/": "GitHub's discussion forms, and the documents job's target check",
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
                         "these name one of %s bare, so a lane gate_inputs.py "
                         "may skip could read it.  A file that only names "
                         "another README, its own directory's say, names it by "
                         "its path (environments/x/README.md), which this does "
                         "not match; one that names a top-level document without "
                         "reading it gets an entry in READERS saying why; and one "
                         "a lane really reads takes the document out of "
                         "CONTENT_FREE" % ", ".join(gate_inputs.CONTENT_FREE))


if __name__ == "__main__":
    unittest.main()
