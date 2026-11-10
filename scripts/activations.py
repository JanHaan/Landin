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
directory, the base name of exactly one tracked file (`debug.sh`, when no
tracked file is that exact path), or an Ada unit (`Landin.Driver.Usage`,
its `.ads` and `.adb`), and AREAS gives a path to the few names of an area
that activations use for one file.  Any other activation that names an
area in words, "the next change to the Cortex-M lane runner", has no path
to match; the count of such rows is printed, and --unmatched lists them
to be read by hand.

A base name several tracked files share, `run.py`, is not matched: a row
meaning `environments/boards/run.py` was once listed as met by a change
to `environments/cortex-m/run.py`.  Each such name is reported with the
files it could mean, so the row can spell the path.

A directory written as the owner of something narrower, "`core/io`'s
`make_temporary`", is matched by every change under it, most of which do
not concern the row.  A row that only such a directory matched is listed
apart, as one to read, not one the changes are known to meet.

It also names the passes the gate runs and no local check does, when the
changes reach their inputs: the editor grammar's corpus, and the flake.
--run runs those passes, from inside `nix develop`.

The changes are `git diff --name-only BASE...HEAD`, the commits since HEAD
left BASE, together with the uncommitted ones: staged, unstaged and
untracked files.  PATH arguments replace all of that.

A row counts only the changes made after it was written.  When a commit
since BASE added the row or changed its Activation cell, a committed
change meets the row only if that commit is not among the change's
ancestors: a change the row's writer had already seen is what the row was
written about, and over a long window about half the matches were such
changes.  Uncommitted changes always count.  Each listed row names the
commits that met it, and the rows left out for this are named, so either
can be read; --whole-window counts every change since BASE for every row.

A commit made on a parallel branch is not among the statement's
descendants whenever it was made, before the row or after it, so it
counts; but it may be the very change the row records, merged later.
Such a commit is marked in "met by" with the merge that brought it in.

    python3 scripts/activations.py [--base REV] [--unmatched] [--run]
                                   [--whole-window] [PATH ...]

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


def owners(activation):
    """The words ACTIVATION writes as the owner of something: `X`'s, X's."""
    found = re.findall(r"`([^`\s]+)`'s\b", activation)
    bare = re.sub(r"`[^`]*`", " ", activation)
    found.extend(match.group(1) for match in PATHLIKE.finditer(bare)
                 if bare.startswith("'s", match.end()))
    return {word.strip(TRIM).removeprefix("./").rstrip("/") for word in found}


def resolve(word, tracked, directories):
    """(the tracked paths WORD names, the files it could mean but does not).

    Paths are files, and directories ending in `/`.  A base name that
    several tracked files share names none of them: they are the second
    value, for the report.
    """
    if ADA_UNIT.fullmatch(word):
        stem = word.lower().replace(".", "-")
        return sorted(path for path in tracked
                      if os.path.basename(path) in (stem + ".ads", stem + ".adb")), []
    word = word.rstrip("/")
    if word in tracked:
        return [word], []
    if word in directories:
        return [word + "/"], []
    if "/" not in word and "." in word:
        found = sorted(path for path in tracked if os.path.basename(path) == word)
        return (found, []) if len(found) <= 1 else ([], found)
    return [], []


def touched(named, changed):
    """The CHANGED paths that NAMED, a file or a directory, covers."""
    if named.endswith("/"):
        return [path for path in changed if path.startswith(named)]
    return [path for path in changed if path == named]


def activated(rows, tracked, changed):
    """(rows the changes activate, rows that name no path at all, the
    ambiguous base names, the rows only an owning directory matched).

    An activated row is (identity, status, changed paths, activation).  An
    ambiguous name is (identity, word, the files it could mean).  The last
    value is {identity: directories}: activated rows every changed path of
    which is under a directory the activation names only as an owner.
    """
    directories = set()
    for path in tracked:
        parts = path.split("/")[:-1]
        for end in range(1, len(parts) + 1):
            directories.add("/".join(parts[:end]))
    hits, unmatched, ambiguous, narrower = [], [], [], {}
    for identity, activation, status in rows:
        if status.split(" ", 1)[0] not in STATUSES:
            continue
        owned = owners(activation)
        named, owning = [], []
        for word in words(activation):
            paths, candidates = resolve(word, tracked, directories)
            if candidates:
                ambiguous.append((identity, word, candidates))
            for path in paths:
                if path.endswith("/") and word.rstrip("/") in owned:
                    owning.append(path)
                else:
                    named.append(path)
        if not named and not owning:
            unmatched.append((identity, status, activation))
            continue
        reached = sorted({path for one in named for path in touched(one, changed)})
        under = sorted({path for one in owning for path in touched(one, changed)})
        if reached:
            hits.append((identity, status, reached, activation))
        elif under:
            hits.append((identity, status, under, activation))
            narrower[identity] = sorted(set(owning))
    return hits, unmatched, ambiguous, narrower


def cells(line):
    """A register row's cells, or None for a line that is not one."""
    if not ROW.match(line):
        return None
    found = [cell.strip() for cell in line.strip().strip("|").split(" | ")]
    return found if len(found) == 6 else None


def stated(window, root=ROOT):
    """{identity: the newest commit in WINDOW that added the row or changed
    its Activation}, read from one log of ROADMAP.md over the window."""
    log = git("log", "--format=%x00%H", "-p", "-U0", "--no-renames",
              "--no-merges", "--no-color", "--no-ext-diff", window, "--",
              "ROADMAP.md", root=root)
    since = {}
    for chunk in log.split("\0")[1:]:
        commit, _, diff = chunk.partition("\n")
        removed, added = {}, {}
        for line in diff.splitlines():
            if line.startswith(("---", "+++")):
                continue
            row = cells(line[1:]) if line[:1] in "+-" else None
            if row:
                (added if line[0] == "+" else removed)[row[0]] = row[3]
        for identity, activation in added.items():
            if identity not in since and removed.get(identity) != activation:
                since[identity] = commit.strip()
    return since


def history(base, root=ROOT):
    """(paths each commit since HEAD left BASE changed, the row statements
    in that window), for counting a row's changes from its own start."""
    start = git("merge-base", base, "HEAD", root=root).strip()
    window = start + "..HEAD"
    log = git("log", "--format=%x00%H", "--name-only", "--no-renames",
              window, root=root)
    commits = {}
    for chunk in log.split("\0")[1:]:
        commit, _, names = chunk.partition("\n")
        commits[commit.strip()] = {name for name in names.splitlines() if name}
    return commits, stated(window, root)


def since_statement(hits, commits, since, uncommitted, root=ROOT):
    """HITS less the paths only commits the row's own statement had seen
    changed: (kept hits with the commits that met each, rows left out).

    A hit becomes (identity, status, reached, activation, commits).  A
    commit that is not a descendant of the row's statement was made on a
    parallel branch, perhaps before the row and perhaps the change the row
    records; it is marked, with the merge that brought it in."""
    after, descend = {}, {}

    def beside(commit):
        merges = git("rev-list", "--ancestry-path", "--merges", "--reverse",
                     commit + "..HEAD", root=root).split()
        return "%s [beside the row's statement%s]" % (
            commit[:12], ", merged in " + merges[0][:12] if merges else "")
    kept, left = [], []
    for identity, status, reached, activation in hits:
        statement = since.get(identity)
        if statement is None:
            later = set(commits)
        else:
            if statement not in after:
                after[statement] = set(git(
                    "rev-list", statement + "..HEAD", root=root).split())
                descend[statement] = set(git(
                    "rev-list", "--ancestry-path", statement + "..HEAD",
                    root=root).split())
            later = after[statement] & set(commits)
        met = [path for path in reached
               if statement is None or path in uncommitted
               or any(path in commits[commit] for commit in later)]
        by = sorted(commit[:12] if statement is None
                    or commit in descend[statement] else beside(commit)
                    for commit in later
                    if any(path in commits[commit] for path in met))
        if met:
            kept.append((identity, status, met, activation, by))
        else:
            left.append((identity, statement))
    return kept, left


def passes(changed):
    """(description, commands) of each gate-only pass the changes call for."""
    called = []
    for description, prefixes, commands in PASSES:
        if any(path == prefix or (prefix.endswith("/") and path.startswith(prefix))
               for path in changed for prefix in prefixes):
            called.append((description, commands))
    return called


def uncommitted_changes(root=ROOT):
    """The paths staged, unstaged or untracked."""
    lines = git("diff", "--name-only", "--no-renames", "HEAD", root=root)
    lines += git("ls-files", "--others", "--exclude-standard", root=root)
    return {line for line in lines.splitlines() if line}


def changes(base, root=ROOT):
    """The paths changed since HEAD left BASE, and those not yet committed."""
    lines = git("diff", "--name-only", "--no-renames", base + "...HEAD", root=root)
    return sorted({line for line in lines.splitlines() if line}
                  | uncommitted_changes(root))


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
    parser.add_argument("--whole-window", action="store_true",
                        help="count every change since BASE for every row,"
                        " even one made before the row was written or its"
                        " activation last restated")
    parser.add_argument("paths", nargs="*", metavar="PATH",
                        help="changed paths, instead of asking git")
    args = parser.parse_args(argv)
    changed = sorted(set(args.paths)) if args.paths else changes(args.base, root)
    tracked = set(git("ls-files", root=root).splitlines())
    rows = register((root / "ROADMAP.md").read_text(encoding="utf-8"))
    hits, unmatched, ambiguous, narrower = activated(rows, tracked, changed)
    left = []
    if args.paths or args.whole_window:
        hits = [hit + ([],) for hit in hits]
    else:
        commits, since = history(args.base, root)
        hits, left = since_statement(hits, commits, since,
                                     uncommitted_changes(root), root)
    source = "the paths given" if args.paths else "changes since %s" % args.base
    print("%d changed paths (%s)" % (len(changed), source), file=out)

    def show(chosen):
        for identity, status, reached, activation, by in chosen:
            print("\n%s (%s): %s\n    activation: %s"
                  % (identity, status, ", ".join(reached), activation), file=out)
            if identity in narrower:
                print("    owner only: " + " ".join(narrower[identity]), file=out)
            if by:
                print("    met by: " + ", ".join(by), file=out)
    direct = [hit for hit in hits if hit[0] not in narrower]
    owned = [hit for hit in hits if hit[0] in narrower]
    if direct:
        print("\nRegister rows whose activation names a changed path; take each,"
              "\nor restate its activation, before the item closes:", file=out)
    show(direct)
    if not direct:
        print("\nNo open or scheduled row's activation names a changed path.", file=out)
    if owned:
        print("\nRows whose activation names a changed directory only as the"
              " owner of\nsomething narrower; read whether a change concerns"
              " that subject:", file=out)
    show(owned)
    if any("[beside" in commit for hit in hits for commit in hit[4]):
        print("\nA commit marked [beside the row's statement] was made on a"
              " parallel branch,\nnot on top of the commit that states the"
              " row: it may be the change the row\nrecords, merged afterwards.",
              file=out)
    if ambiguous:
        print("\n%d activations name a file by a base name several tracked"
              " files share, which\nmatches none of them; spell the path in"
              " the row:" % len(ambiguous), file=out)
    for identity, word, candidates in ambiguous:
        print("  %s: `%s` could be %s" % (identity, word, ", ".join(candidates)),
              file=out)
    if left:
        print("\n%d rows name a changed path that only commits before their"
              " own statement changed, so they are not listed"
              " (--whole-window lists them): %s"
              % (len(left), ", ".join("%s (stated in %s)"
                                      % (identity, statement[:12])
                                      for identity, statement in left)),
              file=out)
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
