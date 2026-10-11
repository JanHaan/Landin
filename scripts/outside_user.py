#!/usr/bin/env python3
"""Use an installed toolchain the way its documentation tells a newcomer to.

    scripts/outside_user.py --prefix PREFIX --work DIR

PREFIX is an installed toolchain, as `scripts/package.sh` lays one out and
the flake installs it: `bin/refine` with `lib/landin` beside it.  DIR is a
scratch directory outside the checkout.  The README's first program and every
program in `examples.md` are copied out of the documents as a reader would
copy them, each into a project directory of its own, compiled there with
`refine compile` and no option, and run.  The environment is PATH alone, so
nothing the checkout or a developer's shell provides can stand in for what
the installation lacks.  The answers each program must give are the
documents' own: the first program's stated output, and each example's
fixture status and output oracle.
"""

import argparse
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FIRST_PROGRAM_HEADING = "## Your first program"


def landin_block(text, start):
    """The first fenced `landin` block at or after START, and where it ends."""
    found = re.compile(r"^```landin\n(.*?)^```$", re.M | re.S).search(text, start)
    if found is None:
        raise SystemExit("outside user: no landin block after offset %d" % start)
    return found.group(1), found.end()


def first_program():
    """The README's first program and the output it says the program prints."""
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    at = text.find("\n" + FIRST_PROGRAM_HEADING + "\n")
    if at < 0:
        raise SystemExit("outside user: README.md has no %r section"
                         % FIRST_PROGRAM_HEADING)
    source, after = landin_block(text, at)
    printed = re.compile(r"^```text\n(.*?)^```$", re.M | re.S).search(text, after)
    if printed is None:
        raise SystemExit("outside user: the first program's output is not shown")
    return source, printed.group(1).encode("utf-8"), 0


def examples():
    """Each example's source as examples.md shows it, with its oracles."""
    text = (ROOT / "examples.md").read_text(encoding="utf-8")
    for named in re.finditer(r"^Fixture source: `([^`]+)/main\.ldn`\.$", text,
                             re.M):
        fixture = ROOT / named.group(1)
        source, _ = landin_block(text, named.end())
        meta = dict(line.split(": ", 1) for line in
                    (fixture / "fixture.meta").read_text().splitlines()
                    if ": " in line)
        expected = None
        if "run_expect" in meta:
            expected = (fixture / meta["run_expect"]).read_bytes()
        yield fixture.name, source, expected, int(meta.get("status", "0"))


def run(argv, cwd, env, what):
    """Run ARGV, keeping its output as bytes, since some oracles are images."""
    ran = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                         timeout=600)
    shown = (ran.stdout[-2000:] + ran.stderr[-2000:]).decode(
        "utf-8", "replace")
    return ran, "%s: %s exited %d\n%s" % (what, " ".join(argv),
                                         ran.returncode, shown)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--prefix", required=True, type=pathlib.Path)
    parser.add_argument("--work", required=True, type=pathlib.Path)
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    work = args.work.resolve()
    refine = prefix / "bin" / "refine"
    if work == ROOT or ROOT in work.parents:
        raise SystemExit("outside user: %s is inside the checkout" % work)
    work.mkdir(parents=True, exist_ok=True)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    failures = []

    version, report = run([str(refine), "version"], work, env, "version")
    library = "library: %s" % (prefix / "lib" / "landin")
    if (version.returncode != 0
            or library not in version.stdout.decode("utf-8", "replace")
            .splitlines()):
        failures.append("refine does not report %r\n%s" % (library, report))

    programs = [("first-program",) + first_program()]
    programs += [(name, source, expected, status)
                 for name, source, expected, status in examples()]
    for name, source, expected, status in programs:
        project = work / name
        project.mkdir(exist_ok=True)
        (project / "main.ldn").write_text(source, encoding="utf-8")
        built, report = run([str(refine), "compile", "main.ldn", "-o", "prog"],
                            project, env, name)
        if built.returncode != 0:
            failures.append(report)
            continue
        ran, report = run([str(project / "prog")], project, env, name)
        if ran.returncode != status:
            failures.append("expected status %d\n%s" % (status, report))
        elif expected is not None and ran.stdout != expected:
            failures.append("output differs from the oracle\n%s" % report)
        else:
            print("ok   %s" % name)

    for failure in failures:
        print("FAIL " + failure, file=sys.stderr)
    print("%d programs, %d failed" % (len(programs), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
