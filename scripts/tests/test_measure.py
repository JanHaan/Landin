"""scripts/measure.py: its image readers and the rule a candidate is held to.

docs/measurement.md is the contract: a size differing from the base's
baseline fails unless the candidate's own baselines record exactly the
measured figure; a new key is declared the same way; a moved linker is
named and fails nothing that still matches.
"""

import contextlib
import hashlib
import io
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import measure  # noqa: E402


def elf32(sections):
    """A little-endian ELF32 image holding SECTIONS: (name, kind, flags, data)."""
    names = b"\0" + b"".join(n.encode() + b"\0" for n, *_ in sections) + b".shstrtab\0"
    body = b"".join(data for *_, data in sections)
    shoff = 52 + len(body) + len(names)
    header = b"\x7fELF" + bytes([1, 1, 1]) + bytes(9)
    header += struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0, 0, shoff, 0, 52, 0, 0,
                          40, len(sections) + 2, len(sections) + 1)
    table = [struct.pack("<IIIIIIIIII", *([0] * 10))]
    offset, name_at = 52, 1
    for name, kind, flags, data in sections:
        table.append(struct.pack("<IIIIIIIIII", name_at, kind, flags, 0, offset,
                                 len(data) or 16, 0, 0, 1, 0))
        offset += len(data)
        name_at += len(name) + 1
    table.append(struct.pack("<IIIIIIIIII", name_at, 3, 0, 0, offset,
                             len(names), 0, 0, 1, 0))
    return header + body + names + b"".join(table)


class Images(unittest.TestCase):
    def test_only_allocated_sections_count(self):
        image = elf32([(".text", 1, 0x6, b"\x01" * 8), (".comment", 1, 0, b"x" * 5),
                       (".bss", 8, 0x3, b"")])
        self.assertEqual(measure.elf_sections(image), {".text": 8, ".bss": 16})

    def test_the_digest_reads_contents_not_the_file(self):
        one = elf32([(".text", 1, 0x6, b"\x01" * 8), (".comment", 1, 0, b"a")])
        two = elf32([(".text", 1, 0x6, b"\x01" * 8), (".comment", 1, 0, b"b")])
        three = elf32([(".text", 1, 0x6, b"\x02" * 8), (".comment", 1, 0, b"a")])
        digests = []
        for image in (one, two, three):
            digest = hashlib.sha256()
            measure.elf_sections(image, digest)
            digests.append(digest.hexdigest())
        self.assertEqual(digests[0], digests[1])
        self.assertNotEqual(digests[0], digests[2])

    def test_a_mach_o_image_names_segment_and_section(self):
        section = (b"__text".ljust(16, b"\0") + b"__TEXT".ljust(16, b"\0")
                   + struct.pack("<QQIIIIIIII", 0x1000, 24, 0, 0, 0, 0, 0, 0, 0, 0))
        command = struct.pack("<II", 0x19, 72 + 80) + bytes(56) + struct.pack(
            "<II", 1, 0) + section
        image = struct.pack("<IIIIIIII", 0xFEEDFACF, 0, 0, 2, 1, len(command), 0, 0)
        self.assertEqual(measure.macho_sections(image + command), {"__TEXT,__text": 24})


class Compare(unittest.TestCase):
    def run_compare(self, measured, base, candidate):
        with tempfile.TemporaryDirectory() as where:
            path = Path(where) / "size.json"
            path.write_text(json.dumps(measured))
            output = io.StringIO()
            with mock.patch.object(measure, "read_baseline",
                                   lambda target, rev: base if rev else candidate), \
                    contextlib.redirect_stdout(output), \
                    contextlib.redirect_stderr(io.StringIO()):
                status = measure.compare(mock.Mock(
                    measurements=str(path), base="BASE", verbose=True))
        return status, output.getvalue()

    def figures(self, text, environment="env"):
        return {"schema": 1, "environments": {"t": environment},
                "targets": {"t": {"l/size-auto/w": {"sections": {".text": text}}}}}

    def baseline(self, text, environment="env"):
        return {"environment": environment,
                "entries": {"l/size-auto/w": {"sections": {".text": text}}}}

    def test_an_unchanged_image_passes(self):
        status, _ = self.run_compare(self.figures(10), self.baseline(10), self.baseline(10))
        self.assertEqual(status, 0)

    def test_growth_and_shrinking_both_fail_undeclared(self):
        for text in (11, 9):
            status, output = self.run_compare(
                self.figures(text), self.baseline(10), self.baseline(10))
            self.assertEqual(status, 1)
            self.assertIn("UNDECLARED", output)

    def test_the_candidates_baseline_declares_a_change(self):
        status, output = self.run_compare(
            self.figures(12), self.baseline(10), self.baseline(12))
        self.assertEqual(status, 0)
        self.assertIn("10 -> 12 (+2)", output)

    def test_a_declaration_must_match_the_measurement(self):
        status, _ = self.run_compare(self.figures(12), self.baseline(10), self.baseline(11))
        self.assertEqual(status, 1)

    def test_a_key_with_no_baseline_is_unrecorded(self):
        status, output = self.run_compare(self.figures(10), {}, {})
        self.assertEqual(status, 1)
        self.assertIn("UNRECORDED", output)

    def test_a_moved_linker_is_named_and_judged_by_the_figure(self):
        status, output = self.run_compare(
            self.figures(10, "new"), self.baseline(10, "old"), self.baseline(10, "old"))
        self.assertEqual(status, 0)
        self.assertIn("linker moved", output)
        status, _ = self.run_compare(
            self.figures(11, "new"), self.baseline(10, "old"), self.baseline(10, "old"))
        self.assertEqual(status, 1)


class Record(unittest.TestCase):
    def test_record_writes_the_named_keys_alone(self):
        measured = {"schema": 1, "environments": {"t": "env"}, "targets": {"t": {
            "a/none-off/w": {"sections": {".text": 1}},
            "b/none-off/w": {"sections": {".text": 2}}}}}
        with tempfile.TemporaryDirectory() as where:
            where = Path(where)
            (where / "size.json").write_text(json.dumps(measured))
            with mock.patch.object(measure, "BASELINES", where / "b"), \
                    mock.patch.object(measure, "ROOT", where), \
                    contextlib.redirect_stdout(io.StringIO()):
                measure.record(mock.Mock(measurements=str(where / "size.json"),
                                         from_run=None, key=["t b/none-off/w"]))
                written = json.loads((where / "b" / "t.size.json").read_text())
        self.assertEqual(list(written["entries"]), ["b/none-off/w"])
        self.assertEqual(written["environment"], "env")


class Levels(unittest.TestCase):
    def test_kernel_flag_spellings(self):
        cpuinfo = "flags\t: fpu cx16 lahf_lm pni avx2\n"
        with mock.patch.object(measure.sys, "platform", "linux"), \
                mock.patch.object(measure.Path, "read_text", lambda self: cpuinfo):
            self.assertEqual(measure.host_lacks(["cmpxchg16b", "lahf", "sse3", "avx2"]), [])
            self.assertEqual(measure.host_lacks(["avx512f"]), ["avx512f"])


if __name__ == "__main__":
    unittest.main()
