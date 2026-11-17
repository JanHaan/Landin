#!/usr/bin/env python3
"""Carry the compiler sources' modification times with a cached build tree.

    source_times.py save ROOT BUILD_DIR
    source_times.py apply ROOT BUILD_DIR

GPRbuild's checksum mode (`-m2`, which `scripts/dev-build.sh` selects)
spares the units that depend on an unchanged source, but still recompiles
every unit whose own source's time stamp differs from the one its ALI file
records, and the C sources go by time stamps alone.  A fresh checkout gives
every file the time of the checkout, so a build over an object tree
restored from the cache recompiled every unit, and took as long as a clean
build: 224 Ada units over a tree whose sources were all unchanged, in the
gate's `linux-release-build` of run 44052328931 and again on a Linux host.

`save` writes BUILD_DIR/source-times.txt: for every input the build manifest
counts (`scripts/build_identity.py`), its modification time and SHA-256, as
the checkout the tree was built from has them.  `apply` gives each input of
the checkout at ROOT whose SHA-256 is the one recorded the recorded time, so
the objects compiled from that very content are current again, and leaves
every other file's time alone, so what changed is newer than its objects
and is recompiled.  It says how many files it gave their time and which
differ.  It changes no content and decides nothing: `scripts/build.sh`
still rebuilds from clean when the manifest says so, and the gate holds the
build to a clean one byte for byte.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_identity  # noqa: E402

NAME = "source-times.txt"


def digest(path: Path) -> str:
    return build_identity.file_digest(path)


def save(root: Path, build: Path) -> int:
    rows = []
    for name in build_identity.inputs(root):
        path = root / name
        rows.append(f"{path.stat().st_mtime_ns} {digest(path)} {name}")
    build.mkdir(parents=True, exist_ok=True)
    (build / NAME).write_text("\n".join(rows) + "\n")
    print(f"source_times: recorded {len(rows)} inputs' times in {build / NAME}")
    return 0


def apply(root: Path, build: Path) -> int:
    record = build / NAME
    if not record.is_file():
        print(f"source_times: {record} is absent; every source keeps its"
              " checkout time, and every unit is recompiled")
        return 0
    given, differ = 0, []
    for row in record.read_text().splitlines():
        mtime, sha, name = row.split(" ", 2)
        path = root / name
        if not path.is_file():
            differ.append(f"{name} is gone")
        elif digest(path) != sha:
            differ.append(f"{name} changed")
        else:
            os.utime(path, ns=(int(mtime), int(mtime)))
            given += 1
    print(f"source_times: {given} inputs unchanged since the cached build"
          f" took their recorded times; {len(differ)} differ")
    for line in differ[:40]:
        print(f"source_times:   {line}")
    if len(differ) > 40:
        print(f"source_times:   and {len(differ) - 40} more")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[1] not in ("save", "apply"):
        print("usage: source_times.py save|apply ROOT BUILD_DIR", file=sys.stderr)
        return 2
    root, build = Path(argv[2]).resolve(), Path(argv[3])
    return (save if argv[1] == "save" else apply)(root, build)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
