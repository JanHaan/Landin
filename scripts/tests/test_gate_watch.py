#!/usr/bin/env python3
"""Hold the gate watcher to returning at the first failed job, or at the end
naming every failed job when asked to."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WATCH = ROOT / "scripts" / "gate_watch.py"

#  Answers each `gh run view` with the next recorded state, holding the last.
FAKE_GH = '''#!%s
import json, os, sys
states = json.load(open(os.environ["STATES"]))
count = os.environ["STATES"] + ".count"
if "--commit" in sys.argv:
    open(os.environ["STATES"] + ".commit", "w").write(
        sys.argv[sys.argv.index("--commit") + 1])
seen = int(open(count).read()) if os.path.exists(count) else 0
if sys.argv[1] == "api":
    #  The jobs of the state the last `run view` answered, as GitHub's
    #  listing of every attempt gives them, in one page.
    jobs = states[min(max(seen - 1, 0), len(states) - 1)]["jobs"]
    print(json.dumps([{"total_count": len(jobs), "jobs": [
        {"id": j["databaseId"], "name": j["name"], "status": j["status"],
         "conclusion": j["conclusion"] or None, "started_at": j["startedAt"],
         "completed_at": j["completedAt"], "steps": j["steps"],
         "run_attempt": j.get("run_attempt", 1)} for j in jobs]}]))
    sys.exit(0)
open(count, "w").write(str(seen + 1))
if sys.argv[1:3] == ["run", "list"]:
    print(json.dumps([{"databaseId": 7}]))
else:
    view = dict(states[min(seen, len(states) - 1)])
    view.pop("jobs")
    print(json.dumps(view))
'''


def job(number, name, status="completed", conclusion="success", steps=()):
    return {"databaseId": number, "name": name, "status": status,
            "conclusion": conclusion if status == "completed" else "",
            "startedAt": "2026-10-16T12:00:00Z",
            "completedAt": "2026-10-16T12:03:00Z",
            "steps": [{"name": step, "conclusion": "failure"} for step in steps]}


def state(status, jobs, conclusion=""):
    return {"status": status, "conclusion": conclusion,
            "url": "https://example.invalid/run/7", "jobs": jobs}


class GateWatch(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="landin-watch-")
        self.addCleanup(self.temporary.cleanup)
        directory = Path(self.temporary.name)
        gh = directory / "gh"
        gh.write_text(FAKE_GH % sys.executable)
        gh.chmod(0o755)
        self.states = directory / "states.json"

    def watch(self, states, *arguments):
        self.states.write_text(json.dumps(states))
        environment = {**os.environ, "STATES": str(self.states),
                       "PATH": "%s%s%s" % (self.temporary.name, os.pathsep,
                                           os.environ["PATH"])}
        return subprocess.run(
            [sys.executable, str(WATCH), "--interval=0", *arguments],
            capture_output=True, text=True, timeout=30, env=environment,
            cwd=ROOT)

    def asked_for(self):
        return (self.states.parent / "states.json.commit").read_text()

    def test_the_first_failed_job_ends_the_watch_while_others_run(self):
        result = self.watch([
            state("in_progress", [job(1, "documents"),
                                  job(2, "compiler", status="in_progress")]),
            state("in_progress", [job(1, "documents"),
                                  job(2, "compiler", status="in_progress"),
                                  job(3, "scripts", conclusion="failure",
                                      steps=["scripts/tests"])]),
        ], "--run=7")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAILED: scripts at scripts/tests", result.stdout)
        self.assertIn("gh run view 7 --job 3 --log-failed", result.stdout)
        self.assertEqual(result.stdout.count("documents"), 1)

    def test_all_names_every_failed_job_once_the_run_ends(self):
        result = self.watch([
            state("in_progress", [job(1, "documents"),
                                  job(2, "scripts", conclusion="failure"),
                                  job(3, "compiler", status="in_progress")]),
            state("completed", [job(1, "documents"),
                                job(2, "scripts", conclusion="failure"),
                                job(3, "editor-grammar", conclusion="failure",
                                    steps=["The integration pass"])],
                  conclusion="failure"),
        ], "--run=7", "--all")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAILED: editor-grammar at The integration pass",
                      result.stdout)
        self.assertIn("failed jobs: scripts, editor-grammar", result.stdout)
        self.assertIn("run 7: failure", result.stdout)

    def test_a_run_that_succeeds_exits_zero(self):
        result = self.watch([
            state("in_progress", [job(1, "documents")]),
            state("completed", [job(1, "documents"), job(2, "gate")],
                  conclusion="success"),
        ], "--commit=" + "a" * 40)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("following gate run 7", result.stdout)

    def test_a_short_hash_is_asked_for_in_full(self):
        head = subprocess.run(("git", "rev-parse", "HEAD"), cwd=ROOT,
                              check=True, capture_output=True,
                              text=True).stdout.strip()
        result = self.watch([state("completed", [job(1, "gate")],
                                   conclusion="success")],
                            "--commit=" + head[:8])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.asked_for(), head)

    def test_a_name_that_is_no_commit_is_refused_at_once(self):
        result = self.watch([state("completed", [job(1, "gate")],
                                   conclusion="success")],
                            "--commit=0decafbad")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("names no commit in this clone", result.stderr)
        self.assertFalse((self.states.parent / "states.json.commit").exists())

    def test_a_rerun_job_is_judged_by_its_latest_attempt(self):
        failed = job(2, "scripts", conclusion="failure")
        failed["run_attempt"] = 1
        passed = job(3, "scripts")
        passed["run_attempt"] = 2
        result = self.watch([state("completed", [job(1, "documents"), failed,
                                                 passed], conclusion="success")],
                            "--run=7", "--all")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("FAILED", result.stdout)
        self.assertIn("judged on 2 jobs", result.stdout)

    def test_a_cancelled_run_is_neither_pass_nor_failure(self):
        result = self.watch([
            state("completed", [job(1, "compiler", conclusion="cancelled")],
                  conclusion="cancelled"),
        ], "--run=7")
        self.assertEqual(result.returncode, 2, result.stdout)


if __name__ == "__main__":
    unittest.main()
