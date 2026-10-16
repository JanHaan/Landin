#!/usr/bin/env python3
"""Write platform/linux's system-call numbers from a pinned Linux release.

    scripts/linux_syscalls.py
    scripts/linux_syscalls.py --check
    scripts/linux_syscalls.py --fetch DIR
    scripts/linux_syscalls.py --tarball linux-7.2.tar.xz
    scripts/linux_syscalls.py --tarball linux-7.2.tar.xz --check

With no release named, the generator reads the numbers the checked-in
module platform/linux/numbers already holds, holds that file to being its
own rendering under the pin named below, and writes platform/linux's
wrapped.ldn from it: adding a wrapper for another call needs no download.
The release is needed only to change the pin.

The numbers are the kernel's own, read out of the release tarball named by
VERSION, URL and SHA256 below and never typed by hand.  `--fetch` downloads
that tarball into DIR, which must be new or empty, and `--tarball` names one
already downloaded; either way its SHA-256 must be the pinned one before a
byte of it is read.  The members are read straight out of the archive and
nothing is extracted.

Each architecture's table is the one its kernel build uses for 64-bit
user space, with the ABIs that build selects:

  x86-64  arch/x86/entry/syscalls/syscall_64.tbl, with the ABIs
          arch/x86/entry/syscalls/Makefile gives unistd_64.h: `common` and
          `64`, so not x32's.
  arm64,  scripts/syscall.tbl, or the table the architecture's
  RV64    kernel/Makefile.syscalls names in its place, with `common` and
          `64` from scripts/Makefile.asm-headers and the ABIs that Makefile
          adds to syscall_abis_64: arm64's renameat, rlimit and memfd_secret,
          RV64's riscv (riscv_hwprobe among them), rlimit and memfd_secret.

Every number is named after its call: the table's name followed by
`_number`.  The suffix is the one naming rule, so a number cannot take a
reserved word's spelling or the name of a wrapper declared beside it, and
the generator refuses a name that is not an identifier or that repeats.

It writes two files, each with a header naming the pinned release.  The
module platform/linux/numbers is every number, public, for a program that
makes a call through `linux.system_call`.  It is a module of its own because
platform/linux is part of every static Linux executable: a thousand public
declarations there would be checked and emitted for every program, which
roughly quadrupled the time to compile a small one.  platform/linux's own
wrappers use the numbers of the calls they make, which the generator finds
by name in the module's other files and writes, private and under the same
names, into platform/linux/wrapped.ldn.  `--check` compares both checked-in
files with what the tarball gives instead of writing them, or, with no
release named, the numbers file with its own rendering and wrapped.ldn with
what those numbers give.
scripts/tests/test_linux_syscalls.py runs all of this on small tables of its
own and holds the checked-in files to the generator's form.
"""

import argparse
import hashlib
import pathlib
import re
import sys
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = ROOT / "platform/linux"
OUTPUT = MODULE / "numbers/numbers.ldn"
WRAPPED = MODULE / "wrapped.ldn"

VERSION = "7.2"
URL = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz"
SHA256 = "f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3"

SUFFIX = "_number"
NAME = re.compile(r"[a-z_][a-z0-9_]*\Z")

#  The Landin architecture, how its comments name it, and where its table
#  and ABIs come from.
X86_64 = ("x86_64", "x86-64")
ARCHITECTURES = (
    X86_64,
    ("arm64", "arm64"),
    ("rv64", "RV64"),
)
#  The kernel's directory for each architecture whose 64-bit table follows
#  the generic build.
GENERIC = {"arm64": "arm64", "rv64": "riscv"}


class Refused(Exception):
    """The input is not what the generator was written for."""


def digest(path):
    hashed = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            hashed.update(block)
    return hashed.hexdigest()


def fetch(directory, url=URL, expected=SHA256):
    """Download URL into DIRECTORY, which must be new or empty, and keep it
    only if its SHA-256 is EXPECTED."""
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise Refused("%s is not empty" % directory)
    target = directory / url.rsplit("/", 1)[1]
    partial = target.with_name(target.name + ".partial")
    with urllib.request.urlopen(url, timeout=600) as response, \
            open(partial, "wb") as stream:
        while True:
            block = response.read(1 << 20)
            if not block:
                break
            stream.write(block)
    found = digest(partial)
    if found != expected:
        partial.unlink()
        raise Refused("%s has SHA-256 %s, not the pinned %s"
                      % (url, found, expected))
    partial.rename(target)
    return target


class Release:
    """The members of a verified kernel tarball, read without extracting."""

    def __init__(self, path, expected=SHA256):
        found = digest(path)
        if found != expected:
            raise Refused("%s has SHA-256 %s, not the pinned %s"
                          % (path, found, expected))
        self.archive = tarfile.open(path)
        names = self.archive.getnames()
        if not names:
            raise Refused("%s is empty" % path)
        self.top = names[0].split("/", 1)[0]

    def read(self, member):
        try:
            handle = self.archive.extractfile(self.top + "/" + member)
        except KeyError:
            handle = None
        if handle is None:
            raise Refused("the release has no %s" % member)
        return handle.read().decode("utf-8")


def makefile_values(text, variable):
    """Every word a Makefile assigns or appends to VARIABLE, in order, with
    commas read as separators.  `$(srctree)/` is dropped from a path."""
    words = []
    pattern = re.compile(r"^\s*(?:\$\([^)]*\):\s*)?" + re.escape(variable)
                         + r"\s*(\+=|:=|=)\s*(.*?)\s*$")
    for line in text.splitlines():
        found = pattern.match(line)
        if not found:
            continue
        values = [word.replace("$(srctree)/", "")
                  for word in re.split(r"[\s,]+", found.group(2)) if word]
        if found.group(1) == "+=":
            words += values
        else:
            words = values
    return words


def x86_abis(makefile):
    """The ABIs x86's Makefile gives unistd_64.h."""
    found = re.search(r"^\$\(uapi\)/unistd_64\.h:\s*abis\s*:=\s*(\S+)\s*$",
                      makefile, re.M)
    if not found:
        raise Refused("arch/x86/entry/syscalls/Makefile names no ABIs for"
                      " unistd_64.h")
    return found.group(1).split(",")


def parse_table(text, abis, where):
    """The (number, name) pairs of TEXT's lines whose ABI is in ABIS, by
    number.  A line is `number abi name [entry [compat]]`."""
    rows = []
    for at, line in enumerate(text.splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) < 3 or not fields[0].isdigit():
            raise Refused("%s:%d: not a table line: %r" % (where, at, line))
        number, abi, name = int(fields[0]), fields[1], fields[2]
        if abi not in abis:
            continue
        if not NAME.match(name):
            raise Refused("%s:%d: %r is not a name a number can take"
                          % (where, at, name))
        rows.append((number, name))
    rows.sort()
    names = [name for _, name in rows]
    numbers = [number for number, _ in rows]
    for kind, values in (("name", names), ("number", numbers)):
        repeated = sorted({value for value in values if values.count(value) > 1})
        if repeated:
            raise Refused("%s: the %s %s repeats under the ABIs %s"
                          % (where, kind, repeated[0], ",".join(abis)))
    if not rows:
        raise Refused("%s: no call under the ABIs %s" % (where, ",".join(abis)))
    return rows


def tables(release):
    """Each architecture's source, ABIs and rows, in ARCHITECTURES' order."""
    result = []
    x86_table = "arch/x86/entry/syscalls/syscall_64.tbl"
    abis = x86_abis(release.read("arch/x86/entry/syscalls/Makefile"))
    result.append((X86_64, x86_table, abis,
                   parse_table(release.read(x86_table), abis, x86_table)))
    generic = release.read("scripts/Makefile.asm-headers")
    base_abis = makefile_values(generic, "syscall_abis_64")
    base_table = makefile_values(generic, "syscalltbl")
    for architecture in ARCHITECTURES[1:]:
        directory = GENERIC[architecture[0]]
        own = release.read("arch/%s/kernel/Makefile.syscalls" % directory)
        abis = base_abis + makefile_values(own, "syscall_abis_64")
        table = (makefile_values(own, "syscalltbl") or base_table)
        if len(table) != 1:
            raise Refused("arch/%s names no single system-call table"
                          % directory)
        source = table[0].replace("%", "64")
        result.append((architecture, source, abis,
                       parse_table(release.read(source), abis, source)))
    return result


def render(version, sha256, url, generated):
    """The platform/linux file holding GENERATED's numbers."""
    lines = [
        "--  Linux's system-call numbers on x86-64, arm64 and RV64, generated by",
        "--  scripts/linux_syscalls.py from Linux %s:" % version,
        "--  %s" % url,
        "--  SHA-256 %s." % sha256,
        "--  Do not edit it: change the pin in the generator and run it again.",
        "--",
        "--  Each number is named after its call, the kernel table's name",
        "--  followed by `_number`, and goes to platform/linux's `system_call`.",
        "--  A number whose call the running kernel lacks gives minus ENOSYS.",
    ]
    for (_, spoken), source, abis, _ in generated:
        lines.append("--  %s reads %s" % (spoken, source))
        lines.append("--  with the ABIs %s." % ", ".join(abis))
    lines += ["--",
              "--  Its scope is platform/linux's, Linux, Darwin and FreeBSD, and on",
              "--  Darwin and FreeBSD it declares nothing.",
              "",
              "compiler.assert(compiler.os == linux or compiler.os == darwin",
              "                or compiler.os == freebsd)",
              "", "fixed if compiler.os == linux then"]
    for index, ((arch, spoken), _, _, rows) in enumerate(generated):
        keyword = "fixed if" if index == 0 else "elsif"
        lines.append("    %s compiler.arch == %s then" % (keyword, arch))
        for number, name in rows:
            lines.append("        --- `%s`'s system-call number on %s."
                         % (name, spoken))
            lines.append("        public %s%s: i64 = %d" % (name, SUFFIX, number))
    lines += ["    end if", "end if", ""]
    return "\n".join(lines)


def used_names(module):
    """The calls whose numbers the files of platform/linux at MODULE name,
    leaving out the file the generator writes there."""
    names = set()
    for path in sorted(pathlib.Path(module).glob("*.ldn")):
        if path.name != WRAPPED.name:
            #  Comments mention numbers without using them.
            code = re.sub(r"--.*", "", path.read_text(encoding="utf-8"))
            names |= set(re.findall(r"\b(\w+)" + re.escape(SUFFIX) + r"\b",
                                    code))
    return names


def render_wrapped(version, generated, used):
    """platform/linux's private copy of the numbers its wrappers use, from the
    same tables: on each architecture, every name in USED its table has.  A
    name no table has is refused, since no wrapper could be built on it."""
    known = set()
    for _, _, _, rows in generated:
        known |= {name for _, name in rows}
    unknown = sorted(used - known)
    if unknown:
        raise Refused("platform/linux names %s, which no table has"
                      % ", ".join(name + SUFFIX for name in unknown))
    lines = [
        "--  The numbers of the calls platform/linux's wrappers make, generated by",
        "--  scripts/linux_syscalls.py from Linux %s with the module" % version,
        "--  platform/linux/numbers, whose header names the release.  Do not edit",
        "--  it: the generator finds the names the module's other files use.",
        "",
        "fixed if compiler.os == linux then",
    ]
    for index, ((arch, _), _, _, rows) in enumerate(generated):
        keyword = "fixed if" if index == 0 else "elsif"
        lines.append("    %s compiler.arch == %s then" % (keyword, arch))
        for number, name in rows:
            if name in used:
                lines.append("        %s%s: i64 = %d" % (name, SUFFIX, number))
    lines += ["    end if", "end if", ""]
    return "\n".join(lines)


HEADER = re.compile(r"^--  scripts/linux_syscalls\.py from Linux (\S+):\n"
                    r"--  (\S+)\n--  SHA-256 ([0-9a-f]{64})\.$", re.M)
SOURCE = re.compile(r"^--  (.+) reads (\S+)\n--  with the ABIs (.+)\.$", re.M)
BRANCH = re.compile(r"^    (?:fixed if|elsif) compiler\.arch == (\w+) then$")
NUMBER = re.compile(r"^        public (\w+)" + re.escape(SUFFIX)
                    + r": i64 = (\d+)$")


def read_back(text):
    """The pin and the tables a generated file holds, as `render` takes
    them, so the file can be held to being the generator's output."""
    header = HEADER.search(text)
    if not header:
        raise Refused("no generator header")
    spoken = {arch: words for arch, words in ARCHITECTURES}
    sources = SOURCE.findall(text)
    generated = []
    current = None
    for line in text.splitlines():
        branch = BRANCH.match(line)
        if branch:
            arch = branch.group(1)
            if arch not in spoken or len(generated) >= len(sources):
                raise Refused("an unexpected branch: %r" % line)
            said, source, abis = sources[len(generated)]
            if said != spoken[arch]:
                raise Refused("%s's sources are listed as %s's"
                              % (arch, said))
            current = []
            generated.append(((arch, said), source, abis.split(", "),
                              current))
            continue
        number = NUMBER.match(line)
        if number:
            if current is None:
                raise Refused("a number outside a branch: %r" % line)
            current.append((int(number.group(2)), number.group(1)))
    return header.group(1), header.group(3), header.group(2), generated


def committed(module):
    """The tables the checked-in numbers file at MODULE holds, held to being
    the generator's own rendering of them under the pin VERSION, SHA256 and
    URL, so that the wrappers can be generated without the release."""
    version, sha256, url = VERSION, SHA256, URL
    path = module / OUTPUT.relative_to(MODULE)
    if not path.exists():
        raise Refused("%s does not exist; generate it from the release with"
                      " --fetch or --tarball" % path)
    text = path.read_text(encoding="utf-8")
    found_version, found_sha, found_url, generated = read_back(text)
    if (found_version, found_sha, found_url) != (version, sha256, url):
        raise Refused("%s names Linux %s, not the pinned %s; generate it from"
                      " the release with --fetch or --tarball"
                      % (path, found_version, version))
    if [arch for (arch, _), _, _, _ in generated] != [
            arch for arch, _ in ARCHITECTURES]:
        raise Refused("%s does not hold every architecture's table" % path)
    if render(found_version, found_sha, found_url, generated) != text:
        raise Refused("%s is not the generator's output; generate it from"
                      " the release with --fetch or --tarball" % path)
    return generated


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--fetch", type=pathlib.Path, metavar="DIR",
                        help="download the pinned release into DIR first")
    source.add_argument("--tarball", type=pathlib.Path,
                        help="the pinned release, already downloaded")
    parser.add_argument("--module", type=pathlib.Path, default=MODULE,
                        help="platform/linux, which both outputs belong to")
    parser.add_argument("--check", action="store_true",
                        help="compare the outputs instead of writing them")
    args = parser.parse_args(argv)
    module = args.module
    outputs = (module / OUTPUT.relative_to(MODULE),
               module / WRAPPED.relative_to(MODULE))
    released = args.fetch is not None or args.tarball is not None
    try:
        if released:
            tarball = (fetch(args.fetch, URL, SHA256) if args.fetch
                       else args.tarball)
            generated = tables(Release(tarball, SHA256))
            texts = (render(VERSION, SHA256, URL, generated),
                     render_wrapped(VERSION, generated, used_names(module)))
        else:
            #  The numbers file is the input here, already held to its own
            #  rendering, so only the wrappers' file is written.
            generated = committed(module)
            outputs = outputs[1:]
            texts = (render_wrapped(VERSION, generated, used_names(module)),)
    except (Refused, OSError, tarfile.TarError) as problem:
        print("linux_syscalls: %s" % problem, file=sys.stderr)
        return 2
    if args.check:
        stale = [path for path, text in zip(outputs, texts)
                 if not path.exists()
                 or path.read_text(encoding="utf-8") != text]
        for path in stale:
            print("linux_syscalls: %s is not what Linux %s gives; run"
                  " scripts/linux_syscalls.py without --check"
                  % (path, VERSION), file=sys.stderr)
        if stale:
            return 1
        print("linux_syscalls: %s Linux %s"
              % ("both files match" if released
                 else "the numbers and the wrappers' numbers match", VERSION))
        return 0
    for path, text in zip(outputs, texts):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print("linux_syscalls: wrote %s from Linux %s%s"
              % (path, VERSION,
                 "" if released else ", as platform/linux/numbers holds it"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
