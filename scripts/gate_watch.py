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
                                  [--all] [--event E] [--branch B]

`--all` follows the run to its end instead and names every failed job,
for a round whose fixes should all go in one push: returning at the first
failure once left a second failed lane of the same run unseen, and the
next push failed on it again.

With neither, it follows the gate run for HEAD, waiting for one to appear.
A commit may be anything `git rev-parse` names here, a short hash among
them; GitHub matches only a full one, so it is expanded before asking, and
a name that is neither a commit here nor a full hash is refused rather
than waited for.

One commit can have several gate runs: a branch's push, a boards dispatch
of the same commit, and main's push once it is promoted.  The first line
says which run is followed, with its event and branch.  `--event` and
`--branch` narrow the choice and wait for a run of that kind, so
`--commit C --event push --branch main` started right after a promotion
waits for main's own gate rather than following the branch's finished
dispatch, which is all GitHub lists for the first seconds.

A job is judged by its latest attempt, read from the complete listing.  A
failure left from an earlier attempt, while a rerun is still replacing
jobs, is printed as such and does not end the watch: it counts only if it
is still the job's latest attempt when the run ends.  Failures a rerun
replaced are named apart from the verdict.

The listing is read thirty jobs to a page, since GitHub answered 502 for
hundred-job pages of a run holding 193 jobs, and a server error is asked
again a bounded number of times.  A request that still fails is named, with
GitHub's answer, and ends the watch with status 3.

The exit status is 0 when the run succeeded, 1 when a job failed, and 2
when the run ended otherwise, for instance cancelled by a newer push, and
3 when GitHub could not be asked.
"""
import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime

FAILED = ("failure", "timed_out", "startup_failure")
#  Jobs to a page of the listing.  GitHub answered 502 for hundred-job
#  pages once a run held 193 jobs over four attempts; thirty-job pages
#  answered.
PAGE = 30
#  Pages read before the listing is called endless: 3000 jobs.
PAGES = 100
#  Times one request is asked while GitHub answers a server error.
TRIES = 4
SERVER_ERROR = re.compile(r"HTTP 5\d\d")
#  Seconds between those tries; main lowers it to a shorter --interval.
retry_pause = 5.0


class Unanswered(Exception):
    """A request GitHub did not answer, with what `gh` said."""


def gh(*arguments):
    """`gh ARGUMENTS`'s JSON answer, asking again after a server error.

    A 502 from the job listing once ended the watch with a traceback.  A
    server error is retried TRIES times; any other refusal, or the last
    server error, raises Unanswered naming the request.
    """
    said = ""
    for attempt in range(1, TRIES + 1):
        done = subprocess.run(("gh",) + arguments, capture_output=True,
                              text=True)
        if done.returncode == 0:
            return json.loads(done.stdout)
        said = (done.stderr.strip() or done.stdout.strip()
                or "exit status %d" % done.returncode)
        if not SERVER_ERROR.search(said):
            break
        if attempt < TRIES:
            print("gh %s: %s; asking again (%d of %d)"
                  % (" ".join(arguments), said.splitlines()[-1], attempt + 1,
                     TRIES), flush=True)
            time.sleep(retry_pause * attempt)
    raise Unanswered("gh %s\n  %s" % (" ".join(arguments), said))


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


def find_run(commit, interval, event=None, branch=None):
    """The newest gate run of COMMIT, of EVENT and BRANCH when given.

    Waits until GitHub lists one.  Without EVENT and BRANCH the newest run
    of any kind is taken, which right after a promotion is the branch's
    finished run, not main's.
    """
    wanted = (["--event", event] if event else []) + (
        ["--branch", branch] if branch else [])
    kind = " ".join(part for part in (event, "on " + branch if branch else "")
                    if part)
    while True:
        runs = gh("run", "list", "--workflow=gate.yml", "--commit", commit,
                  *wanted, "--limit", "1", "--json", "databaseId")
        if runs:
            return runs[0]["databaseId"]
        print("no %sgate run for %s yet" % (kind + " " if kind else "",
                                            commit[:12]), flush=True)
        time.sleep(interval)


def jobs_of(run):
    """RUN's jobs, each name's latest attempt, from GitHub's job listing.

    `gh run view --json jobs` once named three of a run's 47 jobs, as
    GitHub's latest-attempt listing did, and the watcher called the run
    green on those three.  Every attempt's jobs are read here, every page
    of them, and each name's latest attempt kept: all its jobs, so two of
    one name in one attempt are both seen.  The second value is the jobs
    of earlier attempts that a later attempt of their name replaced.

    Each page is its own request, PAGE jobs long, so a server error costs
    one page's retry and the failing request can be named.
    """
    listed, total = [], None
    for page in range(1, PAGES + 1):
        listing = gh("api", "repos/{owner}/{repo}/actions/runs/%s/jobs"
                     "?filter=all&per_page=%d&page=%d" % (run, PAGE, page))
        total = listing.get("total_count")
        batch = listing.get("jobs") or []
        listed.extend(batch)
        if not batch or total is None or len(listed) >= total:
            break
    if total is not None and len(listed) < total:
        raise Unanswered("the job listing of run %s ended at %d of its %d jobs"
                         % (run, len(listed), total))
    latest, replaced = {}, []
    for job in listed:
        attempt = job.get("run_attempt", 1)
        held = latest.setdefault(job["name"], (attempt, []))
        if attempt > held[0]:
            replaced.extend(held[1])
            latest[job["name"]] = (attempt, [job])
        elif attempt == held[0]:
            held[1].append(job)
        else:
            replaced.append(job)

    def shown(job):
        return {"databaseId": job["id"], "name": job["name"],
                "status": job["status"],
                "conclusion": job.get("conclusion") or "",
                "attempt": job.get("run_attempt", 1),
                "startedAt": job.get("started_at") or "",
                "completedAt": job.get("completed_at") or "",
                "steps": job.get("steps") or []}
    return ([shown(job) for _, named in latest.values() for job in named],
            [shown(job) for job in replaced])


def minutes(job):
    started, completed = job.get("startedAt"), job.get("completedAt")
    if not started or not completed or started.startswith("0001"):
        return ""
    elapsed = (datetime.fromisoformat(completed.replace("Z", "+00:00"))
               - datetime.fromisoformat(started.replace("Z", "+00:00")))
    return " %.1f min" % (elapsed.total_seconds() / 60)


def log_commands(run, job, active):
    """The lines naming the command that shows failed JOB's log.

    `gh run view --log-failed` refuses while the run is ACTIVE, saying logs
    are available only when it completes; the job's own log endpoint
    answers as soon as the job has ended.
    """
    whole = "gh run view %s --job %s --log-failed" % (run, job["databaseId"])
    if not active:
        return ["log:    " + whole]
    return ["log:    gh api repos/{owner}/{repo}/actions/jobs/%s/logs"
            % job["databaseId"],
            "        (the job's whole log, readable while run %s is still "
            "active;" % run,
            "        once the run ends: %s)" % whole]


def watch(run, interval, every=False):
    """Follow RUN; the verdict is read from the last complete listing.

    A failed job of the run's current attempt ends the watch at once unless
    EVERY.  One left from an earlier attempt is held back while the run is
    active, because the rerun that made the newer attempt may be about to
    replace it; whether it failed the run is read when the run ends.
    """
    reported = set()
    held_back = set()
    while True:
        view = gh("run", "view", str(run), "--json",
                  "status,conclusion,url,attempt")
        jobs, replaced = jobs_of(run)
        ended = view["status"] == "completed"
        current = view.get("attempt") or max(
            [job["attempt"] for job in jobs] or [1])
        for job in jobs:
            if job["status"] != "completed" or job["databaseId"] in reported:
                continue
            failed = job["conclusion"] in FAILED
            if failed and not ended and job["attempt"] < current:
                if job["databaseId"] not in held_back:
                    held_back.add(job["databaseId"])
                    print("%-10s %s in attempt %d; the run is at attempt %d, "
                          "which may replace it"
                          % (job["conclusion"], job["name"], job["attempt"],
                             current), flush=True)
                continue
            reported.add(job["databaseId"])
            print("%-10s %s%s" % (job["conclusion"], job["name"], minutes(job)),
                  flush=True)
            if failed:
                steps = [step["name"] for step in job.get("steps", ())
                         if step.get("conclusion") in FAILED]
                print("FAILED: %s%s" % (job["name"],
                                        " at %s" % steps[0] if steps else ""))
                for line in log_commands(run, job, not ended):
                    print(line)
                print("run:    %s" % view["url"], flush=True)
                if not every and not ended:
                    return 1
        if ended:
            #  The verdict: this listing's failures and nothing remembered.
            failed = [job["name"] for job in jobs if job["conclusion"] in FAILED]
            earlier = sorted({job["name"] for job in replaced
                              if job["conclusion"] in FAILED}
                             - set(failed))
            print("run %s: %s, judged on %d jobs  %s"
                  % (run, view["conclusion"], len(jobs), view["url"]))
            if earlier:
                print("failed in an earlier attempt and since replaced, "
                      "not part of the verdict: %s" % ", ".join(earlier))
            if failed:
                print("failed jobs: %s" % ", ".join(failed))
                return 1
            return 0 if view["conclusion"] == "success" else 2
        time.sleep(interval)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    which = parser.add_mutually_exclusive_group()
    which.add_argument("--run", type=int)
    which.add_argument("--commit")
    parser.add_argument("--interval", type=float, default=30)
    parser.add_argument("--all", action="store_true",
                        help="follow the run to its end, naming every failure")
    parser.add_argument("--event", help="with a commit, wait for a run of "
                        "this event: push, workflow_dispatch, pull_request, "
                        "schedule")
    parser.add_argument("--branch", help="with a commit, wait for a run on "
                        "this branch")
    args = parser.parse_args(argv[1:])
    if args.run is not None and (args.event or args.branch):
        parser.error("--event and --branch choose among a commit's runs; "
                     "--run already names one")
    global retry_pause
    retry_pause = min(retry_pause, args.interval)
    run = args.run
    try:
        if run is None:
            commit = full_commit(args.commit or "HEAD")
            if commit is None:
                parser.error("%s names no commit in this clone; fetch it, or "
                             "give its full hash" % args.commit)
            run = find_run(commit, args.interval, args.event, args.branch)
        about = gh("run", "view", str(run), "--json", "event,headBranch")
        print("following gate run %s (%s on %s)"
              % (run, about.get("event") or "unknown event",
                 about.get("headBranch") or "no branch"), flush=True)
        return watch(run, args.interval, args.all)
    except Unanswered as error:
        print("gate_watch: GitHub did not answer: %s" % error, file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
