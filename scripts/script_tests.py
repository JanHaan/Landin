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
which module took the time.  The exit status is 1 if any process failed,
or printed a ResourceWarning.

    python3 scripts/script_tests.py [--jobs N] [MODULE | DIRECTORY]...

With no operand every test_*.py module in scripts/tests runs.  An operand
is a directory, whose test_*.py modules run, or one module: its path, or
its name in scripts/tests with or without .py, such as test_fuzz_close.
Several operands run together in one invocation, in the order given.
--jobs defaults to the processor count, at most 16.

Each module reads its standard input from /dev/null, so whether a test
passes does not depend on what the caller's standard input is: a socket
there once made bash read its startup files in a test that ran `bash -c`.
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


DEFAULT = ROOT / "scripts" / "tests"


def modules(operands):
    """The module paths the operands name, in order, each once.

    A directory names its test_*.py modules; any other operand is one
    module, as a path or as a name in scripts/tests.  An operand naming
    nothing raises ValueError with the refusal to print."""
    paths = []
    for operand in operands or [str(DEFAULT)]:
        given = Path(operand)
        if given.is_dir():
            found = sorted(given.resolve().glob("test_*.py"))
            if not found:
                raise ValueError("%s holds no test_*.py module" % operand)
        elif given.is_file():
            found = [given.resolve()]
        else:
            name = operand if operand.endswith(".py") else operand + ".py"
            candidate = DEFAULT / name
            if "/" in operand or not candidate.is_file():
                raise ValueError(
                    "%s is neither a directory, a file nor a module in %s;"
                    " name a module such as test_fuzz_close or"
                    " scripts/tests/test_fuzz_close.py"
                    % (operand, os.path.relpath(DEFAULT, Path.cwd())))
            found = [candidate]
        for path in found:
            if path not in paths:
                paths.append(path)
    return paths


def plan(paths, shards):
    """The processes to run, each a label and its command, in log order."""
    work = []
    for path in paths:
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
    result = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    return result.returncode, result.stdout, time.monotonic() - started


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--jobs", type=int,
                        default=min(16, os.cpu_count() or 1))
    parser.add_argument("operands", nargs="*", metavar="MODULE | DIRECTORY",
                        help="a test module, by path or by its name in"
                        " scripts/tests, or a directory of them;"
                        " default scripts/tests")
    args = parser.parse_args(argv[1:])
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    try:
        paths = modules(args.operands)
    except ValueError as refusal:
        parser.error(str(refusal))
    work = plan(paths, args.jobs)
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
            elif "ResourceWarning" in output:
                #  unittest shows a file or socket left to the collector,
                #  and forty-five thousand such lines once buried the
                #  failures in this output; one is a failure here.
                failed.append("%s (left a file or socket open; see its"
                              " ResourceWarning)" % label)
    print("== %d processes at --jobs=%d in %.1f s"
          % (len(work), args.jobs, time.monotonic() - started))
    for label in failed:
        print("FAILED: %s" % label)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
