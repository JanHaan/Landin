#!/usr/bin/env python3
"""Check or regenerate the debugger workloads' committed source closures.

`workload-sources.json` records, for each complete debugger workload, every
source file its program is built from.  The GDB and LLDB sessions hold each
build to it, and the test program's `debugger workload inventories are
their closures` compares it on every run, so a library file added to a
module the workloads import is named where the change is made.  This
computes each closure the way both do, from the build report a compile
writes, prints every file that differs, and with --write rewrites the
record:

    python3 compiler/tests/debugging/workload_sources.py \\
        --refine compiler/ada/build/TAG/MODE/bin/refine --write

Review the difference it prints: a file the workloads did not import before
is a change to what the debugger sessions cover.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
RECORD = HERE / "workload-sources.json"
#  Each workload's entry fixture, as check.py, darwin_workloads.py and the
#  test program name them.
WORKLOADS = {
    "parser": "compiler/tests/fixtures/runtime/derived-parser",
    "containers": "compiler/tests/fixtures/runtime/derived-containers",
    "hosted": "compiler/tests/fixtures/runtime/derived-hosted-memory",
}


def closure(refine: Path, workload: str, scratch: Path) -> list[str]:
    """The sorted repository-relative sources one workload's build reads."""
    report = scratch / f"{workload}.json"
    completed = subprocess.run(
        [str(refine), "compile", "--target=linux-x86-64", WORKLOADS[workload],
         "--root=.", "--emit=asm", "-o", str(scratch / f"{workload}.s"),
         "--optimize=none", "--specialize=off", f"--build-report={report}"],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        check=False)
    if completed.returncode != 0:
        raise SystemExit(f"the {workload} workload did not compile:\n"
                         + completed.stdout)
    sources = json.loads(report.read_text())["sources"]
    return sorted(os.path.normpath(os.fsdecode(bytes.fromhex(entry["path_hex"])))
                  for entry in sources)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--refine", type=Path, required=True,
                        help="the built compiler, e.g. compiler/ada/build/TAG/debug/bin/refine")
    parser.add_argument("--write", action="store_true",
                        help="rewrite workload-sources.json with the computed closures")
    args = parser.parse_args()
    refine = args.refine.resolve(strict=True)
    recorded = json.loads(RECORD.read_text())
    with tempfile.TemporaryDirectory(prefix="workload-sources-") as directory:
        computed = {name: closure(refine, name, Path(directory))
                    for name in WORKLOADS}
    differs = False
    for name, sources in computed.items():
        wanted = set(recorded.get(name, []))
        for source in sorted(set(sources) - wanted):
            print(f"{name}: added   {source}")
            differs = True
        for source in sorted(wanted - set(sources)):
            print(f"{name}: removed {source}")
            differs = True
    if set(recorded) != set(computed):
        print("workloads recorded: " + ", ".join(sorted(recorded))
              + "; run: " + ", ".join(sorted(computed)))
        differs = True
    if args.write:
        if differs:
            RECORD.write_text(json.dumps(computed, indent=2) + "\n")
            print(f"wrote {RECORD.relative_to(ROOT)}")
        else:
            print(f"{RECORD.relative_to(ROOT)} is current")
        return 0
    if differs:
        print(f"{RECORD.relative_to(ROOT)} differs; rerun with --write to rewrite it",
              file=sys.stderr)
        return 1
    print(f"{RECORD.relative_to(ROOT)} is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
