#!/usr/bin/env python3
"""Install and run refine through nix as the README tells a reader to.

    scripts/nix_route.py --work DIR [--flake REF]

REF is the flake, `.` by default: in the gate that is the candidate's tree,
which is what `github:701-dev/Landin` names once the candidate is main.
DIR is a scratch directory outside the checkout.

D1707: the flake's default package is the published release archive on a
system a release covers, so `nix profile install REF` and `nix run REF`
fetch it rather than compile.  This holds that to the store:

- `nix profile install --profile DIR/profile REF` installs a `refine`
  whose executable is the `refine-bin` package's, and which reports the
  release version that package fetches;
- `nix run REF -- run main.ldn` runs the first program and prints its
  output, the line the README promises;
- the source build is still one name away: `REF#refine` evaluates to a
  derivation that is not `refine-bin`.  The gate's flake job builds it.

The first program is read from its runtime fixture, as
`scripts/outside_user.py` reads it.  A non-zero exit names each failure.
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from outside_user import first_program  # noqa: E402

NIX = ["nix", "--extra-experimental-features", "nix-command flakes"]


def nix(*argv, cwd=None):
    """Run nix with ARGV and return its standard output, stripped; stop
    with what it printed when it fails."""
    ran = subprocess.run(NIX + list(argv), cwd=cwd, capture_output=True,
                         text=True, timeout=1800)
    if ran.returncode != 0:
        raise SystemExit("nix route: nix %s exited %d\n%s"
                         % (" ".join(argv), ran.returncode,
                            ran.stderr[-4000:]))
    return ran.stdout.strip()


def checks(flake, work, nix=nix, run=subprocess.run):
    """The failures of the nix route for FLAKE, using WORK as scratch."""
    failures = []
    released = nix("eval", "--raw", flake + "#refine-bin.outPath")
    version = nix("eval", "--raw", flake + "#refine-bin.version")
    source = nix("eval", "--raw", flake + "#refine.outPath")
    if source == released:
        failures.append("%s#refine is the prebuilt package, not the source "
                        "build" % flake)
    else:
        print("ok   %s#refine is the source build" % flake)

    profile = work / "profile"
    nix("profile", "install", "--profile", str(profile), flake)
    installed = os.path.realpath(profile / "bin" / "refine")
    if not installed.startswith(released + "/"):
        failures.append("nix profile install %s installed %s, not the "
                        "release archive's %s" % (flake, installed, released))
    else:
        ran = run([str(profile / "bin" / "refine"), "version"],
                  capture_output=True, text=True, timeout=60)
        first = (ran.stdout.splitlines() or [""])[0]
        if ran.returncode != 0 or first != "refine " + version:
            failures.append("the installed refine version says %r, not "
                            "'refine %s'\n%s" % (first, version, ran.stderr))
        else:
            print("ok   nix profile install %s: %s" % (flake, first))

    project = work / "run"
    project.mkdir(parents=True, exist_ok=True)
    program, printed = first_program()[:2]
    (project / "main.ldn").write_text(program, encoding="utf-8")
    reference = str(pathlib.Path(flake).resolve()) \
        if flake.startswith((".", "/")) else flake
    ran = run(NIX + ["run", reference, "--", "run", "main.ldn"],
              cwd=project, capture_output=True, timeout=1800)
    if ran.returncode != 0 or ran.stdout != printed:
        failures.append("nix run %s -- run main.ldn exited %d and printed "
                        "%r, not %r\n%s"
                        % (flake, ran.returncode, ran.stdout, printed,
                           ran.stderr.decode("utf-8", "replace")[-4000:]))
    else:
        print("ok   nix run %s -- run main.ldn" % flake)
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--work", required=True, type=pathlib.Path)
    parser.add_argument("--flake", default=".")
    arguments = parser.parse_args()
    if arguments.work.exists():
        shutil.rmtree(arguments.work)
    arguments.work.mkdir(parents=True)
    failures = checks(arguments.flake, arguments.work)
    for failure in failures:
        print("FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
