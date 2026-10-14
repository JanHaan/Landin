#!/usr/bin/env python3
"""platform/linux's system-call numbers are the pinned kernel's own.

scripts/linux_syscalls.py reads each architecture's table out of a pinned
Linux release with the ABIs that architecture's build selects.  These cases
run it on a small release of their own, so what it selects, what it refuses
and the files it writes are held without the 160 MB tarball; and they hold
the checked-in module platform/linux/numbers to being exactly what the
generator renders under the pin it names, and platform/linux's wrapped.ldn to
being the numbers the module's wrappers use, from those same tables.
"""
import hashlib
import importlib.util
import io
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "linux_syscalls", ROOT / "scripts/linux_syscalls.py")
linux_syscalls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linux_syscalls)

X86_MAKEFILE = """\
$(uapi)/unistd_x32.h: abis := common,x32
$(uapi)/unistd_64.h: abis := common,64
"""
X86_TABLE = """\
# comment
0\tcommon\tread\t\t\tsys_read
1\tcommon\twrite\t\t\tsys_write
13\t64\trt_sigaction\t\tsys_rt_sigaction
156\t64\t_sysctl
512\tx32\trt_sigaction\t\tcompat_sys_rt_sigaction
"""
GENERIC_MAKEFILE = """\
syscall_abis_32  += common,32
syscall_abis_64  += common,64
syscalltbl := $(srctree)/scripts/syscall.tbl
syshdr-args := --emit-nr
"""
GENERIC_TABLE = """\
38\trenameat renameat\t\tsys_renameat
56\tcommon\topenat\t\t\tsys_openat
62\t32\tllseek\t\t\tsys_llseek
62\t64\tlseek\t\t\tsys_lseek
63\tcommon\tread\t\t\tsys_read
163\trlimit\tgetrlimit\t\tsys_getrlimit
258\triscv\triscv_hwprobe\t\tsys_riscv_hwprobe
403\ttime32\tclock_gettime\t\tsys_clock_gettime32
"""
ARM64_MAKEFILE = """\
syscall_abis_32 +=
syscall_abis_64 += renameat rlimit

syscalltbl = arch/arm64/tools/syscall_%.tbl
"""
RISCV_MAKEFILE = """\
syscall_abis_32 += riscv
syscall_abis_64 += riscv rlimit
"""


def release(directory, members, top="linux-9.9"):
    """A tar.xz of MEMBERS under TOP, and its SHA-256."""
    path = Path(directory) / (top + ".tar.xz")
    with tarfile.open(path, "w:xz") as archive:
        for name, text in sorted(members.items()):
            data = text.encode()
            info = tarfile.TarInfo(top + "/" + name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return path, hashlib.sha256(path.read_bytes()).hexdigest()


def kernel(**changes):
    members = {
        "arch/x86/entry/syscalls/Makefile": X86_MAKEFILE,
        "arch/x86/entry/syscalls/syscall_64.tbl": X86_TABLE,
        "scripts/Makefile.asm-headers": GENERIC_MAKEFILE,
        "scripts/syscall.tbl": GENERIC_TABLE,
        "arch/arm64/kernel/Makefile.syscalls": ARM64_MAKEFILE,
        "arch/arm64/tools/syscall_64.tbl": GENERIC_TABLE,
        "arch/riscv/kernel/Makefile.syscalls": RISCV_MAKEFILE,
    }
    members.update(changes)
    return {name: text for name, text in members.items() if text is not None}


class Generator(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)

    def generate(self, **changes):
        path, sha = release(self.directory, kernel(**changes))
        return linux_syscalls.tables(linux_syscalls.Release(path, sha))

    def test_each_architecture_takes_its_own_table_and_abis(self):
        found = {arch: (source, abis, rows)
                 for (arch, _), source, abis, rows in self.generate()}
        self.assertEqual(found["x86_64"],
                         ("arch/x86/entry/syscalls/syscall_64.tbl",
                          ["common", "64"],
                          [(0, "read"), (1, "write"), (13, "rt_sigaction"),
                           (156, "_sysctl")]))
        #  arm64 names a table of its own, and adds renameat and rlimit.
        self.assertEqual(found["arm64"],
                         ("arch/arm64/tools/syscall_64.tbl",
                          ["common", "64", "renameat", "rlimit"],
                          [(38, "renameat"), (56, "openat"), (62, "lseek"),
                           (63, "read"), (163, "getrlimit")]))
        #  RV64 keeps the generic table and adds its own riscv_hwprobe.
        self.assertEqual(found["rv64"],
                         ("scripts/syscall.tbl",
                          ["common", "64", "riscv", "rlimit"],
                          [(56, "openat"), (62, "lseek"), (63, "read"),
                           (163, "getrlimit"), (258, "riscv_hwprobe")]))

    def test_a_release_with_another_digest_is_refused_unread(self):
        path, _ = release(self.directory, kernel())
        with self.assertRaisesRegex(linux_syscalls.Refused, "not the pinned"):
            linux_syscalls.Release(path, "0" * 64)

    def test_a_repeated_name_is_refused(self):
        with self.assertRaisesRegex(linux_syscalls.Refused, "name read repeats"):
            self.generate(**{"arch/x86/entry/syscalls/syscall_64.tbl":
                             X86_TABLE + "400\tcommon\tread\tsys_read\n"})

    def test_a_repeated_number_is_refused(self):
        with self.assertRaisesRegex(linux_syscalls.Refused, "number 1 repeats"):
            self.generate(**{"arch/x86/entry/syscalls/syscall_64.tbl":
                             X86_TABLE + "1\t64\tanother\tsys_another\n"})

    def test_a_name_no_number_can_take_is_refused(self):
        with self.assertRaisesRegex(linux_syscalls.Refused, "not a name"):
            self.generate(**{"scripts/syscall.tbl":
                             GENERIC_TABLE + "500\tcommon\tBad-name\tsys_x\n"})

    def test_a_missing_member_is_refused(self):
        with self.assertRaisesRegex(linux_syscalls.Refused,
                                    "no arch/riscv/kernel/Makefile.syscalls"):
            self.generate(**{"arch/riscv/kernel/Makefile.syscalls": None})

    def test_x86_without_its_abis_is_refused(self):
        with self.assertRaisesRegex(linux_syscalls.Refused, "names no ABIs"):
            self.generate(**{"arch/x86/entry/syscalls/Makefile": "all:\n"})

    def test_what_is_rendered_reads_back(self):
        generated = self.generate()
        text = linux_syscalls.render("9.9", "a" * 64, "https://example/x",
                                     generated)
        self.assertIn("        public riscv_hwprobe_number: i64 = 258\n", text)
        self.assertIn("        public _sysctl_number: i64 = 156\n", text)
        self.assertEqual(linux_syscalls.read_back(text),
                         ("9.9", "a" * 64, "https://example/x", generated))

    def module(self, uses):
        """A platform/linux of one file whose code uses the numbers USES."""
        module = self.directory / "linux"
        module.mkdir()
        (module / "linux.ldn").write_text(
            "--  read_number in a comment is no use of it\n"
            + "".join("x%d: i64 = %s_number\n" % (at, name)
                      for at, name in enumerate(uses)))
        return module

    def test_the_command_writes_and_then_checks_both_files(self):
        path, sha = release(self.directory, kernel())
        module = self.module(["write", "openat", "riscv_hwprobe"])
        public = module / "numbers/numbers.ldn"
        wrapped = module / "wrapped.ldn"
        arguments = ["--tarball", str(path), "--module", str(module)]
        with mock.patch.object(linux_syscalls, "SHA256", sha), \
                mock.patch("sys.stdout", io.StringIO()), \
                mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(linux_syscalls.main(arguments + ["--check"]), 1)
            self.assertFalse(public.exists() or wrapped.exists())
            self.assertEqual(linux_syscalls.main(arguments), 0)
            self.assertEqual(linux_syscalls.main(arguments + ["--check"]), 0)
            public.write_text(public.read_text().replace("= 258", "= 259"))
            self.assertEqual(linux_syscalls.main(arguments + ["--check"]), 1)
            self.assertEqual(linux_syscalls.main(arguments), 0)
            wrapped.write_text(wrapped.read_text().replace("= 258", "= 259"))
            self.assertEqual(linux_syscalls.main(arguments + ["--check"]), 1)
        with mock.patch("sys.stderr", io.StringIO()) as said:
            self.assertEqual(linux_syscalls.main(arguments), 2)
        self.assertIn("not the pinned", said.getvalue())

    def test_the_wrappers_get_only_their_numbers_on_each_architecture(self):
        module = self.module(["write", "openat", "riscv_hwprobe"])
        text = linux_syscalls.render_wrapped(
            "9.9", self.generate(), linux_syscalls.used_names(module))
        self.assertNotIn("public", text)
        self.assertNotIn("read_number", text)
        x86, arm64, rv64 = text.split("compiler.arch == ")[1:]
        self.assertIn("write_number: i64 = 1\n", x86)
        self.assertNotIn("openat", x86)
        self.assertIn("openat_number: i64 = 56\n", arm64)
        self.assertNotIn("riscv_hwprobe", arm64)
        self.assertIn("riscv_hwprobe_number: i64 = 258\n", rv64)

    def test_a_number_no_table_has_is_refused(self):
        module = self.module(["no_such_call"])
        with self.assertRaisesRegex(linux_syscalls.Refused,
                                    "no_such_call_number"):
            linux_syscalls.render_wrapped(
                "9.9", self.generate(), linux_syscalls.used_names(module))

    def test_a_fetch_into_a_used_directory_is_refused(self):
        (self.directory / "left").write_text("x")
        with self.assertRaisesRegex(linux_syscalls.Refused, "not empty"):
            linux_syscalls.fetch(self.directory, "https://example/x.tar.xz")


class CheckedIn(unittest.TestCase):
    def test_the_file_is_the_generator_output_under_its_pin(self):
        text = linux_syscalls.OUTPUT.read_text(encoding="utf-8")
        version, sha, url, generated = linux_syscalls.read_back(text)
        self.assertEqual((version, sha, url),
                         (linux_syscalls.VERSION, linux_syscalls.SHA256,
                          linux_syscalls.URL))
        self.assertEqual([arch for (arch, _), _, _, _ in generated],
                         [arch for arch, _ in linux_syscalls.ARCHITECTURES])
        self.assertEqual(linux_syscalls.render(version, sha, url, generated),
                         text)

    def test_the_wrappers_numbers_are_generated_from_the_same_tables(self):
        version, _, _, generated = linux_syscalls.read_back(
            linux_syscalls.OUTPUT.read_text(encoding="utf-8"))
        used = linux_syscalls.used_names(linux_syscalls.MODULE)
        self.assertTrue({"read", "openat", "getdents64", "riscv_hwprobe"}
                        <= used)
        self.assertEqual(
            linux_syscalls.render_wrapped(version, generated, used),
            linux_syscalls.WRAPPED.read_text(encoding="utf-8"))
        #  No file of the module declares a number of its own.
        for path in linux_syscalls.MODULE.glob("*.ldn"):
            if path != linux_syscalls.WRAPPED:
                self.assertNotRegex(path.read_text(encoding="utf-8"),
                                    r"(?m)^\s*(?:public )?\w+_number:",
                                    path)


if __name__ == "__main__":
    unittest.main()
