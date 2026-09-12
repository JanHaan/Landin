#!/usr/bin/env python3
"""Hold build locks across shell commands and their nested build/test calls.

The global lock is shared by ordinary operations and exclusive for clean --all.
Per-mode locks serialize builders/testers; tag cleanup takes both in order.
Files are permanent: unlinking a locked inode would permit a second lock owner.
Descriptors survive exec, so the kernel releases locks after the last user exits.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import sys


CONTEXT = "LANDIN_BUILD_LOCK_CONTEXT"


def lock_plan(scope):
    root = Path(__file__).resolve().parents[1] / "compiler/ada/.build-locks"
    tag = os.environ["LANDIN_BUILD_TAG"]
    mode = os.environ["LANDIN_BUILD_MODE"]
    if (not re.fullmatch(r"[a-z0-9_-][a-z0-9._-]*", tag)
            or ".." in tag or mode not in ("debug", "release")):
        raise ValueError("invalid build tag or mode")
    if scope not in ("mode", "tag", "all"):
        raise ValueError("invalid build lock scope")
    plan = [(str(root / "all"),
             fcntl.LOCK_EX if scope == "all" else fcntl.LOCK_SH)]
    if scope != "all":
        for selected in ((mode,) if scope == "mode" else ("debug", "release")):
            plan.append((str(root / f"{tag}-{selected}"), fcntl.LOCK_EX))
    return plan


def inherited(plan):
    """Validate live descriptors, not an environment flag claiming ownership."""
    try:
        context = json.loads(os.environ.get(CONTEXT, "null"))
        if not isinstance(context, list) or len(context) != len(plan):
            return False
        for (path, kind), (held_path, held_kind, fd) in zip(plan, context):
            if path != held_path or kind != held_kind or not isinstance(fd, int):
                return False
            held, current = os.fstat(fd), os.stat(path)
            if (held.st_dev, held.st_ino) != (current.st_dev, current.st_ino):
                return False
            fcntl.flock(fd, kind | fcntl.LOCK_NB)
        return True
    except (OSError, ValueError, TypeError):
        return False


def main(arguments):
    checking = bool(arguments and arguments[0] == "--check")
    if checking:
        arguments = arguments[1:]
    if not arguments or (not checking and len(arguments) < 2):
        raise ValueError("expected scope and command")
    plan = lock_plan(arguments[0])
    if checking:
        return 0 if inherited(plan) else 1
    context = []
    for path, kind in plan:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, kind | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"landin: waiting for build lock {Path(path).name}",
                  file=sys.stderr, flush=True)
            fcntl.flock(fd, kind)
        os.set_inheritable(fd, True)
        context.append((path, kind, fd))
    environment = {**os.environ, CONTEXT: json.dumps(context)}
    os.execvpe(arguments[1], arguments[1:], environment)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError) as error:
        print(f"landin: build lock: {error}", file=sys.stderr)
        sys.exit(2)
