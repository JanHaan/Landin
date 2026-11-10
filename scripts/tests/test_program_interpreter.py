#!/usr/bin/env python3
"""scripts/program_interpreter.py reads the loader an executable requests.

The packager names a binary whose loader is not a system path.  ELF files
are made here byte by byte, in both widths and byte orders, so the reader
is held without a compiler: a loader in a store, a system's own, none at
all, a file that is not ELF, and headers that end early.
"""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/program_interpreter.py"
spec = importlib.util.spec_from_file_location("program_interpreter", SCRIPT)
READER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(READER)

#  Seconds before the script, which answers at once, is called hung.
HANG = 300
STORE = "/nix/store/abc-glibc-2.42-67/lib/ld-linux-x86-64.so.2"


def elf(loader, wide=True, little=True):
    """An ELF file of one PT_LOAD and, with LOADER, one PT_INTERP."""
    order = "<" if little else ">"
    ident = b"\x7fELF" + bytes([2 if wide else 1, 1 if little else 2, 1]) \
        + bytes(9)
    header_size, entry_size = (64, 56) if wide else (52, 32)
    kinds = [1] + ([3] if loader is not None else [])
    name = (loader or "").encode() + b"\0"
    where = header_size + entry_size * len(kinds)
    if wide:
        header = ident + struct.pack(order + "HHIQQQIHHHHHH", 2, 62, 1, 0,
                                     header_size, 0, 0, header_size,
                                     entry_size, len(kinds), 0, 0, 0)
        entries = b"".join(struct.pack(order + "IIQQQQQQ", kind, 4, where, 0,
                                       0, len(name), len(name), 1)
                           for kind in kinds)
    else:
        header = ident + struct.pack(order + "HHIIIIIHHHHHH", 2, 3, 1, 0,
                                     header_size, 0, 0, header_size,
                                     entry_size, len(kinds), 0, 0, 0)
        entries = b"".join(struct.pack(order + "IIIIIIII", kind, where, 0, 0,
                                       len(name), len(name), 4, 1)
                           for kind in kinds)
    return header + entries + name


class ProgramInterpreter(unittest.TestCase):
    def test_the_loader_is_read_in_each_width_and_byte_order(self):
        for wide in (True, False):
            for little in (True, False):
                with self.subTest(wide=wide, little=little):
                    self.assertEqual(
                        READER.interpreter(elf(STORE, wide, little)), STORE)

    def test_a_static_executable_and_a_file_that_is_not_elf_name_none(self):
        self.assertIsNone(READER.interpreter(elf(None)))
        self.assertIsNone(READER.interpreter(b"\xcf\xfa\xed\xfe" + bytes(60)))
        self.assertIsNone(READER.interpreter(b""))

    def test_headers_that_end_early_are_an_error(self):
        whole = elf(STORE)
        for cut in (5, 40, 70, len(whole) - 8):
            with self.subTest(cut=cut), self.assertRaises(ValueError):
                READER.interpreter(whole[:cut])

    def test_a_systems_own_loader_is_told_from_one_in_a_store(self):
        for path in ("/lib64/ld-linux-x86-64.so.2", "/lib/ld-linux-aarch64.so.1",
                     "/libexec/ld-elf.so.1", "/usr/lib/ld.so.1"):
            self.assertTrue(READER.system_path(path), path)
        for path in (STORE, "/gnu/store/abc/lib/ld.so", "/home/someone/ld.so",
                     "/opt/toolchain/lib64/ld.so", "ld.so"):
            self.assertFalse(READER.system_path(path), path)

    def test_the_command_says_which_by_its_status(self):
        with tempfile.TemporaryDirectory() as directory:
            for name, data, status, printed in (
                    ("store", elf(STORE), 3, STORE + "\n"),
                    ("system", elf("/lib64/ld-linux-x86-64.so.2"), 0,
                     "/lib64/ld-linux-x86-64.so.2\n"),
                    ("static", elf(None), 0, ""),
                    ("text", b"#!/bin/sh\n", 0, ""),
                    ("cut", elf(STORE)[:40], 1, "")):
                with self.subTest(name=name):
                    path = Path(directory, name)
                    path.write_bytes(data)
                    ran = subprocess.run(
                        [sys.executable, str(SCRIPT), str(path)],
                        capture_output=True, text=True, timeout=HANG)
                    self.assertEqual((ran.returncode, ran.stdout),
                                     (status, printed), ran.stderr)
            ran = subprocess.run(
                [sys.executable, str(SCRIPT), str(Path(directory, "absent"))],
                capture_output=True, text=True, timeout=HANG)
            self.assertEqual(ran.returncode, 1)
            self.assertIn("absent", ran.stderr)


if __name__ == "__main__":
    unittest.main()
