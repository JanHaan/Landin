#!/usr/bin/env python3
"""scripts/measure_count.py without an emulator: the image it reads, the
plugin it builds and the version it asks a QEMU for, and what it refuses.
The counted runs themselves are the lanes': a Cortex-M corpus `--program`
run prints the count, and docs/measurement.md's noise study records it."""
from __future__ import annotations

from pathlib import Path
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import measure_count  # noqa: E402


def arm_image(path: Path, symbols: dict[str, tuple[int, int]]) -> None:
    """A little-endian ELF32 Arm image: one executable segment at 0x100 of
    0x80 bytes, one writable one, and SYMBOLS as NAME: (value, type)."""
    strtab = b"\0" + b"".join(name.encode() + b"\0" for name in symbols)
    shstrtab = b"\0.symtab\0.strtab\0.shstrtab\0"
    entries = [b"\0" * 16]
    at = 1
    for name, (value, kind) in symbols.items():
        entries.append(struct.pack("<IIIBBH", at, value, 0, kind, 0, 1))
        at += len(name) + 1
    symtab = b"".join(entries)
    header_size, ph_size, sh_size = 52, 32, 40
    phoff = header_size
    body = phoff + 2 * ph_size
    sym_at, str_at = body, body + len(symtab)
    shstr_at = str_at + len(strtab)
    shoff = (shstr_at + len(shstrtab) + 3) & ~3
    sections = [b"\0" * sh_size,
                struct.pack("<10I", 1, 2, 0, 0, sym_at, len(symtab), 2, 1, 4, 16),
                struct.pack("<10I", 9, 3, 0, 0, str_at, len(strtab), 0, 0, 1, 0),
                struct.pack("<10I", 17, 3, 0, 0, shstr_at, len(shstrtab), 0, 0, 1, 0)]
    header = (b"\x7fELF\x01\x01\x01" + b"\0" * 9
              + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0x101, phoff, shoff, 0,
                            header_size, ph_size, 2, sh_size, len(sections), 3))
    programs = (struct.pack("<8I", 1, 0, 0x100, 0x100, 0, 0x80, 5, 4)
                + struct.pack("<8I", 1, 0, 0x20000000, 0x20000000, 0, 0x20, 6, 4))
    data = header + programs + symtab + strtab + shstrtab
    data += b"\0" * (shoff - len(data)) + b"".join(sections)
    path.write_bytes(data)


class ImageTest(unittest.TestCase):
    def test_an_arm_image_gives_its_executable_range_and_thumb_symbols(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.elf"
            arm_image(path, {"main": (0x121, 2), "backend_done": (0x171, 2),
                             "backend_result": (0x20000000, 1)})
            image = measure_count.Image(path)
            self.assertEqual(image.machine, 40)
            #  The writable segment is not executable, so not counted.
            self.assertEqual(image.executable, (0x100, 0x180))
            #  A Thumb routine's address is its first instruction's.
            self.assertEqual(image.address("main"), 0x120)
            self.assertEqual(image.address("backend_done"), 0x170)
            self.assertEqual(image.address("backend_result"), 0x20000000)
            self.assertEqual(image.address("0x144"), 0x144)
            with self.assertRaisesRegex(measure_count.Failure, "has no symbol absent"):
                image.address("absent")

    @unittest.skipUnless(shutil.which("cc"), "no C compiler")
    def test_a_host_image_gives_its_routines(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "program.c"
            source.write_text("int twice(int x) { return 2 * x; }\n"
                              "int main(void) { return twice(21); }\n")
            path = Path(directory) / "program"
            subprocess.run(["cc", "-O0", "-o", str(path), str(source)], check=True)
            image = measure_count.Image(path)
            lo, hi = image.executable
            self.assertTrue(lo <= image.address("twice") < hi)
            self.assertTrue(lo <= image.address("main") < hi)

    def test_what_is_no_elf_image_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image"
            path.write_bytes(b"MZ" + b"\0" * 62)
            with self.assertRaisesRegex(measure_count.Failure, "not an ELF image"):
                measure_count.Image(path)


class PluginTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cc"), "no C compiler")
    def test_count_c_builds_for_each_form_of_the_api(self):
        with tempfile.TemporaryDirectory() as directory:
            for api in (2, 4, 6, 7):
                plugin = measure_count.build_plugin(api, Path(directory))
                self.assertTrue(plugin.is_file(), api)

    def test_an_api_count_c_does_not_know_is_refused_before_building(self):
        with self.assertRaisesRegex(measure_count.Failure,
                                    "version 8; count.c knows versions 2 to 7"):
            measure_count.build_plugin(8, Path("/nonexistent"))

    @unittest.skipUnless(shutil.which("cc"), "no C compiler")
    def test_the_version_is_the_one_qemu_names_refusing_the_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "qemu"
            fake.write_text("#!/bin/sh\necho 'qemu: Could not load plugin p.so: plugin"
                            " requires API version 9999, but this QEMU supports only"
                            " up to version 4' >&2\nexit 1\n")
            fake.chmod(0o755)
            self.assertEqual(measure_count.plugin_api([str(fake)]), 4)
            fake.write_text("#!/bin/sh\necho 'qemu-system-xtensa: -plugin p.so: plugin"
                            " interface not enabled in this build' >&2\nexit 1\n")
            with self.assertRaisesRegex(measure_count.Failure, "built without plugins"):
                measure_count.plugin_api([str(fake)])

    @unittest.skipUnless(shutil.which("cc"), "no C compiler")
    def test_user_emulation_named_alone_is_given_a_program(self):
        #  qemu-aarch64 alone, as `measure_count.py plugin --qemu` takes it,
        #  refuses to start without a program before it reads the plugin.
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "qemu"
            fake.write_text("#!/bin/sh\nif [ $# -lt 3 ]; then echo 'qemu: no user"
                            " program specified' >&2; exit 1; fi\necho 'qemu: plugin"
                            " requires API version 9999, but this QEMU supports only"
                            " up to version 5' >&2\nexit 1\n")
            fake.chmod(0o755)
            self.assertEqual(measure_count.plugin_api([str(fake)]), 5)

    def test_the_count_file_says_whether_its_bounds_were_met(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "count.txt"
            out.write_text("instructions 36909\n")
            self.assertEqual(measure_count.read_count(out),
                             {"instructions": 36909, "started": True, "reached": True})
            out.write_text("instructions 0\nstarted 0\nreached 0\n")
            self.assertEqual(measure_count.read_count(out),
                             {"instructions": 0, "started": False, "reached": False})
            out.unlink()
            with self.assertRaisesRegex(measure_count.Failure, "wrote no"):
                measure_count.read_count(out)


class RefusalTest(unittest.TestCase):
    def test_the_espressif_targets_are_refused_naming_why(self):
        for target in ("rv32", "xtensa"):
            with self.assertRaisesRegex(measure_count.Failure,
                                        "built without plugins"):
                measure_count.count(target, "any", Path("/nonexistent"))

    def test_a_target_with_no_emulated_count_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.elf"
            arm_image(path, {"main": (0x121, 2)})
            with self.assertRaisesRegex(measure_count.Failure,
                                        "only linux-rv64 and cortex-m0"):
                measure_count.count("linux-x86-64", "x86-64-v1", path)

    def test_a_firmware_program_takes_no_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.elf"
            arm_image(path, {"main": (0x121, 2)})
            with self.assertRaisesRegex(measure_count.Failure, "no arguments"):
                measure_count.count("cortex-m0", "armv6-m", path, ["7"])

    def test_measure_py_can_take_the_commands(self):
        import argparse
        top = argparse.ArgumentParser()
        measure_count.add_commands(top.add_subparsers(dest="command"))
        args = measure_count.parse(top, ["count", "--target", "linux-rv64", "--level",
                                         "rv64gc", "image", "--from", "a", "--to", "b",
                                         "--", "7"])
        self.assertEqual((getattr(args, "from"), args.to, args.arguments), ("a", "b", ["7"]))
        self.assertIs(args.run, measure_count.run_count)


if __name__ == "__main__":
    unittest.main()
