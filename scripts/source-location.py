#!/usr/bin/env python3
"""Resolve D192 caller coordinates using the matching compiler file table."""

import argparse
import bisect
import hashlib
import json
import sys
from pathlib import Path


def resolve(table, file_id):
    """Return filesystem bytes without interpreting colons or path encoding."""
    entries = [entry for entry in table["files"] if entry["file_id"] == file_id]
    if len(entries) != 1:
        raise ValueError(f"file ID {file_id} has no unique entry in this table")
    return bytes.fromhex(entries[0]["path_hex"])


def panic_position(table, site):
    """Decode the four check-family slots at each canonical source byte."""
    if not 0 < site < 2**32:
        raise ValueError("panic site must be a nonzero u32; zero is a synthetic guard")
    entries = [entry for entry in table["files"]
               if "panic_base" in entry and entry["panic_base"] <= site
               < entry["panic_base"] + 4 * (entry["byte_length"] + 1)]
    if len(entries) != 1:
        raise ValueError("panic site has no unique entry in this table")
    entry = entries[0]
    offset, kind = divmod(site - entry["panic_base"], 4)
    lines = entry["line_offsets"]
    if not lines or lines[0] != 0 or any(a >= b for a, b in zip(lines, lines[1:])):
        raise ValueError("invalid panic line map")
    line = bisect.bisect_right(lines, offset)
    column = offset - lines[line - 1] + 1
    reason = ("out_of_range", "overflow", "bad_conversion", "unreachable")[kind]
    return entry["file_id"], line, column, reason


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("table", type=Path)
    parser.add_argument("file_id", type=int, nargs="?")
    parser.add_argument("line", type=int, nargs="?")
    parser.add_argument("column", type=int, nargs="?")
    parser.add_argument("--panic-site", type=int, help="compiler-check site number")
    identity = parser.add_mutually_exclusive_group(required=True)
    identity.add_argument("--build-id", help="ELF build ID of the diagnosed build")
    identity.add_argument("--assembly", type=Path, help="assembly from that build")
    identity.add_argument("--macho", type=Path, help="native arm64 executable")
    parser.add_argument("--dsym", type=Path, help="matching dSYM DWARF file (with --macho)")
    args = parser.parse_args()
    try:
        table = json.loads(args.table.read_text(encoding="ascii"))
        if args.build_id is not None and args.build_id.lower() != table["build_id"]:
            raise ValueError("build ID does not match the source table")
        if args.assembly is not None:
            digest = hashlib.sha256(args.assembly.read_bytes()).hexdigest()
            if digest != table["assembly_sha256"]:
                raise ValueError("assembly does not match the source table")
        if args.dsym is not None and args.macho is None:
            raise ValueError("--dsym requires --macho")
        if args.macho is not None:
            from macho_identity import match
            match(table, args.macho, args.dsym)
        reason = ""
        if args.panic_site is not None:
            if any(value is not None for value in (args.file_id, args.line, args.column)):
                raise ValueError("choose panic site or caller coordinates")
            args.file_id, args.line, args.column, reason = panic_position(table, args.panic_site)
        elif any(value is None or value < 1 for value in (args.file_id, args.line, args.column)):
            raise ValueError("three positive caller coordinates are required")
        path = resolve(table, args.file_id)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    # The table records filesystem bytes, not text in stdout's encoding.
    # In particular, strict UTF-8 stdout must not reject a non-UTF-8 name.
    suffix = f" ({reason})" if reason else ""
    sys.stdout.buffer.write(path + f":{args.line}:{args.column}{suffix}\n".encode("ascii"))


if __name__ == "__main__":
    main()
