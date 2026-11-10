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

    python3 scripts/script_tests.py [--jobs N] [--gate-environment]
                                    [MODULE | DIRECTORY]...

With no operand every test_*.py module in scripts/tests runs.  An operand
is a directory, whose test_*.py modules run, or one module: its path, or
its name in scripts/tests with or without .py, such as test_fuzz_close.
Several operands run together in one invocation, in the order given.
--jobs defaults to the processor count, at most 16.

Each module reads its standard input from /dev/null, so whether a test
passes does not depend on what the caller's standard input is: a socket
there once made bash read its startup files in a test that ran `bash -c`.

The gate's `scripts`, `release` and `arm64-release` jobs run this on a
runner, outside the development shell, and a test that leans on a tool
only the shell carries passes here and fails there first: one expected a
refusal the runners never reached, having no `lldb`.  --gate-environment
runs the modules as those jobs do, as far as a local host can: PATH holds
only GATE_TOOLS, the tools the tests may assume on a runner, each found on
the caller's PATH and linked into a scratch directory, and the environment
holds only GATE_VARIABLES, so nothing the shell exports reaches a test.
A tool the host lacks is named before any test runs.  It does not make the
host a runner: a tool a runner has and GATE_TOOLS does not name is hidden
too, so a test that newly needs one adds it there, which is the decision
that the gate's jobs have it.
"""
import argparse
import concurrent.futures
import contextlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
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

#  The tools a script test may assume on PATH in the gate's jobs, which
#  run on GitHub's ubuntu-24.04 and macOS runners with nothing installed
#  for these tests.  The development shell's own tools are not here:
#  gprbuild, gnat, lldb, gdb, qemu, clang, nix, tree-sitter, node.
GATE_TOOLS = (
    "python3", "git", "sh", "bash", "env",
    #  What the scripts under test and the tests' own stand-ins call.
    "awk", "basename", "cat", "chmod", "cmp", "cp", "cut", "date", "df",
    "diff", "dirname", "expr", "find", "grep", "head", "id", "ln", "ls",
    "mkdir", "mktemp", "mv", "od", "printf", "readlink", "rm", "rmdir",
    "sed", "sha256sum", "sleep", "sort", "stat", "tail", "tar", "tee",
    "touch", "tr", "true", "false", "uname", "uniq", "wc", "xargs",
    "gzip", "nproc", "seq", "timeout", "realpath", "install", "dd", "du",
    "echo", "test", "kill", "ps", "which", "flock", "getconf", "tty",
    "cksum",
    #  The runners' C compiler, which two tests build a helper with, and
    #  the binutils the packaging test splits debug information with.
    "cc", "objcopy", "readelf",
)
#  The variables kept from the caller's environment.  Everything else,
#  the development shell's exports among them, is dropped.
GATE_VARIABLES = ("HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE",
                  "TERM", "TMPDIR", "TZ", "SHELL")


def gate_environment(scratch, environ=None, tools=GATE_TOOLS):
    """The environment --gate-environment gives each module.

    SCRATCH receives a link to each of TOOLS as found on the caller's
    PATH, and is the whole PATH.  A tool the host lacks raises ValueError
    naming every one, since a missing `git` would fail a hundred tests
    with no word of why.
    """
    environ = os.environ if environ is None else environ
    missing = []
    for tool in tools:
        found = shutil.which(tool, path=environ.get("PATH", ""))
        if found is None:
            missing.append(tool)
        else:
            os.symlink(os.path.abspath(found), os.path.join(scratch, tool))
    if missing:
        raise ValueError(
            "--gate-environment needs %s on PATH, which the gate's runners"
            " have; this host does not" % ", ".join(missing))
    kept = {name: environ[name] for name in GATE_VARIABLES if name in environ}
    kept["PATH"] = scratch
    return kept


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


def run(command, cwd, env=None):
    started = time.monotonic()
    result = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, env=env,
                            stderr=subprocess.STDOUT, text=True)
    return result.returncode, result.stdout, time.monotonic() - started


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--jobs", type=int,
                        default=min(16, os.cpu_count() or 1))
    parser.add_argument("--gate-environment", action="store_true",
                        help="run as the gate's jobs do, outside the"
                        " development shell: only the tools and variables"
                        " a runner has")
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
    environment = None
    with contextlib.ExitStack() as stack:
        if args.gate_environment:
            scratch = stack.enter_context(tempfile.TemporaryDirectory(
                prefix="landin-gate-path-"))
            try:
                environment = gate_environment(scratch)
            except ValueError as refusal:
                parser.error(str(refusal))
            print("== gate environment: PATH holds %d tools, %d variables"
                  " kept" % (len(GATE_TOOLS), len(environment) - 1))
        status = run_all(work, args.jobs, environment)
    print("== %d processes at --jobs=%d in %.1f s"
          % (len(work), args.jobs, time.monotonic() - started))
    for label in status:
        print("FAILED: %s" % label)
    if status and args.gate_environment:
        print("== in the gate environment: a failure that passes without"
              " --gate-environment leans on a tool or variable only the"
              " development shell has")
    return 1 if status else 0


def run_all(work, jobs, environment):
    """Run WORK's processes, print each whole in order; the failed labels."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run, command, ROOT, environment)
                   for _, command in work]
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
    return failed


if __name__ == "__main__":
    sys.exit(main(sys.argv))
