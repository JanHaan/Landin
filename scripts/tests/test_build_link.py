#!/usr/bin/env python3
"""What build_link.py says an executable was linked from."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "build_link", ROOT / "scripts/build_link.py")
LINK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINK)


def archive(members):
    """A GNU ar archive of MEMBERS, with a symbol table and a long name."""
    def header(name, size):
        return (name.ljust(16).encode() + b"0".ljust(12) + b"0".ljust(6)
                + b"0".ljust(6) + b"644".ljust(8) + str(size).ljust(10).encode()
                + b"`\n")
    long_names = b""
    names = {}
    for name in members:
        if len(name) > 15:
            names[name] = f"/{len(long_names)}"
            long_names += name.encode() + b"/\n"
        else:
            names[name] = name + "/"
    data = b"!<arch>\n" + header("/", 4) + b"\0\0\0\0"
    if long_names:
        data += header("//", len(long_names)) + long_names
        if len(long_names) & 1:
            data += b"\n"
    for name, body in members.items():
        data += header(names[name], len(body)) + body
        if len(body) & 1:
            data += b"\n"
    return data


class BuildLink(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="landin link ")
        self.addCleanup(temporary.cleanup)
        self.build = Path(temporary.name)
        for directory in ("lib", "lib-obj", "refine-obj", "link", "bin"):
            (self.build / directory).mkdir()
        self.objects = {"a.o": b"first object", "a-long-unit-name.o": b"odd"}
        for name, body in self.objects.items():
            (self.build / "lib-obj" / name).write_bytes(body)
        (self.build / "lib-obj/landin.lexch").write_text("exchange\n")
        (self.build / "lib/liblandin.a").write_bytes(archive(self.objects))
        (self.build / "refine-obj/refine.o").write_bytes(b"main")
        self.executable = self.build / "link/refine"
        self.said = io.StringIO()
        self.enterContext(contextlib.redirect_stdout(self.said))
        self.enterContext(contextlib.redirect_stderr(self.said))

    def link(self, text="linked"):
        self.executable.write_text(text)

    def verify(self, before):
        return LINK.verify(self.build, "refine", "refine-obj", before)

    def test_members_of_an_archive(self):
        self.assertEqual(
            LINK.members(self.build / "lib/liblandin.a"),
            {name: hashlib.sha256(body).hexdigest()
             for name, body in self.objects.items()})
        self.assertEqual(LINK.members(self.build / "lib/absent.a"), {})

    def test_a_fresh_link_is_recorded(self):
        before = LINK.stamp(self.build, "refine")
        self.assertEqual(before, "absent")
        self.link()
        self.assertEqual(self.verify(before), 0)
        record = json.loads((self.build / "link/.refine.linked").read_text())
        self.assertEqual(record["executable"],
                         hashlib.sha256(b"linked").hexdigest())
        self.assertEqual(sorted(record["inputs"]), [
            "lib/liblandin.a(a-long-unit-name.o)", "lib/liblandin.a(a.o)",
            "refine-obj/refine.o"])
        # Nothing changed and nothing relinked: current.
        self.assertEqual(self.verify(LINK.stamp(self.build, "refine")), 0)

    def test_an_object_changed_under_an_old_executable_relinks(self):
        self.link()
        self.assertEqual(self.verify("absent"), 0)
        (self.build / "refine-obj/refine.o").write_bytes(b"main, changed")
        self.assertEqual(self.verify(LINK.stamp(self.build, "refine")), 3)
        self.assertFalse(self.executable.exists())
        self.assertIn("refine-obj/refine.o changed since it was linked",
                      self.said.getvalue())

    def test_an_archive_without_the_compiled_object_is_rebuilt(self):
        self.link()
        self.assertEqual(self.verify("absent"), 0)
        # The object was recompiled; the library kept the old one.
        (self.build / "lib-obj/a.o").write_bytes(b"recompiled object")
        self.assertEqual(self.verify(LINK.stamp(self.build, "refine")), 3)
        self.assertFalse(self.executable.exists())
        self.assertFalse((self.build / "lib-obj/landin.lexch").exists())
        self.assertIn("lib/liblandin.a does not hold the compiled a.o",
                      self.said.getvalue())

    def test_published_executable_is_held_to_the_manifest(self):
        manifest = self.build / "source-manifest.txt"
        (self.build / "bin/refine").write_text("linked")
        manifest.write_text("source 1 a.adb\nlinked refine "
                            + hashlib.sha256(b"linked").hexdigest() + "\n")
        self.assertEqual(LINK.published(self.build, manifest, ["refine"]), 0)
        self.assertEqual(LINK.published(self.build, manifest,
                                        ["landin_tests"]), 1)
        (self.build / "bin/refine").write_text("another")
        self.assertEqual(LINK.published(self.build, manifest, ["refine"]), 1)

    def test_command_line(self):
        self.assertEqual(LINK.main([]), 2)
        self.link()
        os.utime(self.executable, ns=(1, 1))
        self.assertEqual(LINK.main(["stamp", str(self.build), "refine"]), 0)


if __name__ == "__main__":
    unittest.main()
