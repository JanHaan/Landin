#!/usr/bin/env python3
"""Compare the images two compilers linked over one lane's corpus.

A change that should leave a firmware image alone, or should change only
the routines it names, is shown to by running a lane twice, once with the
compiler built before the change and once with the one built after it,
each into an output directory of its own, and comparing the two trees:

    compare_images.py BASE_DIR NEW_DIR [--names=N]

Every `*.elf` under NEW_DIR is compared with the file at the same relative
path under BASE_DIR.  Two images are the same when they load the same
bytes: the same entry point, the same PT_LOAD segments, each at the same
virtual and physical address with the same sizes and flags, and the same
file bytes in each.  Sections that load nothing, the symbol table and the
debugging information among them, are not compared, so an image whose
only change is a path or a line number in its debugging information is
the same image.

For an image that differs the report names what differs: the entry point
and the segment table when they do, then the routines (`FUNC` symbols)
and the data (`OBJECT` symbols) of another size, those of the same size
whose loaded bytes differ, those only in one image, those whose bytes are
the same at another address, and the loaded bytes that lie outside every
named symbol.  A symbol's bytes are
read from its image's segments at its address, with a Thumb routine's
address bit cleared, and a symbol in a segment's zero-filled tail reads as
zeros; a symbol of no recorded size extends to the next symbol or to the
end of its segment.  A name several local symbols share is told apart by
its order of address.  An instruction that reaches another routine, a
call or a literal, changes when that routine moves, so a routine is often
named because something before it grew; the moved routines beside it say
so.  At most N names are printed in each list, 12 by default, then a count
of the rest.

Images only in one tree are named, and the last line counts each kind.
The exit status is 0 when both trees hold the same images and every one is
the same, 1 when any differs or is in one tree alone, and 2 when an operand
is no directory or a file named `*.elf` is no ELF image this reads.  ELF of
either class and either byte order is read; the lanes' Cortex-M, RV32 and
Xtensa images are 32-bit little-endian.  Standard-library Python, reading
the files alone: it needs no toolchain.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

PT_LOAD = 1
SHT_SYMTAB = 2
STT_OBJECT = 1
STT_FUNC = 2
SHN_UNDEF = 0
SHN_LORESERVE = 0xFF00
EM_ARM = 40


class NotAnImage(Exception):
    """A file this cannot read as an ELF image."""


class Image:
    """One ELF file's loaded content and its named routines and data."""

    def __init__(self, path):
        self.path = Path(path)
        data = self.path.read_bytes()
        if len(data) < 52 or data[:4] != b"\x7fELF":
            raise NotAnImage("not an ELF file")
        if data[4] not in (1, 2) or data[5] not in (1, 2):
            raise NotAnImage("unknown ELF class %d or byte order %d"
                             % (data[4], data[5]))
        self.wide = data[4] == 2
        order = "<" if data[5] == 1 else ">"
        try:
            self._read(data, order)
        except (struct.error, IndexError, ValueError) as error:
            raise NotAnImage("truncated or malformed ELF: %s" % error) from None

    def _read(self, data, order):
        if self.wide:
            (machine, _, entry, phoff, shoff, _, _, phentsize, phnum,
             shentsize, shnum, _) = struct.unpack_from(order + "HIQQQIHHHHHH",
                                                        data, 18)
        else:
            (machine, _, entry, phoff, shoff, _, _, phentsize, phnum,
             shentsize, shnum, _) = struct.unpack_from(order + "HIIIIIHHHHHH",
                                                        data, 18)
        self.entry = entry
        #  (vaddr, paddr, filesz, memsz, flags) and the file bytes, in the
        #  order the program headers give them.
        self.segments = []
        for index in range(phnum):
            at = phoff + index * phentsize
            if self.wide:
                (kind, flags, offset, vaddr, paddr, filesz, memsz,
                 _) = struct.unpack_from(order + "IIQQQQQQ", data, at)
            else:
                (kind, offset, vaddr, paddr, filesz, memsz, flags,
                 _) = struct.unpack_from(order + "IIIIIIII", data, at)
            if kind != PT_LOAD:
                continue
            if offset + filesz > len(data):
                raise ValueError("a segment runs past the end of the file")
            self.segments.append(((vaddr, paddr, filesz, memsz, flags),
                                  data[offset:offset + filesz]))
        self.symbols = self._symbols(data, order, machine, shoff, shentsize,
                                     shnum)

    def _symbols(self, data, order, machine, shoff, shentsize, shnum):
        """{(kind, name, occurrence): (address, size)} for sized routines and data."""
        header = order + ("IIQQQQIIQQ" if self.wide else "IIIIIIIIII")
        sections = [struct.unpack_from(header, data, shoff + i * shentsize)
                    for i in range(shnum)] if shoff else []
        found = []
        for section in sections:
            if section[1] != SHT_SYMTAB:
                continue
            offset, size, link, entsize = (section[4], section[5], section[6],
                                           section[9])
            strings = sections[link][4]
            for at in range(offset + entsize, offset + size, entsize):
                if self.wide:
                    name, info, _, shndx, value, length = struct.unpack_from(
                        order + "IBBHQQ", data, at)
                else:
                    name, value, length, info, _, shndx = struct.unpack_from(
                        order + "IIIBBH", data, at)
                kind = info & 0xF
                if kind not in (STT_FUNC, STT_OBJECT):
                    continue
                if shndx == SHN_UNDEF or shndx >= SHN_LORESERVE:
                    continue
                if kind == STT_FUNC and machine == EM_ARM:
                    value &= ~1
                end = data.index(b"\0", strings + name)
                found.append((value, length, kind,
                              data[strings + name:end].decode("utf-8", "replace")))
        found.sort()
        starts = sorted({value for value, _, _, _ in found})
        symbols, seen = {}, {}
        for value, length, kind, name in found:
            if not length:
                length = self._extent(value, starts)
            label = "routine" if kind == STT_FUNC else "data"
            occurrence = seen.get((label, name), 0)
            seen[(label, name)] = occurrence + 1
            symbols[(label, name, occurrence)] = (value, length)
        return symbols

    def _extent(self, value, starts):
        """The bytes from VALUE to the next symbol or its segment's end."""
        for (vaddr, _, _, memsz, _), _ in self.segments:
            if vaddr <= value < vaddr + memsz:
                later = [start for start in starts
                         if value < start < vaddr + memsz]
                return (min(later) if later else vaddr + memsz) - value
        return 0

    def header(self):
        return self.entry, [fields for fields, _ in self.segments]

    def same_load(self, other):
        return (self.header() == other.header()
                and [b for _, b in self.segments] == [b for _, b in other.segments])

    def read(self, address, size):
        """SIZE loaded bytes at ADDRESS, or None where nothing is loaded."""
        for (vaddr, _, _, memsz, _), contents in self.segments:
            if vaddr <= address and address + size <= vaddr + memsz:
                start = address - vaddr
                chunk = contents[start:start + size]
                return chunk + bytes(size - len(chunk))
        return None

    def boundaries(self):
        """Every address a segment of this image starts or ends at."""
        return {edge for (vaddr, _, _, memsz, _), _ in self.segments
                for edge in (vaddr, vaddr + memsz)}

    def spans(self):
        """(start, end) of every named symbol of this image."""
        return [(address, address + size)
                for address, size in self.symbols.values() if size]


#  Bytes compared at once before a differing block is read byte by byte.
BLOCK = 4096


def differing_runs(base, new):
    """[start, end) runs of addresses whose loaded bytes differ.

    An address one image loads and the other does not differs.  Every
    segment edge of either image is a boundary, so each interval between
    two is loaded whole or not at all by each image.
    """
    edges = sorted(base.boundaries() | new.boundaries())
    runs = []

    def add(start, end):
        if runs and runs[-1][1] == start:
            runs[-1][1] = end
        else:
            runs.append([start, end])

    for start, end in zip(edges, edges[1:]):
        before, after = base.read(start, end - start), new.read(start, end - start)
        if before is None and after is None or before == after:
            continue
        if before is None or after is None:
            add(start, end)
            continue
        for block in range(0, end - start, BLOCK):
            if before[block:block + BLOCK] == after[block:block + BLOCK]:
                continue
            for offset in range(block, min(block + BLOCK, end - start)):
                if before[offset] != after[offset]:
                    add(start + offset, start + offset + 1)
    return runs


def subtract(runs, spans):
    """The parts of RUNS no span of SPANS covers."""
    merged = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    left = []
    for start, end in runs:
        for cover_start, cover_end in merged:
            if cover_end <= start or cover_start >= end:
                continue
            if cover_start > start:
                left.append((start, cover_start))
            start = max(start, cover_end)
            if start >= end:
                break
        if start < end:
            left.append((start, end))
    return left


def symbol_differences(base, new):
    """What differs between two images, by named symbol and outside them."""
    resized, changed, moved = {"routine": [], "data": []}, {"routine": [], "data": []}, []
    only_base = {"routine": [], "data": []}
    only_new = {"routine": [], "data": []}

    def shown(key):
        label, name, occurrence = key
        return name if not occurrence else "%s (%d)" % (name, occurrence + 1)

    for key in sorted(set(base.symbols) | set(new.symbols),
                      key=lambda k: (k[0], k[1], k[2])):
        label = key[0]
        if key not in new.symbols:
            only_base[label].append(shown(key))
            continue
        if key not in base.symbols:
            only_new[label].append(shown(key))
            continue
        (base_at, base_size), (new_at, new_size) = base.symbols[key], new.symbols[key]
        before, after = base.read(base_at, base_size), new.read(new_at, new_size)
        if base_size != new_size:
            resized[label].append(shown(key))
        elif before != after:
            changed[label].append(shown(key))
        elif base_at != new_at:
            moved.append(shown(key))
    #  Loaded bytes no named symbol of either image spans.
    outside = subtract(differing_runs(base, new), base.spans() + new.spans())
    return resized, changed, only_base, only_new, moved, outside


def names_line(title, names, limit):
    listed = ", ".join(names[:limit])
    rest = len(names) - limit
    return "  %s (%d): %s%s" % (title, len(names), listed,
                                ", and %d more" % rest if rest > 0 else "")


def describe(base, new, limit, out):
    """Write what differs between two images that do not load the same bytes."""
    if base.entry != new.entry:
        out.write("  entry 0x%x, was 0x%x\n" % (new.entry, base.entry))
    if base.header()[1] != new.header()[1]:
        for which, image in (("base", base), ("new", new)):
            out.write("  %s segments:" % which)
            for vaddr, paddr, filesz, memsz, flags in image.header()[1]:
                out.write(" [0x%x lma 0x%x file 0x%x mem 0x%x flags %d]"
                          % (vaddr, paddr, filesz, memsz, flags))
            out.write("\n")
    (resized, changed, only_base, only_new, moved,
     outside) = symbol_differences(base, new)
    for label, plural in (("routine", "routines"), ("data", "data")):
        if resized[label]:
            out.write(names_line(plural + " of another size", resized[label],
                                 limit) + "\n")
        if changed[label]:
            out.write(names_line(plural + " of the same size whose bytes differ",
                                 changed[label],
                                 limit) + "\n")
        if only_base[label]:
            out.write(names_line(plural + " only in base", only_base[label],
                                 limit) + "\n")
        if only_new[label]:
            out.write(names_line(plural + " only in new", only_new[label],
                                 limit) + "\n")
    if moved:
        out.write(names_line("the same bytes at another address", moved, limit)
                  + "\n")
    if outside:
        shown = ", ".join("0x%x" % start if end == start + 1
                          else "0x%x-0x%x" % (start, end - 1)
                          for start, end in outside[:limit])
        rest = len(outside) - limit
        out.write("  %d loaded byte(s) outside every named symbol differ, in "
                  "%d run(s): %s%s\n"
                  % (sum(end - start for start, end in outside), len(outside),
                     shown, ", and %d more" % rest if rest > 0 else ""))


def compare(base_dir, new_dir, limit=12, out=sys.stdout):
    """Compare every image of two lane output trees; the exit status."""
    base_dir, new_dir = Path(base_dir), Path(new_dir)
    for directory in (base_dir, new_dir):
        if not directory.is_dir():
            print("compare_images: %s is not a directory" % directory,
                  file=sys.stderr)
            return 2
    new_images = {p.relative_to(new_dir) for p in new_dir.rglob("*.elf")
                  if p.is_file()}
    base_images = {p.relative_to(base_dir) for p in base_dir.rglob("*.elf")
                   if p.is_file()}
    same = differ = unreadable = 0
    for relative in sorted(new_images & base_images):
        try:
            base, new = Image(base_dir / relative), Image(new_dir / relative)
        except NotAnImage as error:
            out.write("UNREADABLE %s: %s\n" % (relative, error))
            unreadable += 1
            continue
        if base.same_load(new):
            same += 1
            continue
        differ += 1
        out.write("DIFFER %s\n" % relative)
        describe(base, new, limit, out)
    for relative in sorted(new_images - base_images):
        out.write("ONLY-NEW %s\n" % relative)
    for relative in sorted(base_images - new_images):
        out.write("ONLY-BASE %s\n" % relative)
    out.write("images %d in new, %d in base: same %d  differ %d  only in new %d"
              "  only in base %d%s\n"
              % (len(new_images), len(base_images), same, differ,
                 len(new_images - base_images), len(base_images - new_images),
                 "  unreadable %d" % unreadable if unreadable else ""))
    if unreadable:
        return 2
    return 1 if differ or new_images != base_images else 0


def names(text):
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("--names needs one or more")
    return value


def main(argv):
    parser = argparse.ArgumentParser(
        prog="compare_images.py",
        description="Compare the loaded bytes of the ELF images in two lane "
                    "output trees, by relative path.")
    parser.add_argument("base", help="the tree the base compiler's lane wrote")
    parser.add_argument("new", help="the tree the candidate's lane wrote")
    parser.add_argument("--names", type=names, default=12,
                        help="names listed in each list of a differing image")
    given = parser.parse_args(argv)
    return compare(given.base, given.new, given.names)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
