#!/usr/bin/env python3
"""Hold build locks across shell commands and their nested build/test calls.

The global lock is shared by ordinary operations and exclusive for clean --all.
Per-mode locks serialize builders/testers; tag cleanup takes both in order.
Files are permanent: unlinking a locked inode would permit a second lock owner.
Descriptors survive exec, so the kernel releases locks after the last user exits.

A build's executables have a third lock, `<tag>-<mode>.readers`.  A tool
that runs a build's `refine` without holding its mode lock -- a corpus lane,
the determinism manifests -- holds it shared through reading(), and a build
publishes its new executables into bin/ only while it holds it exclusively.
A rebuild therefore waits for the run that is using `refine` and never
replaces the executable under it, and a reader waits for a publish to finish.
Lock order is all, then mode, then readers, so none of this can deadlock.

Whoever waits says what it is waiting for and which processes hold it: every
holder writes its pid and command under `<lock>.holders/`, and a waiter
names the live ones.
"""
import atexit
import fcntl
import filecmp
import json
import os
from pathlib import Path
import re
import shutil
import sys


CONTEXT = "LANDIN_BUILD_LOCK_CONTEXT"
#  The readers lock a process tree already holds, so a build started inside
#  that run refuses instead of waiting on its own caller forever.
READER = "LANDIN_BUILD_READER"
LOCKS = Path(__file__).resolve().parents[1] / "compiler/ada/.build-locks"

_held = []


def _identity():
    tag = os.environ["LANDIN_BUILD_TAG"]
    mode = os.environ["LANDIN_BUILD_MODE"]
    if (not re.fullmatch(r"[a-z0-9_-][a-z0-9._-]*", tag)
            or ".." in tag or mode not in ("debug", "release")):
        raise ValueError("invalid build tag or mode")
    return tag, mode


def readers_lock(locks, tag, mode):
    return locks / f"{tag}-{mode}.readers"


def lock_plan(scope):
    tag, mode = _identity()
    if scope not in ("mode", "tag", "all"):
        raise ValueError("invalid build lock scope")
    plan = [(str(LOCKS / "all"),
             fcntl.LOCK_EX if scope == "all" else fcntl.LOCK_SH)]
    if scope != "all":
        modes = (mode,) if scope == "mode" else ("debug", "release")
        for selected in modes:
            plan.append((str(LOCKS / f"{tag}-{selected}"), fcntl.LOCK_EX))
        #  Removing a tag's tree removes its executables, so cleanup also
        #  waits for whoever is running them.
        if scope == "tag":
            for selected in modes:
                plan.append((str(readers_lock(LOCKS, tag, selected)),
                             fcntl.LOCK_EX))
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


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def holders(path):
    """`pid N: command` for every live process recorded as holding PATH."""
    found = []
    directory = Path(str(path) + ".holders")
    try:
        entries = sorted(directory.iterdir())
    except OSError:
        return found
    for entry in entries:
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid == os.getpid() or not _alive(pid):
            try:
                if pid != os.getpid():
                    entry.unlink()
            except OSError:
                pass
            continue
        try:
            command = entry.read_text().strip()
        except OSError:
            continue
        found.append(f"pid {pid}: {command}")
    return found


def _record(path, command):
    directory = Path(str(path) + ".holders")
    directory.mkdir(parents=True, exist_ok=True)
    holders(path)  # and forget the processes that have gone
    (directory / str(os.getpid())).write_text(command + "\n")


def _forget(path):
    try:
        (Path(str(path) + ".holders") / str(os.getpid())).unlink()
    except OSError:
        pass


def acquire(path, kind, command, purpose=None):
    """Open and lock PATH, saying what is waited for and who holds it."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, kind | fcntl.LOCK_NB)
    except BlockingIOError:
        said = f"landin: waiting for build lock {Path(path).name}"
        if purpose:
            said += f" ({purpose})"
        named = holders(path)
        said += (", held by " + "; ".join(named)) if named else ""
        print(said, file=sys.stderr, flush=True)
        fcntl.flock(fd, kind)
    _record(path, command)
    return fd


def reading(refine):
    """Hold the build that REFINE belongs to against replacement.

    For as long as this process lives, no build publishes a new `refine` or
    test program into that build's bin/, and cleanup does not remove it.
    An executable outside a build tree, such as an installed or imported
    compiler, needs no lock and none is taken.  Returns whether one was.
    """
    path = Path(refine).absolute()
    parts = path.parent.resolve().parts
    #  <checkout>/compiler/ada/build/<tag>/<mode>/bin/<executable>
    if (len(parts) < 6 or parts[-1] != "bin" or parts[-4] != "build"
            or parts[-5] != "ada" or parts[-2] not in ("debug", "release")):
        return False
    ada = Path(*parts[:-4])
    tag, mode = parts[-3], parts[-2]
    if not re.fullmatch(r"[a-z0-9_-][a-z0-9._-]*", tag):
        return False
    locks = ada / ".build-locks"
    command = " ".join(sys.argv) or "python3"
    readers = readers_lock(locks, tag, mode)
    for lock, kind in ((locks / "all", fcntl.LOCK_SH),
                       (readers, fcntl.LOCK_SH)):
        fd = acquire(str(lock), kind, command,
                     purpose=f"to run {tag}/{mode} refine")
        _held.append((str(lock), fd))
    #  Held, so no publish is half done: absent means never built.
    if not path.exists():
        raise FileNotFoundError(
            f"{path} does not exist: no build of {tag}/{mode} has published"
            f" it; run LANDIN_BUILD_TAG={tag} LANDIN_BUILD_MODE={mode}"
            " scripts/build.sh --compiler-only")
    os.environ[READER] = f"{readers}:{os.getpid()}"
    atexit.register(_release)
    return True


def _release():
    for path, fd in _held:
        _forget(path)
        try:
            os.close(fd)
        except OSError:
            pass
    _held.clear()


def publish(build, names):
    """Copy each changed executable from BUILD/link into BUILD/bin.

    gprbuild links into link/, never into bin/, so a reader never sees a
    half-written executable.  The new one is copied beside the old and
    renamed over it, which every reader sees as one step, and only while no
    reader holds the build's readers lock.
    """
    tag, mode = _identity()
    build = Path(build)
    changed = []
    for name in names:
        linked, current = build / "link" / name, build / "bin" / name
        if not linked.is_file():
            raise ValueError(f"the build linked no {linked}")
        if not (current.is_file()
                and filecmp.cmp(linked, current, shallow=False)
                and os.access(current, os.X_OK)):
            changed.append(name)
    if not changed:
        return 0
    readers = readers_lock(LOCKS, tag, mode)
    caller = os.environ.get(READER, "")
    if caller.rpartition(":")[0] == str(readers):
        pid = caller.rpartition(":")[2]
        if pid.isdigit() and _alive(int(pid)):
            raise ValueError(
                f"pid {pid} is running this build's refine and started this"
                " build; it cannot replace the executable its caller is"
                " using")
    command = " ".join(sys.argv)
    fd = acquire(str(readers), fcntl.LOCK_EX, command,
                 purpose="to replace " + ", ".join(changed)
                 + " while another run uses it")
    try:
        (build / "bin").mkdir(parents=True, exist_ok=True)
        for name in changed:
            staged = build / "bin" / f".{name}.{os.getpid()}.new"
            shutil.copy2(build / "link" / name, staged)
            os.replace(staged, build / "bin" / name)
    finally:
        _forget(str(readers))
        os.close(fd)
    return 0


def main(arguments):
    if arguments and arguments[0] == "--publish":
        if len(arguments) < 3:
            raise ValueError("expected --publish BUILD_DIR EXECUTABLE...")
        return publish(arguments[1], arguments[2:])
    checking = bool(arguments and arguments[0] == "--check")
    if checking:
        arguments = arguments[1:]
    if not arguments or (not checking and len(arguments) < 2):
        raise ValueError("expected scope and command")
    plan = lock_plan(arguments[0])
    if checking:
        return 0 if inherited(plan) else 1
    context = []
    command = " ".join(arguments[1:])
    for path, kind in plan:
        fd = acquire(path, kind, command)
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
