#!/usr/bin/env python3
"""Hold each linked executable to the objects it was linked from.

GPRbuild never compares contents to decide whether to rebuild a library or
relink an executable.  It rebuilds the static library when an object's time
stamp, at a resolution of one second, differs from the one it recorded when
it last built the library, and it relinks when the library or an object is
newer than the executable.  An object rewritten within the second of its
recorded stamp, or a build tree whose files were copied, restored or synced
with their times, keeps the old library and the old executable, and a
build once reported `built:` over a `refine` linked from the previous
objects.

So build.sh asks this script, after each GPRbuild run, what was linked:

  stamp BUILD NAME
      Print what BUILD/link/NAME is now, before GPRbuild runs.
  verify BUILD NAME OBJECTS BEFORE
      Exit 0 and print the manifest row `linked NAME SHA256` when
      BUILD/link/NAME was linked from the library and OBJECTS as they are
      now: because GPRbuild relinked it in this run, or because the record
      beside it says it was linked from exactly these contents.  Otherwise
      say why, remove what GPRbuild must remake -- the library's exchange
      file when the archive holds an object other than the one compiled,
      and the executable -- and exit 3, so build.sh runs GPRbuild again.
  published BUILD MANIFEST NAME...
      Exit 0 when each BUILD/bin/NAME is the executable MANIFEST's
      `linked NAME` row records; otherwise say which is not and exit 1.
"""
import hashlib
import json
import os
from pathlib import Path
import sys


LIBRARY = Path("lib/liblandin.a")
LIBRARY_OBJECTS = Path("lib-obj")
EXCHANGE = LIBRARY_OBJECTS / "landin.lexch"


def digest(path):
    hashed = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            hashed.update(chunk)
    return hashed.hexdigest()


def members(archive):
    """{member name: sha256} of a System V / GNU `ar` archive, if any."""
    if not Path(archive).exists():
        return {}
    data = Path(archive).read_bytes()
    if not data.startswith(b"!<arch>\n"):
        raise ValueError(f"{archive} is not an ar archive")
    found, names, at = {}, b"", 8
    while at + 60 <= len(data):
        header = data[at:at + 60]
        if header[58:60] != b"`\n":
            raise ValueError(f"{archive} has a damaged member header")
        name = header[:16].rstrip(b" ")
        size = int(header[48:58])
        body = data[at + 60:at + 60 + size]
        at += 60 + size + (size & 1)
        if name in (b"/", b"/SYM64/"):
            continue
        if name == b"//":
            names = body
            continue
        if name.startswith(b"/") and name[1:].isdigit():
            start = int(name[1:])
            name = names[start:names.index(b"/\n", start)]
        else:
            name = name.removesuffix(b"/")
        found[name.decode()] = hashlib.sha256(body).hexdigest()
    return found


def stamp(build, name):
    try:
        status = (Path(build) / "link" / name).stat()
    except FileNotFoundError:
        return "absent"
    return f"{status.st_ino}:{status.st_size}:{status.st_mtime_ns}"


def inputs(build, objects, archived):
    """{input: sha256} of what NAME links: the library's members and OBJECTS."""
    build = Path(build)
    linked = {f"{LIBRARY}({name})": value for name, value in archived.items()}
    for path in sorted((build / objects).glob("*.o")):
        linked[path.relative_to(build).as_posix()] = digest(path)
    return linked


def stale_library(build, archived):
    """The objects the library archive does not hold as compiled, if any."""
    build = Path(build)
    compiled = {path.name: digest(path)
                for path in (build / LIBRARY_OBJECTS).glob("*.o")}
    return sorted(name for name in set(archived) | set(compiled)
                  if archived.get(name) != compiled.get(name))


def verify(build, name, objects, before):
    build = Path(build)
    executable = build / "link" / name
    record_path = build / "link" / f".{name}.linked"
    archived = members(build / LIBRARY)
    stale = stale_library(build, archived)
    if stale:
        print(f"landin: {LIBRARY} does not hold the compiled {stale[0]}"
              + (f" and {len(stale) - 1} more" if len(stale) > 1 else "")
              + "; GPRbuild did not rebuild it, so it is rebuilt and"
              f" {name} relinked", file=sys.stderr)
        for path in (build / EXCHANGE, executable):
            path.unlink(missing_ok=True)
        return 3
    current = inputs(build, objects, archived)
    linked = digest(executable)
    if stamp(build, name) != before:
        record = {"executable": linked, "inputs": current}
        staged = record_path.with_name(record_path.name + ".tmp")
        staged.write_text(json.dumps(record, indent=1, sort_keys=True) + "\n")
        os.replace(staged, record_path)
    else:
        try:
            record = json.loads(record_path.read_text())
        except (OSError, ValueError):
            record = {}
        if record.get("executable") != linked or record.get("inputs") != current:
            recorded = record.get("inputs", {})
            changed = sorted(key for key in set(recorded) | set(current)
                             if recorded.get(key) != current.get(key))
            why = (f"{changed[0]} changed since it was linked"
                   + (f", with {len(changed) - 1} more" if len(changed) > 1
                      else "")
                   if changed and record.get("executable") == linked
                   else "nothing records what it was linked from")
            print(f"landin: link/{name} was not relinked and {why};"
                  " relinking it", file=sys.stderr)
            executable.unlink()
            return 3
    print(f"linked {name} {linked}")
    return 0


def published(build, manifest, names):
    rows = {}
    for row in Path(manifest).read_text().splitlines():
        words = row.split()
        if len(words) == 3 and words[0] == "linked":
            rows[words[1]] = words[2]
    for name in names:
        path = Path(build) / "bin" / name
        if name not in rows:
            print(f"landin: {Path(manifest).name} records no linked {name}",
                  file=sys.stderr)
            return 1
        if not path.is_file() or digest(path) != rows[name]:
            print(f"landin: bin/{name} is not the executable the last build"
                  " linked", file=sys.stderr)
            return 1
    return 0


def main(arguments):
    if len(arguments) == 3 and arguments[0] == "stamp":
        print(stamp(arguments[1], arguments[2]))
        return 0
    if len(arguments) == 5 and arguments[0] == "verify":
        return verify(*arguments[1:])
    if len(arguments) >= 4 and arguments[0] == "published":
        return published(arguments[1], arguments[2], arguments[3:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print(f"landin: build link: {error}", file=sys.stderr)
        sys.exit(2)
