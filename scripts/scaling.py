#!/usr/bin/env python3
"""How the compiler's time grows with the size of the program it checks.

Each family below generates a program at 1,000, 2,000, 4,000, 8,000 and
16,000 declarations and asks the compiler to check it and emit its assembly:
scan, parse, resolve, type and flow checking and lowering to verified IR,
which is the frontend, and then optimization and the backend, which is
emission.  The compiler's own `--stage-report` says how much processor time
each stage took, which leaves out process start, reading the sources and
the harness.  Five runs per input, and the median of them.

The verdict is a ratio: the median at one size over the median at half that
size, for every doubling in every family, taken for the frontend and for
emission separately so that a cheap stage cannot hide a growing one.  A ratio compares two runs on the
same machine a few seconds apart, so it does not depend on how fast the
runner is, and a pass that grows with the square of the program shows up as
four no matter what the machine is.  A ratio above the limit fails.

Noise is handled three ways.  Processor time rather than wall time, so a
busy neighbour that takes the core away costs nothing that is counted.  The
median of five, so one run disturbed by a page-cache miss or a migration
does not decide anything.  And the smallest size is large enough, a
thousand declarations, that the fixed cost of a compilation is a small part
of every measurement, so what is left to vary is the part being measured.

The derived programs, the complete programs derived from the four
prototypes, are measured too, at their one size: they are what a real
program looks like, and a pass that none of the families exercises still
shows up there.  They have no ratio, only a time and a peak.

The generated programs are written into a temporary directory and never
into the repository; the same size always produces the same bytes.

This is standard-library Python, like `check.py`, and needs a built
compiler: `--refine=PATH`, or the release build under
`compiler/ada/build/<tag>/release/bin/refine`.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#  The first size is a thousand declarations and the last sixteen thousand;
#  a family's size is its count of declarations, not of functions, except
#  that the struct family's is its count of fields.
SIZES = (1000, 2000, 4000, 8000, 16000)
RUNS = 5
LIMIT = 2.5

#  The stages the ratios are taken over: everything that reads the source,
#  and everything that turns the verified IR into assembly.
FRONTEND = ("loading", "syntax", "configuration", "resolution",
            "checking", "lowering")
EMISSION = ("emission",)
PARTS = (("frontend", FRONTEND), ("emission", EMISSION))

DERIVED = (
    ("derived log filter", "examples/derived_hosted"),
    ("derived parser", "compiler/tests/fixtures/runtime/derived-parser"),
    ("derived containers",
     "compiler/tests/fixtures/runtime/derived-containers"),
    ("derived hosted memory",
     "compiler/tests/fixtures/runtime/derived-hosted-memory"),
)


#  Each family returns {relative path: text} for a program of about `size`
#  declarations.  Every one has a hosted `main`, so the program is complete
#  and checks with no diagnostic; a family that begins to report one is a
#  broken family, and the benchmark refuses it rather than timing the
#  refusal.

def functions(size: int) -> dict[str, str]:
    """Functions that each call the one before: three declarations each,
    the function, its parameter and its named return."""
    count = size // 3
    parts = []
    for index in range(count):
        call = f"f{index - 1}(x)" if index else "x"
        parts.append(f"f{index}: (x: i32) -> (r: i32) =\n"
                     f"    r = {call}\nend f{index}\n")
    parts.append("public main: () -> (code: i32) =\n"
                 f"    code = f{count - 1}(42)\nend main\n")
    return {"main.ldn": "\n".join(parts)}


def atoms(size: int) -> dict[str, str]:
    """Functions that each fail with an atom of their own and handle the
    failure of the one before: four declarations each, the atom, the
    function, its parameter and its named return."""
    count = size // 4
    parts = []
    for index in range(count):
        call = (f"    result = f{index - 1}(value) else 0\n" if index
                else "    result = value\n")
        parts.append(f"e{index}: atom\n"
                     f"f{index}: (value: i32) -> (result: i32) ! e{index} =\n"
                     f"    fail e{index} when value == {index + 100000}\n"
                     + call + f"end f{index}\n")
    parts.append("public main: () -> (code: i32) =\n"
                 f"    code = f{count - 1}(42) else 1\nend main\n")
    return {"main.ldn": "\n".join(parts)}


def modules(size: int) -> dict[str, str]:
    """Modules of 100 functions each, importing the one before, with
    structs, a variant, a pointer, a loop, a branch and a match in every
    function: about ten declarations per function."""
    count = size // 10
    per = 100
    files = {}
    total = (count + per - 1) // per
    for module in range(total):
        parts = []
        if module:
            parts.append(f"import gen/m{module - 1}\n")
        parts.append(f"public pair{module}: type = struct\n"
                     "    left: i32\n    right: i32\n"
                     f"end pair{module}\n")
        parts.append(f"public shape{module}: type = struct\n"
                     "    kind: variant\n        a: (v: i32) |\n        b\n"
                     f"    end kind\nend shape{module}\n")
        first = module * per
        last = min(count, first + per) - 1
        for index in range(first, last + 1):
            visible = "public " if index == last else ""
            if index == first and module:
                local = f"m{module - 1}.pair{module - 1}"
                inner = f"m{module - 1}.g{index - 1}(t, x)"
            elif index == first:
                local = f"pair{module}"
                inner = "x"
            else:
                local = f"pair{module}"
                inner = f"g{index - 1}(t, x)"
            parts.append(
                f"{visible}g{index}: (inout p: pair{module}, x: i32)"
                " -> (r: i32) =\n"
                f"    mut t: {local} = (left: 0, right: 0)\n"
                f"    mut acc: i32 = {inner}\n"
                f"    q: ptr mut pair{module} = addr p\n"
                f"    mut s: shape{module} = (kind: a(v: acc))\n"
                "    for i in 0..<3 do\n"
                "        if acc > 1000 then\n"
                "            acc = acc - 1\n"
                "        else\n"
                "            q.val.left = q.val.left + 1\n"
                "        end if\n"
                "    end for\n"
                "    match s.kind\n"
                "        a(v): r = v + p.left - p.left\n"
                "        b: r = 0\n"
                "    end match\n"
                f"end g{index}\n")
        files[f"gen/m{module}/m{module}.ldn"] = "\n".join(parts)
    last_module = total - 1
    files["main.ldn"] = (
        f"import gen/m{last_module}\n\n"
        "public main: () -> (code: i32) =\n"
        f"    mut p: m{last_module}.pair{last_module} ="
        " (left: 0, right: 0)\n"
        f"    code = m{last_module}.g{count - 1}(p, 42)\n"
        "end main\n")
    return files


def generics(size: int) -> dict[str, str]:
    """One generic routine instantiated over a distinct struct from each of
    many functions: about six declarations per instance."""
    count = size // 6
    parts = ["box: type (item: type) = struct\n    value: item\nend box\n",
             "get: (item: type, b: box(item)) -> (v: item) =\n"
             "    v = b.value\nend get\n"]
    for index in range(count):
        parts.append(f"t{index}: type = struct\n    x: i32\nend t{index}\n")
        parts.append(f"u{index}: (x: i32) -> (r: i32) =\n"
                     f"    b: box(t{index}) = (value: (x: x))\n"
                     f"    got: t{index} = get(b)\n"
                     "    r = got.x\n"
                     f"end u{index}\n")
    parts.append("public main: () -> (code: i32) =\n"
                 "    code = u0(42)\nend main\n")
    return {"main.ldn": "\n".join(parts)}


def constants(size: int) -> dict[str, str]:
    """Module constants, each folded from the one before."""
    body = "".join(f"c{index}: i32 = c{index - 1} + 1\n" if index
                   else "c0: i32 = 0\n" for index in range(size))
    return {"main.ldn": body + "\npublic main: () -> (code: i32) =\n"
            f"    code = c{size - 1} - c{size - 1} + 42\nend main\n"}


def locals_(size: int) -> dict[str, str]:
    """One function holding every declaration as a local."""
    body = "".join(f"    v{index}: i32 = v{index - 1} + 1\n" if index
                   else "    v0: i32 = 0\n" for index in range(size))
    return {"main.ldn": "public main: () -> (code: i32) =\n" + body
            + f"    code = v{size - 1} - v{size - 1} + 42\nend main\n"}


def fields(size: int) -> dict[str, str]:
    """One struct with every declaration as a field."""
    body = "".join(f"    f{index}: i32\n" for index in range(size))
    return {"main.ldn": "big: type = struct\n" + body + "end big\n\n"
            "public main: () -> (code: i32) =\n"
            "    mut b: big = zeroed\n"
            f"    b.f{size - 1} = 42\n"
            f"    code = b.f{size - 1}\nend main\n"}


FAMILIES = (
    ("functions", functions),
    ("atoms", atoms),
    ("modules", modules),
    ("generics", generics),
    ("constants", constants),
    ("locals", locals_),
    ("fields", fields),
)


def default_refine() -> str:
    tag = os.environ.get("LANDIN_BUILD_TAG")
    build = os.path.join(ROOT, "compiler", "ada", "build")
    if not tag:
        tags = sorted(os.listdir(build)) if os.path.isdir(build) else []
        tag = tags[0] if len(tags) == 1 else "nix"
    return os.path.join(build, tag, "release", "bin", "refine")


def measure(refine: str, root: str, entry: str, report: str,
            timeout: float) -> dict:
    """One compilation; the frontend's and emission's processor seconds, the
    peak resident set in KiB and the compilation's sizes, from the
    compiler's own report."""
    command = [refine, "--root=" + root, "--stage-report=" + report,
               "--emit=asm", "-o", report + ".s", entry]
    started = time.monotonic()
    completed = subprocess.run(command, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=timeout,
                               check=False)
    if completed.returncode != 0:
        raise RuntimeError(
            "%s exited %d after %.1fs\n%s" % (
                " ".join(command), completed.returncode,
                time.monotonic() - started,
                completed.stderr.decode("utf-8", "replace")[-2000:]))
    with open(report, encoding="utf-8") as handle:
        data = json.load(handle)
    stages = {row["stage"]: row for row in data["stages"]}
    missing = [name for name in FRONTEND + EMISSION if name not in stages]
    if missing:
        raise RuntimeError("the stage report lacks " + ", ".join(missing))
    result = {part: sum(stages[name]["processor_us"] for name in names) / 1e6
              for part, names in PARTS}
    result.update(
        peak_kib=max(row["peak_kib"] for row in data["stages"]),
        stages={name: stages[name]["processor_us"] / 1e6
                for name in FRONTEND + EMISSION},
        sizes=data["sizes"])
    return result


def median_of(refine: str, root: str, entry: str, work: str, runs: int,
              timeout: float) -> dict:
    samples = [measure(refine, root, entry,
                       os.path.join(work, "stages.json"), timeout)
               for _ in range(runs)]
    result = {part: statistics.median(sample[part] for sample in samples)
              for part, _ in PARTS}
    result.update(
        stages={name: statistics.median(sample["stages"][name]
                                        for sample in samples)
                for name in FRONTEND + EMISSION},
        peak_kib=max(sample["peak_kib"] for sample in samples),
        sizes=samples[0]["sizes"],
        samples={part: [sample[part] for sample in samples]
                 for part, _ in PARTS})
    return result


def write_program(directory: str, files: dict[str, str]) -> None:
    for relative, text in files.items():
        path = os.path.join(directory, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)


def main(argv: list[str]) -> int:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--refine", default=None,
                        help="the compiler to measure (default: the"
                             " release build)")
    parser.add_argument("--runs", type=int, default=RUNS)
    parser.add_argument("--limit", type=float, default=LIMIT)
    parser.add_argument("--largest", type=int, default=SIZES[-1],
                        help="stop at this size (for a quick look; the"
                             " verdict needs the whole range)")
    parser.add_argument("--family", action="append", default=None,
                        help="measure only this family; repeatable")
    parser.add_argument("--no-derived", action="store_true")
    parser.add_argument("--timeout", type=float, default=900.0,
                        help="seconds one compilation may take")
    parser.add_argument("--json", default=None,
                        help="also write every measurement here")
    arguments = parser.parse_args(argv)

    refine = os.path.abspath(arguments.refine or default_refine())
    if not os.access(refine, os.X_OK):
        print("scaling: no compiler at " + refine, file=sys.stderr)
        return 2
    if arguments.runs < 1:
        parser.error("--runs must be at least one")
    known = {name for name, _ in FAMILIES}
    for name in arguments.family or ():
        if name not in known:
            parser.error("unknown family: " + name)
    sizes = [size for size in SIZES if size <= arguments.largest]
    families = [(name, build) for name, build in FAMILIES
                if not arguments.family or name in arguments.family]

    record = {"refine": refine, "runs": arguments.runs,
              "limit": arguments.limit, "families": {}, "derived": {}}
    failures = []
    with tempfile.TemporaryDirectory(prefix="landin-scaling-") as work:
        for name, build in families:
            rows = []
            print(f"{name}:")
            for size in sizes:
                directory = os.path.join(work, f"{name}-{size}")
                write_program(directory, build(size))
                try:
                    result = median_of(refine, directory, directory, work,
                                       arguments.runs, arguments.timeout)
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    failures.append(f"{name} at {size}: {error}")
                    print(f"  {size:>6}  failed")
                    break
                ratios = {part: (result[part] / rows[-1][part]
                                 if rows and rows[-1][part] > 0 else None)
                          for part, _ in PARTS}
                result.update(size=size, ratios=ratios)
                rows.append(result)
                shown = "".join(
                    f"  {part} {result[part]:8.3f}s "
                    + (f"{ratios[part]:5.2f}x" if ratios[part] is not None
                       else "      ")
                    for part, _ in PARTS)
                print(f"  {size:>6}{shown}"
                      f"  {result['peak_kib'] / 1024:8.1f} MiB"
                      f"  {result['sizes']['declarations']:>6} declarations")
                for part, _ in PARTS:
                    ratio = ratios[part]
                    if ratio is not None and ratio > arguments.limit:
                        failures.append(
                            f"{name}: {part} {rows[-2]['size']} -> {size}"
                            f" grew {ratio:.2f}x, more than"
                            f" {arguments.limit}x")
            record["families"][name] = rows

        if not arguments.no_derived:
            print("derived programs:")
            for name, relative in DERIVED:
                try:
                    result = median_of(refine, ROOT,
                                       os.path.join(ROOT, relative), work,
                                       arguments.runs, arguments.timeout)
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    failures.append(f"{name}: {error}")
                    print(f"  {name:<22}  failed")
                    continue
                record["derived"][name] = result
                print(f"  {name:<22}  frontend {result['frontend']:8.3f}s"
                      f"  emission {result['emission']:8.3f}s"
                      f"  {result['peak_kib'] / 1024:8.1f} MiB")

    if arguments.json:
        with open(arguments.json, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2)
            handle.write("\n")
    for failure in failures:
        print("scaling: " + failure, file=sys.stderr)
    if len(sizes) < len(SIZES):
        print("scaling: a partial range is not a verdict", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
