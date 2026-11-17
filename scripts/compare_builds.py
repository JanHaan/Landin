#!/usr/bin/env python3
"""Require two builds of one tree to have produced the same executables.

The gate builds the Linux x86-64 and the Darwin release executables twice:
from clean, and incrementally over the object tree a previous run left in
the cache, so that the lanes waiting for a compiler can start sooner.  The lanes take the
incremental build; this holds it to the clean one:

    compare_builds.py CLEAN_DIR CACHED_DIR NAME...

Each directory is an unpacked build archive, holding `bin/NAME` and the
manifests `source-manifest.txt` and `tests-manifest.txt`.  The builds are
the same when each `bin/NAME` is the same file, byte for byte, in both, and
the manifests record the same inputs: the same sources, project files,
switches and toolchain.  Nothing is stripped or ignored, the debugging
information included, so a lane that ran the cached build ran the very file
the clean build made.

When an executable differs the report says how, to find the cause: the
sizes and digests, the sections whose contents differ or that one file
lacks, whether anything but the debugging information differs, and for
ELF, when loaded bytes differ, the routines and data that do
(scripts/compare_images.py's report).  An ELF file's debugging information
is its `.debug_*` sections; a Mach-O file's, whose DWARF stays in the
object files, is its debug map (the symbol table's stabs, naming each
object file and its modification time), its LC_UUID and its ad hoc
signature, which hashes every other page.  A Mach-O file's load commands
are reported by name beside its sections, and its symbol table as its
stabs, its other symbols and its strings.  A difference confined to the
debugging information still fails: the clean build is what the lanes'
evidence must stand on, and an incremental build that differs from it in
any byte has shown that it is not a clean build's equal.

The exit status is 0 when every NAME is the same and the manifests agree,
1 when anything differs, an executable this cannot read among them, and 2
when a file is missing.  Standard-library Python, reading the files alone.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare_images  # noqa: E402

MANIFESTS = ("source-manifest.txt", "tests-manifest.txt")


class Unreadable(Exception):
    """A file this cannot compare."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


#  Mach-O load commands this names; any other is named by its number.
LOAD_COMMANDS = {0x2: "LC_SYMTAB", 0xB: "LC_DYSYMTAB", 0xC: "LC_LOAD_DYLIB",
                 0xE: "LC_LOAD_DYLINKER", 0x1B: "LC_UUID",
                 0x1D: "LC_CODE_SIGNATURE", 0x26: "LC_FUNCTION_STARTS",
                 0x29: "LC_DATA_IN_CODE", 0x2A: "LC_SOURCE_VERSION",
                 0x32: "LC_BUILD_VERSION", 0x80000028: "LC_MAIN",
                 0x80000033: "LC_DYLD_EXPORTS_TRIE",
                 0x80000034: "LC_DYLD_CHAINED_FIXUPS"}
#  Load commands whose payload is a (file offset, size) range of
#  __LINKEDIT, linkedit_data_command.
LINKEDIT_DATA = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x80000033, 0x80000034}
#  The parts of a Mach-O executable the linker derives from its other
#  bytes or that only a debugger reads: the debug map, the stabs naming each
#  object file and its time, the UUID and the ad hoc signature hashing the
#  rest.
MACHO_DEBUGGING = ("symbol table stabs", "LC_UUID", "LC_CODE_SIGNATURE",
                   "LC_CODE_SIGNATURE data")


def sections(data):
    """{name: (header fields but the file offset, contents)} of an ELF or a
    64-bit Mach-O file, and the names in file order."""
    if data[:4] == b"\xcf\xfa\xed\xfe":
        return macho_sections(data)
    if len(data) < 52 or data[:4] != b"\x7fELF":
        raise Unreadable("neither an ELF nor a 64-bit Mach-O file")
    if data[4] not in (1, 2) or data[5] not in (1, 2):
        raise Unreadable("unknown ELF class %d or byte order %d"
                         % (data[4], data[5]))
    wide = data[4] == 2
    order = "<" if data[5] == 1 else ">"
    try:
        if wide:
            shoff, = struct.unpack_from(order + "Q", data, 40)
            shentsize, shnum, shstrndx = struct.unpack_from(order + "HHH",
                                                            data, 58)
            layout = order + "IIQQQQIIQQ"
        else:
            shoff, = struct.unpack_from(order + "I", data, 32)
            shentsize, shnum, shstrndx = struct.unpack_from(order + "HHH",
                                                            data, 46)
            layout = order + "IIIIIIIIII"
        headers = [struct.unpack_from(layout, data, shoff + i * shentsize)
                   for i in range(shnum)] if shoff else []
        names = headers[shstrndx][4] if headers else 0
        found, order_of = {}, []
        for index, (name, kind, flags, address, offset, size, link, info,
                    align, entsize) in enumerate(headers):
            if index == 0:
                continue
            end = data.index(b"\0", names + name)
            label = data[names + name:end].decode("utf-8", "replace")
            #  SHT_NOBITS occupies no file bytes.
            contents = b"" if kind == 8 else data[offset:offset + size]
            if len(contents) != (0 if kind == 8 else size):
                raise ValueError("section %s runs past the end" % label)
            found[label] = ((kind, flags, address, size, link, info, align,
                             entsize), contents)
            order_of.append(label)
    except (struct.error, IndexError, ValueError) as error:
        raise Unreadable("truncated or malformed ELF: %s" % error) from None
    return found, order_of


def macho_sections(data):
    """The sections of a little-endian 64-bit Mach-O file named
    `SEGMENT,section`, each load command but the segments by its name, the
    data a linkedit_data_command names as `NAME data`, and the symbol table
    as its stabs (the debug map), its other symbols and its strings."""
    found, order_of = {}, []

    def add(label, fields, contents):
        while label in found:
            label += "'"
        found[label] = (fields, contents)
        order_of.append(label)

    try:
        _, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
        cursor, end = 32, 32 + size
        if end > len(data):
            raise ValueError("load commands run past the end")
        for _ in range(count):
            command, length = struct.unpack_from("<II", data, cursor)
            if length < 8 or cursor + length > end:
                raise ValueError("load command %#x has size %d" % (command, length))
            if command == 0x19:
                segment = data[cursor + 8:cursor + 24].rstrip(b"\0").decode()
                vmaddr, vmsize, _, filesize = struct.unpack_from(
                    "<4Q", data, cursor + 24)
                nsects, = struct.unpack_from("<I", data, cursor + 64)
                add("segment " + segment, (vmaddr, vmsize, filesize), b"")
                for index in range(nsects):
                    at = cursor + 72 + 80 * index
                    name = data[at:at + 16].rstrip(b"\0").decode()
                    address, extent, offset, align, _, _, flags = \
                        struct.unpack_from("<QQIIIII", data, at + 32)
                    #  Zero-fill sections occupy no file bytes.
                    zerofill = (flags & 0xFF) in (1, 0xC, 0x12)
                    contents = b"" if zerofill else data[offset:offset + extent]
                    if not zerofill and len(contents) != extent:
                        raise ValueError("section %s runs past the end" % name)
                    add(segment + "," + name, (address, extent, align, flags),
                        contents)
            else:
                name = LOAD_COMMANDS.get(command, "load command %#x" % command)
                add(name, (command,), data[cursor:cursor + length])
                if command in LINKEDIT_DATA:
                    offset, extent = struct.unpack_from("<II", data, cursor + 8)
                    add(name + " data", (), data[offset:offset + extent])
                elif command == 0x2:
                    symoff, nsyms, stroff, strsize = struct.unpack_from(
                        "<4I", data, cursor + 8)
                    stabs, symbols = [], []
                    for index in range(nsyms):
                        entry = data[symoff + 16 * index:symoff + 16 * index + 16]
                        if len(entry) != 16:
                            raise ValueError("the symbol table runs past the end")
                        #  N_STAB bits: a debugger's entry, such as N_OSO.
                        (stabs if entry[4] & 0xE0 else symbols).append(entry)
                    add("symbol table stabs", (), b"".join(stabs))
                    add("symbol table symbols", (), b"".join(symbols))
                    add("string table", (), data[stroff:stroff + strsize])
            cursor += length
    except (struct.error, ValueError, UnicodeDecodeError) as error:
        raise Unreadable("truncated or malformed Mach-O: %s" % error) from None
    return found, order_of


def stab_note(clean, cached):
    """Which of two debug maps' entries differ, and the usual cause."""
    if len(clean) != len(cached):
        return "    the debug maps hold other objects\n"
    entries = [(clean[at:at + 16], cached[at:at + 16])
               for at in range(0, len(clean), 16)
               if clean[at:at + 16] != cached[at:at + 16]]
    times = sum(1 for a, b in entries
                if a[4] == 0x66 and a[:8] == b[:8])     # N_OSO, n_value alone
    note = "    %d of its %d entries differ" % (len(entries), len(clean) // 16)
    if times == len(entries):
        return (note + ", each an object's modification time (N_OSO):"
                " Apple's ar and linker write 0 under ZERO_AR_DATE=1\n")
    return note + ", %d of them an object's modification time alone\n" % times


def debugging(name):
    return name.startswith(".debug_") or name in MACHO_DEBUGGING


def describe(clean_path, cached_path, clean, cached, out):
    """Write how two different executables differ."""
    out.write("  clean  %d bytes sha256 %s\n" % (len(clean), digest(clean)))
    out.write("  cached %d bytes sha256 %s\n" % (len(cached), digest(cached)))
    try:
        clean_sections, clean_order = sections(clean)
        cached_sections, cached_order = sections(cached)
    except Unreadable as error:
        out.write("  cannot read the sections: %s\n" % error)
        return
    only_clean = [n for n in clean_order if n not in cached_sections]
    only_cached = [n for n in cached_order if n not in clean_sections]
    for label, names in (("only in the clean build", only_clean),
                         ("only in the cached build", only_cached)):
        if names:
            out.write("  sections %s: %s\n" % (label, ", ".join(names)))
    changed = [n for n in clean_order
               if n in cached_sections and clean_sections[n] != cached_sections[n]]
    for name in changed:
        (clean_fields, clean_bytes) = clean_sections[name]
        (cached_fields, cached_bytes) = cached_sections[name]
        out.write("  section %s differs: %d bytes in the clean build, %d in the cached%s\n"
                  % (name, len(clean_bytes), len(cached_bytes),
                     "" if clean_fields[:3] == cached_fields[:3]
                     else "; its type, flags or address differ too"))
        if name == "symbol table stabs":
            out.write(stab_note(clean_bytes, cached_bytes))
    if (not only_clean and not only_cached
            and [n for n in clean_order if not debugging(n)]
            == [n for n in cached_order if not debugging(n)]
            and all(debugging(n) for n in changed)):
        out.write("  only the debugging information differs; the code, the"
                  " data and the symbols are the same\n")
        return
    if clean_order != cached_order and not only_clean and not only_cached:
        out.write("  the sections are in another order\n")
    if clean[:4] == b"\xcf\xfa\xed\xfe":
        #  compare_images reads ELF alone; the sections above are the report.
        return
    try:
        clean_image = compare_images.Image(clean_path)
        cached_image = compare_images.Image(cached_path)
    except compare_images.NotAnImage as error:
        out.write("  cannot read the loaded bytes: %s\n" % error)
        return
    if clean_image.same_load(cached_image):
        out.write("  the loaded bytes are the same\n")
    else:
        compare_images.describe(clean_image, cached_image, 12, out)


def requested(path):
    """A manifest's rows but those naming what was linked."""
    return [row for row in Path(path).read_text().splitlines()
            if not row.startswith("linked ")]


def compare(clean_dir, cached_dir, names, out=None):
    """Compare two unpacked builds; the exit status."""
    out = out or sys.stdout
    clean_dir, cached_dir = Path(clean_dir), Path(cached_dir)
    missing = [str(directory / relative)
               for directory in (clean_dir, cached_dir)
               for relative in [*MANIFESTS, *("bin/" + n for n in names)]
               if not (directory / relative).is_file()]
    if missing:
        for path in missing:
            print("compare_builds: %s is missing" % path, file=sys.stderr)
        return 2
    differ = 0
    for manifest in MANIFESTS:
        clean_rows = requested(clean_dir / manifest)
        cached_rows = requested(cached_dir / manifest)
        if clean_rows != cached_rows:
            differ += 1
            rows = sorted(set(clean_rows) ^ set(cached_rows))
            out.write("DIFFER %s: the builds record other inputs, %d row(s)"
                      " in one alone:\n" % (manifest, len(rows)))
            for row in rows[:12]:
                side = "clean" if row in clean_rows else "cached"
                out.write("  %s: %s\n" % (side, row))
            if len(rows) > 12:
                out.write("  and %d more\n" % (len(rows) - 12))
    for name in names:
        clean_path = clean_dir / "bin" / name
        cached_path = cached_dir / "bin" / name
        clean, cached = clean_path.read_bytes(), cached_path.read_bytes()
        if clean == cached:
            out.write("SAME %s: %d bytes, sha256 %s\n"
                      % (name, len(clean), digest(clean)))
            continue
        differ += 1
        out.write("DIFFER %s\n" % name)
        describe(clean_path, cached_path, clean, cached, out)
    out.write("%s\n" % ("the cached build is the clean build's equal"
                        if not differ else
                        "%d difference(s): the cached build is not the clean"
                        " build's equal, so no lane that took it counts"
                        % differ))
    return 1 if differ else 0


def main(argv):
    parser = argparse.ArgumentParser(
        prog="compare_builds.py",
        description="Require a cached build's executables to be the clean "
                    "build's, byte for byte, and its manifests to record "
                    "the same inputs.")
    parser.add_argument("clean", help="the unpacked clean build")
    parser.add_argument("cached", help="the unpacked build made over the cache")
    parser.add_argument("names", nargs="+", metavar="NAME",
                        help="an executable under each build's bin/")
    given = parser.parse_args(argv)
    try:
        return compare(given.clean, given.cached, given.names)
    except OSError as error:
        print("compare_builds: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
