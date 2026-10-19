#!/usr/bin/env python3
"""Check or regenerate where the debugger sessions' expected frames live.

`workload-frames.json` is what the GDB sessions in check.py and the LLDB
sessions in darwin_workloads.py expect each complete workload's stack to
hold at each stop, innermost first, under `stops`, and the routines every
stop of a workload also passes through under `beneath`.  Its `declared`
names the file that declares each of those routines, found among the
workload's sources in `workload-sources.json`.  The test program's
`debugger session frames are declared` reads every routine in the file it
names on every run, so renaming or removing a routine a session stops in
fails where the library changes, not only in the gate's debugger jobs.

This computes `declared` from the stops and the closures, prints every
entry that differs, and with --write rewrites it:

    python3 compiler/tests/debugging/workload_frames.py --write

A moved routine is found again; a renamed one is not, and the stops that
name it are edited by hand, here, for both debuggers at once.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
RECORD = HERE / "workload-frames.json"
SOURCES = HERE / "workload-sources.json"


def declares(text: str, routine: str) -> bool:
    """Whether a Landin source declares `routine` at its top level."""
    return re.search(r"^(?:public\s+)?%s\s*:" % re.escape(routine), text,
                     re.M) is not None


def routines(entry: dict) -> list[str]:
    """Every routine one workload's sessions expect, once, in order."""
    seen: list[str] = []
    for stack in entry["stops"].values():
        for routine in stack:
            if routine not in seen:
                seen.append(routine)
    for routine in entry.get("beneath", []):
        if routine not in seen:
            seen.append(routine)
    return seen


def computed(record: dict, closures: dict, root: Path = ROOT):
    """(declared per workload, problems), the way --write would write it."""
    result: dict[str, dict[str, str]] = {}
    problems: list[str] = []
    for workload, entry in record.items():
        texts = {}
        for source in closures.get(workload, []):
            path = root / source
            if path.suffix == ".ldn" and path.is_file():
                texts[source] = path.read_text(encoding="utf-8")
        if not texts:
            problems.append(f"{workload}: workload-sources.json records no"
                            " sources for it")
        declared: dict[str, str] = {}
        for routine in routines(entry):
            found = sorted(source for source, text in texts.items()
                           if declares(text, routine))
            recorded = entry.get("declared", {}).get(routine)
            if len(found) == 1:
                declared[routine] = found[0]
            elif recorded in found:
                declared[routine] = recorded
            elif not found:
                problems.append(f"{workload}: no source the workload is built"
                                f" from declares {routine}")
            else:
                problems.append(f"{workload}: {routine} is declared in"
                                f" {', '.join(found)}; name the one meant in"
                                f" {RECORD.name} by hand")
        result[workload] = declared
    return result, problems


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true",
                        help="rewrite the record's declared files")
    args = parser.parse_args()
    record = json.loads(RECORD.read_text())
    closures = json.loads(SOURCES.read_text())
    declared, problems = computed(record, closures)
    differs = False
    for workload, entry in record.items():
        before = entry.get("declared", {})
        for routine in sorted(set(before) | set(declared[workload])):
            if before.get(routine) != declared[workload].get(routine):
                print(f"{workload}: {routine}: {before.get(routine)}"
                      f" -> {declared[workload].get(routine)}")
                differs = True
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    if args.write:
        if differs:
            for workload, entry in record.items():
                entry["declared"] = declared[workload]
            RECORD.write_text(json.dumps(record, indent=2) + "\n")
            print(f"wrote {RECORD.relative_to(ROOT)}")
        else:
            print(f"{RECORD.relative_to(ROOT)} is current")
        return 0
    if differs:
        print(f"{RECORD.relative_to(ROOT)} differs; rerun with --write to"
              " rewrite it", file=sys.stderr)
        return 1
    print(f"{RECORD.relative_to(ROOT)} is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
