#!/usr/bin/env python3
"""A build that names no target is for the compiler's own host (D257).

Pass an already-built refine, never build.  Deliberate real-host exception:
the compiler must not ask the machine what it is, so this asks instead and
holds refine's answer to it.  A refine built for this host compiles a
program with no --target and names that host's description in its build
report; a host no description covers must refuse with L0004.  Run on every
gate host, so each answer is checked where it is the answer.
"""
import argparse
import json
import platform
from pathlib import Path
import subprocess
import sys
import tempfile

SOURCE = b"public main: () -> (code: i32) = code = 0 end main\n"

#  (system, machine) as Python reports them, to the description D257 says
#  a compiler built there defaults to.
HOSTS = {
    ("Linux", "x86_64"): "linux-x86-64",
    ("Linux", "aarch64"): "linux-arm64",
    ("Darwin", "arm64"): "darwin-arm64",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    args = parser.parse_args()
    refine = args.refine.resolve(strict=True)
    host = (platform.system(), platform.machine())
    expected = HOSTS.get(host)
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        (root / "main.ldn").write_bytes(SOURCE)
        result = subprocess.run(
            [str(refine), "main.ldn", "--emit=asm", "-o", "main.s",
             "--build-report=build.json"],
            cwd=root, capture_output=True, timeout=60)
        if expected is None:
            if result.returncode != 1 or b"error[L0004]" not in result.stderr:
                sys.exit("default target: %s/%s has no description, and refine"
                         " did not refuse with L0004: %r"
                         % (host + (result.stderr,)))
            print("default target: %s/%s has none, and L0004 says so" % host)
            return
        if result.returncode != 0:
            sys.exit("default target: refine failed with no --target: %r"
                     % result.stderr)
        report = json.loads((root / "build.json").read_text())["build"]
        if report.get("target") != expected:
            sys.exit("default target: %s/%s should default to %s, not %s"
                     % (host + (expected, report.get("target"))))
        print("default target: %s/%s defaults to %s" % (host + (expected,)))


if __name__ == "__main__":
    main()
