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
        every target/level pair the compiler gives and how it is measured,
        checked against compiler/tests/measure/runners.json
    measure.py time --refine R --base-refine B --target T --output DIR
        paired wall time of every configuration the runner table times on
        this host: the candidate's and the base's images interleaved

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
import time

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


def elf_sections(data: bytes, digest=None) -> dict[str, int]:
    """Each allocated section's size in an ELF image, by name; with
    DIGEST, a hashlib object, each one's name, size and content fed to it,
    so two images that differ only in what the linker records of their own
    file name have the same digest."""
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
    for name, kind, flags, offset, size in headers:
        if not flags & SHF_ALLOC or size == 0:
            continue
        label = table[name:table.index(b"\0", name)].decode()
        sections[label] = sections.get(label, 0) + size
        if digest is not None:
            digest.update(f"{label} {size}\n".encode())
            if kind != 8:  # SHT_NOBITS has no content
                digest.update(data[offset:offset + size])
    return sections


def macho_sections(data: bytes, digest=None) -> dict[str, int]:
    """Each section's size in a 64-bit Mach-O image, as SEGMENT,section;
    with DIGEST, each one's name, size and content fed to it, so the
    signature and UUID in __LINKEDIT and the load commands do not move it."""
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
                offset, = struct.unpack_from("<I", data, base + 48)
                flags, = struct.unpack_from("<I", data, base + 64)
                if bytes_:
                    label = segment + "," + section
                    sections[label] = bytes_
                    if digest is not None:
                        digest.update(f"{label} {bytes_}\n".encode())
                        if flags & 0xFF not in (0x1, 0xC, 0x12):  # zero fill
                            digest.update(data[offset:offset + bytes_])
        at += size
    return sections


def image_sections(path: Path) -> tuple[dict[str, int], str]:
    """The allocated sections' sizes, and a digest of their contents."""
    data = path.read_bytes()
    if data[:4] == b"\x7fELF":
        digest = hashlib.sha256()
        return elf_sections(data, digest), digest.hexdigest()
    digest = hashlib.sha256()
    return macho_sections(data, digest), digest.hexdigest()


# --- configurations and workloads -------------------------------------------

def targets(refine: Path) -> dict[str, dict[str, list[str]]]:
    """{target: {level: [feature, ...]}} as the compiler gives them, in its
    order, for the targets that emit."""
    listed = json.loads(subprocess.run(
        [str(refine), "targets", "--json"], check=True, capture_output=True,
        text=True).stdout)
    require(listed.get("schema") == 1, "unknown `refine targets --json` schema")
    found = {}
    for one in listed["targets"]:
        if not (one["emission"] and one["levels"]):
            continue
        require("features" in one, "this refine's `targets --json` gives no"
                " level features; build it from this checkout")
        found[one["name"]] = {level.strip(): one["features"][level.strip()]
                              for level in one["levels"].split(",")}
    return found


#  The word the kernel uses where it differs from the level feature's
#  spelling: /proc/cpuinfo's `flags` on x86-64 and `Features` on arm64, as
#  the test program's Host_Has_Level reads them.
KERNEL_FLAG = {"cmpxchg16b": "cx16", "lahf": "lahf_lm", "sse3": "pni",
               "lzcnt": "abm", "lse": "atomics", "rdm": "asimdrdm"}
DARWIN_FEATURE = {"lse": "FEAT_LSE", "crc32": "FEAT_CRC32", "rdm": "FEAT_RDM"}


def host_lacks(features: list[str]) -> list[str]:
    """The FEATURES this host's processor does not report."""
    if sys.platform == "darwin":
        lacking = []
        for feature in features:
            answer = subprocess.run(
                ["sysctl", "-n", "hw.optional.arm." + DARWIN_FEATURE[feature]],
                capture_output=True, text=True).stdout.strip()
            if answer != "1":
                lacking.append(feature)
        return lacking
    flags = set()
    for line in Path("/proc/cpuinfo").read_text().splitlines():
        name, _, value = line.partition(":")
        if name.strip() in ("flags", "Features"):
            flags.update(value.split())
    return [f for f in features if KERNEL_FLAG.get(f, f) not in flags]


def linker_identity(driver: str) -> str:
    """The first line the linker DRIVER uses says of its version."""
    for flags in (["-Wl,--version"], ["-Wl,-v"]):
        done = subprocess.run([driver, *flags], capture_output=True, text=True)
        for line in (done.stdout + done.stderr).splitlines():
            if "ld" in line.lower() and any(c.isdigit() for c in line):
                return line.strip()
    return "unknown linker " + driver


def workloads() -> dict:
    data = json.loads((MEASURE / "workloads.json").read_text())
    require(data.get("schema") == 1, "unknown workloads.json schema")
    return data


def key(level: str, profile: tuple[str, str], workload: str) -> str:
    return f"{level}/{profile[0]}-{profile[1]}/{workload}"


#  The driver refine links each target with when no --toolchain names
#  one, whose linker the size baseline records.
DEFAULT_DRIVER = {"linux-x86-64": "gcc", "linux-arm64": "aarch64-linux-gnu-gcc",
                  "linux-rv64": "riscv64-linux-gnu-gcc", "darwin-arm64": "cc",
                  "cortex-m0": "arm-eabi-gcc", "rv32": "riscv64-elf-gcc",
                  "xtensa": "xtensa-esp32-elf-gcc"}
FIRMWARE = ("cortex-m0", "rv32", "xtensa")
ENTRY = MEASURE / "entry.ldn"


def entry(target: str, level: str) -> list[str]:
    """The firmware entry file a workload is linked with at LEVEL, and the
    root it needs: the target's reference profile, but Xtensa's chips'
    own descriptions, since the Xtensa reference gives initialized data no
    load address at boot, a defect the register records."""
    if target == "xtensa":
        chip = level.removeprefix("xtensa-")
        return ["--root=" + str(ROOT / "devices"),
                str(MEASURE / f"entry-{chip}.ldn")]
    return [str(ENTRY)]


def sources(arguments: list[str]) -> list[str]:
    """ARGUMENTS with a module directory named by its own `.ldn` files, as
    a rooted request must when the entry file is added to it (L0002)."""
    named = []
    for one in arguments:
        path = Path(one)
        if not one.startswith("-") and path.is_dir():
            named += sorted(str(p) for p in path.glob("*.ldn"))
        else:
            named.append(one)
    return named


def build(refine, target, level, profile, workload, out, toolchain):
    fixture = ROOT / "compiler/tests/fixtures" / workload["fixture"]
    meta = fixture_meta.read(fixture)
    name = f"{target}-{level}-{profile[0]}-{profile[1]}-{workload['name']}"
    #  Each configuration publishes into a directory of its own: the callers
    #  build concurrently, and refine refuses an output whose directory
    #  another compile's publication holds locked for two seconds (D1049).
    (out / name).mkdir(parents=True, exist_ok=True)
    image = out / name / name
    firmware = (["--firmware-entry=start"] if target in FIRMWARE else [])
    command = [str(refine), "compile", f"--target={target}", f"--level={level}",
               f"--optimize={profile[0]}", f"--specialize={profile[1]}",
               *firmware, *(["--toolchain=" + toolchain] if toolchain else []),
               *meta.library_arguments(fixture),
               *(sources(meta.source_arguments(fixture)) + entry(target, level)
                 if firmware else meta.source_arguments(fixture)),
               "-o", str(image),
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
    result = {"schema": 1, "environments": {}, "targets": {}}
    work = []
    for target in args.target:
        require(target in given, f"refine gives no emitting target {target}")
        kind = "firmware" if target in FIRMWARE else "hosted"
        driver = toolchains.get(target, DEFAULT_DRIVER.get(target))
        require(driver is not None, f"{target}: --toolchain names its driver")
        result["environments"][target] = (
            f"{args.environment}; {linker_identity(driver)}")
        for level, features in given[target].items():
            runs = target in runners or (
                target == args.host and not host_lacks(features))
            for profile in PROFILES:
                for workload in sets[kind]:
                    if workload["name"] not in args.skip:
                        work.append((target, level, profile, workload, runs))

    def one(item):
        target, level, profile, workload, runs = item
        image, meta, fixture = build(
            args.refine, target, level, profile, workload, images,
            toolchains.get(target))
        if runs and target not in FIRMWARE:
            oracle(image, meta, fixture, runners.get(target, "").split())
        sections, digest = image_sections(image)
        figure = {"sections": sections, "image_digest": digest}
        report = json.loads(Path(f"{image}.json").read_text())
        if "firmware" in report:
            figure["flash_used"] = report["firmware"]["flash_used"]
        return target, key(level, profile, workload["name"]), figure

    failures = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for future in concurrent.futures.as_completed(
                [pool.submit(one, item) for item in work]):
            try:
                target, name, figure = future.result()
            except (Failure, subprocess.TimeoutExpired) as error:
                failures.append(str(error))
                continue
            result["targets"].setdefault(target, {})[name] = figure
    for target in result["targets"]:
        result["targets"][target] = dict(sorted(result["targets"][target].items()))
    (out / "size.json").write_text(json.dumps(result, indent=1) + "\n")
    distinct = len({f["image_digest"] for t in result["targets"].values()
                    for f in t.values()})
    print(f"measured {sum(map(len, result['targets'].values()))} of {len(work)}"
          f" configurations, {distinct} distinct images; {out / 'size.json'}")
    for failure in failures:
        print("FAILED " + failure, file=sys.stderr)
    return 1 if failures else 0


# --- the runner table -------------------------------------------------------

def runner_rows(given) -> dict[tuple[str, str], dict]:
    """{(target, level): row} from runners.json, every level the compiler
    GIVES with a row and no row naming a level it does not give."""
    table = json.loads((MEASURE / "runners.json").read_text())
    require(table.get("schema") == 1, "unknown runners.json schema")
    rows, problems = {}, []
    for target, levels in given.items():
        entry = table["targets"].get(target)
        if entry is None:
            problems.append(f"{target} has no row")
            continue
        for named in entry.get("levels", {}):
            if named not in levels:
                problems.append(f"{target} names {named}, which refine does not give")
        for level in levels:
            row = {k: v for k, v in entry.items() if k != "levels"}
            row.update(entry.get("levels", {}).get(level, {}))
            if not row.get("classes"):
                problems.append(f"{target} {level} has no class")
            rows[(target, level)] = row
    for target in table["targets"]:
        if target not in given:
            problems.append(f"the table names {target}, which refine does not emit")
    require(not problems, "compiler/tests/measure/runners.json disagrees with"
            " refine targets --json: " + "; ".join(problems))
    return rows


def runners(args) -> int:
    rows = runner_rows(targets(args.refine))
    for (target, level), row in rows.items():
        print(f"{target:15} {level:22} {', '.join(row['classes']):22}"
              f" {row.get('runner') or '-'}")
    return 0


# --- wall time --------------------------------------------------------------

def runner_class() -> dict:
    """What a wall figure was measured on: the job's runner label, the
    processor's model and the runner image, as GitHub names them."""
    if sys.platform == "darwin":
        model = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                               capture_output=True, text=True).stdout.strip()
    else:
        lines = Path("/proc/cpuinfo").read_text().splitlines()
        model = next((line.split(":", 1)[1].strip() for line in lines
                      if line.startswith("model name")), None)
        if model is None:
            #  An arm64 kernel names no model; its implementer and part do.
            fields = {line.split(":", 1)[0].strip(): line.split(":", 1)[1].strip()
                      for line in lines if ":" in line}
            model = ("implementer %s part %s" % (fields.get("CPU implementer", "?"),
                                                 fields.get("CPU part", "?")))
    return {"label": os.environ.get("LANDIN_RUNNER_LABEL", "local"),
            "processor": model,
            "image": " ".join(filter(None, (os.environ.get("ImageOS"),
                                            os.environ.get("ImageVersion"))))
            or "local"}


def timing_input(workload: dict, where: Path) -> Path | None:
    """The standard input a timing run reads, made once."""
    repeat = workload["timing"].get("stdin_repeat")
    if not repeat:
        return None
    fixture = ROOT / "compiler/tests/fixtures" / workload["fixture"]
    meta = fixture_meta.read(fixture)
    made = where / f"{workload['name']}.stdin"
    if not made.exists():
        made.write_bytes((fixture / meta["stdin"]).read_bytes() * repeat)
    return made


def timed_run(image: Path, workload: dict, stdin: Path | None, scratch: Path):
    """One timing run of a fresh copy of IMAGE: (seconds, output digest)."""
    fixture = ROOT / "compiler/tests/fixtures" / workload["fixture"]
    fresh = Path(tempfile.mkdtemp(dir=scratch)) / image.name
    shutil.copy2(image, fresh)
    meta = fixture_meta.read(fixture)
    arguments = workload["timing"].get("args")
    if arguments is None:
        arguments = meta.program_arguments(fixture)
    with (open(stdin, "rb") if stdin else open(os.devnull, "rb")) as given:
        start = time.perf_counter()
        done = subprocess.run([str(fresh), *arguments], stdin=given,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              cwd=ROOT / "compiler/ada", timeout=600,
                              env={**os.environ, "LC_ALL": "C"})
        seconds = time.perf_counter() - start
    shutil.rmtree(fresh.parent)
    require(done.returncode == meta.status,
            f"{image.name} returned {done.returncode} in its timing run,"
            f" expected {meta.status}: {done.stderr[-500:]!r}")
    return seconds, hashlib.sha256(done.stdout).hexdigest()


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return (ordered[middle] if len(ordered) % 2
            else (ordered[middle - 1] + ordered[middle]) / 2)


def measure_time(args) -> int:
    """Paired wall time: each configuration's image from the candidate's
    compiler and from the base's, built here and run interleaved, fresh
    copies each run, on one processor."""
    given = targets(args.refine)
    rows = runner_rows(given)
    target = args.target
    require(target in given and target in HOSTED, f"{target}: not a hosted target")
    sets = workloads()
    out = Path(args.output)
    for side in ("candidate", "base"):
        (out / side).mkdir(parents=True, exist_ok=True)
    scratch = out / "runs"
    scratch.mkdir(exist_ok=True)
    work = []
    for level, features in given[target].items():
        if "wall" not in rows[(target, level)]["classes"]:
            continue
        lacking = host_lacks(features)
        require(not lacking, f"{target} {level}'s runner row says wall, and this"
                f" processor lacks {', '.join(lacking)}")
        for profile in PROFILES:
            for workload in sets["hosted"]:
                if workload["name"] not in args.skip:
                    work.append((level, profile, workload))

    def built(item):
        level, profile, workload = item
        pair = []
        for side, refine in (("candidate", args.refine), ("base", args.base_refine)):
            image, _, _ = build(refine, target, level, profile, workload,
                                out / side, None)
            pair.append((image, image_sections(image)[1]))
        return item, pair

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        images = list(pool.map(built, work))
    #  One timing per distinct pair of images; the others cite it.
    distinct: dict[tuple[str, str, str], list] = {}
    for (level, profile, workload), pair in images:
        identity = (workload["name"], pair[0][1], pair[1][1])
        distinct.setdefault(identity, []).append(((level, profile, workload), pair))
    print(f"{len(work)} configurations, {len(distinct)} distinct image pairs,"
          f" {args.samples} interleaved runs of each side", flush=True)
    figures, outputs = {}, {}
    tolerance = wall_tolerance()

    def timed(pair, workload, stdin, count):
        samples = {"candidate": [], "base": []}
        for index in range(count):
            #  A candidate already past twice the tolerance after one
            #  interleaved sample of each is judged on it: a gross slowdown
            #  is a verdict at once, not a job that runs out its time.
            if (index == 1 and tolerance is not None
                    and samples["candidate"][0]
                    > samples["base"][0] * (1 + 2 * tolerance)):
                break
            order = (("candidate", 0), ("base", 1)) if index % 2 == 0 else (
                ("base", 1), ("candidate", 0))
            for side, at in order:
                seconds, digest = timed_run(pair[at][0], workload, stdin, scratch)
                samples[side].append(seconds)
                first = outputs.setdefault(workload["name"], digest)
                require(digest == first, f"{pair[at][0].name}'s timing output"
                        " differs from the other configurations'")
        candidate, base = median(samples["candidate"]), median(samples["base"])
        return {"candidate": round(candidate, 6), "base": round(base, 6),
                "ratio": round(candidate / base, 4), "samples": len(samples["base"]),
                "spread": round((max(samples["candidate"]) - min(samples["candidate"]))
                                / candidate, 4)}

    for identity, members in distinct.items():
        (level, profile, workload), pair = members[0]
        stdin = timing_input(workload, out)
        figure = timed(pair, workload, stdin, args.samples)
        #  A pair past the tolerance is timed again, three times as often,
        #  and judged on that: a slowdown survives it, one noisy draw of a
        #  hosted runner does not (the second A/A run's 1.085).
        if (tolerance is not None and 1 + tolerance < figure["ratio"]
                and figure["samples"] == args.samples):
            first = figure
            figure = timed(pair, workload, stdin, 3 * args.samples)
            figure["first"] = {k: first[k] for k in ("ratio", "samples")}
        candidate, base = figure["candidate"], figure["base"]
        first_key = key(level, profile, workload["name"])
        figures[first_key] = figure
        print(f"  {first_key}: {candidate:.4f} s against {base:.4f} s,"
              f" ratio {figure['ratio']}, spread {figure['spread']:.2%}"
              + (f", {len(members) - 1} more the same" if len(members) > 1 else ""),
              flush=True)
        for (other_level, other_profile, _), _ in members[1:]:
            figures[key(other_level, other_profile, workload["name"])] = {
                "same_as": first_key}
    result = {"schema": 1, "class": "wall", "runner": runner_class(),
              "outputs": outputs, "targets": {target: dict(sorted(figures.items()))}}
    (out / "time.json").write_text(json.dumps(result, indent=1) + "\n")
    print(f"wrote {out / 'time.json'}")
    return judge_time(result)


def wall_tolerance() -> float | None:
    """This runner's wall tolerance from the noise study, or None."""
    noise = MEASURE / "noise" / "wall.json"
    if not noise.exists():
        return None
    return json.loads(noise.read_text())["tolerance"].get(runner_class()["label"])


def judge_time(result: dict) -> int:
    """Hold each ratio to the class's tolerance from its noise study, or
    report alone while the class has none."""
    noise = MEASURE / "noise" / "wall.json"
    tolerance = None
    if noise.exists():
        tolerance = json.loads(noise.read_text())["tolerance"].get(
            result["runner"]["label"])
    slower = []
    for target, figures in result["targets"].items():
        for name, figure in figures.items():
            if "ratio" in figure and tolerance is not None and (
                    figure["ratio"] > 1 + tolerance):
                slower.append(f"{target} {name}: {figure['candidate']:.4f} s against"
                              f" the base's {figure['base']:.4f} s,"
                              f" ratio {figure['ratio']}")
    ratios = [f["ratio"] for t in result["targets"].values()
              for f in t.values() if "ratio" in f]
    print(f"wall: {len(ratios)} timed pairs, ratio median {median(ratios):.4f},"
          f" range {min(ratios):.4f} to {max(ratios):.4f}; tolerance "
          + (f"{tolerance:.2%}" if tolerance is not None else
             "not yet set by a noise study, so nothing fails"))
    for line in slower:
        print("SLOWER " + line)
    return 1 if slower else 0



# --- instruction counts -----------------------------------------------------

def counted_rv64(args, given, sets) -> dict:
    import measure_count
    out = Path(args.output) / "rv64"
    out.mkdir(parents=True, exist_ok=True)
    work = [(level, profile, workload) for level in given["linux-rv64"]
            for profile in PROFILES for workload in sets["hosted"]]

    def one(item):
        level, profile, workload = item
        image, meta, fixture = build(args.refine, "linux-rv64", level, profile,
                                     workload, out, None)
        stdin = (fixture / meta["stdin"]) if "stdin" in meta else None
        place = out / "runs" / image.name
        place.mkdir(parents=True, exist_ok=True)
        result = measure_count.count("linux-rv64", level, image,
                                     meta.program_arguments(fixture), stdin, work=place)
        require(result["status"] == meta.status, f"{image.name} returned"
                f" {result['status']} under the counter, expected {meta.status}")
        return key(level, profile, workload["name"]), result["instructions"]

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        return dict(sorted(pool.map(one, work)))


def counted_cortex(args, sets) -> dict:
    sys.path.insert(0, str(ROOT / "environments/cortex-m"))
    from backend import LEVELS  # noqa: E402
    import backend_corpus  # noqa: E402
    levels = [level for level, row in LEVELS.items() if row.get("arch") != "rv32"]
    workloads = sets["firmware"]
    programs = [ROOT / "compiler/tests/fixtures" / one["fixture"] / "main.ldn"
                for one in workloads]
    names = dict(zip(backend_corpus.program_names(programs),
                     (one["name"] for one in workloads)))
    results = backend_corpus.observe(Path(args.output) / "cortex", args.tools,
                                     args.refine, programs, list(PROFILES), levels)
    found = {}
    for result in results:
        require(result.get("instructions") is not None,
                f"no count for {result['name']} at {result['level']}")
        name = names.get(result["name"], result["name"])
        found[key(result["level"], (result["optimize"], result["specialize"]), name)] = (
            result["instructions"])
    return dict(sorted(found.items()))


def measure_instructions(args) -> int:
    """Every configuration the runner table counts on TARGET, at its
    fixture's own arguments: the count is exact, so no large input is
    needed, and it is compared with the base's baselines exactly."""
    sets = workloads()
    given = targets(args.refine)
    if args.target == "linux-rv64":
        figures = counted_rv64(args, given, sets)
    else:
        require(args.target == "cortex-m0", "only linux-rv64 and cortex-m0 are"
                " counted under emulation (docs/measurement.md, Runners)")
        require(args.tools is not None, "--tools names the Cortex-M lanes' tool root")
        import measure_count
        measure_count.nixos_route()  # the lanes' Debian tools, as they run them
        figures = counted_cortex(args, sets)
    result = {"schema": 1, "class": "instructions",
              "targets": {args.target: {name: {"instructions": value}
                                        for name, value in figures.items()}}}
    path = Path(args.output) / "instructions.json"
    path.write_text(json.dumps(result, indent=1) + "\n")
    print(f"counted {len(figures)} configurations; {path}")
    return 0



# --- baselines --------------------------------------------------------------

def baseline_path(target: str, kind: str = "size") -> Path:
    return BASELINES / f"{target}.{kind}.json"


def read_baseline(target: str, rev: str | None, kind: str = "size") -> dict:
    path = baseline_path(target, kind)
    if rev is None:
        return json.loads(path.read_text()) if path.exists() else {}
    shown = subprocess.run(
        ["git", "show", f"{rev}:{path.relative_to(ROOT).as_posix()}"],
        cwd=ROOT, capture_output=True, text=True)
    return json.loads(shown.stdout) if shown.returncode == 0 else {}


def default_base() -> str:
    base = merge_base()
    present = subprocess.run(["git", "cat-file", "-e", base + "^{commit}"],
                             cwd=ROOT, capture_output=True)
    require(present.returncode == 0, f"the base commit {base} is not in this"
            " checkout, whose history is too shallow to compare with it;"
            " check out with fetch-depth: 0, or name --base")
    return base


def merge_base() -> str:
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, check=True,
                          capture_output=True, text=True).stdout.strip()
    main = subprocess.run(["git", "rev-parse", "--verify", "-q", "origin/main"],
                          cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if not main or main == head:
        return "HEAD^"
    return subprocess.run(["git", "merge-base", "HEAD", "origin/main"], cwd=ROOT,
                          check=True, capture_output=True, text=True).stdout.strip()


def field(kind: str) -> str:
    """The figure a baseline entry of KIND holds."""
    return "sections" if kind == "size" else "instructions"


def total(value) -> int:
    return sum(value.values()) if isinstance(value, dict) else value


def compare(args) -> int:
    measured = json.loads(Path(args.measurements).read_text())
    kind = measured.get("class", "size")
    named = field(kind)
    base = args.base or default_base()
    undeclared, declared, missing, moved = {}, {}, [], []
    for target, figures in measured["targets"].items():
        environment = measured.get("environments", {}).get(target)
        before = read_baseline(target, base, kind)
        after = read_baseline(target, None, kind)
        old = before.get("entries", {})
        new = after.get("entries", {})
        if before and before.get("environment") != environment:
            moved.append(f"{target}: baseline linked by {before.get('environment')},"
                         f" measured with {environment}")
        for name, figure in figures.items():
            group = f"{target} {name.rsplit('/', 1)[0]}"
            if name not in old:
                if new.get(name, {}).get(named) == figure[named]:
                    declared.setdefault(group, []).append((name, None, figure))
                else:
                    missing.append(f"{target} {name}")
                continue
            if old[name][named] == figure[named]:
                continue
            bucket = (declared if new.get(name, {}).get(named)
                      == figure[named] else undeclared)
            bucket.setdefault(group, []).append((name, old[name], figure))
    for title, groups in (("declared by the candidate's baselines", declared),
                          ("UNDECLARED", undeclared)):
        if groups:
            print(f"{title}: {sum(map(len, groups.values()))} keys")
            for group, rows in sorted(groups.items()):
                a = sum(total(o[named]) for _, o, _ in rows if o)
                b = sum(total(f[named]) for _, o, f in rows if o)
                print(f"  {group}: {len(rows)} workloads, total {a} -> {b} ({b - a:+d})")
                if args.verbose:
                    for name, o, f in rows:
                        print("    " + name.rsplit("/", 1)[1] + ": "
                              + ("new" if not o else describe(o[named], f[named])
                                 if kind == "size" else
                                 f"{o[named]} -> {f[named]} ({f[named] - o[named]:+d})"))
    if moved:
        print("the linker moved since the base's baselines (a differing figure"
              " needs recording, as a compiler change does):")
        for line in moved:
            print("  " + line)
    if missing:
        print(f"UNRECORDED: {len(missing)} keys have no baseline, such as {missing[0]}")
    count = sum(map(len, measured["targets"].values()))
    bad = sum(map(len, undeclared.values()))
    print(f"compared {count} configurations' {kind} with {base}:"
          f" {bad} undeclared, {len(missing)} unrecorded")
    if bad or missing:
        print("a deliberate change is declared by recording it: scripts/measure.py"
              " record DIR/FILE.json, or record --from-run RUN for a gate run's"
              " figures, and the commit message says why", file=sys.stderr)
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


def from_run(run: str) -> list[Path]:
    """The size.json files a gate run's measure artifacts hold."""
    where = Path(tempfile.mkdtemp(prefix="measure-run-"))
    subprocess.run(["gh", "run", "download", run, "--pattern", "measure-*",
                    "--dir", str(where)], check=True, cwd=ROOT)
    found = sorted(list(where.rglob("size.json")) + list(where.rglob("instructions.json")))
    require(found, f"run {run} has no measure-* artifact with figures")
    return found


def record(args) -> int:
    sources = ([Path(args.measurements)] if args.measurements else []) + (
        from_run(args.from_run) if args.from_run else [])
    require(sources, "name a size.json or --from-run RUN")
    BASELINES.mkdir(parents=True, exist_ok=True)
    wanted = set(args.key)
    written = 0
    for source in sources:
        measured = json.loads(source.read_text())
        kind = measured.get("class", "size")
        if kind not in ("size", "instructions"):
            continue  # a wall figure is a trend, compared in pairs, not recorded
        named = field(kind)
        for target, figures in measured["targets"].items():
            if args.target and target not in args.target:
                continue
            current = read_baseline(target, None, kind) or {
                "schema": 1, "target": target, "entries": {}}
            if not wanted or any(f"{target} {name}" in wanted for name in figures):
                current["environment"] = measured.get("environments", {}).get(target)
            if not wanted:
                #  A whole record is the target's whole baseline: a key no
                #  workload measures any more goes with it.
                current["entries"] = {}
            for name, figure in figures.items():
                if wanted and f"{target} {name}" not in wanted:
                    continue
                current["entries"][name] = {named: figure[named]}
                written += 1
            current["entries"] = dict(sorted(current["entries"].items()))
            baseline_path(target, kind).write_text(json.dumps(current, indent=1) + "\n")
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
    size.add_argument("--host", default=None,
                      help="the target this host runs natively, whose images"
                      " are run against their oracle at every level the"
                      " processor has")
    size.add_argument("--skip", action="append", default=[])
    size.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    size.set_defaults(run=measure_size)
    against = commands.add_parser("compare", help="hold measurements to baselines")
    against.add_argument("measurements")
    against.add_argument("--base")
    against.add_argument("--verbose", action="store_true",
                         help="each key's sections, not only its group's total")
    against.set_defaults(run=compare)
    keep = commands.add_parser("record", help="write measurements as baselines")
    keep.add_argument("measurements", nargs="?")
    keep.add_argument("--from-run", metavar="RUN",
                      help="take the figures from a gate run's artifacts")
    keep.add_argument("--target", action="append", default=[],
                      help="record only this target's figures; repeat for more")
    keep.add_argument("--key", action="append", default=[],
                      metavar="'TARGET KEY'")
    keep.set_defaults(run=record)
    count = commands.add_parser("instructions", help="count every configuration"
                                " under its lane's emulator")
    count.add_argument("--refine", type=Path, required=True)
    count.add_argument("--target", required=True, help="linux-rv64 or cortex-m0")
    count.add_argument("--output", required=True)
    count.add_argument("--tools", type=Path,
                       help="cortex-m0: the lanes' tool root (environments/cortex-m/setup.py)")
    count.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    count.set_defaults(run=measure_instructions)
    import measure_count
    measure_count.add_commands(commands)
    base = commands.add_parser("base", help="print the commit a candidate is"
                               " compared with")
    base.set_defaults(run=lambda args: print(default_base()) or 0)
    table = commands.add_parser("runners", help="the runner table, checked")
    table.add_argument("--refine", type=Path, required=True)
    table.set_defaults(run=runners)
    wall = commands.add_parser("time", help="paired wall time on this runner")
    wall.add_argument("--refine", type=Path, required=True)
    wall.add_argument("--base-refine", type=Path, required=True,
                      help="the base commit's compiler")
    wall.add_argument("--target", required=True, help="this host's target")
    wall.add_argument("--output", required=True)
    wall.add_argument("--samples", type=int, default=5)
    wall.add_argument("--skip", action="append", default=[])
    wall.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    wall.set_defaults(run=measure_time)
    import measure_count
    args = measure_count.parse(parser, argv)
    if getattr(args, "refine", None):
        import refine_revision
        refine_revision.warn(args.refine)  # is it this checkout's?
    try:
        return args.run(args)
    except Failure as error:
        print(f"measure.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
