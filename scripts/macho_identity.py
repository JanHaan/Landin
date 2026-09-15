"""Read the native arm64 UUID and Landin source identity without tool output parsing."""
import re
import struct
from pathlib import Path


def identity(path):
    data = Path(path).read_bytes()
    if len(data) < 32:
        raise ValueError("truncated Mach-O header")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or kind not in (2, 10):
        raise ValueError("expected a thin arm64 Mach-O executable or dSYM")
    end = 32 + size
    if end > len(data) or count > size // 8:
        raise ValueError("invalid Mach-O load commands")
    uuid = None
    digest = None
    cursor = 32
    for _ in range(count):
        if cursor + 8 > end:
            raise ValueError("truncated Mach-O load command")
        command, length = struct.unpack_from("<II", data, cursor)
        if length < 8 or length % 8 or cursor + length > end:
            raise ValueError("invalid Mach-O load command size")
        if command == 0x1B:
            if length != 24 or uuid is not None:
                raise ValueError("invalid or duplicate Mach-O UUID")
            uuid = data[cursor + 8:cursor + 24].hex()
        elif command == 0x19:
            if length < 72:
                raise ValueError("truncated Mach-O segment")
            nsects = struct.unpack_from("<I", data, cursor + 64)[0]
            if length != 72 + 80 * nsects:
                raise ValueError("invalid Mach-O sections")
            for index in range(nsects):
                at = cursor + 72 + 80 * index
                section, segment, _, extent, offset = struct.unpack_from("<16s16sQQI", data, at)
                if (kind == 2 and section.rstrip(b"\0") == b"__landin_id"
                        and segment.rstrip(b"\0") == b"__TEXT"):
                    if digest is not None or extent != 64 or offset + extent > len(data):
                        raise ValueError("invalid or duplicate Landin identity")
                    digest = data[offset:offset + extent]
                    if not re.fullmatch(b"[0-9a-f]{64}", digest):
                        raise ValueError("invalid Landin identity digest")
                    digest = digest.decode("ascii")
        cursor += length
    if cursor != end or uuid is None:
        raise ValueError("missing Mach-O UUID or invalid command extent")
    return {"uuid": uuid, "build_id": digest, "kind": kind}


def match(table, executable, dsym=None):
    binary = identity(executable)
    if binary["kind"] != 2 or binary["build_id"] != table["build_id"]:
        raise ValueError("Mach-O build ID does not match the source table")
    if dsym is not None:
        debug = identity(dsym)
        if debug["kind"] != 10 or debug["uuid"] != binary["uuid"]:
            raise ValueError("dSYM UUID does not match the executable")
    return binary
