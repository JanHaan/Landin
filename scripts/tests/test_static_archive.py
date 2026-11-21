"""A Linux release links glibc into refine, and its archive says so.

The gate's release jobs build, package and run the static compiler on
Alpine (scripts/static_check.py); these hold, on every scripts job, the
pieces that do not need a build: the link the build chooses and refuses,
package.sh's glibc licence and notice and its refusals, and the fixtures
and ELF reading the check relies on.
"""
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import static_check  # noqa: E402

MACHINES = {"x86_64": 62, "aarch64": 183}
SPLITS = [entry["name"] for entry in json.loads(
    (ROOT / "compiler/ada/split-commands.json").read_text(
        encoding="utf-8"))["commands"]]


def elf(machine):
    """A 64-bit little-endian ELF header for MACHINE with no program
    headers: no interpreter and no dynamic section, as a static executable
    reads to package.sh."""
    header = bytearray(64)
    header[:4] = b"\x7fELF"
    header[4], header[5], header[6] = 2, 1, 1
    struct.pack_into("<HHI", header, 16, 3, machine, 1)
    return bytes(header)


class Link(unittest.TestCase):
    def test_a_linux_release_links_statically_and_refuses_a_warning(self):
        common = (ROOT / "compiler/ada/landin_common.gpr").read_text()
        self.assertIn('external ("LANDIN_LINK", "dynamic")', common)
        static = common.split('when "static" =>', 1)[1].split("end case", 1)[0]
        self.assertIn('"-static-pie"', static)
        self.assertIn('"-Wl,--fatal-warnings"', static)
        environment = (ROOT / "scripts/env.sh").read_text()
        self.assertIn('if [ "$LANDIN_BUILD_MODE" = release ] && '
                      '[ "$(uname -s)" = Linux ]; then\n    LANDIN_LINK=static',
                      environment)
        build = (ROOT / "scripts/build.sh").read_text()
        self.assertIn('if [ "${LANDIN_LINK:-dynamic}" = static ]; then', build)

    def test_every_executable_project_takes_the_link(self):
        for project in sorted((ROOT / "compiler/ada").glob("*.gpr")):
            text = project.read_text()
            if "for Main use" in text:
                self.assertIn("package Linker   renames Landin_Common.Linker;",
                              text, project.name)

    @unittest.skipUnless(platform.system() == "Linux"
                         and shutil.which("gcc"), "a Linux C compiler")
    def test_the_static_link_refuses_a_name_service_call(self):
        #  The warning glibc gives for a call that needs its shared
        #  libraries at run time fails the link under --fatal-warnings.
        with TemporaryDirectory() as scratch:
            source = Path(scratch) / "nss.c"
            source.write_text("#include <netdb.h>\nint main(void) {\n"
                              "  struct addrinfo *r;\n"
                              "  return getaddrinfo(\"x\", 0, 0, &r);\n}\n")
            plain = subprocess.run(
                ["gcc", "-static-pie", str(source), "-o",
                 str(Path(scratch) / "plain")], capture_output=True,
                text=True)
            if plain.returncode != 0:
                self.skipTest("no static glibc here: " + plain.stderr[-200:])
            self.assertIn("statically linked applications requires at"
                          " runtime", plain.stderr)
            refused = subprocess.run(
                ["gcc", "-static-pie", "-Wl,--fatal-warnings", str(source),
                 "-o", str(Path(scratch) / "refused")], capture_output=True,
                text=True)
            self.assertNotEqual(refused.returncode, 0)


@unittest.skipUnless(platform.system() == "Linux"
                     and platform.machine() in MACHINES, "a Linux host")
class Package(unittest.TestCase):
    def built(self, directory, machine):
        binary = directory / "build/bin/refine"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(elf(machine))
        binary.chmod(0o755)
        libexec = directory / "build/libexec/landin"
        libexec.mkdir(parents=True)
        for name in SPLITS:
            shutil.copy2(binary, libexec / ("refine-" + name))
        return binary

    def fake_dpkg(self, directory):
        """A dpkg-query that knows libc6-dev, and its copyright file."""
        bin_dir = directory / "fake"
        bin_dir.mkdir()
        copyright = directory / "copyright"
        copyright.write_text("glibc's copyright, as Debian ships it\n")
        query = bin_dir / "dpkg-query"
        query.write_text(
            "#!/bin/sh\ncase $1 in\n"
            " -W) echo 'libc6-dev 2.39-0ubuntu8.6 glibc 2.39-0ubuntu8.6' ;;\n"
            " -L) echo /usr/share/doc/libc6-dev; echo %s ;;\n"
            "esac\n" % copyright)
        query.chmod(0o755)
        return bin_dir

    def package(self, binary, asset, path):
        return subprocess.run(
            [str(ROOT / "scripts/package.sh"), str(binary), str(asset)],
            capture_output=True, text=True,
            env=dict(os.environ, PATH=path))

    def test_a_static_refine_carries_glibc_s_licence_and_notice(self):
        with TemporaryDirectory() as scratch:
            directory = Path(scratch)
            binary = self.built(directory, MACHINES[platform.machine()])
            fake = self.fake_dpkg(directory)
            asset = directory / "landin.tar.gz"
            ran = self.package(binary, asset,
                               "%s:%s" % (fake, os.environ["PATH"]))
            self.assertEqual(ran.returncode, 0, ran.stderr)
            with tarfile.open(asset) as archive:
                licence = archive.extractfile("LICENSE-GLIBC").read()
                notice = archive.extractfile("NOTICE-GLIBC").read().decode()
            self.assertEqual(licence, b"glibc's copyright, as Debian ships it\n")
            for said in ("linked statically with the GNU C Library",
                         "libc6-dev 2.39-0ubuntu8.6",
                         "source package glibc 2.39-0ubuntu8.6",
                         "version 2.1 or later",
                         "apt-get source glibc=2.39-0ubuntu8.6",
                         "LANDIN_BUILD_MODE=release"):
                self.assertIn(said, " ".join(notice.split()))

    def test_a_static_refine_is_refused_without_libc6_dev(self):
        with TemporaryDirectory() as scratch:
            directory = Path(scratch)
            binary = self.built(directory, MACHINES[platform.machine()])
            bin_dir = directory / "nodpkg"
            bin_dir.mkdir()
            (bin_dir / "dpkg-query").write_text("#!/bin/sh\nexit 1\n")
            (bin_dir / "dpkg-query").chmod(0o755)
            ran = self.package(binary, directory / "landin.tar.gz",
                               "%s:%s" % (bin_dir, os.environ["PATH"]))
            self.assertEqual(ran.returncode, 1)
            self.assertIn("must carry glibc's licence", ran.stderr)
            self.assertIn("no libc6-dev package", ran.stderr)
            self.assertFalse((directory / "landin.tar.gz").exists())

    def test_another_architecture_s_refine_is_refused_first(self):
        other = [name for name in MACHINES if name != platform.machine()][0]
        with TemporaryDirectory() as scratch:
            directory = Path(scratch)
            binary = self.built(directory, MACHINES[other])
            ran = self.package(binary, directory / "landin.tar.gz",
                               os.environ["PATH"])
            self.assertEqual(ran.returncode, 1)
            self.assertIn("is built for %s, and this host is %s"
                          % (other, platform.machine()), ran.stderr)
            self.assertIn("devShells.%s-linux.default" % other, ran.stderr)
            self.assertFalse((directory / "landin.tar.gz").exists())


class Check(unittest.TestCase):
    def test_the_libc_fixtures_are_found_for_each_architecture(self):
        for target in ("linux-x86-64", "linux-arm64"):
            found = static_check.libc_fixtures(target)
            self.assertGreaterEqual(len(found), 7, target)
            for directory, meta in found:
                self.assertEqual(meta["link"], "libc", directory)

    def test_needed_libraries_reads_a_dynamic_and_a_static_executable(self):
        self.assertEqual(static_check.needed_libraries(elf(62)), 0)
        if platform.system() == "Linux":
            python = Path(os.path.realpath(sys.executable)).read_bytes()
            self.assertGreater(static_check.needed_libraries(python), 0)


if __name__ == "__main__":
    unittest.main()
