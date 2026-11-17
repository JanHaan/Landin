#!/usr/bin/env python3
"""Measure the code refine emits, and hold a candidate to its baselines.

docs/measurement.md is the contract this carries out.  A configuration is
a target, one of the levels `refine targets --json` gives it, and one of
the nine optimization and specialization profiles; a workload is a fixture
with an oracle, named in compiler/tests/measure/workloads.json.

    measure.py size --refine R --target T ... --output DIR
        build every workload in every configuration of each target, check
        its oracle where the host runs it, and write DIR/size.json: each
        allocated section's bytes, read from the linked image
    measure.py compare DIR/size.json [--base REV]
        the measurements against the base commit's baselines, and the keys
        the candidate's own baseline files changed; exit 1 on a difference
        the candidate did not declare
    measure.py record DIR/size.json [--key KEY ...]
        write the measurements into the candidate's baseline files
    measure.py runners --refine R
        every target/level pair the compiler gives and how it is measured

Standard library only.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MEASURE = ROOT / "compiler/tests/measure"
BASELINES = MEASURE / "baselines"
sys.path.insert(0, str(ROOT / "compiler/tests"))
import fixture_meta  # noqa: E402

OPTIMIZE = ("none", "size", "speed")
SPECIALIZE = ("off", "auto", "all")
PROFILES = tuple((o, s) for o in OPTIMIZE for s in SPECIALIZE)
HOSTED = ("linux-x86-64", "linux-arm64", "darwin-arm64", "freebsd-x86-64",
          "freebsd-arm64", "linux-rv64")


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


# --- reading images ---------------------------------------------------------

SHF_ALLOC = 0x2


def elf_sections(data: bytes) -> dict[str, int]:
    """Each allocated section's size in an ELF image, by name."""
    require(data[:4] == b"\x7fELF", "not an ELF image")
    wide = data[4] == 2
    order = "<" if data[5] == 1 else ">"
    if wide:
        shoff, = struct.unpack_from(order + "Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from(order + "HHH", data, 0x3A)
    else:
        shoff, = struct.unpack_from(order + "I", data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from(order + "HHH", data, 0x2E)
    headers = []
    for index in range(shnum):
        at = shoff + index * shentsize
        if wide:
            name, kind, flags, _, offset, size = struct.unpack_from(
                order + "IIQQQQ", data, at)
        else:
            name, kind, flags, _, offset, size = struct.unpack_from(
                order + "IIIIII", data, at)
        headers.append((name, kind, flags, offset, size))
    strings = headers[shstrndx]
    table = data[strings[3]:strings[3] + strings[4]]
    sections: dict[str, int] = {}
    for name, kind, flags, _, size in headers:
        if not flags & SHF_ALLOC or size == 0:
            continue
        label = table[name:table.index(b"\0", name)].decode()
        sections[label] = sections.get(label, 0) + size
    return sections


def macho_sections(data: bytes) -> dict[str, int]:
    """Each section's size in a 64-bit Mach-O image, as SEGMENT,section."""
    magic, = struct.unpack_from("<I", data, 0)
    require(magic == 0xFEEDFACF, "not a 64-bit little-endian Mach-O image")
    ncmds, = struct.unpack_from("<I", data, 16)
    at = 32
    sections: dict[str, int] = {}
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, at)
        if command == 0x19:  # LC_SEGMENT_64
            nsects, = struct.unpack_from("<I", data, at + 64)
            for index in range(nsects):
                base = at + 72 + index * 80
                section = data[base:base + 16].rstrip(b"\0").decode()
                segment = data[base + 16:base + 32].rstrip(b"\0").decode()
                bytes_, = struct.unpack_from("<Q", data, base + 40)
                if bytes_:
                    sections[segment + "," + section] = bytes_
        at += size
    return sections


def image_sections(path: Path) -> dict[str, int]:
    data = path.read_bytes()
    if data[:4] == b"\x7fELF":
        return elf_sections(data)
    return macho_sections(data)


# --- configurations and workloads -------------------------------------------

def targets(refine: Path) -> dict[str, list[str]]:
    """{target: [level, ...]} as the compiler gives them, emitting ones only."""
    listed = json.loads(subprocess.run(
        [str(refine), "targets", "--json"], check=True, capture_output=True,
        text=True).stdout)
    require(listed.get("schema") == 1, "unknown `refine targets --json` schema")
    return {one["name"]: [level.strip() for level in one["levels"].split(",")]
            for one in listed["targets"] if one["emission"] and one["levels"]}


def workloads() -> dict:
    data = json.loads((MEASURE / "workloads.json").read_text())
    require(data.get("schema") == 1, "unknown workloads.json schema")
    return data


def key(level: str, profile: tuple[str, str], workload: str) -> str:
    return f"{level}/{profile[0]}-{profile[1]}/{workload}"


def hosted_build(refine, target, level, profile, workload, out, toolchain):
    fixture = ROOT / "compiler/tests/fixtures" / workload["fixture"]
    meta = fixture_meta.read(fixture)
    image = out / f"{target}-{level}-{profile[0]}-{profile[1]}-{workload['name']}"
    command = [str(refine), "compile", f"--target={target}", f"--level={level}",
               f"--optimize={profile[0]}", f"--specialize={profile[1]}",
               *(["--toolchain=" + toolchain] if toolchain else []),
               *meta.library_arguments(fixture),
               *meta.source_arguments(fixture), "-o", str(image),
               f"--build-report={image}.json"]
    done = subprocess.run(command, capture_output=True, text=True, timeout=900,
                          cwd=ROOT / "compiler/ada")
    require(done.returncode == 0, f"{target} {key(level, profile, workload['name'])}"
            f" did not build:\n{' '.join(command)}\n{done.stdout}{done.stderr}")
    return image, meta, fixture


def oracle(image: Path, meta, fixture: Path, runner: list[str]):
    """Run IMAGE at its fixture's own arguments and hold it to the oracle."""
    stdin = (fixture / meta["stdin"]) if "stdin" in meta else None
    with (open(stdin, "rb") if stdin else open(os.devnull, "rb")) as given:
        done = subprocess.run([*runner, str(image),
                               *meta.program_arguments(fixture)],
                              stdin=given, capture_output=True, timeout=300,
                              cwd=ROOT / "compiler/ada",
                              env={**os.environ, "LC_ALL": "C"})
    require(done.returncode == meta.status,
            f"{image.name} returned {done.returncode}, expected {meta.status}")
    expected = meta.run_expected(fixture)
    if expected is not None:
        require(done.stdout == expected,
                f"{image.name}'s output differs from its fixture's oracle")


def measure_size(args) -> int:
    given = targets(args.refine)
    sets = workloads()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    images = out / "images"
    images.mkdir(exist_ok=True)
    toolchains = dict(one.split("=", 1) for one in args.toolchain)
    runners = dict(one.split("=", 1) for one in args.runner)
    result = {"schema": 1, "environment": args.environment, "targets": {}}
    work = []
    for target in args.target:
        require(target in given, f"refine gives no emitting target {target}")
        require(target in HOSTED, f"{target}: only hosted targets are measured yet")
        for level in given[target]:
            for profile in PROFILES:
                for workload in sets["hosted"]:
                    if workload["name"] in args.skip:
                        continue
                    work.append((target, level, profile, workload))

    def one(item):
        target, level, profile, workload = item
        image, meta, fixture = hosted_build(
            args.refine, target, level, profile, workload, images,
            toolchains.get(target))
        if target in runners:
            oracle(image, meta, fixture, runners[target].split())
        data = image.read_bytes()
        return target, key(level, profile, workload["name"]), {
            "sections": image_sections(image),
            "image_sha256": hashlib.sha256(data).hexdigest()}

    failures = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for future in concurrent.futures.as_completed(
                [pool.submit(one, item) for item in work]):
            try:
                target, name, figure = future.result()
            except Failure as error:
                failures.append(str(error))
                continue
            result["targets"].setdefault(target, {})[name] = figure
    for target in result["targets"]:
        result["targets"][target] = dict(sorted(result["targets"][target].items()))
    (out / "size.json").write_text(json.dumps(result, indent=1) + "\n")
    print(f"measured {sum(map(len, result['targets'].values()))} of {len(work)}"
          f" configurations; {out / 'size.json'}")
    for failure in failures:
        print("FAILED " + failure, file=sys.stderr)
    return 1 if failures else 0


# --- baselines --------------------------------------------------------------

def baseline_path(target: str) -> Path:
    return BASELINES / f"{target}.size.json"


def read_baseline(target: str, rev: str | None) -> dict:
    path = baseline_path(target)
    if rev is None:
        return json.loads(path.read_text()) if path.exists() else {}
    shown = subprocess.run(
        ["git", "show", f"{rev}:{path.relative_to(ROOT).as_posix()}"],
        cwd=ROOT, capture_output=True, text=True)
    return json.loads(shown.stdout) if shown.returncode == 0 else {}


def default_base() -> str:
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, check=True,
                          capture_output=True, text=True).stdout.strip()
    main = subprocess.run(["git", "rev-parse", "--verify", "-q", "origin/main"],
                          cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if not main or main == head:
        return "HEAD^"
    return subprocess.run(["git", "merge-base", "HEAD", "origin/main"], cwd=ROOT,
                          check=True, capture_output=True, text=True).stdout.strip()


def compare(args) -> int:
    measured = json.loads(Path(args.measurements).read_text())
    base = args.base or default_base()
    undeclared, declared, rebaselined, missing = [], [], [], []
    for target, figures in measured["targets"].items():
        before = read_baseline(target, base)
        after = read_baseline(target, None)
        if before.get("environment") != measured["environment"] and before:
            rebaselined.append(f"{target}: baseline environment"
                               f" {before.get('environment')} measured in"
                               f" {measured['environment']}")
            continue
        old = before.get("entries", {})
        new = after.get("entries", {})
        for name, figure in figures.items():
            if name not in old:
                if new.get(name, {}).get("sections") == figure["sections"]:
                    declared.append(f"{target} {name}: new, declared")
                else:
                    missing.append(f"{target} {name}: no baseline")
                continue
            if old[name]["sections"] == figure["sections"]:
                continue
            change = describe(old[name]["sections"], figure["sections"])
            if new.get(name, {}).get("sections") == figure["sections"]:
                declared.append(f"{target} {name}: {change}")
            else:
                undeclared.append(f"{target} {name}: {change}")
    for title, lines in (("declared by the candidate's baselines", declared),
                         ("re-baselined: another environment", rebaselined),
                         ("UNDECLARED", undeclared), ("UNRECORDED", missing)):
        if lines:
            print(f"{title} ({len(lines)}):")
            for line in lines:
                print("  " + line)
    total = sum(map(len, measured["targets"].values()))
    print(f"compared {total} configurations with {base}:"
          f" {len(undeclared)} undeclared, {len(missing)} unrecorded")
    if undeclared or missing:
        print("record a deliberate change with scripts/measure.py record"
              " and say why in the commit message", file=sys.stderr)
        return 1
    return 0


def describe(old: dict, new: dict) -> str:
    parts = []
    for name in sorted(set(old) | set(new)):
        a, b = old.get(name, 0), new.get(name, 0)
        if a != b:
            parts.append(f"{name} {a} -> {b} ({b - a:+d})")
    total_a, total_b = sum(old.values()), sum(new.values())
    return f"total {total_a} -> {total_b} ({total_b - total_a:+d}); " + ", ".join(parts)


def record(args) -> int:
    measured = json.loads(Path(args.measurements).read_text())
    BASELINES.mkdir(parents=True, exist_ok=True)
    wanted = set(args.key)
    written = 0
    for target, figures in measured["targets"].items():
        current = read_baseline(target, None) or {
            "schema": 1, "target": target, "entries": {}}
        if current.get("environment") != measured["environment"]:
            require(not wanted or not current["entries"],
                    f"{target}: a new environment re-records every key")
            current["entries"] = {}
        current["environment"] = measured["environment"]
        for name, figure in figures.items():
            if wanted and f"{target} {name}" not in wanted:
                continue
            current["entries"][name] = {"sections": figure["sections"]}
            written += 1
        current["entries"] = dict(sorted(current["entries"].items()))
        baseline_path(target).write_text(json.dumps(current, indent=1) + "\n")
    print(f"recorded {written} keys under {BASELINES.relative_to(ROOT)}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("\n\n", 1)[1])
    commands = parser.add_subparsers(dest="command", required=True)
    size = commands.add_parser("size", help="measure section sizes")
    size.add_argument("--refine", type=Path, required=True)
    size.add_argument("--target", action="append", required=True)
    size.add_argument("--output", required=True)
    size.add_argument("--environment", required=True,
                      help="the linking environment's name, kept with the figures")
    size.add_argument("--toolchain", action="append", default=[],
                      metavar="TARGET=DRIVER")
    size.add_argument("--runner", action="append", default=[],
                      metavar="TARGET=COMMAND",
                      help="run TARGET's images through COMMAND to check"
                      " their oracle; the host's own target needs ''")
    size.add_argument("--skip", action="append", default=[])
    size.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    size.set_defaults(run=measure_size)
    against = commands.add_parser("compare", help="hold measurements to baselines")
    against.add_argument("measurements")
    against.add_argument("--base")
    against.set_defaults(run=compare)
    keep = commands.add_parser("record", help="write measurements as baselines")
    keep.add_argument("measurements")
    keep.add_argument("--key", action="append", default=[],
                      metavar="'TARGET KEY'")
    keep.set_defaults(run=record)
    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except Failure as error:
        print(f"measure.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
