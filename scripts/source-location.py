#!/usr/bin/env python3
"""Resolve D192 caller coordinates using the matching compiler file table."""

import argparse
import hashlib
import json
import os
from pathlib import Path


def resolve(table, file_id):
    """Return filesystem bytes without interpreting colons or path encoding."""
    entries = [entry for entry in table["files"] if entry["file_id"] == file_id]
    if len(entries) != 1:
        raise ValueError(f"file ID {file_id} has no unique entry in this table")
    return bytes.fromhex(entries[0]["path_hex"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("table", type=Path)
    parser.add_argument("file_id", type=int)
    parser.add_argument("line", type=int)
    parser.add_argument("column", type=int)
    identity = parser.add_mutually_exclusive_group(required=True)
    identity.add_argument("--build-id", help="ELF build ID of the diagnosed build")
    identity.add_argument("--assembly", type=Path, help="assembly from that build")
    args = parser.parse_args()
    try:
        if min(args.file_id, args.line, args.column) < 1:
            raise ValueError("caller coordinates must be positive")
        table = json.loads(args.table.read_text(encoding="ascii"))
        if args.build_id is not None and args.build_id.lower() != table["build_id"]:
            raise ValueError("build ID does not match the source table")
        if args.assembly is not None:
            digest = hashlib.sha256(args.assembly.read_bytes()).hexdigest()
            if digest != table["assembly_sha256"]:
                raise ValueError("assembly does not match the source table")
        path = os.fsdecode(resolve(table, args.file_id))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    print(f"{path}:{args.line}:{args.column}")


if __name__ == "__main__":
    main()
