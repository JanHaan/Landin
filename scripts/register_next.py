#!/usr/bin/env python3
"""Allocate the next register or question identities, and file them.

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
`python3 check.py` refuses the file until they are filled in.

    python3 scripts/register_next.py --question --file --asked-by ITEM

does the same for a question for the maintainer, Q-n, under
`roadmap/questions/`: the next number past every question file this
repository has had, and with `--file` a file with the parts `ROADMAP.md`'s
Mechanics ask for, each a `TODO` that `python3 check.py` refuses.  Two branches
that take the same number collide as an add/add conflict on the file when
they meet: that is the detection, and the integrator renumbers the later
one.  The numbers are only proposed; a number becomes taken when its file
is committed.

Items started with `scripts/item.py start` reserve blocks of numbers, kept
in the clone's item state.  Run from a running item's worktree, this gives
out that item's own block first; from anywhere it skips every other running
item's block, so two items of one clone do not propose the same number.
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
QUESTION_DIRECTORY = "roadmap/questions"
QUESTION_NUMBER = re.compile(r"Q-(\d+)\.md")
QUESTION_TEMPLATE = """# {identity} — TODO, the question?

Asked by {asker} on {date}.

TODO: what the maintainer needs to decide it, and why it is theirs.

**Options:**

1. TODO
2. TODO

**Recommendation:** TODO

**Default until answered:** TODO, in words, not an option's number alone.

**What waits on the answer:** TODO, or nothing.
"""
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


def numbers_in(names, number=NUMBER):
    """The numbers of the file names among NAMES that NUMBER matches."""
    return {int(found.group(1)) for name in names
            for found in [number.fullmatch(os.path.basename(name.strip()))]
            if found}


def taken(root, question=False):
    """Every number the register, or the questions, have used, here and in
    the history."""
    directory_name, number = ((QUESTION_DIRECTORY, QUESTION_NUMBER)
                              if question else (DIRECTORY, NUMBER))
    used = {0 if question else SECOND_ROADMAP_LAST}
    directory = Path(root) / directory_name
    if directory.is_dir():
        used |= numbers_in((path.name for path in directory.iterdir()),
                           number)
    try:
        log = subprocess.run(
            ["git", "log", "--all", "--format=", "--name-only",
             "--diff-filter=A", "--", directory_name], cwd=root,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        print("register_next.py: the history cannot be read (%s); counting"
              " the files alone" % error, file=sys.stderr)
    else:
        used |= numbers_in(log.stdout.decode("utf-8").splitlines(), number)
    return used


def blocks(root, question=False):
    """The reserved blocks: the running item's own, and every other's.

    Each is a list of (low, high).  Outside a Git clone, or with no item
    running, both are empty.
    """
    kind = "Q" if question else "SR"
    sys.path.insert(0, str(ROOT / "scripts"))
    import item
    try:
        mine = item.item_of_branch(root)
        own, others = [], []
        for state in item.running_states(root):
            low, high = state.get("reserved", {}).get(kind, (None, None))
            if low is not None:
                (own if state["item"] == mine else others).append((low, high))
        return own, others
    except (OSError, ValueError, item.Refused):
        return [], []


def allocate(root, count, question=False):
    """The next COUNT identities, in order: the running item's reserved
    block first, then past every number used or reserved."""
    used = taken(root, question)
    own, others = blocks(root, question)
    numbers = [n for low, high in own for n in range(low, high + 1)
               if n not in used][:count]
    start = max(used | {high for _, high in own + others}) + 1
    numbers += range(start, start + count - len(numbers))
    return [("Q-%d" if question else "SR-%d") % n for n in numbers]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("count", nargs="?", type=int, default=1,
                        help="how many identities (default 1)")
    parser.add_argument("--file", action="store_true",
                        help="write each row's file with its keys to fill")
    parser.add_argument("--question", action="store_true",
                        help="a question for the maintainer, Q-n, rather"
                        " than a register row")
    parser.add_argument("--asked-by", metavar="ITEM", default="TODO",
                        help="with --question --file, the item asking it")
    parser.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
    arguments = parser.parse_args(argv)
    if arguments.count < 1:
        parser.error("count must be at least 1")
    identities = allocate(arguments.root, arguments.count, arguments.question)
    date = datetime.date.today().isoformat()
    for identity in identities:
        if arguments.file:
            if arguments.question:
                path = (Path(arguments.root) / QUESTION_DIRECTORY
                        / (identity + ".md"))
                path.parent.mkdir(parents=True, exist_ok=True)
                text = QUESTION_TEMPLATE.format(
                    identity=identity, asker=arguments.asked_by, date=date)
            else:
                path = Path(arguments.root) / DIRECTORY / (identity + ".md")
                text = TEMPLATE.format(date=date)
            path.write_text(text, encoding="utf-8")
            print(path.relative_to(arguments.root))
        else:
            print(identity)
    return 0


if __name__ == "__main__":
    sys.exit(main())
