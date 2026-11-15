"""compare_images.py over ELF images written here, without a toolchain."""

import contextlib
import io
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compare_images  # noqa: E402

FUNC, OBJECT, NOTYPE = 2, 1, 0
EM_ARM, EM_XTENSA, EM_RISCV = 40, 94, 243


def elf(segments, symbols=(), entry=0x100, machine=EM_ARM, wide=False,
        order="<"):
    """An executable ELF: SEGMENTS as (vaddr, contents, memsz), SYMBOLS as
    (name, value, size, kind, section index), a section index 0 meaning
    undefined, and a symbol table with its strings."""
    ehsize, phentsize, shentsize = ((64, 56, 64) if wide else (52, 32, 40))
    phoff = ehsize
    body = bytearray()
    at = phoff + phentsize * len(segments)
    headers = []
    for vaddr, contents, memsz in segments:
        headers.append((at + len(body), vaddr, len(contents), memsz))
        body += contents
    strings = b"\0" + b"".join(name.encode() + b"\0" for name, *_ in symbols)
    entsize = 24 if wide else 16
    table = bytearray(entsize)
    name_at = 1
    for name, value, size, kind, section in symbols:
        if wide:
            table += struct.pack(order + "IBBHQQ", name_at, kind, 0, section,
                                 value, size)
        else:
            table += struct.pack(order + "IIIBBH", name_at, value, size, kind,
                                 0, section)
        name_at += len(name) + 1
    table_at = at + len(body)
    strings_at = table_at + len(table)
    shoff = strings_at + len(strings)
    out = bytearray()
    ident = b"\x7fELF" + bytes([2 if wide else 1, 1 if order == "<" else 2, 1])
    out += ident + bytes(16 - len(ident))
    if wide:
        out += struct.pack(order + "HHIQQQIHHHHHH", 2, machine, 1, entry, phoff,
                           shoff, 0, ehsize, phentsize, len(segments),
                           shentsize, 3, 0)
    else:
        out += struct.pack(order + "HHIIIIIHHHHHH", 2, machine, 1, entry, phoff,
                           shoff, 0, ehsize, phentsize, len(segments),
                           shentsize, 3, 0)
    for offset, vaddr, filesz, memsz in headers:
        if wide:
            out += struct.pack(order + "IIQQQQQQ", 1, 5, offset, vaddr, vaddr,
                               filesz, memsz, 4)
        else:
            out += struct.pack(order + "IIIIIIII", 1, offset, vaddr, vaddr,
                               filesz, memsz, 5, 4)
    out += body + table + strings
    form = order + ("IIQQQQIIQQ" if wide else "IIIIIIIIII")
    out += bytes(shentsize)
    out += struct.pack(form, 0, 2, 0, 0, table_at, len(table), 2, 0, 4, entsize)
    out += struct.pack(form, 0, 3, 0, 0, strings_at, len(strings), 0, 0, 1, 0)
    return bytes(out)


#  Three routines and one datum in one text segment, and a zero-filled one.
TEXT = 0x100
CODE = bytes(range(16)) + bytes(range(16, 32)) + bytes(range(32, 48)) + b"DATA"
SYMBOLS = [("first", TEXT | 1, 16, FUNC, 1), ("second", TEXT + 16 | 1, 16, FUNC, 1),
           ("third", TEXT + 32 | 1, 16, FUNC, 1), ("table", TEXT + 48, 4, OBJECT, 1),
           ("$t", TEXT, 0, NOTYPE, 1), ("counter", 0x2000, 4, OBJECT, 2),
           ("imported", 0, 0, FUNC, 0)]


def image(code=CODE, symbols=SYMBOLS, **given):
    return elf([(TEXT, code, len(code)), (0x2000, b"", 64)], symbols, **given)


class Trees(unittest.TestCase):
    def compare(self, base, new, limit=12):
        with tempfile.TemporaryDirectory() as tmp:
            for side, files in (("base", base), ("new", new)):
                for relative, contents in files.items():
                    path = Path(tmp) / side / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(contents)
                (Path(tmp) / side).mkdir(exist_ok=True)
            out = io.StringIO()
            status = compare_images.compare(Path(tmp) / "base", Path(tmp) / "new",
                                            limit, out)
        return status, out.getvalue()

    def test_identical_trees_are_the_same(self):
        files = {"a/core.elf": image(), "b.elf": image(machine=EM_RISCV),
                 "a/core.map": b"not compared"}
        status, said = self.compare(files, dict(files))
        self.assertEqual(status, 0, said)
        self.assertEqual(said, "images 2 in new, 2 in base: same 2  differ 0  "
                               "only in new 0  only in base 0\n")

    def test_debugging_and_symbols_do_not_make_an_image_differ(self):
        #  The same loaded bytes under other names: nothing loaded changed.
        renamed = [("other" + name, *rest) for name, *rest in SYMBOLS]
        status, said = self.compare({"x.elf": image()},
                                    {"x.elf": image(symbols=renamed)})
        self.assertEqual(status, 0, said)

    def test_a_changed_routine_is_named_and_no_other(self):
        code = bytearray(CODE)
        code[20] ^= 0xFF
        status, said = self.compare({"x.elf": image()},
                                    {"x.elf": image(bytes(code))})
        self.assertEqual(status, 1)
        self.assertIn("DIFFER x.elf\n", said)
        self.assertIn("routines of the same size whose bytes differ (1): second\n",
                      said)
        self.assertNotIn("first", said)
        self.assertNotIn("segments", said)
        self.assertIn("differ 1", said)

    def test_changed_data_is_named_as_data(self):
        status, said = self.compare({"x.elf": image()},
                                    {"x.elf": image(CODE[:-4] + b"date")})
        self.assertEqual(status, 1)
        self.assertIn("data of the same size whose bytes differ (1): table\n", said)
        self.assertNotIn("routines", said)

    def test_a_routine_that_grew_moves_those_after_it(self):
        code = CODE[:16] + bytes(range(16, 36)) + CODE[32:]
        symbols = [("first", TEXT | 1, 16, FUNC, 1),
                   ("second", TEXT + 16 | 1, 20, FUNC, 1),
                   ("third", TEXT + 36 | 1, 16, FUNC, 1),
                   ("table", TEXT + 52, 4, OBJECT, 1),
                   ("counter", 0x2000, 4, OBJECT, 2)]
        status, said = self.compare({"x.elf": image()},
                                    {"x.elf": image(code, symbols)})
        self.assertEqual(status, 1)
        self.assertIn("base segments: [0x100 lma 0x100 file 0x34 mem 0x34 flags 5]",
                      said)
        self.assertIn("routines of another size (1): second\n", said)
        self.assertIn("the same bytes at another address (2): table, third\n", said)
        self.assertNotIn("whose bytes differ", said)

    def test_routines_in_one_image_alone(self):
        symbols = [s for s in SYMBOLS if s[0] != "third"] + [
            ("replacement", TEXT + 32 | 1, 16, FUNC, 1)]
        status, said = self.compare({"x.elf": image()},
                                    {"x.elf": image(bytes(48) + b"DATA", symbols)})
        self.assertEqual(status, 1)
        self.assertIn("routines only in base (1): third\n", said)
        self.assertIn("routines only in new (1): replacement\n", said)

    def test_bytes_outside_every_symbol(self):
        code = CODE + b"\x01\x02\x03\x04"
        status, said = self.compare(
            {"x.elf": image(code)},
            {"x.elf": image(code[:-4] + b"\x01\x09\x09\x04")})
        self.assertEqual(status, 1)
        self.assertIn("2 loaded byte(s) outside every named symbol differ, in "
                      "1 run(s): 0x135-0x136\n", said)
        self.assertNotIn("routines", said)

    def test_a_zero_filled_tail_is_loaded_and_compared(self):
        base = elf([(TEXT, CODE, len(CODE)), (0x2000, b"", 64)], SYMBOLS)
        new = elf([(TEXT, CODE, len(CODE)), (0x2000, b"", 128)], SYMBOLS)
        status, said = self.compare({"x.elf": base}, {"x.elf": new})
        self.assertEqual(status, 1)
        self.assertIn("mem 0x80", said)
        self.assertIn("64 loaded byte(s) outside every named symbol differ, in "
                      "1 run(s): 0x2040-0x207f\n", said)

    def test_a_symbol_of_no_size_reaches_the_next(self):
        symbols = [("first", TEXT | 1, 0, FUNC, 1),
                   ("second", TEXT + 16 | 1, 16, FUNC, 1)]
        code = bytearray(CODE)
        code[3] ^= 1
        status, said = self.compare({"x.elf": image(symbols=symbols)},
                                    {"x.elf": image(bytes(code), symbols)})
        self.assertIn("routines of the same size whose bytes differ (1): first\n",
                      said)
        self.assertNotIn("outside", said)

    def test_a_name_two_local_symbols_share_is_told_apart(self):
        symbols = [("unexpected", TEXT | 1, 16, FUNC, 1),
                   ("unexpected", TEXT + 16 | 1, 16, FUNC, 1)]
        code = bytearray(CODE)
        code[17] ^= 1
        status, said = self.compare({"x.elf": image(symbols=symbols)},
                                    {"x.elf": image(bytes(code), symbols)})
        self.assertIn("whose bytes differ (1): unexpected (2)\n", said)

    def test_the_entry_point(self):
        status, said = self.compare({"x.elf": image()},
                                    {"x.elf": image(entry=0x105)})
        self.assertEqual(status, 1)
        self.assertIn("  entry 0x105, was 0x100\n", said)

    def test_the_thumb_bit_is_cleared_on_arm_alone(self):
        #  On Xtensa an odd routine address is the routine's own.
        symbols = [("odd", TEXT + 1, 15, FUNC, 1)]
        code = bytearray(CODE)
        code[0] ^= 1
        status, said = self.compare(
            {"x.elf": image(symbols=symbols, machine=EM_XTENSA)},
            {"x.elf": image(bytes(code), symbols, machine=EM_XTENSA)})
        self.assertIn("1 loaded byte(s) outside every named symbol", said)
        status, said = self.compare({"x.elf": image(symbols=symbols)},
                                    {"x.elf": image(bytes(code), symbols)})
        self.assertNotIn("outside", said)

    def test_images_in_one_tree_alone(self):
        status, said = self.compare({"gone.elf": image(), "kept.elf": image()},
                                    {"kept.elf": image(), "n/added.elf": image()})
        self.assertEqual(status, 1)
        self.assertIn("ONLY-NEW n/added.elf\nONLY-BASE gone.elf\n", said)
        self.assertIn("same 1  differ 0  only in new 1  only in base 1", said)

    def test_names_are_limited(self):
        code = bytes(b ^ 0xFF for b in CODE)
        status, said = self.compare({"x.elf": image()},
                                    {"x.elf": image(code)}, limit=2)
        self.assertIn("whose bytes differ (3): first, second, and 1 more\n", said)

    def test_sixty_four_bit_and_big_endian_images(self):
        for given in ({"wide": True}, {"order": ">"}, {"wide": True, "order": ">"}):
            with self.subTest(**given):
                code = bytearray(CODE)
                code[40] ^= 1
                status, said = self.compare(
                    {"x.elf": image(machine=EM_RISCV, **given)},
                    {"x.elf": image(bytes(code), machine=EM_RISCV, **given)})
                self.assertEqual(status, 1)
                self.assertIn("whose bytes differ (1): third\n", said)

    def test_a_file_that_is_no_image(self):
        status, said = self.compare({"x.elf": b"not an image"},
                                    {"x.elf": image()})
        self.assertEqual(status, 2)
        self.assertIn("UNREADABLE x.elf: not an ELF file\n", said)
        truncated = image()[:200]
        status, said = self.compare({"x.elf": image()}, {"x.elf": truncated})
        self.assertEqual(status, 2)
        self.assertIn("UNREADABLE x.elf: truncated or malformed ELF", said)


class Command(unittest.TestCase):
    def test_an_operand_that_is_no_directory(self):
        said = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stderr(said):
            self.assertEqual(compare_images.main([tmp, str(Path(tmp) / "absent")]),
                             2)
        self.assertIn("absent is not a directory", said.getvalue())


if __name__ == "__main__":
    unittest.main()
