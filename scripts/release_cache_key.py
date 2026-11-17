#!/usr/bin/env python3
"""Name the gate's release object cache by what the objects were compiled against.

    release_cache_key.py PLATFORM

prints one cache key prefix to standard output, for PLATFORM `linux` or
`darwin`, and on standard error the facts it is made of.  The gate's
cached release builds (`linux-release-build`, `darwin-release-build`) and
`board-bundles` restore and save their object trees under it.

A cached object tree may serve a build only where the objects are what a
clean build there would compile.  The Ada objects depend on the sources and
the pinned toolchain, which `scripts/build.sh`'s manifest checks after the
restore and the key names through the pins' digest.  The C adapters also
read the host's C library headers, which no manifest records, so the key
names them: the installed `libc6-dev` and `linux-libc-dev` versions on
Linux, the selected Xcode's macOS SDK's version and build on Darwin.  It
names the C compiler's version too, the pinned GNAT's gcc.

It used to name the runner image's version instead, which changes with
every image GitHub rolls out, while one run is often served two image
versions at once: a job then found the saved entry only when it shared an
image with the job that saved it, and mostly built from clean.  An image
change that leaves the headers and the compiler alone now keeps the entry.

The pins' digest and the remaining key parts are the workflow's to add.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys


def run(*arguments: str) -> str:
    try:
        return subprocess.run(arguments, check=True, capture_output=True,
                              text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"release_cache_key: {' '.join(arguments)} failed ({error});"
                         " this names a GitHub runner's C headers, read with dpkg-query"
                         " on Ubuntu and xcrun on macOS") from error


def compiler() -> str:
    """The version of the C driver the build's configuration selects: the
    pinned GNAT's gcc, which scripts/env.sh puts first on PATH from
    LANDIN_GNAT_HOME, or else the gcc on PATH."""
    home = os.environ.get("LANDIN_GNAT_HOME")
    gcc = str(Path(home) / "bin" / "gcc") if home else shutil.which("gcc")
    if gcc is None or not Path(gcc).is_file():
        raise SystemExit("release_cache_key: no gcc; install the pinned toolchain first")
    return "gcc " + run(gcc, "-dumpfullversion")


def linux_facts() -> list[str]:
    versions = run("dpkg-query", "-W", "-f=${Package} ${Version}\\n",
                   "libc6-dev", "linux-libc-dev")
    return sorted(versions.splitlines()) + [compiler()]


def darwin_facts() -> list[str]:
    return ["sdk " + run("xcrun", "--sdk", "macosx", "--show-sdk-version"),
            "sdk-build " + run("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
            compiler()]


def key(platform: str, facts: list[str]) -> str:
    digest = hashlib.sha256("\n".join(facts).encode()).hexdigest()[:16]
    return f"{platform}-headers-{digest}"


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in ("linux", "darwin"):
        print("usage: release_cache_key.py linux|darwin", file=sys.stderr)
        return 2
    facts = linux_facts() if argv[1] == "linux" else darwin_facts()
    for fact in facts:
        print(f"release_cache_key: {fact}", file=sys.stderr)
    print(key(argv[1], facts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
