#!/usr/bin/env python3
"""Select the documents for the external link workflow."""

import os
import re
import subprocess
from pathlib import Path


FULL = "./**/*.md\n"
ZERO_REVISION = re.compile(r"0{40}|0{64}")
REVISION = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


def git(*args):
    return subprocess.run(("git", *args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout


def inputs(event, before):
    if event != "push" or not REVISION.fullmatch(before) or ZERO_REVISION.fullmatch(before):
        return FULL, "full"

    try:
        git("cat-file", "-e", before + "^{commit}")
    except subprocess.CalledProcessError:
        try:
            git("fetch", "--no-tags", "--depth=1", "origin", before)
        except subprocess.CalledProcessError:
            return FULL, "full"

    try:
        changed = git("diff", "--name-only", "-z", "--diff-filter=ACMRT",
                      before, "HEAD", "--", "*.md")
        config = git("diff", "--name-only", "-z", before, "HEAD", "--",
                     "lychee.toml", ".github/workflows/links.yml")
    except subprocess.CalledProcessError:
        return FULL, "full"

    if config:
        return FULL, "full"

    paths = [os.fsdecode(path) for path in changed.split(b"\0") if path]
    # --files-from is line-based and interprets globs. Such names cannot be
    # represented literally there, so let the full glob discover them.
    if any(any(char in path for char in "\r\n*?[]{}\\") or
           path.encode("utf-8", errors="replace").decode("utf-8") != path
           for path in paths):
        return FULL, "full"
    if not paths:
        return "", "none"
    return "".join("./" + path + "\n" for path in paths), "changed"


def main():
    listing, scope = inputs(os.environ.get("GITHUB_EVENT_NAME", ""),
                            os.environ.get("BEFORE", ""))
    Path(os.environ["RUNNER_TEMP"], "lychee-inputs.txt").write_text(listing)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write("scope=" + scope + "\n")


if __name__ == "__main__":
    main()
