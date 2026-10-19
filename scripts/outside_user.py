#!/usr/bin/env python3
"""Use an installed toolchain the way its documentation tells a newcomer to.

    scripts/outside_user.py --prefix PREFIX --work DIR

PREFIX is an installed toolchain, as `scripts/package.sh` lays one out and
the flake installs it: `bin/refine` with `lib/landin` beside it.  DIR is a
scratch directory outside the checkout.  The first program and every program
in `examples.md` are copied out as a reader would copy them, each into a
project directory of its own, compiled there with `refine compile` and no
option, and run.  The environment is PATH alone, so nothing the checkout or
a developer's shell provides can stand in for what the installation lacks.
Each program is held to its fixture's status and output oracle, is given its
fixture's `run_args:` and `run_files:` as its arguments, and reads the file
its fixture's `stdin:` names as its standard input, or an empty one.

With `--stock`, the system is a stock distribution with only its own GCC
(D364): the first compile's plan must name a driver the distribution
installs, never the pinned image's `x86_64-pc-linux-gnu-gcc`, and a program
that traps must report its kind and site (D361) before it ends.

The first program is read from its runtime fixture, not from the README
that shows it: the gate may skip this lane for an edit confined to the
README, so the lane must not read it, and `check.py` holds the README's
listing and output to the fixture instead.
"""

import argparse
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "compiler/tests"))
import fixture_meta  # noqa: E402

FIRST_PROGRAM = ROOT / "compiler/tests/fixtures/runtime/first-program"


def landin_block(text, start):
    """The first fenced `landin` block at or after START, and where it ends."""
    found = re.compile(r"^```landin\n(.*?)^```$", re.M | re.S).search(text, start)
    if found is None:
        raise SystemExit("outside user: no landin block after offset %d" % start)
    return found.group(1), found.end()


def first_program():
    """The first program, the output it prints, its status, its input and
    its arguments."""
    return ((FIRST_PROGRAM / "main.ldn").read_text(encoding="utf-8"),
            (FIRST_PROGRAM / "output.txt").read_bytes(), 0, b"", [])


def examples():
    """Each example's source as examples.md shows it, with its oracles, the
    bytes its standard input reads and the arguments it is given."""
    text = (ROOT / "examples.md").read_text(encoding="utf-8")
    for named in re.finditer(r"^Fixture source: `([^`]+)/main\.ldn`\.$", text,
                             re.M):
        fixture = ROOT / named.group(1)
        source, _ = landin_block(text, named.end())
        meta = fixture_meta.read(fixture)
        given = pathlib.Path(meta.standard_input(fixture)).read_bytes()
        yield (fixture.name, source, meta.run_expected(fixture), meta.status,
               given, meta.program_arguments(fixture))


def run(argv, cwd, env, what, given=b""):
    """Run ARGV with GIVEN as its standard input, keeping its output as
    bytes, since some oracles are images."""
    ran = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                         input=given, timeout=600)
    shown = (ran.stdout[-2000:] + ran.stderr[-2000:]).decode(
        "utf-8", "replace")
    return ran, "%s: %s exited %d\n%s" % (what, " ".join(argv),
                                         ran.returncode, shown)


TRAPPING = """public main: () -> (code: i32) =
    values: [3]i32 = [1, 2, 3]
    index: usize = 3
    code = values[index]
end main
"""


def stock_checks(refine, work, env):
    """D364's driver and D361's report on a system with only the
    distribution's GCC."""
    failures = []
    project = work / "stock"
    project.mkdir(exist_ok=True)
    (project / "main.ldn").write_text(TRAPPING, encoding="utf-8")
    planned, report = run([str(refine), "compile", "--dry-run", "main.ldn",
                           "-o", "prog"], project, env, "stock plan")
    drivers = re.findall(r'^run \["([^"]+)"', planned.stdout.decode(
        "utf-8", "replace"), re.M)
    if planned.returncode != 0 or not drivers:
        failures.append("no link was planned\n%s" % report)
    elif drivers[-1] == "x86_64-pc-linux-gnu-gcc":
        failures.append("the plan names the pinned driver\n%s" % report)
    built, report = run([str(refine), "compile", "main.ldn", "-o", "prog"],
                        project, env, "stock trap")
    if built.returncode != 0:
        failures.append(report)
        return failures
    if (project / "prog.s").exists():
        failures.append("the intermediate assembly was left beside prog")
    ran, report = run([str(project / "prog")], project, env, "stock trap")
    if ran.returncode >= 0 or b"main.ldn:4:12: trap: out_of_range\n" \
            not in ran.stderr:
        failures.append("the trap did not report its site\n%s" % report)
    else:
        print("ok   stock driver %s and trap report" % drivers[-1])
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--prefix", required=True, type=pathlib.Path)
    parser.add_argument("--work", required=True, type=pathlib.Path)
    parser.add_argument("--stock", action="store_true",
                        help="hold the run to a stock distribution's driver")
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
    programs += list(examples())
    for name, source, expected, status, given, arguments in programs:
        project = work / name
        project.mkdir(exist_ok=True)
        (project / "main.ldn").write_text(source, encoding="utf-8")
        built, report = run([str(refine), "compile", "main.ldn", "-o", "prog"],
                            project, env, name)
        if built.returncode != 0:
            failures.append(report)
            continue
        ran, report = run([str(project / "prog")] + arguments, project, env,
                          name, given)
        if ran.returncode != status:
            failures.append("expected status %d\n%s" % (status, report))
        elif expected is not None and ran.stdout != expected:
            failures.append("output differs from the oracle\n%s" % report)
        else:
            print("ok   %s" % name)

    if args.stock:
        failures += stock_checks(refine, work, env)
        programs.append(("stock driver and trap report",))

    for failure in failures:
        print("FAIL " + failure, file=sys.stderr)
    print("%d programs, %d failed" % (len(programs), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
