#!/usr/bin/env python3
"""Print the program interpreter an ELF executable requests, if any.

    python3 scripts/program_interpreter.py BINARY

An executable linked against a dynamic loader names it by path, in its
PT_INTERP segment, and the kernel refuses to start the program on a
machine without that path; bash then says only "cannot execute: required
file not found".  A `refine` built in `nix develop` names a loader in the
Nix store, so an archive of it starts only where that store path exists.
`scripts/package.sh` asks this which loader a binary names.

Prints the path and a newline, or nothing for a file that is not ELF (a
Mach-O executable names no such path) or names no interpreter (a static
executable).  The exit status is 0 when there is none or it is where a
system keeps its own loader, 3 when it is anywhere else, and 1 for a file
that cannot be read or an ELF file whose headers end early.
"""
import struct
import sys

PT_INTERP = 3
#  Where a system's own loader lives.  A path elsewhere, a package store or
#  a home directory, is on the machine that built the program and perhaps
#  no other.
SYSTEM = ("/lib/", "/lib64/", "/lib32/", "/libexec/", "/usr/lib/",
          "/usr/lib64/", "/usr/lib32/", "/usr/libexec/", "/system/bin/")


def interpreter(data):
    """The interpreter path DATA, an executable's bytes, requests, or None."""
    if data[:4] != b"\x7fELF":
        return None
    if len(data) < 6 or data[4] not in (1, 2) or data[5] not in (1, 2):
        raise ValueError("an ELF header this does not read")
    wide = data[4] == 2
    order = "<" if data[5] == 1 else ">"
    try:
        if wide:
            offset, = struct.unpack_from(order + "Q", data, 32)
            size, count = struct.unpack_from(order + "HH", data, 54)
        else:
            offset, = struct.unpack_from(order + "I", data, 28)
            size, count = struct.unpack_from(order + "HH", data, 42)
        for index in range(count):
            at = offset + index * size
            kind, = struct.unpack_from(order + "I", data, at)
            if kind != PT_INTERP:
                continue
            if wide:
                where, = struct.unpack_from(order + "Q", data, at + 8)
                length, = struct.unpack_from(order + "Q", data, at + 32)
            else:
                where, = struct.unpack_from(order + "I", data, at + 4)
                length, = struct.unpack_from(order + "I", data, at + 16)
            path = data[where:where + length]
            if len(path) != length:
                raise ValueError("the interpreter's name lies past the end")
            return path.split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
    except struct.error as error:
        raise ValueError("the program headers end early") from error
    return None


def system_path(path):
    """Whether PATH is where a system keeps its own loader."""
    return path.startswith(SYSTEM)


def main(argv):
    if len(argv) != 2:
        print("usage: program_interpreter.py BINARY", file=sys.stderr)
        return 2
    try:
        with open(argv[1], "rb") as stream:
            found = interpreter(stream.read())
    except (OSError, ValueError) as error:
        print("program_interpreter: %s: %s" % (argv[1], error), file=sys.stderr)
        return 1
    if found is None:
        return 0
    print(found)
    return 0 if system_path(found) else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
