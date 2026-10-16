#!/usr/bin/env python3
"""Run every scripts/tests module at once, check.py's controls in shards.

The gate's scripts job ran the modules one after another, and check.py's
controls were ten of its eleven and a half minutes: 119 independent cases,
each breaking a copy of the tree and running a check over it.  Here each
module is its own process, and a sharded module's cases are dealt round
the shards and named to its own unittest.main, so every case still runs
exactly as `python3 scripts/tests/<module>` would run it.

Output is held per process and printed whole in module order, then shard
order, with its time, so the log reads as the serial loop's did and says
which module took the time.  The exit status is 1 if any process failed.

    python3 scripts/script_tests.py [--jobs N] [directory]

--jobs defaults to the processor count, at most 16.
"""
import argparse
import concurrent.futures
import importlib.util
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

#  Modules whose cases are dealt across processes rather than run in one.
SHARDED = ("test_check_controls.py",)


def case_names(path):
    """Every case in a module as unittest.main accepts it: Class.method."""
    sys.path.insert(0, str(path.parent))
    try:
        spec = importlib.util.spec_from_file_location(path.stem, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(path.parent))
    names = []

    def walk(suite):
        for test in suite:
            if isinstance(test, unittest.TestSuite):
                walk(test)
            else:
                names.append(test.id().split(".", 1)[1])
    walk(unittest.defaultTestLoader.loadTestsFromModule(module))
    return names


def plan(directory, shards):
    """The processes to run, each a label and its command, in log order."""
    work = []
    for path in sorted(directory.glob("test_*.py")):
        label = os.path.relpath(path, ROOT)
        if path.name in SHARDED and shards > 1:
            names = case_names(path)
            count = min(shards, len(names))
            for index in range(count):
                work.append(("%s (shard %d of %d)" % (label, index + 1, count),
                             [sys.executable, str(path)] + names[index::count]))
        else:
            work.append((label, [sys.executable, str(path)]))
    return work


def run(command, cwd):
    started = time.monotonic()
    result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    return result.returncode, result.stdout, time.monotonic() - started


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--jobs", type=int,
                        default=min(16, os.cpu_count() or 1))
    parser.add_argument("directory", nargs="?", type=Path,
                        default=ROOT / "scripts" / "tests")
    args = parser.parse_args(argv[1:])
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    directory = args.directory.resolve()
    work = plan(directory, args.jobs)
    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run, command, ROOT) for _, command in work]
        failed = []
        for (label, _), future in zip(work, futures):
            status, output, seconds = future.result()
            print("== %s: %.1f s" % (label, seconds))
            sys.stdout.write(output)
            if status != 0:
                failed.append(label)
    print("== %d processes at --jobs=%d in %.1f s"
          % (len(work), args.jobs, time.monotonic() - started))
    for label in failed:
        print("FAILED: %s" % label)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
