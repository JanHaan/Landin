#!/usr/bin/env python3
"""Maintainer approval tags and the shared fail-closed publication guard."""
import argparse
from pathlib import Path
import subprocess
import sys

from common import Invalid, clean_checkout, commit_source, decode, git, require
from records import validate_approval

CANONICAL = "https://git.sr.ht/~sinnfrei/landin"


def tag_name(commit):
    return "ci/accepted/" + commit


def read_approval(root, commit):
    ref = "refs/tags/" + tag_name(commit)
    require(git(root, "cat-file", "-t", ref).strip() == b"tag", "approval must be an annotated tag")
    raw = git(root, "cat-file", "tag", ref)
    header, annotation = raw.split(b"\n\n", 1)
    fields = header.splitlines()
    require(len(fields) == 4 and fields[0] == b"object " + commit.encode() and
            fields[1] == b"type commit" and fields[2] == b"tag " + tag_name(commit).encode()
            and fields[3].startswith(b"tagger "), "approval tag target/type/name mismatch")
    _, source = commit_source(root, commit)
    return validate_approval(decode(annotation), source)


def remote_ref(root, remote, ref):
    rows = git(root, "ls-remote", "--refs", remote, ref).splitlines()
    require(len(rows) == 1, "canonical ref missing or ambiguous: " + ref)
    oid, found = rows[0].split(b"\t")
    require(found.decode() == ref, "unexpected remote ref")
    return oid.decode()


def guard(root, remote=CANONICAL):
    clean_checkout(root)
    commit = git(root, "rev-parse", "HEAD").decode().strip()
    require(remote_ref(root, remote, "refs/heads/main") == commit, "checkout is not current canonical main")
    ref = "refs/tags/" + tag_name(commit)
    remote_tag = remote_ref(root, remote, ref)
    # Fetch without force: an existing different local approval is a collision.
    git(root, "fetch", "--no-tags", remote, ref + ":" + ref)
    require(git(root, "rev-parse", ref).decode().strip() == remote_tag, "approval changed during fetch")
    read_approval(root, commit)
    clean_checkout(root)
    require(git(root, "rev-parse", "HEAD").decode().strip() == commit, "checkout HEAD changed during validation")
    require(remote_ref(root, remote, "refs/heads/main") == commit, "canonical main changed during validation")
    return commit


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    try:
        print("approved canonical publication: " + guard(args.root))
        return 0
    except (Invalid, OSError, subprocess.CalledProcessError) as exc:
        print("landin: publication refused: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
