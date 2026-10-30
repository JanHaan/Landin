"""The outside-user check reads the documents and installs what they promise.

The gate's step packages the release compiler, unpacks it outside the
checkout and runs the README's first program and every examples.md program
through it.  That is only as strong as the reading of the documents and the
layout of the archive, so both are held here: every program the documents
show is found, with the oracle it is held to, and the archive is the
installed prefix `refine` looks for, the same bytes on a second packaging.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import outside_user  # noqa: E402


class Documents(unittest.TestCase):
    def test_the_readme_shows_a_first_program_and_its_output(self):
        source, printed, status, given, arguments = \
            outside_user.first_program()
        self.assertIn("public main", source)
        self.assertTrue(printed.endswith(b"\n") and printed.strip())
        self.assertEqual(status, 0)
        self.assertEqual(given, b"")
        self.assertEqual(arguments, [])

    def test_every_example_is_its_fixture_with_its_oracle(self):
        found = list(outside_user.examples())
        listed = (ROOT / "examples.md").read_text().count("Fixture source: `")
        self.assertEqual(len(found), listed)
        reading = sized = 0
        for name, source, expected, status, given, arguments in found:
            fixture = ROOT / "compiler/tests/fixtures/runtime" / name
            self.assertEqual(source, (fixture / "main.ldn").read_text(),
                             name)
            if expected is not None:
                self.assertTrue(expected, name)
            if given:
                #  A program that reads its input is held to the output for
                #  the input it is given.
                reading += 1
            if arguments:
                #  A Benchmark Game port takes its size as its argument and
                #  is held, as one, to the game's output for that size.
                sized += 1
            #  Every example prints what it computes and returns 0, and is
            #  held to that output.
            self.assertEqual(status, 0, name)
            self.assertIsNotNone(expected, name)
        self.assertGreaterEqual(reading, 1)
        self.assertGreaterEqual(sized, 1)

    def test_a_program_reads_the_input_it_is_given(self):
        ran, _ = outside_user.run(
            [sys.executable, "-c",
             "import sys; sys.stdout.buffer.write("
             "sys.stdin.buffer.read()[::-1])"],
            ROOT, dict(os.environ), "reverse", b"abc\n")
        self.assertEqual(ran.stdout, b"\ncba")
        ran, _ = outside_user.run(
            [sys.executable, "-c",
             "import sys; sys.stdout.write(repr(sys.stdin.read()))"],
            ROOT, dict(os.environ), "nothing")
        self.assertEqual(ran.stdout, b"''")


class Archive(unittest.TestCase):
    def package(self, directory, binary, name):
        asset = directory / name
        subprocess.run([str(ROOT / "scripts/package.sh"), str(binary),
                        str(asset)], check=True)
        return asset

    def test_the_archive_is_an_installed_prefix_and_reproducible(self):
        with TemporaryDirectory() as scratch:
            directory = Path(scratch)
            binary = directory / "refine"
            binary.write_text("#!/bin/sh\n")
            os.chmod(binary, 0o755)
            first = self.package(directory, binary, "first.tar.gz")
            second = self.package(directory, binary, "second.tar.gz")
            self.assertEqual(hashlib.sha256(first.read_bytes()).hexdigest(),
                             hashlib.sha256(second.read_bytes()).hexdigest())
            with tarfile.open(first) as archive:
                names = archive.getnames()
                self.assertEqual(names, sorted(names))
                self.assertIn("bin/refine", names)
                for namespace in ("core", "hosted", "platform"):
                    self.assertIn("lib/landin/" + namespace, names)
                self.assertIn("lib/landin/core/mem/mem.ldn", names)
                self.assertIn("LICENSE", names)
                mode = archive.getmember("bin/refine").mode
                self.assertEqual(mode & 0o111, 0o111)

    @unittest.skipUnless(sys.platform.startswith("linux")
                         and shutil.which("cc") and shutil.which("objcopy")
                         and shutil.which("readelf"),
                         "needs Linux with cc, objcopy and readelf")
    def test_debug_information_is_packaged_apart(self):
        with TemporaryDirectory() as scratch:
            directory = Path(scratch)
            source = directory / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            binary = directory / "refine"
            subprocess.run(["cc", "-g", "-o", str(binary), str(source)],
                           check=True)
            before = binary.read_bytes()
            asset = directory / "landin.tar.gz"
            debug = directory / "landin-debug.tar.gz"
            subprocess.run([str(ROOT / "scripts/package.sh"), "--debug",
                            str(debug), str(binary), str(asset)], check=True)
            self.assertEqual(binary.read_bytes(), before)
            unpacked = directory / "unpacked"
            for archive in (asset, debug):
                with tarfile.open(archive) as opened:
                    opened.extractall(unpacked, filter="data")

            def sections(path):
                return subprocess.run(["readelf", "-S", str(path)],
                                      capture_output=True, text=True,
                                      check=True).stdout
            stripped = sections(unpacked / "bin/refine")
            self.assertNotIn(".debug_info", stripped)
            self.assertNotIn(".symtab", stripped)
            self.assertIn(".gnu_debuglink", stripped)
            self.assertIn(".debug_info", sections(unpacked / "refine.debug"))
            with tarfile.open(debug) as opened:
                self.assertEqual(opened.getnames(), ["refine.debug"])

    def test_a_missing_binary_is_refused(self):
        with TemporaryDirectory() as scratch:
            directory = Path(scratch)
            ran = subprocess.run(
                [str(ROOT / "scripts/package.sh"), str(directory / "absent"),
                 str(directory / "asset.tar.gz")], capture_output=True)
            self.assertNotEqual(ran.returncode, 0)
            self.assertFalse((directory / "asset.tar.gz").exists())


class Boundary(unittest.TestCase):
    def test_a_work_directory_inside_the_checkout_is_refused(self):
        with self.assertRaises(SystemExit):
            sys.argv = ["outside_user.py", "--prefix", "/nonexistent",
                        "--work", str(ROOT / "build-outside")]
            outside_user.main()
        self.assertFalse((ROOT / "build-outside").exists())


if __name__ == "__main__":
    shutil.which("tar") or sys.exit("tar is required")
    unittest.main()
