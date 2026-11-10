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
#  Seconds before a subprocess here is called hung.  It ends in well under
#  a second on an idle host; the limit only stops a hang, and is wide
#  because scripts/script_tests.py's own workers load the host.
HANG = 300
WATCH = ROOT / "scripts" / "gate_watch.py"

#  Answers each `gh run view` of a run's status with the next recorded
#  state, holding the last, and the job listing in pages of the size asked
#  for.  Every call's arguments are appended to STATES.calls.  STATES.fail,
#  when present, is [count, message]: that many job-listing requests are
#  refused with the message before one is answered.  STATES.unlisted is
#  the number of `run list` requests answered with no run.
FAKE_GH = '''#!%s
import json, os, re, sys
base = os.environ["STATES"]
states = json.load(open(base))
with open(base + ".calls", "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\\n")
def number(suffix):
    return int(open(base + suffix).read()) if os.path.exists(base + suffix) else 0
seen = number(".count")
if sys.argv[1] == "api":
    if os.path.exists(base + ".fail"):
        left, message = json.load(open(base + ".fail"))
        if left:
            json.dump([left - 1, message], open(base + ".fail", "w"))
            sys.stderr.write(message + "\\n")
            sys.exit(1)
    #  The jobs of the state the last `run view` answered, as GitHub's
    #  listing of every attempt gives them.
    jobs = states[min(max(seen - 1, 0), len(states) - 1)]["jobs"]
    size = int(re.search(r"per_page=(\\d+)", sys.argv[2]).group(1))
    page = int(re.search(r"[?&]page=(\\d+)", sys.argv[2]).group(1))
    print(json.dumps({"total_count": len(jobs), "jobs": [
        {"id": j["databaseId"], "name": j["name"], "status": j["status"],
         "conclusion": j["conclusion"] or None, "started_at": j["startedAt"],
         "completed_at": j["completedAt"], "steps": j["steps"],
         "run_attempt": j.get("run_attempt", 1)}
        for j in jobs[(page - 1) * size:page * size]]}))
elif sys.argv[1:3] == ["run", "list"]:
    unlisted = number(".unlisted")
    if unlisted:
        open(base + ".unlisted", "w").write(str(unlisted - 1))
        print("[]")
    else:
        print(json.dumps([{"databaseId": 7}]))
elif "event,headBranch" in sys.argv:
    print(json.dumps({"event": "push", "headBranch": "main"}))
else:
    open(base + ".count", "w").write(str(seen + 1))
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


def attempt(number, held):
    return {**held, "run_attempt": number}


def state(status, jobs, conclusion="", attempt=1):
    return {"status": status, "conclusion": conclusion, "attempt": attempt,
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
            capture_output=True, text=True, timeout=HANG, env=environment,
            cwd=ROOT)

    def calls(self):
        recorded = self.states.parent / "states.json.calls"
        if not recorded.exists():
            return []
        return [json.loads(line) for line in recorded.read_text().splitlines()]

    def asked_for(self):
        listed = [call for call in self.calls() if call[:2] == ["run", "list"]]
        return listed[0][listed[0].index("--commit") + 1]

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
        self.assertEqual(result.stdout.count("documents"), 1)

    def test_a_failed_job_of_an_active_run_gets_a_log_command_that_answers(self):
        #  `gh run view --log-failed` refuses until the whole run ends; the
        #  job's own endpoint answers at once.  Both name run 7 and job 3.
        result = self.watch([
            state("in_progress", [job(2, "compiler", status="in_progress"),
                                  job(3, "scripts", conclusion="failure")]),
        ], "--run=7")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("log:    gh api repos/{owner}/{repo}/actions/jobs/3/logs",
                      result.stdout)
        self.assertIn("readable while run 7 is still active", result.stdout)
        self.assertIn("once the run ends: gh run view 7 --job 3 --log-failed",
                      result.stdout)

    def test_a_failed_job_of_an_ended_run_gets_the_failed_step_command(self):
        result = self.watch([
            state("completed", [job(3, "scripts", conclusion="failure")],
                  conclusion="failure"),
        ], "--run=7")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("log:    gh run view 7 --job 3 --log-failed",
                      result.stdout)
        self.assertNotIn("actions/jobs/3/logs", result.stdout)

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
        self.assertIn("following gate run 7 (push on main)", result.stdout)

    def test_a_named_event_and_branch_are_waited_for(self):
        #  Right after a promotion GitHub lists only the branch's finished
        #  runs of the commit; the caller names main's push and the watcher
        #  asks for exactly that until it is listed.
        (self.states.parent / "states.json.unlisted").write_text("2")
        result = self.watch([
            state("completed", [job(1, "gate")], conclusion="success"),
        ], "--commit=" + "a" * 40, "--event=push", "--branch=main")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stdout.count("no push on main gate run for aaaaaaaaaaaa yet"),
            2, result.stdout)
        listed = [call for call in self.calls() if call[:2] == ["run", "list"]]
        self.assertEqual(len(listed), 3)
        for call in listed:
            self.assertEqual(call[call.index("--event") + 1], "push")
            self.assertEqual(call[call.index("--branch") + 1], "main")

    def test_an_event_with_a_run_number_is_refused(self):
        result = self.watch([state("completed", [job(1, "gate")],
                                   conclusion="success")],
                            "--run=7", "--event=push")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("--run already names one", result.stderr)
        self.assertEqual(self.calls(), [])

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
        self.assertEqual(self.calls(), [])

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

    def test_a_failure_being_rerun_is_not_the_verdict(self):
        #  The watcher starts while attempt 2 reruns the failed jobs.  The
        #  aggregate's new attempt is not listed until its needs end, so
        #  its old failure is the latest one listed for a while.
        old_scripts = attempt(1, job(2, "scripts", conclusion="failure"))
        old_gate = attempt(1, job(3, "gate", conclusion="failure"))
        new_scripts = attempt(2, job(4, "scripts"))
        new_gate = attempt(2, job(5, "gate"))
        states = [
            state("in_progress", [job(1, "documents"), old_scripts, old_gate,
                                  attempt(2, job(4, "scripts",
                                                 status="in_progress"))],
                  attempt=2),
            state("completed", [job(1, "documents"), old_scripts, old_gate,
                                new_scripts, new_gate],
                  conclusion="success", attempt=2),
        ]
        for arguments in (("--run=7", "--all"), ("--run=7",)):
            for suffix in (".count", ".calls"):
                (self.states.parent / ("states.json" + suffix)).unlink(
                    missing_ok=True)
            result = self.watch(states, *arguments)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("failure    gate in attempt 1; the run is at "
                          "attempt 2, which may replace it", result.stdout)
            self.assertNotIn("FAILED", result.stdout)
            self.assertNotIn("failed jobs:", result.stdout)
            self.assertIn("run 7: success, judged on 3 jobs", result.stdout)
            self.assertIn("failed in an earlier attempt and since replaced, "
                          "not part of the verdict: gate, scripts",
                          result.stdout)

    def test_an_earlier_failure_no_rerun_replaced_still_fails_the_run(self):
        #  Attempt 2 reran one other job; `scripts` keeps its failure.
        old_scripts = attempt(1, job(2, "scripts", conclusion="failure"))
        result = self.watch([
            state("in_progress", [old_scripts,
                                  attempt(2, job(4, "compiler",
                                                 status="in_progress"))],
                  attempt=2),
            state("completed", [old_scripts, attempt(2, job(4, "compiler"))],
                  conclusion="failure", attempt=2),
        ], "--run=7")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAILED: scripts", result.stdout)
        self.assertIn("failed jobs: scripts", result.stdout)

    def test_the_listing_is_read_in_pages_github_answers(self):
        jobs = [job(number, "lane-%d" % number) for number in range(1, 72)]
        result = self.watch([state("completed", jobs, conclusion="success")],
                            "--run=7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("judged on 71 jobs", result.stdout)
        asked = [call[1] for call in self.calls() if call[0] == "api"]
        self.assertEqual(asked, [
            "repos/{owner}/{repo}/actions/runs/7/jobs"
            "?filter=all&per_page=30&page=%d" % page for page in (1, 2, 3)])

    def test_a_server_error_is_asked_again(self):
        (self.states.parent / "states.json.fail").write_text(json.dumps(
            [2, "gh: Server Error (HTTP 502)"]))
        result = self.watch([state("completed", [job(1, "gate")],
                                   conclusion="success")], "--run=7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("asking again"), 2, result.stdout)
        self.assertIn("gh: Server Error (HTTP 502); asking again (2 of 4)",
                      result.stdout)

    def test_a_request_that_stays_unanswered_is_named_without_a_traceback(self):
        (self.states.parent / "states.json.fail").write_text(json.dumps(
            [99, "gh: Server Error (HTTP 502)"]))
        result = self.watch([state("completed", [job(1, "gate")],
                                   conclusion="success")], "--run=7")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("gate_watch: GitHub did not answer: gh api "
                      "repos/{owner}/{repo}/actions/runs/7/jobs"
                      "?filter=all&per_page=30&page=1", result.stderr)
        self.assertIn("HTTP 502", result.stderr)
        self.assertEqual(
            len([call for call in self.calls() if call[0] == "api"]), 4)

    def test_a_refusal_that_is_no_server_error_is_not_asked_again(self):
        (self.states.parent / "states.json.fail").write_text(json.dumps(
            [99, "gh: Not Found (HTTP 404)"]))
        result = self.watch([state("completed", [job(1, "gate")],
                                   conclusion="success")], "--run=7")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("HTTP 404", result.stderr)
        self.assertEqual(
            len([call for call in self.calls() if call[0] == "api"]), 1)

    def test_a_cancelled_run_is_neither_pass_nor_failure(self):
        result = self.watch([
            state("completed", [job(1, "compiler", conclusion="cancelled")],
                  conclusion="cancelled"),
        ], "--run=7")
        self.assertEqual(result.returncode, 2, result.stdout)


if __name__ == "__main__":
    unittest.main()
