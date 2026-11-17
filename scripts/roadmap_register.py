#!/usr/bin/env python3
"""Move the second roadmap's register table into one file per row.

The second roadmap kept its register as one Markdown table in ROADMAP.md,
345 rows of which 193 were retired.  The third keeps each live row as a
file, `roadmap/register/<identity>.md`, and this script made the move: it
reads the table from a ROADMAP.md that still has one, and writes a file for
every row that is not retired, keeping its identity and applying no
judgement.  Retired rows stay in the history and get no file.

    python3 scripts/roadmap_register.py ROADMAP-WITH-TABLE OUTPUT-DIRECTORY

A row's file is its front matter, then what stands, then what completes it:

    ---
    family: Usability
    status: open
    opened: 2026-11-14
    activation: The next change to the corpus runner's options.
    ---

    What stands, as the row said it.

    Completion: what the row said would complete it.

The old statuses map without judgement: `open` and `scheduled ...` stay as
they were; `limit` and `watch` become `open` with that word as the row's
`kind`, which the new register spells out.  `opened` is the date of the
first commit whose ROADMAP.md added a table row with the identity, read
from one log of ROADMAP.md; a row older than the table's form is dated by
the first commit anywhere that wrote its identity.  The script refuses to
overwrite a file that exists, so a second run cannot change a moved row.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADING = "\n## Register\n"
COLUMNS = ("Record", "Family", "What stands", "Activation", "Completion",
           "Status")
ROW = re.compile(r"^\| ((?:R551|R730|SR)-\d+|[A-F]\d) \| ")


def table(text):
    """[{column: cell}] of every row of TEXT's register table, in order."""
    parts = text.split(HEADING, 1)
    if len(parts) != 2:
        raise ValueError("no `## Register` section")
    rows = []
    for line in parts[1].split("\n## ", 1)[0].splitlines():
        if not ROW.match(line):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split(" | ")]
        if len(cells) != len(COLUMNS):
            raise ValueError("a register row without six cells: " + cells[0])
        rows.append(dict(zip(COLUMNS, cells)))
    return rows


def front_status(status):
    """(status, kind or None) for the new register, from an old status."""
    if status in ("limit", "watch"):
        return "open", status
    if status == "open" or re.fullmatch(r"scheduled R\d+\.\d+(?:, R\d+\.\d+)*",
                                        status):
        return status, None
    raise ValueError("not a live status: %r" % status)


def first_dates(identities, root=ROOT):
    """{identity: the date of the first commit that added its table row}."""
    log = subprocess.run(
        ["git", "log", "--reverse", "--format=%x00%as", "-p", "-U0",
         "--no-color", "--no-ext-diff", "--no-renames", "--", "ROADMAP.md"],
        cwd=root, check=True, stdout=subprocess.PIPE, text=True).stdout
    wanted = set(identities)
    found = {}
    for chunk in log.split("\0")[1:]:
        date, _, diff = chunk.partition("\n")
        for line in diff.splitlines():
            if line.startswith("+| "):
                match = ROW.match(line[1:])
                if match and match.group(1) in wanted \
                        and match.group(1) not in found:
                    found[match.group(1)] = date.strip()
    for identity in sorted(wanted - set(found)):
        first = subprocess.run(
            ["git", "log", "--reverse", "--format=%as", "-S", identity],
            cwd=root, check=True, stdout=subprocess.PIPE, text=True).stdout
        if first.split():
            found[identity] = first.split()[0]
    return found


def render(row, opened):
    """The text of ROW's file."""
    status, kind = front_status(row["Status"])
    lines = ["---"]
    if kind:
        lines.append("kind: " + kind)
    lines += ["family: " + row["Family"], "status: " + status,
              "opened: " + opened, "activation: " + row["Activation"], "---",
              "", row["What stands"], "", "Completion: " + row["Completion"],
              ""]
    return "\n".join(lines)


def move(roadmap, directory, dates=None, root=ROOT):
    """Write every live row of ROADMAP's table into DIRECTORY; the paths."""
    rows = [row for row in table(roadmap.read_text(encoding="utf-8"))
            if not row["Status"].startswith("retired")]
    if dates is None:
        dates = first_dates([row["Record"] for row in rows], root)
    missing = [row["Record"] for row in rows if row["Record"] not in dates]
    if missing:
        raise ValueError("no history dates " + ", ".join(missing))
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for row in rows:
        path = directory / (row["Record"] + ".md")
        if path.exists():
            raise ValueError("%s exists; a moved row is not moved again" % path)
        path.write_text(render(row, dates[row["Record"]]), encoding="utf-8")
        written.append(path)
    return written


def main(argv):
    if len(argv) != 2:
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        return 2
    try:
        written = move(Path(argv[0]), Path(argv[1]))
    except ValueError as error:
        print("roadmap_register: %s" % error, file=sys.stderr)
        return 1
    print("wrote %d rows into %s" % (len(written), argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
