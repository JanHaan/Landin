#!/usr/bin/env python3
"""Allocate the next register identities, SR-n, and optionally file them.

A new register row takes the next SR number: one past every SR number the
register has had.  A retired or completed row has no file, so the files
alone undercount; the script also reads every file name the register
directory has had in this repository's history, on every local branch, and
the second roadmap's last number, which its retired rows took with them.

    python3 scripts/register_next.py            # the next identity
    python3 scripts/register_next.py 3          # the next three
    python3 scripts/register_next.py --file 2   # and write their files

`--file` writes `roadmap/register/SR-n.md` with the keys every row has and
`opened` set to today; it leaves each `TODO` for the writer, and
`python3 check.py` refuses the file until they are filled in.  Two branches
that take the same number collide as an add/add conflict on the file when
they meet: that is the detection, and the integrator renumbers the later
one.  The numbers are only proposed; a number becomes taken when its file
is committed.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = "roadmap/register"
#  The second roadmap's register ended at this number; its retired rows
#  were not moved into files, so no file name in the history shows it.
SECOND_ROADMAP_LAST = 1281
NUMBER = re.compile(r"SR-(\d+)\.md")
TEMPLATE = """---
kind: TODO
family: TODO
status: open
opened: {date}
activation: TODO
effort: TODO
impact: TODO
---

TODO: what stands, in a few lines.

Completion: TODO
"""


def numbers_in(names):
    """The SR numbers of the file names among NAMES."""
    return {int(found.group(1)) for name in names
            for found in [NUMBER.fullmatch(os.path.basename(name.strip()))]
            if found}


def taken(root):
    """Every SR number the register has used, here and in the history."""
    used = {SECOND_ROADMAP_LAST}
    directory = Path(root) / DIRECTORY
    if directory.is_dir():
        used |= numbers_in(path.name for path in directory.iterdir())
    try:
        log = subprocess.run(
            ["git", "log", "--all", "--format=", "--name-only",
             "--diff-filter=A", "--", DIRECTORY], cwd=root,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        print("register_next.py: the history cannot be read (%s); counting"
              " the files alone" % error, file=sys.stderr)
    else:
        used |= numbers_in(log.stdout.decode("utf-8").splitlines())
    return used


def allocate(root, count):
    """The next COUNT identities, in order."""
    start = max(taken(root)) + 1
    return ["SR-%d" % n for n in range(start, start + count)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("count", nargs="?", type=int, default=1,
                        help="how many identities (default 1)")
    parser.add_argument("--file", action="store_true",
                        help="write each row's file with its keys to fill")
    parser.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
    arguments = parser.parse_args(argv)
    if arguments.count < 1:
        parser.error("count must be at least 1")
    identities = allocate(arguments.root, arguments.count)
    for identity in identities:
        if arguments.file:
            path = Path(arguments.root) / DIRECTORY / (identity + ".md")
            path.write_text(TEMPLATE.format(
                date=datetime.date.today().isoformat()), encoding="utf-8")
            print(path.relative_to(arguments.root))
        else:
            print(identity)
    return 0


if __name__ == "__main__":
    sys.exit(main())
