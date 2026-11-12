#!/usr/bin/env python3
"""The decisions of the release workflow that are not a build.

    python3 scripts/release.py ref TAG
    python3 scripts/release.py gated [CHECKOUT]
    python3 scripts/release.py publish TAG DIRECTORY

`ref` answers whether this run may publish TAG at all: it must run on that
tag, `GITHUB_REF` being `refs/tags/TAG`, since the publishing job's
environment, `release`, deploys only from a `v*` tag (D1337).  A push of
the tag runs on it; a dispatch runs on it only when it is made with
`--ref TAG`, and one made on a branch is refused here, before the builds,
rather than by the environment after them.

`gated` answers whether the commit checked out in CHECKOUT, by default the
current directory, may be released: it must be
an ancestor of `origin/main`, and the gate must have passed on main's own
push of exactly that commit.  A tag is a name anyone with write access can
put on any commit, and the build's own checks tie the binary to the tag,
not the tag to a tree that was tested: without this a tag on an unmerged
or ungated commit published a compiler without complaint.  It reads
GITHUB_API_URL, GITHUB_REPOSITORY and GH_TOKEN, and needs a checkout with
history (`fetch-depth: 0`).

`publish` uploads every file of DIRECTORY as the assets of TAG's release,
through `gh`, so that a reader of the releases page never sees part of
one.  The release is made as a draft, the files are uploaded, the list of
what it then holds is compared with DIRECTORY, and only then is it
published.  A run that stops part-way leaves a draft, which the next run
empties and fills again.  A release that is already published is final,
as it always was: a file of a name it already publishes is refused, since
the build is not reproducible and the flake records the published hashes.
The release's notes say how a user checks an archive's attestation, which
the workflow makes before this runs, and the environment holds this job
until the maintainer approves it.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

WORKFLOW = "gate.yml"
MAIN = "main"
#  The workflow that builds, attests and publishes, as an attestation's
#  signer names it.
RELEASE_WORKFLOW = ".github/workflows/release.yml"


def ref_refused(tag, ref):
    """Why a run on `ref` may not publish `tag`, or None."""
    if not tag.startswith("v"):
        return ("%s is not a v* tag, which is all the release environment "
                "deploys from" % tag)
    if ref != "refs/tags/" + tag:
        return ("this run is on %s; a release of %s runs on its tag, so "
                "dispatch it with --ref %s: the release environment deploys "
                "only from a v* tag" % (ref or "no ref", tag, tag))
    return None


def repository():
    return os.environ.get("GITHUB_REPOSITORY") or "JanHaan/Landin"


def notes(tag):
    """What the release says about checking its files."""
    return ("The refine compiler, built from %s by the release workflow. "
            "Each archive is attested; check one with\n\n"
            "    gh attestation verify FILE --repo %s \\\n"
            "      --signer-workflow %s/%s \\\n"
            "      --source-ref refs/tags/%s --deny-self-hosted-runners\n\n"
            "which says this workflow built it from that tag. The .sha256 "
            "beside each asset is its digest." % (
                tag, repository(), repository(), RELEASE_WORKFLOW, tag))


def github(path):
    url = "%s/repos/%s/%s" % (os.environ["GITHUB_API_URL"],
                              os.environ["GITHUB_REPOSITORY"], path)
    request = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + os.environ["GH_TOKEN"],
        "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def git(*arguments, cwd=None):
    return subprocess.run(["git", *arguments], cwd=cwd, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def gated(api=github, cwd=None):
    """Why the checked-out commit may not be released, or None."""
    head = git("rev-parse", "HEAD", cwd=cwd)
    if head.returncode:
        return "git cannot name the checked-out commit: " + head.stderr.strip()
    commit = head.stdout.strip()
    main = git("rev-parse", "--verify", "--quiet",
               "refs/remotes/origin/%s^{commit}" % MAIN, cwd=cwd)
    if main.returncode:
        return ("this checkout has no origin/%s to compare with; it needs "
                "the history, fetch-depth: 0" % MAIN)
    ancestor = git("merge-base", "--is-ancestor", commit, main.stdout.strip(),
                   cwd=cwd)
    if ancestor.returncode == 1:
        return ("%s is not on %s: a release is cut from a commit that was "
                "promoted" % (commit, MAIN))
    if ancestor.returncode:
        return "git cannot compare %s with %s: %s" % (
            commit, MAIN, ancestor.stderr.strip())
    listing = api("actions/workflows/%s/runs?head_sha=%s&event=push&branch=%s"
                  "&status=success&per_page=20" % (WORKFLOW, commit, MAIN))
    runs = listing.get("workflow_runs") if isinstance(listing, dict) else None
    if not isinstance(runs, list):
        return "GitHub's list of %s runs for %s could not be read" % (
            WORKFLOW, commit)
    passed = [run for run in runs if isinstance(run, dict)
              and run.get("head_sha") == commit
              and run.get("event") == "push"
              and run.get("head_branch") == MAIN
              and run.get("status") == "completed"
              and run.get("conclusion") == "success"]
    if not passed:
        return ("no %s run of %s's push of %s succeeded: a release is cut "
                "from a commit whose own gate passed"
                % (WORKFLOW, MAIN, commit))
    print("release: %s is on %s and its gate passed, run %s"
          % (commit, MAIN, passed[0].get("id")))
    return None


class Refused(Exception):
    pass


def gh(*arguments, check=True):
    done = subprocess.run(["gh", *arguments], text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and done.returncode:
        raise Refused("gh %s failed (%d): %s" % (
            " ".join(arguments[:3]), done.returncode, done.stderr.strip()))
    return done


def release_of(tag):
    """TAG's release as (is a draft, its asset names), or None for none."""
    seen = gh("release", "view", tag, "--json", "isDraft,assets", check=False)
    if seen.returncode:
        return None
    state = json.loads(seen.stdout)
    return bool(state["isDraft"]), [asset["name"] for asset in state["assets"]]


def publish(tag, directory):
    files = sorted(path for path in Path(directory).iterdir() if path.is_file())
    if not files:
        raise Refused("%s holds no file to publish" % directory)
    names = [path.name for path in files]
    found = release_of(tag)
    if found is None:
        gh("release", "create", tag, "--draft", "--verify-tag",
           "--title", "Landin " + tag, "--notes", notes(tag))
        draft = True
    else:
        draft, held = found
        if draft:
            #  What an earlier run left before it stopped.  Its files are
            #  not this build's, and the build is not reproducible.
            for name in held:
                gh("release", "delete-asset", tag, name, "--yes")
        else:
            again = [name for name in names if name in held]
            if again:
                raise Refused("%s already publishes %s; refusing to replace it"
                              % (tag, ", ".join(again)))
    gh("release", "upload", tag, *[str(path) for path in files])
    after = release_of(tag)
    if after is None:
        raise Refused("the release of %s cannot be read back" % tag)
    missing = [name for name in names if name not in after[1]]
    if missing:
        raise Refused("%s does not hold %s after the upload; the release is "
                      "%s" % (tag, ", ".join(missing),
                              "left a draft" if draft else "already public"))
    if draft:
        gh("release", "edit", tag, "--draft=false")
    print("release: %s publishes %d files" % (tag, len(names)))


def main(argv):
    if len(argv) == 3 and argv[1] == "ref":
        reason = ref_refused(argv[2], os.environ.get("GITHUB_REF", ""))
        if reason:
            print("release: " + reason, file=sys.stderr)
            return 1
        return 0
    if argv[1:2] == ["gated"] and len(argv) <= 3:
        reason = gated(cwd=argv[2] if len(argv) == 3 else None)
        if reason:
            print("release: " + reason, file=sys.stderr)
            return 1
        return 0
    if len(argv) == 4 and argv[1] == "publish":
        try:
            publish(argv[2], argv[3])
        except Refused as refusal:
            print("release: %s" % refusal, file=sys.stderr)
            return 1
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
