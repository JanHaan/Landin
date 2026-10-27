#!/usr/bin/env python3
"""Follow a gate run and return at its first failed job.

A failed gate says so only when its final `gate` job runs, after every
other lane: a scripts failure at eleven minutes was reported at seventy-one,
a Darwin parity failure at twelve was reported at 135.  `gh run watch`
waits for the same end.  This prints each job as it finishes and exits as
soon as one fails, naming its failed step and the command that shows the
log, so the fix can start while the other lanes run on.  Pushing the fix
cancels the superseded run, because the gate's concurrency group does.

    python3 scripts/gate_watch.py [--run ID | --commit SHA] [--interval S]

With neither, it follows the gate run for HEAD, waiting for one to appear.
A commit may be anything `git rev-parse` names here, a short hash among
them; GitHub matches only a full one, so it is expanded before asking, and
a name that is neither a commit here nor a full hash is refused rather
than waited for.
The exit status is 0 when the run succeeded, 1 when a job failed, and 2
when the run ended otherwise, for instance cancelled by a newer push.
"""
import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime

FAILED = ("failure", "timed_out", "startup_failure")


def gh(*arguments):
    return json.loads(subprocess.run(
        ("gh",) + arguments, check=True, capture_output=True, text=True).stdout)


def full_commit(name):
    """The full hash `name` stands for, or None when it names nothing here.

    `gh run list --commit` compares the whole hash, so a short one matches no
    run, and the watcher used to wait for ever beside a run that had passed.
    A full hash this clone lacks is still a commit GitHub may know.
    """
    found = subprocess.run(
        ("git", "rev-parse", "--verify", "--quiet", name + "^{commit}"),
        capture_output=True, text=True)
    if found.returncode == 0:
        return found.stdout.strip()
    if re.fullmatch(r"[0-9a-f]{40}", name):
        return name
    return None


def find_run(commit, interval):
    while True:
        runs = gh("run", "list", "--workflow=gate.yml", "--commit", commit,
                  "--limit", "1", "--json", "databaseId")
        if runs:
            return runs[0]["databaseId"]
        print("no gate run for %s yet" % commit[:12], flush=True)
        time.sleep(interval)


def minutes(job):
    started, completed = job.get("startedAt"), job.get("completedAt")
    if not started or not completed or started.startswith("0001"):
        return ""
    elapsed = (datetime.fromisoformat(completed.replace("Z", "+00:00"))
               - datetime.fromisoformat(started.replace("Z", "+00:00")))
    return " %.1f min" % (elapsed.total_seconds() / 60)


def watch(run, interval):
    reported = set()
    while True:
        view = gh("run", "view", str(run), "--json",
                  "status,conclusion,url,jobs")
        for job in view["jobs"]:
            if job["status"] != "completed" or job["databaseId"] in reported:
                continue
            reported.add(job["databaseId"])
            print("%-10s %s%s" % (job["conclusion"], job["name"], minutes(job)),
                  flush=True)
            if job["conclusion"] in FAILED:
                steps = [step["name"] for step in job.get("steps", ())
                         if step.get("conclusion") in FAILED]
                print("FAILED: %s%s" % (job["name"],
                                        " at %s" % steps[0] if steps else ""))
                print("log:    gh run view %s --job %s --log-failed"
                      % (run, job["databaseId"]))
                print("run:    %s" % view["url"])
                return 1
        if view["status"] == "completed":
            print("run %s: %s  %s" % (run, view["conclusion"], view["url"]))
            return 0 if view["conclusion"] == "success" else 2
        time.sleep(interval)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    which = parser.add_mutually_exclusive_group()
    which.add_argument("--run", type=int)
    which.add_argument("--commit")
    parser.add_argument("--interval", type=float, default=30)
    args = parser.parse_args(argv[1:])
    run = args.run
    if run is None:
        commit = full_commit(args.commit or "HEAD")
        if commit is None:
            parser.error("%s names no commit in this clone; fetch it, or give "
                         "its full hash" % args.commit)
        run = find_run(commit, args.interval)
    print("following gate run %s" % run, flush=True)
    return watch(run, args.interval)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
