#!/usr/bin/env python3
"""What an Ada unit of the compiler links: its closure over `with` clauses.

A unit's closure is the unit, every unit its spec or body withs, and the
parent of every child unit, taken transitively over the sources under
`compiler/ada/src/`.  The Ada and GNAT run-time and the C sources are left
out: every executable carries them.  The closure over-approximates what a
command runs, since it counts every package that is linked whether or not
its code is called, but it is exactly what one `with` edge decides, which
is what a split command pays for (D1386).

    python3 scripts/unit_closure.py Landin.Source_Maps
    python3 scripts/unit_closure.py --list Landin.Library
    python3 scripts/unit_closure.py --cut Landin.Commands \\
        --objects compiler/ada/build/TAG/release/lib-obj Landin.Library

Several roots give one closure, the closure of a command whose code names
those units.  `--cut UNIT` leaves a unit out and does not follow its
withs: `Landin.Driver` and `Landin.Commands` name every command, so a
measure of one command's code cuts them.  A cut no link can honour is
refused: a unit that is the parent, or any ancestor, of a unit the closure
keeps, since an Ada partition holding a child holds its parent's body and
everything that body withs (D1423).  `--cut Landin.Commands
Landin.Commands.Devices` would report a closure no executable has; the
refusal names the kept child and what the parent brings back.  `--objects DIR`, a build tree's
`lib-obj`, adds the size of the closure's `.text` sections (`size -A`),
the number the command inventory measured, and reads the units the build
generated, `Landin.Build_Identity` among them, from the tree's
`generated`.  `--json` prints the result as one object.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "compiler/ada/src"

_UNIT_START = re.compile(
    r"^(?:private\s+)?(?:package|procedure|function|generic|separate)\b",
    re.IGNORECASE)
_WITH = re.compile(
    r"^\s*(?:limited\s+)?(?:private\s+)?with\s+([\w.\s,]+?)\s*;",
    re.IGNORECASE)
_NAME = re.compile(
    r"^(?:private\s+)?(?:package|procedure|function)\s+(?:body\s+)?"
    r"([\w.]+)", re.IGNORECASE | re.MULTILINE)


class Unit:
    def __init__(self, key):
        self.key = key
        self.name = key
        self.files = []
        self.withs = set()


def _context_withs(text):
    """The unit names of a file's context clause."""
    names = set()
    for line in text.splitlines():
        code = line.split("--", 1)[0]
        if _UNIT_START.match(code):
            break
        found = _WITH.match(code)
        if found:
            for name in found.group(1).split(","):
                names.add(name.strip().lower())
    return names


def read_units(*sources):
    """Every unit under `sources`, keyed by its lower-case name."""
    units = {}
    paths = [path for directory in (sources or (SOURCES,))
             for path in sorted(directory.rglob("*.ad[sb]"))]
    for path in paths:
        key = path.stem.replace("-", ".").lower()
        unit = units.setdefault(key, Unit(key))
        text = path.read_text(encoding="utf-8")
        unit.files.append(path)
        unit.withs |= _context_withs(text)
        declared = _NAME.search(text)
        if declared and declared.group(1).lower() == key:
            unit.name = declared.group(1)
    for unit in units.values():
        parent = unit.key.rpartition(".")[0]
        if parent:
            unit.withs.add(parent)
        unit.withs = {name for name in unit.withs
                      if name in units and name != unit.key}
    return units


class CutError(ValueError):
    """A cut that no link can honour: an ancestor of a unit kept."""


def _follow(units, roots, cut):
    seen = set()
    pending = list(roots)
    while pending:
        key = pending.pop()
        if key in seen or key in cut:
            continue
        seen.add(key)
        pending.extend(units[key].withs - seen)
    return seen


def closure(units, roots, cut=()):
    """The keys of the units `roots` link, without the `cut` ones.

    Raises CutError when a cut unit is an ancestor of one the closure
    keeps: a partition that holds a child holds its parent's body, and
    what that body withs, so the closure would be one no link has."""
    cut = {name.lower() for name in cut}
    roots = [name.lower() for name in roots]
    for name in [*roots, *sorted(cut)]:
        if name not in units:
            raise KeyError(f"no unit {name} in the compiler's sources")
    seen = _follow(units, roots, cut)
    for parent in sorted(cut):
        children = sorted(units[key].name for key in seen
                          if key.startswith(parent + "."))
        if children:
            whole = _follow(units, roots, cut - {parent})
            named = ", ".join(children[:3]) + (
                f" and {len(children) - 3} more" if len(children) > 3 else "")
            raise CutError(
                f"--cut {units[parent].name}: the closure keeps its"
                f" {'children' if len(children) > 1 else 'child'} {named},"
                f" and an Ada partition that holds a child holds its"
                f" parent's body and everything that body withs (D1423),"
                f" so a real link brings {units[parent].name} back:"
                f" {len(whole)} units, not {len(seen)}.  Drop the cut, or"
                f" cut a unit that no kept unit is a child of")
    return seen


def text_size(objects, unit):
    """The bytes of a unit's `.text` sections in `objects`, or None."""
    obj = objects / (unit.files[0].stem + ".o")
    if not obj.is_file():
        return None
    listing = subprocess.run(["size", "-A", str(obj)], check=True,
                             capture_output=True, text=True).stdout
    total = 0
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0].startswith(".text"):
            total += int(fields[1])
    return total


def measure(roots, cut=(), objects=None, sources=(SOURCES,)):
    if objects is not None and (objects.parent / "generated").is_dir():
        sources = (*sources, objects.parent / "generated")
    units = read_units(*sources)
    keys = closure(units, roots, cut)
    members = sorted(units[key].name for key in keys)
    lines = sum(len(path.read_text(encoding="utf-8").splitlines())
                for key in keys for path in units[key].files)
    result = {"roots": list(roots), "cut": list(cut),
              "units": len(keys), "lines": lines, "members": members}
    if objects is not None:
        sizes = {key: text_size(objects, units[key]) for key in keys}
        missing = sorted(units[key].name for key, size in sizes.items()
                         if size is None)
        result["text"] = sum(size for size in sizes.values() if size)
        result["without_object"] = missing
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("roots", nargs="+", metavar="UNIT")
    parser.add_argument("--cut", action="append", default=[],
                        metavar="UNIT", help="leave UNIT out")
    parser.add_argument("--objects", type=Path, metavar="DIR",
                        help="a build tree's lib-obj, for .text sizes")
    parser.add_argument("--list", action="store_true",
                        help="name every unit of the closure")
    parser.add_argument("--json", action="store_true")
    options = parser.parse_args(argv)
    if options.objects is not None and not options.objects.is_dir():
        parser.error(f"--objects {options.objects}: no such directory; "
                     "build a tree with ./scripts/dev-build.sh first")
    try:
        result = measure(options.roots, options.cut, options.objects)
    except KeyError as missing:
        parser.error(missing.args[0])
    except CutError as refused:
        parser.error(str(refused))
    if options.json:
        print(json.dumps(result, indent=2))
        return 0
    summary = f"{result['units']} units, {result['lines']} lines"
    if "text" in result:
        summary += f", {result['text']} B .text"
    print(summary)
    if result.get("without_object"):
        print("no object for: " + ", ".join(result["without_object"]))
    if options.list:
        for name in result["members"]:
            print("  " + name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
