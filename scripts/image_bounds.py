#!/usr/bin/env python3
"""Hold compact static images to D536's and D537's bounds with a real assembler.

`backend scale/compact images emit compact assembly` holds every native
backend's text to the source's size on a fake host; what that text costs
the assembler, and what object it makes, only an assembler can say.  This
compiles a few-line program for each shape below at two sizes, assembles
each with the target's driver (`DRIVER -c`), and requires

- the assembly at twice the image to be no more than a few hundred bytes
  longer than at once, so its size is the source's;
- the object to hold the image's bytes, and no more than a page of other
  bytes, or, for zero images the loader clears, none of them;
- the assembler's peak memory, read with `wait4`, to stay under a fixed
  ceiling for a run one directive writes, `.zero` or `.fill`, whatever its
  size, and to grow at most `GROWTH` times when a repeated composite run
  doubles, within `PER_BYTE` bytes of memory per image byte;
- and a program of a few lines asking for more than the budget to be
  refused with L0505 before any tool runs, quickly, writing no assembly.

Standard-library Python.  It needs a built compiler and the target's
driver; it runs no program.  The target is `--target`, the compiler's own
name for it, and the driver `--toolchain`, default `cc` for the host.

    image_bounds.py --refine=PATH [--target=NAME] [--toolchain=DRIVER]
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

#  One size, in image bytes, for the shapes `.zero` and `.fill` write and
#  the one doubled for the repeated composite shapes: large enough that an
#  expanded run would show, small enough for a shared host.
FILLED = 256 * 1024 * 1024
REPEATED = 16 * 1024 * 1024
#  A run one directive writes costs the assembler this much at most,
#  whatever its image: GNU as holds it as one fragment.
FLAT_CEILING = 96 * 1024 * 1024
#  A repeated composite run's peak memory, per image byte, and its growth
#  when the run doubles: linear, not the run times the body's text.  Short
#  zero gaps and runs inside a repeated body are plain values (D536), so a
#  padded record costs what a repeated quad does, about three bytes per
#  image byte; one `.zero` fragment per copy cost about twenty.
PER_BYTE = 6
GROWTH = 2.5
#  The text the doubled image may add: digits, and a nested level per
#  base-256 digit of a repeated run.
TEXT_SLACK = 512
#  The bytes an object holds besides its image: headers, symbols, sections.
OBJECT_SLACK = 64 * 1024
REFUSAL_SECONDS = 10

#  The reach D537 holds written images to, per target.
REACH = {
    "linux-x86-64": 2 ** 31, "freebsd-x86-64": 2 ** 31,
    "darwin-arm64": 2 ** 31, "linux-rv64": 2 ** 31,
    "linux-arm64": 2 ** 32, "freebsd-arm64": 2 ** 32,
    "cortex-m0": 2 ** 32 - 1,
}

HOSTED_MAIN = "public main: () -> (code: i32) = code = i32(%s) end main\n"
CELL = "cell: type = struct\n    tag: u8\n    value: u32\nend cell\n"
#  Twenty-four bytes: seven of padding after the tag, a run of three
#  halves and two more of padding at the end.
WIDE = ("wide: type = struct\n    tag: u8\n    value: u64\n    pair: [3]u16\n"
        "end wide\n")


def shapes(scale: int) -> dict[str, tuple[str, str, int, int]]:
    """Name -> (declarations, a read of them, written bytes, kind).

    Kind 0 is a run one directive writes, 1 a repeated run, 2 reserved.
    Each image is `scale` times its unit size; the cell is eight bytes.
    """
    filled = FILLED // 4 * scale // 4
    repeated = REPEATED * scale
    return {
        "zero-reserved": (
            "mut image: [%d]u8 = zeroed\n" % (FILLED * 4 * scale),
            "image[1]", 0, 2),
        "zero-written": (
            "mut image: [%d]u32 = [7, of 0]\n" % filled,
            "image[1]", filled * 4, 0),
        "fill-bytes": (
            "mut image: [%d]u8 = [of 165]\n" % (filled * 4),
            "image[1]", filled * 4, 0),
        "fill-halves": (
            "mut image: [%d]u16 = [of 4660]\n" % (filled * 2),
            "image[1]", filled * 4, 0),
        "fill-words": (
            "mut image: [%d]u32 = [of 305419896]\n" % filled,
            "image[1]", filled * 4, 0),
        "repeated-quads": (
            "mut image: [%d]u64 = [of 0x123456789ABCDEF0]\n" % (repeated // 8),
            "image[1]", repeated, 1),
        "repeated-records": (
            CELL + "mut image: [%d][1024]cell = [of [of cell(tag: 1, value: 2)]]\n"
            % (repeated // 8 // 1024),
            "image[1][1].value", repeated, 1),
        "repeated-padded": (
            WIDE + "mut image: [%d]wide = [of wide(tag: 1, value: 2, pair: [of 3])]\n"
            % (REPEATED // 24 * scale),
            "image[1].value", REPEATED // 24 * scale * 24, 1),
    }


def program(target: str, declarations: str, read: str) -> str:
    """A program of the declarations that reads them, so nothing prunes them."""
    if target == "cortex-m0":
        return declarations + "read: () -> (value: u32) = value = u32(%s) end read\n" % read
    return declarations + HOSTED_MAIN % read


def compile_args(target: str) -> list[str]:
    return ["--target=" + target] + ([] if target == "cortex-m0" else ["--link=libc"])


def assemble_args(target: str) -> list[str]:
    if target == "cortex-m0":
        return ["-mcpu=cortex-m0", "-mthumb", "-mfloat-abi=soft"]
    return []


#  Seconds one assembly may take before it is ended and reported.  The
#  largest shape assembles in seconds; this only bounds a driver that hangs.
ASSEMBLY_SECONDS = 900


def peak_of(command: list[str], cwd: str,
            seconds: float = ASSEMBLY_SECONDS) -> tuple[int, int, float, str]:
    """Exit status, peak resident bytes of the command and what it waited
    for, wall seconds, and the last lines it wrote to standard error.
    wait4's maximum covers the driver's own child, the assembler, which is
    what is measured.

    Standard error goes to a file and not a pipe: nothing reads a pipe
    while wait4 waits, so an assembler with more to say than a pipe holds,
    one diagnostic for each line of a repeated body, would block in its
    write and never exit.  A command still running after `seconds` is
    killed, and its status is then the signal's."""
    started = time.monotonic()
    with tempfile.TemporaryFile() as said:
        process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.DEVNULL,
                                   stderr=said)
        timer = threading.Timer(seconds, process.kill)
        timer.start()
        try:
            _, status, usage = os.wait4(process.pid, 0)
        finally:
            timer.cancel()
        process.returncode = os.waitstatus_to_exitcode(status)
        said.seek(max(0, said.seek(0, os.SEEK_END) - 16384))
        lines = said.read().decode(errors="replace").splitlines()[-12:]
    #  Linux reports kilobytes; Darwin, bytes.
    scale = 1 if sys.platform == "darwin" else 1024
    return (process.returncode, usage.ru_maxrss * scale,
            time.monotonic() - started, "\n".join(lines))


def check_shape(refine: str, driver: str, target: str, name: str,
                work: str) -> list[str]:
    """The faults one shape shows at its two sizes; none when it holds."""
    faults = []
    measured = []
    for scale in (1, 2):
        declarations, read, written, kind = shapes(scale)[name]
        directory = os.path.join(work, "%s-%d" % (name, scale))
        os.mkdir(directory)
        with open(os.path.join(directory, "image.ldn"), "w") as out:
            out.write(program(target, declarations, read))
        result = subprocess.run(
            [refine, *compile_args(target), "--emit=asm", "-o", "image.s", "image.ldn"],
            cwd=directory, capture_output=True, text=True)
        if result.returncode != 0:
            return ["%s: refine refused the in-budget image: %s" % (name, result.stderr.strip())]
        status, peak, _, said = peak_of(
            [driver, *assemble_args(target), "-c", "image.s", "-o", "image.o"], directory)
        if status != 0:
            return ["%s: the assembler failed at scale %d with status %d%s"
                    % (name, scale, status,
                       ", its last lines:\n" + said if said else "")]
        text = os.path.getsize(os.path.join(directory, "image.s"))
        size = os.path.getsize(os.path.join(directory, "image.o"))
        measured.append((text, size, peak, written, kind))
        os.remove(os.path.join(directory, "image.o"))
    (text_1, size_1, peak_1, written_1, kind), (text_2, size_2, peak_2, written_2, _) = measured
    print("  %-17s assembly %d then %d bytes; object %d then %d; peak %.0f then %.0f MiB"
          % (name, text_1, text_2, size_1, size_2, peak_1 / 2 ** 20, peak_2 / 2 ** 20))
    if text_2 > text_1 + TEXT_SLACK:
        faults.append("%s: doubling the image grew the assembly from %d to %d bytes"
                      % (name, text_1, text_2))
    for size, written in ((size_1, written_1), (size_2, written_2)):
        if not written <= size <= written + OBJECT_SLACK:
            faults.append("%s: an object of %d bytes for %d image bytes" % (name, size, written))
    if kind in (0, 2) and max(peak_1, peak_2) > FLAT_CEILING:
        faults.append("%s: a run one directive writes took %.0f MiB of the assembler"
                      % (name, max(peak_1, peak_2) / 2 ** 20))
    if kind == 1:
        print("  %-17s %.1f bytes of assembler memory per image byte"
              % ("", peak_2 / written_2))
        if peak_2 > GROWTH * peak_1:
            faults.append("%s: doubling the run grew the assembler from %.0f to %.0f MiB"
                          % (name, peak_1 / 2 ** 20, peak_2 / 2 ** 20))
        if peak_2 > PER_BYTE * written_2 + FLAT_CEILING:
            faults.append("%s: %.1f bytes of assembler memory per image byte"
                          % (name, peak_2 / written_2))
    return faults


def check_refusal(refine: str, target: str, work: str) -> list[str]:
    """A few lines asking for gigabytes past the budget refuse before any tool."""
    directory = os.path.join(work, "refusal")
    os.mkdir(directory)
    if target == "cortex-m0":
        #  A firmware image, held to the reference profile's 32 KiB flash.
        source = ("link(keep) image: [8388609]u8 = [of 1]\n"
                  "start: () -> none = end start\n")
        request = ["--target=cortex-m0", "--firmware-entry=start"]
    else:
        source = program(target, "mut image: [%d]u8 = [of 1]\n" % (REACH[target] + 1),
                         "image[1]")
        request = compile_args(target)
    with open(os.path.join(directory, "image.ldn"), "w") as out:
        out.write(source)
    started = time.monotonic()
    result = subprocess.run(
        [refine, *request, "--emit=exe", "--toolchain=/nonexistent/driver",
         "-o", "image", "image.ldn"],
        cwd=directory, capture_output=True, text=True, timeout=REFUSAL_SECONDS * 6)
    seconds = time.monotonic() - started
    faults = []
    if result.returncode != 1 or "error[L0505]" not in result.stderr:
        faults.append("a source past the budget was not refused as L0505: %s"
                      % result.stderr.strip())
    if os.path.exists(os.path.join(directory, "image.s")) or os.path.exists(
            os.path.join(directory, "image")):
        faults.append("the refusal wrote an artifact")
    if seconds > REFUSAL_SECONDS:
        faults.append("the refusal took %.1f s" % seconds)
    print("  refusal           %s in %.2f s" % (result.stderr.splitlines()[0]
                                                if result.stderr else "nothing", seconds))
    return faults


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--refine", required=True)
    parser.add_argument("--target", default="linux-x86-64", choices=sorted(REACH))
    parser.add_argument("--toolchain", default="cc")
    parser.add_argument("--shape", action="append", choices=sorted(shapes(1)),
                        help="one shape, which repeats; every shape by default")
    options = parser.parse_args(argv)
    driver = shutil.which(options.toolchain) or options.toolchain
    if not os.access(driver, os.X_OK):
        print("image_bounds: no driver %s; name the target's with --toolchain"
              % options.toolchain, file=sys.stderr)
        return 2
    faults: list[str] = []
    with tempfile.TemporaryDirectory(prefix="landin-image-bounds-") as work:
        print("image bounds: %s with %s" % (options.target, driver))
        for name in options.shape or sorted(shapes(1)):
            faults += check_shape(options.refine, driver, options.target, name, work)
        faults += check_refusal(options.refine, options.target, work)
    for fault in faults:
        print("FAIL " + fault, file=sys.stderr)
    print("image bounds: %s" % ("FAILED" if faults else "held"))
    return 1 if faults else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
