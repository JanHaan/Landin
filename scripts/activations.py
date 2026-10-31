#!/usr/bin/env python3
"""What an item's changes activate: register rows, and passes only the gate runs.

Many rows in ROADMAP.md's register wait for "the next change to" a file or
an area, and an item that changes one closes without noticing unless
someone diffs its range against every row's activation.  This does that
diff.  It reads the Activation column of every `open` or `scheduled` row,
finds the paths it names, and lists the rows whose paths the item changed,
so each is taken, or its activation restated, before the item closes.

It is a heuristic, and says so.  A path is found when an activation
writes it -- in backticks or bare -- as a tracked file, a tracked
directory, the base name of a tracked file (`debug.sh`, when no tracked
file is that exact path), or an Ada unit (`Landin.Driver.Usage`, its
`.ads` and `.adb`), and AREAS gives a path to the few names of an area
that activations use for one file.  Any other activation that names an
area in words, "the next change to the Cortex-M lane runner", has no path
to match; the count of such rows is printed, and --unmatched lists them
to be read by hand.

It also names the passes the gate runs and no local check does, when the
changes reach their inputs: the editor grammar's corpus, and the flake.
--run runs those passes, from inside `nix develop`.

The changes are `git diff --name-only BASE...HEAD`, the commits since HEAD
left BASE, together with the uncommitted ones: staged, unstaged and
untracked files.  PATH arguments replace all of that.

    python3 scripts/activations.py [--base REV] [--unmatched] [--run] [PATH ...]

BASE defaults to `main`.  The exit status is 0 whatever is listed, unless
--run was given and a pass failed.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATUSES = ("open", "scheduled")
ROW = re.compile(r"^\| ((?:R551|R730|SR)-\d+|[A-Z]\d+) \| ")

#  Where a written word stops being part of a path: sentence punctuation
#  after it, and a parenthesis or quote around it.
TRIM = ".,;:()'\"*"
PATHLIKE = re.compile(r"(?<![\w`/.-])((?:[\w.-]+/)+[\w.-]*|[\w-]+\.(?:py|sh|md|nix|lock|json|"
                      r"yml|yaml|toml|gpr|ads|adb|ldn|txt|svd|el|lua|scm|js))(?![\w/-])")
ADA_UNIT = re.compile(r"\bLandin(?:\.[A-Z]\w*)+")

#  Names of an area that always mean one path.  Only a name no other
#  area shares belongs here: a wrong path lists a row nobody needs to read,
#  which is how a list like this stops being read.
AREAS = (
    (re.compile(r"\b(?:dev|development) shell\b|\bthe flake\b|\bflake change\b"), "flake.nix"),
    (re.compile(r"\bkernel(?:'s)? grammar\b"), "spec.md"),
)

#  Passes only the gate runs, by the paths whose change calls for each.
PASSES = (
    ("the editor grammar's corpus, the gate's editor-grammar job",
     ("highlight/tree-sitter/", "spec.md", "compiler/tests/fixtures/positive/",
      "compiler/tests/fixtures/runtime/", "compiler/tests/fixtures/abi/", "core/"),
     (("./highlight/test.sh", "--integration"),)),
    ("the flake, the gate's flake job",
     ("flake.nix", "flake.lock", "environments/pins.sh"),
     (("nix", "build", "--no-link", ".#refine", ".#refine-bin"),
      ("nix", "flake", "check", "--no-build", "--all-systems"))),
)


def git(*arguments, root=ROOT):
    return subprocess.run(["git", *arguments], cwd=root, check=True,
                          stdout=subprocess.PIPE, text=True).stdout


def register(text):
    """(identity, activation, status) of every row of TEXT's register."""
    section = text.split("\n## Register\n", 1)
    if len(section) != 2:
        raise ValueError("ROADMAP.md has no `## Register` section")
    section = section[1].split("\n## ", 1)[0]
    rows = []
    for line in section.splitlines():
        if not ROW.match(line):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split(" | ")]
        if len(cells) != 6:
            raise ValueError("a register row without six cells: " + cells[0])
        rows.append((cells[0], cells[3], cells[5]))
    return rows


def words(activation):
    """The words of ACTIVATION that could be paths, in order, once each."""
    found = []
    for quoted in re.findall(r"`([^`]+)`", activation):
        found.extend(quoted.split())
    bare = re.sub(r"`[^`]*`", " ", activation)
    found.extend(match.group(1) for match in PATHLIKE.finditer(bare))
    found.extend(ADA_UNIT.findall(activation))
    found.extend(path for pattern, path in AREAS if pattern.search(activation))
    seen = []
    for word in found:
        word = word.strip(TRIM)
        if word.startswith("./"):
            word = word[2:]
        if word and word not in seen:
            seen.append(word)
    return seen


def resolve(word, tracked, directories):
    """The tracked paths WORD names: files, and directories ending in `/`."""
    if ADA_UNIT.fullmatch(word):
        stem = word.lower().replace(".", "-")
        return sorted(path for path in tracked
                      if os.path.basename(path) in (stem + ".ads", stem + ".adb"))
    word = word.rstrip("/")
    if word in tracked:
        return [word]
    if word in directories:
        return [word + "/"]
    if "/" not in word and "." in word:
        return sorted(path for path in tracked if os.path.basename(path) == word)
    return []


def touched(named, changed):
    """The CHANGED paths that NAMED, a file or a directory, covers."""
    if named.endswith("/"):
        return [path for path in changed if path.startswith(named)]
    return [path for path in changed if path == named]


def activated(rows, tracked, changed):
    """(rows the changes activate, rows that name no path at all).

    An activated row is (identity, status, changed paths, activation).
    """
    directories = set()
    for path in tracked:
        parts = path.split("/")[:-1]
        for end in range(1, len(parts) + 1):
            directories.add("/".join(parts[:end]))
    hits, unmatched = [], []
    for identity, activation, status in rows:
        if status.split(" ", 1)[0] not in STATUSES:
            continue
        named = [path for word in words(activation)
                 for path in resolve(word, tracked, directories)]
        if not named:
            unmatched.append((identity, status, activation))
            continue
        reached = sorted({path for one in named for path in touched(one, changed)})
        if reached:
            hits.append((identity, status, reached, activation))
    return hits, unmatched


def passes(changed):
    """(description, commands) of each gate-only pass the changes call for."""
    called = []
    for description, prefixes, commands in PASSES:
        if any(path == prefix or (prefix.endswith("/") and path.startswith(prefix))
               for path in changed for prefix in prefixes):
            called.append((description, commands))
    return called


def changes(base, root=ROOT):
    """The paths changed since HEAD left BASE, and those not yet committed."""
    lines = git("diff", "--name-only", "--no-renames", base + "...HEAD", root=root)
    lines += git("diff", "--name-only", "--no-renames", "HEAD", root=root)
    lines += git("ls-files", "--others", "--exclude-standard", root=root)
    return sorted({line for line in lines.splitlines() if line})


def main(argv=None, root=ROOT, out=sys.stdout):
    parser = argparse.ArgumentParser(
        description="List the open and scheduled register rows whose "
                    "activation names a path the changes touch, and the "
                    "gate-only passes they call for.")
    parser.add_argument("--base", default="main",
                        help="the revision the item started from (default main)")
    parser.add_argument("--unmatched", action="store_true",
                        help="also list the rows whose activation names no path")
    parser.add_argument("--run", action="store_true",
                        help="run the gate-only passes the changes call for")
    parser.add_argument("paths", nargs="*", metavar="PATH",
                        help="changed paths, instead of asking git")
    args = parser.parse_args(argv)
    changed = sorted(set(args.paths)) if args.paths else changes(args.base, root)
    tracked = set(git("ls-files", root=root).splitlines())
    rows = register((root / "ROADMAP.md").read_text(encoding="utf-8"))
    hits, unmatched = activated(rows, tracked, changed)
    source = "the paths given" if args.paths else "changes since %s" % args.base
    print("%d changed paths (%s)" % (len(changed), source), file=out)
    if hits:
        print("\nRegister rows whose activation names a changed path; take each,"
              "\nor restate its activation, before the item closes:", file=out)
    for identity, status, reached, activation in hits:
        print("\n%s (%s): %s\n    activation: %s"
              % (identity, status, ", ".join(reached), activation), file=out)
    if not hits:
        print("\nNo open or scheduled row's activation names a changed path.", file=out)
    print("\n%d open or scheduled rows name no path this can match; read their"
          " activations by hand%s." % (len(unmatched),
                                       "" if args.unmatched else " (--unmatched lists them)"),
          file=out)
    for identity, status, activation in unmatched if args.unmatched else ():
        print("  %s (%s): %s" % (identity, status, activation), file=out)
    called = passes(changed)
    for description, commands in called:
        print("\nThe changes reach %s; run, inside nix develop:" % description, file=out)
        for command in commands:
            print("    " + " ".join(command), file=out)
    if not args.run:
        return 0
    status = 0
    for description, commands in called:
        for command in commands:
            print("\nactivations: running " + " ".join(command), file=out, flush=True)
            if subprocess.run(command, cwd=root).returncode != 0:
                print("activations: %s failed" % description, file=out)
                status = 1
                break
    return status


if __name__ == "__main__":
    sys.exit(main())
