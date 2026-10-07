#!/usr/bin/env python3
"""Whether the gate may reuse a pass instead of running the target lanes.

A lane's verdict depends on its checkout.  Four top-level documents are in
every checkout and are read by no lane that builds or runs the compiler:
`README.md`, `ROADMAP.md`, `handoff.md` and `AGENTS.md`.  `check.py` and the
`scripts/tests` modules read them, and those jobs always run.  So two trees
that differ only in the CONTENT of those four files give the compiler,
target and determinism lanes the same inputs.

That alone does not make an edit explanatory: a sentence in these files can
change a target, language, scope or acceptance claim, and such a change
keeps its target evidence.  Nothing here reads a sentence to decide.  A
pass is reused only when all of these hold:

  - the base is a commit on which a push to main ran this workflow under a
    week ago, with every named job -- every matrix leg by its own name --
    run and succeeded, read from a complete job listing.  GitHub records
    that run; nothing a pull request writes is consulted, so a pass cannot
    be forged from a branch;
  - the tree differs from the base only in the content of the four files,
    so a path, a mode or any other byte runs everything;
  - every commit since the base, on each side of what is checked out --
    the pushed commit, or both parents of a pull request's merge commit, so
    main-side commits merged after the base count too -- says `Gate:
    explanatory` on a line of its own, and the run is a push to main or a
    pull request from a branch of this repository whose author has write
    access.  The declaration is the trusted judgement no syntax can
    make, bound to the exact commits it covers: a new commit without it,
    or one with a semantic claim the author did not declare, runs
    everything.

An identical candidate tree may also reuse a recent full successful push
run from a branch of this repository. This comparison includes ALL files,
modes, workflow definitions and tool pins, without explanatory exclusions.
Manual dispatch always runs the lanes. Anything uncertain runs every lane.

    key [REV]                       print the key of REV, HEAD by default
    same A B                        succeed only when A and B have one key
    reuse WORKFLOW JOB ...          print reuse=true or reuse=false, and why;
                                    each JOB is an exact job name
    verdict [--always JOB ...]      judge the `needs` context in $NEEDS
"""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request

DECLARATION = re.compile(r"^Gate: explanatory$", re.M)
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
MAX_AGE = timedelta(days=7)

#  Exact repository paths.  scripts/tests/test_gate_inputs.py names every
#  file that mentions one of these by name, so a new reader is a decision.
CONTENT_FREE = ("AGENTS.md", "README.md", "ROADMAP.md", "handoff.md")


def entries(rev, cwd=None):
    """REV's tree as (mode, type, object, path) rows, every level."""
    listing = subprocess.run(["git", "ls-tree", "-r", "-z", "--full-tree", rev],
                             cwd=cwd, check=True, stdout=subprocess.PIPE).stdout
    rows = []
    for record in listing.split(b"\0"):
        if not record:
            continue
        head, path = record.split(b"\t", 1)
        mode, kind, name = head.split(b" ")
        rows.append((mode, kind, name, path))
    return rows


def key(rev="HEAD", cwd=None, content_free=CONTENT_FREE):
    digest = hashlib.sha256()
    for mode, kind, name, path in entries(rev, cwd):
        if path.decode("utf-8", "surrogateescape") in content_free:
            name = b"-"
        digest.update(b"%s %s %s\t%s\0" % (mode, kind, name, path))
    return digest.hexdigest()


def tips_of(event_name, event, checked_out):
    """The commits whose history this run's tree is, and why there are none.

    CHECKED_OUT is (sha, parents) of the commit the job checked out.  A
    push to main checks out the pushed commit.  A pull request checks out
    GitHub's merge commit, whose first parent is main as it was when the
    merge was made -- possibly past the event's base.sha -- and whose
    second is the head; both histories are in the tree, so both are tips.
    A push to main is trusted by having happened.  A pull request is
    trusted when its author has write access and its branch is in this
    repository, where only someone with write access can add a commit; a
    fork's branch takes commits from whoever its owner lets in.
    """
    sha, parents = checked_out
    if event_name == "push":
        if event.get("ref") != "refs/heads/main":
            return None, "only a push to main or a pull request can be reused"
        if sha != event["after"]:
            return None, "the checkout is not the pushed commit"
        return [sha], None
    if event_name == "pull_request":
        request = event["pull_request"]
        if request.get("author_association") not in TRUSTED:
            return None, ("a pull request by a %s is never reused"
                          % request.get("author_association"))
        if request["head"]["repo"]["full_name"] != request["base"]["repo"]["full_name"]:
            return None, "a pull request from another repository is never reused"
        if len(parents) != 2 or parents[1] != request["head"]["sha"]:
            return None, "the checkout is not the pull request's merge commit"
        return list(parents), None
    return None, "a %s run is never reused" % event_name


def full_run(run, listing, required, now, main_only=True):
    """Whether RUN, with its job LISTING, ran every REQUIRED job and passed.

    REQUIRED names jobs exactly, a matrix leg by its own name, so a leg
    that never ran is missing rather than covered by its sibling.  A
    listing shorter than its total is not read as complete.  A run that
    itself reused a pass skipped its lanes, so it is not one: a reuse
    always points at a run that did the work.
    """
    if (run.get("event") != "push"
            or (main_only and run.get("head_branch") != "main")
            or not run.get("head_branch")
            or run.get("conclusion") != "success"):
        return False
    started = datetime.fromisoformat(run["run_started_at"].replace("Z", "+00:00"))
    if not timedelta(0) <= now - started <= MAX_AGE:
        return False
    jobs = listing.get("jobs", [])
    if listing.get("total_count") != len(jobs):
        return False
    for name in required:
        found = [job for job in jobs if job["name"] == name]
        if len(found) != 1 or found[0].get("conclusion") != "success":
            return False
    return True


def candidate_tips(event_name, event, checked_out):
    """Trusted branch pushes and same-repository merge checkouts only."""
    sha, unused_parents = checked_out
    if event_name == "push":
        if not event.get("ref", "").startswith("refs/heads/"):
            return None, "candidate reuse requires a branch push"
        if sha != event.get("after"):
            return None, "the checkout is not the pushed commit"
        return [sha], None
    return tips_of(event_name, event, checked_out)


def decide_candidate(event_name, event, api, key_of, checked_out,
                     workflow, required, now):
    """Reuse a full GitHub push run only when every tracked input is identical.

    KEY_OF must include every file and mode, including the four documents.
    Runs are obtained from this repository's workflow API, never from a
    branch-provided artifact or a local test transcript. A PR's checked-out
    merge tree must match; its head alone is insufficient.
    """
    tips, why = candidate_tips(event_name, event, checked_out)
    if tips is None:
        return False, why
    here = key_of("HEAD")
    runs = api("actions/workflows/%s/runs?event=push&status=success&per_page=30"
               % workflow)
    for run in runs.get("workflow_runs", []):
        # Compare inputs before fetching every job of an unrelated run.
        if key_of(run["head_sha"]) != here:
            continue
        listing = api("actions/runs/%d/jobs?filter=latest&per_page=100" % run["id"])
        if full_run(run, listing, required, now, main_only=False):
            return True, "identical candidate tree: reusing %s, which ran every lane on %s" % (
                run["html_url"], run["head_sha"][:12])
    return False, "no recent full push run has the identical candidate tree"


def undeclared(compared):
    """The commits in a comparison that do not declare, or why it is unusable.

    The base must be an ancestor of the tip: a base off the tip's history
    would carry changes the tip does not, which no listing here shows.
    """
    if compared.get("status") not in ("ahead", "identical"):
        return ["the base is not an ancestor (%s)" % compared.get("status")]
    commits = compared.get("commits", [])
    if compared.get("total_commits") != len(commits):
        return ["the comparison has more commits than it lists"]
    return [commit["sha"][:12] for commit in commits
            if not DECLARATION.search(commit["commit"]["message"])]


def decide(event_name, event, api, key_of, checked_out, workflow, required, now):
    """(reuse, reason).  API(path) answers GitHub's REST API; KEY_OF(rev).

    The record is GitHub's own: a run of WORKFLOW from a push to main.
    Nothing a pull request can write -- a cache, an artifact, a file -- is
    consulted, so a branch cannot manufacture the pass it then reuses.
    """
    tips, why = tips_of(event_name, event, checked_out)
    if tips is None:
        return False, why
    here = key_of("HEAD")
    runs = api("actions/workflows/%s/runs?branch=main&event=push&status=success"
               "&per_page=30" % workflow)
    reasons = []
    for run in runs.get("workflow_runs", []):
        listing = api("actions/runs/%d/jobs?filter=latest&per_page=100" % run["id"])
        if not full_run(run, listing, required, now):
            continue
        base = run["head_sha"]
        if key_of(base) != here:
            reasons.append("%s: more than the four documents' content differs"
                           % base[:12])
            continue
        missing = [problem for tip in tips
                   for problem in undeclared(api("compare/%s...%s" % (base, tip)))]
        if missing:
            reasons.append("%s: %s" % (base[:12], ", ".join(missing)))
            continue
        return True, "reusing %s, which ran every lane on %s" % (
            run["html_url"], base[:12])
    return False, "; ".join(reasons) or "no recent push to main ran every lane"


def github(path):
    url = "%s/repos/%s/%s" % (os.environ["GITHUB_API_URL"],
                              os.environ["GITHUB_REPOSITORY"], path)
    request = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + os.environ["GH_TOKEN"],
        "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def checkout():
    """The checked-out commit and its parents, which a shallow clone still names."""
    text = subprocess.run(["git", "cat-file", "commit", "HEAD"], check=True,
                          stdout=subprocess.PIPE, text=True).stdout
    header = text.split("\n\n", 1)[0].splitlines()
    sha = subprocess.run(["git", "rev-parse", "HEAD"], check=True,
                         stdout=subprocess.PIPE, text=True).stdout.strip()
    return sha, [line.split()[1] for line in header if line.startswith("parent ")]


def fetched_key(rev, content_free=CONTENT_FREE):
    if rev != "HEAD":
        subprocess.run(["git", "fetch", "-q", "--no-tags", "--depth=1",
                        "origin", rev], check=True)
    return key(rev, content_free=content_free)


def fetched_candidate_key(rev):
    return fetched_key(rev, content_free=())


def verdict(needs, always):
    """Problems with NEEDS, the workflow's `needs` context; none is a pass.

    The jobs in ALWAYS must succeed.  The rest must all succeed, or, when
    `inputs` found a pass to reuse, must all be skipped: a lane that ran
    anyway, or failed, is not explained by the reuse.
    """
    problems = []
    inputs = needs.get("inputs")
    if inputs is None:
        return ["no inputs job"]
    reuse = (inputs.get("result") == "success"
             and inputs.get("outputs", {}).get("reuse") == "true")
    for name, job in sorted(needs.items()):
        wanted = "success" if name in always or not reuse else "skipped"
        if job.get("result") != wanted:
            problems.append("%s is %s, not %s" % (name, job.get("result"), wanted))
    return problems


def main(argv):
    if len(argv) in (1, 2) and argv[0] == "key":
        print(key(*argv[1:]))
        return 0
    if len(argv) == 3 and argv[0] == "same":
        #  A tree that cannot be read raises, so two failures never compare
        #  equal the way two empty strings would in a shell.
        return 0 if key(argv[1]) == key(argv[2]) else 1
    if len(argv) >= 3 and argv[0] == "reuse":
        try:
            with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
                event = json.load(stream)
            checked_out = checkout()
            now = datetime.now(timezone.utc)
            reuse, why = decide_candidate(
                os.environ["GITHUB_EVENT_NAME"], event, github,
                fetched_candidate_key, checked_out, argv[1], argv[2:], now)
            if not reuse:
                reuse, explanatory_why = decide(
                    os.environ["GITHUB_EVENT_NAME"], event, github,
                    fetched_key, checked_out, argv[1], argv[2:], now)
                why += "; " + explanatory_why
        except Exception as error:  # noqa: BLE001 -- any doubt runs everything
            reuse, why = False, "%s: %s" % (type(error).__name__, error)
        print("gate_inputs: " + why, file=sys.stderr)
        print("reuse=" + ("true" if reuse else "false"))
        return 0
    if argv[:1] == ["verdict"] and argv[1:2] in ([], ["--always"]):
        always = ("inputs",) + tuple(argv[2:])
        needs = json.loads(os.environ["NEEDS"])
        problems = verdict(needs, always)
        for name, job in sorted(needs.items()):
            print("%s: %s" % (name, job.get("result")))
        for problem in problems:
            print("gate_inputs: " + problem, file=sys.stderr)
        return 1 if problems else 0
    print("usage: gate_inputs.py key [REV] | same A B"
          " | reuse WORKFLOW JOB ... | verdict [--always JOB ...]",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
