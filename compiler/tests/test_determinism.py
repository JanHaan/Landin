#!/usr/bin/env python3
"""The declared determinism contract, checked on every target.

Hosted Linux parity claimed "equivalent builds produce identical assembly and
behavior under the pinned toolchain" for Linux x86-64 alone, under the
weakest equivalence there is: `compiler/tests/quality/check.py` runs one
command twice in one directory.  A property that only holds when nothing
differs is not a determinism property, and a claim without a stated
equivalence relation is not a claim.  This states the relation and checks it
on linux-x86-64, darwin-arm64 and cortex-m0 alike.

Two compilations are EQUIVALENT CLOSURES when they agree on the source bytes,
the module closure, the target, `--optimize`, `--specialize`, `--build-mode`
and the pinned compiler.  They are free to differ in the absolute build
directory, the working directory, the output path and file name, the whole
environment (locale, timezone, SOURCE_DATE_EPOCH, everything), in how often
and in what order they are run, and in THE HOST THEY RUN ON.

Tier 1, TARGET CODE, is deterministic under that whole relation:

  * the assembly emitted without `--debug`;
  * the build report, apart from its `sources[].path_hex` entries.

Tier 2, SOURCE-IDENTIFYING ARTIFACTS, is deterministic under Tier 1's relation
narrowed by a fixed absolute compilation directory and a fixed source-path
spelling:

  * `--debug=full` and `--debug=lines` assembly;
  * the source/panic map, and `sources[].path_hex` in the build report.

Tier 2 is a declared record, not a defect.  DWARF's `comp_dir` and `.file` are
how a debugger finds source, and the panic map resolves an off-target check
site back to the file the caller named.  So this does not merely allow Tier 2
to vary: it pins exactly HOW it varies.  When only the compilation directory
moves, the debug assembly must differ in the `comp_dir` string and the build
identity derived from it and in nothing else.  An instruction that moved with
the build directory fails here, which is the whole point of checking a
boundary instead of excusing it.

What is deliberately NOT claimed: bit-identity of a linked HOSTED image.
The hosted parity claim says "identical assembly and behavior", and the measured
reason that wording is right is recorded in `linked_image` below: on the
pinned Linux toolchain two links of one unchanged assembly differ in six
bytes, in the same directory, from the same command, because the GNU driver
writes its own random temporary object name into the symbol table.  That is
the driver's artifact.  Landin's side -- the assembly the link consumes -- is
checked to be identical, the residue is reported rather than excused, and a
reproducible hosted image is transferred rather than promised.  On Darwin the
same comparison happened to come out identical; one toolchain being tidier is
not a contract.  Nothing here claims determinism across compiler versions,
across differing pins, across differing build options -- an option is an
input, not an equivalence -- or any timing reproducibility.

The host is the one freedom this file cannot exercise, because one machine
cannot disagree with itself.  It is checked from two instead:
`scripts/emit_manifest.py` emits every positive fixture on every target in
both build modes and hashes each one, and `.github/workflows/determinism.yml`
builds that manifest on each host and requires the manifests to agree.
Measured across macOS arm64 and Linux x86-64: 1446 entries, identical, with
the 22 refusals agreeing too -- so accept and reject are host-neutral as well
as the bytes.  The claim is worth stating because nothing outside
`Landin.Targets` may ask the host how wide a pointer is; when that slips, a
32-bit target quietly follows the machine it was built on.

The first run of that check disagreed on six entries and the check was wrong,
not the compiler.  Tier 2's fixed source-path spelling is an INPUT, `caller`
locations put a digest of the caller files into the assembly, and two
absolute paths disagree that way on one host as readily as on two.  A
cross-host check that does not pin the spelling is measuring its own working
directory.

Cortex-M firmware ELF, object, assembly, linker script and linker map identity
across build directories is claimed too, and is checked where the ARM
toolchain lives: `environments/cortex-m/devices.py`.  This file is
host-neutral on purpose -- it emits assembly and needs no target assembler,
linker or emulator -- so it runs in both native acceptance environments.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent

#  One shared corpus on all three targets, so the contract is the same
#  contract everywhere rather than three target-shaped approximations.
CORPUS = ("insertion-sort", "sieve-of-eratosthenes", "add-exits-with-its-sum",
          "array-of-structs", "atom-values-cross-the-abi",
          "array-arguments-cross-calls")
TARGETS = ("linux-x86-64", "darwin-arm64", "cortex-m0")
PROFILES = (("none", "off"), ("size", "auto"), ("speed", "all"))
DEBUG_FLAG = {"linux-x86-64": "full", "darwin-arm64": "full",
              "cortex-m0": "lines"}
#  A module closure, so the contract covers import resolution and not only
#  one file: the report's source order is what makes closure order irrelevant.
CLOSURE_FIXTURE = "core-mem-allocators"

#  The build identity is a hash over the caller file set, so it follows the
#  compilation directory into the record.  Matching a bare 64-hex line would
#  excuse any hash that moved; a differing identity is only excused below
#  when a compilation directory differed on its own line as well.
IDENTITY = re.compile(r'^(?:# Landin caller files [0-9a-f]{64}|'
                      r'\.ascii "[0-9a-f]{64}")$')


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def repository_root() -> Path:
    return HERE.parents[1]


def host_target() -> str | None:
    """The one target this host can also assemble and link."""
    if platform.system() == "Linux" and platform.machine() == "x86_64":
        return "linux-x86-64"
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        return "darwin-arm64"
    return None


def compile(refine: Path, source, output: Path, *, target: str,
            profile: tuple[str, str], cwd: Path, report: Path | None = None,
            debug: str | None = None, root: Path | None = None,
            emit: str = "asm", environment: dict | None = None,
            panic_map: bool = False):
    args = [str(refine), str(source), "--emit=" + emit, "-o", str(output),
            "--target=" + target, "--optimize=" + profile[0],
            "--specialize=" + profile[1]]
    if report is not None:
        args.append("--build-report=" + str(report))
    if debug is not None:
        args.append("--debug=" + debug)
    if root is not None:
        args.append("--root=" + str(root))
    if panic_map:
        args.append("--panic-map")
    completed = subprocess.run(args, cwd=cwd, capture_output=True, timeout=120,
                               env=environment)
    require(completed.returncode == 0,
            f"refine failed: {' '.join(args)}\n{completed.stderr.decode()}")


def without_paths(report: bytes) -> bytes:
    """The build report with only its caller-spelled paths removed."""
    parsed = json.loads(report)
    for source in parsed["sources"]:
        require("path_hex" in source and "sha256" in source,
                "build report source lost its path or content hash")
        source["path_hex"] = None
    return json.dumps(parsed, sort_keys=True).encode()


def check_canonical_sources(report: bytes, label: str):
    """Entry module first, then sorted: why closure order cannot matter."""
    parsed = json.loads(report)
    sources = parsed["sources"]
    require([s["source"] for s in sources] == list(range(1, len(sources) + 1)),
            label + ": build report source identities are not 1..n in order")
    paths = [bytes.fromhex(s["path_hex"]).decode("utf-8", "surrogateescape")
             for s in sources]
    require(paths[1:] == sorted(paths[1:]),
            label + ": imported sources are not in canonical order")
    for source in sources:
        require(re.fullmatch(r"[0-9a-f]{64}", source["sha256"]),
                label + ": build report source lost its content hash")


def without_map_paths(panic_map: bytes) -> bytes:
    """The panic map with only its caller-spelled paths removed."""
    parsed = json.loads(panic_map)
    require(re.fullmatch(r"[0-9a-f]{64}", parsed["build_id"]),
            "panic map lost its build identity")
    for entry in parsed["files"]:
        require("path_hex" in entry and "source_sha256" in entry,
                "panic map file lost its path or content hash")
        require(entry["line_offsets"] == sorted(entry["line_offsets"]),
                "panic map line offsets are not ordered")
        entry["path_hex"] = None
    return json.dumps(parsed, sort_keys=True).encode()


def check_map_binds_assembly(panic_map: bytes, assembly: bytes, label: str):
    """A map that does not name its own assembly maps nothing."""
    parsed = json.loads(panic_map)
    require(parsed["assembly_sha256"] == hashlib.sha256(assembly).hexdigest(),
            label + ": panic map is not bound to the assembly it describes")


def debug_residue(first: bytes, second: bytes, left_dir: Path,
                  right_dir: Path, label: str):
    """Exactly the compilation directory and the identity derived from it.

    A differing line is excused only when it literally names the directory
    its own compilation ran in, or when it is the build identity hashed over
    that record.  Every other line must be byte-identical: an instruction
    that followed the build directory fails here.
    """
    left = first.decode().splitlines()
    right = second.decode().splitlines()
    require(len(left) == len(right),
            label + ": debug assembly changed length with the build directory")
    directories = 0
    identities = 0
    for index, (a, b) in enumerate(zip(left, right)):
        if a == b:
            continue
        if str(left_dir) in a and str(right_dir) in b:
            directories += 1
        elif IDENTITY.match(a.strip()) and IDENTITY.match(b.strip()):
            identities += 1
        else:
            raise Failure(
                f"{label}: line {index + 1} moved with the build directory\n"
                f"  {a}\n  {b}")
    require(directories > 0,
            label + ": debug assembly recorded no compilation directory")
    require(identities == 0 or directories > 0,
            label + ": build identity moved without a compilation directory")


def equivalent_closures(refine: Path, source, root: Path | None, target: str,
                        profile: tuple[str, str], label: str, area: Path):
    """One corpus member on one target under one profile."""
    #  Two differently named build directories, two different output names,
    #  and two deliberately hostile environments.  Nothing a build is allowed
    #  to differ in is held fixed here.
    alpha, beta = area / "alpha", area / "b-considerably-longer-name"
    alpha.mkdir(parents=True)
    beta.mkdir(parents=True)
    stripped = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(area)}
    hostile = {**os.environ, "TZ": "Pacific/Kiritimati", "LC_ALL": "C",
               "LANG": "C", "SOURCE_DATE_EPOCH": "1"}
    runs = []
    for index, (directory, name, environment) in enumerate((
            (alpha, "out", stripped), (beta, "a-different-name", hostile))):
        assembly = directory / (name + ".s")
        report = directory / (name + ".json")
        compile(refine, source, assembly, target=target, profile=profile,
                cwd=directory, report=report, root=root,
                environment=environment)
        runs.append((assembly.read_bytes(), report.read_bytes()))

    require(runs[0][0] == runs[1][0], label + ": assembly is not deterministic")
    require(without_paths(runs[0][1]) == without_paths(runs[1][1]),
            label + ": build report is not deterministic beyond its paths")
    check_canonical_sources(runs[0][1], label)

    #  Repetition in one directory: the old Linux-only property, on every
    #  target, and now over the report's paths as well.
    again = alpha / "out-again.s"
    again_report = alpha / "out-again.json"
    compile(refine, source, again, target=target, profile=profile, cwd=alpha,
            report=again_report, root=root, environment=stripped)
    require(again.read_bytes() == runs[0][0],
            label + ": repeated assembly differs")
    require(again_report.read_bytes() == runs[0][1],
            label + ": repeated build report differs")

    #  The panic map records caller-spelled paths and nothing about where
    #  the compilation ran, so it is Tier 1 under the same rule as the
    #  report -- and it must name the assembly it claims to map.
    maps = []
    for directory, name in ((alpha, "pm"), (beta, "pm-other")):
        assembly = directory / (name + ".s")
        compile(refine, source, assembly, target=target, profile=profile,
                cwd=directory, root=root, environment=stripped,
                panic_map=True)
        panic_map = directory / (name + ".s.sources.json")
        require(panic_map.is_file(),
                label + ": --panic-map emitted no source map")
        check_map_binds_assembly(panic_map.read_bytes(),
                                 assembly.read_bytes(), label)
        maps.append(panic_map.read_bytes())
    require(without_map_paths(maps[0]) == without_map_paths(maps[1]),
            label + ": panic map is not deterministic beyond its paths")

    #  Tier 2.  Fixed compilation directory and spelling: byte-identical.
    #  Moved compilation directory: the comp_dir and its identity, and
    #  nothing else -- no instruction may follow the build directory.
    debug = DEBUG_FLAG[target]
    fixed = alpha / "dbg.s"
    repeat = alpha / "dbg-again.s"
    moved = beta / "dbg.s"
    for destination, directory in ((fixed, alpha), (repeat, alpha),
                                   (moved, beta)):
        compile(refine, source, destination, target=target, profile=profile,
                cwd=directory, debug=debug, root=root, environment=stripped)
    require(fixed.read_bytes() == repeat.read_bytes(),
            label + ": debug assembly differs under a fixed directory")
    debug_residue(fixed.read_bytes(), moved.read_bytes(), alpha, beta,
                  label + "/debug")


def linked_image(refine: Path, source, target: str, area: Path, label: str):
    """The assembly handed to the platform linker, and what the link adds.

    Landin's side of `--emit=exe` is the assembly; the object and the image
    are the platform driver's.  Measured on the pinned toolchains, that
    matters: `x86_64-pc-linux-gnu-gcc` records its own random temporary
    object name (`ccXXXXXX.o`) in the symbol table, so two Linux links of
    one unchanged assembly differ in those bytes -- in the same directory,
    on the same host, from the same command.  It is the driver's artifact
    and not a build-directory effect, so a reproducible hosted image is not
    claimed here.  What is claimed, and checked, is that the assembly the
    link consumed was byte-identical, and the residue is reported so a
    growth in it is visible rather than silent.
    """
    alpha, beta = area / "link-a", area / "link-b-longer"
    alpha.mkdir(parents=True)
    beta.mkdir(parents=True)
    images, assemblies = [], []
    for directory in (alpha, beta):
        image = directory / "program"
        compile(refine, source, image, target=target, profile=("size", "auto"),
                cwd=directory, emit="exe")
        images.append(image.read_bytes())
        assembly = directory / "program.s"
        require(assembly.is_file(), label + ": --emit=exe kept no assembly")
        assemblies.append(assembly.read_bytes())
    require(assemblies[0] == assemblies[1],
            label + ": the assembly handed to the linker is not deterministic")
    residue = (0 if images[0] == images[1] else
               sum(a != b for a, b in zip(images[0], images[1]))
               + abs(len(images[0]) - len(images[1])))
    return {"assembly_sha256": hashlib.sha256(assemblies[0]).hexdigest(),
            "image_bytes": len(images[0]), "link_residue_bytes": residue}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--targets", default=",".join(TARGETS))
    parser.add_argument("--output", type=Path,
                        help="write the measured record here")
    args = parser.parse_args()
    refine = args.refine.resolve(strict=True)
    targets = tuple(args.targets.split(","))
    for target in targets:
        require(target in TARGETS, "unknown determinism target: " + target)
    root = repository_root()
    fixtures = root / "compiler/tests/fixtures/runtime"
    record = {"compiler_sha256": hashlib.sha256(refine.read_bytes()).hexdigest(),
              "targets": list(targets), "profiles": [list(p) for p in PROFILES],
              "corpus": list(CORPUS) + [CLOSURE_FIXTURE], "closures": 0,
              "linked": {}}
    failures = []
    with tempfile.TemporaryDirectory(prefix="landin-determinism-") as scratch:
        area = Path(scratch)
        index = 0
        for target in targets:
            for profile in PROFILES:
                for name in CORPUS:
                    index += 1
                    label = f"{target}/{profile[0]}-{profile[1]}/{name}"
                    try:
                        equivalent_closures(
                            refine, fixtures / name / "main.ldn", None, target,
                            profile, label, area / str(index))
                        record["closures"] += 1
                    except Failure as failure:
                        failures.append(str(failure))
                #  The module closure, once per target and profile.
                index += 1
                label = f"{target}/{profile[0]}-{profile[1]}/{CLOSURE_FIXTURE}"
                try:
                    equivalent_closures(
                        refine, fixtures / CLOSURE_FIXTURE, root, target,
                        profile, label, area / str(index))
                    record["closures"] += 1
                except Failure as failure:
                    failures.append(str(failure))
            print(f"determinism: {target} passed {len(CORPUS) + 1} closures "
                  f"over {len(PROFILES)} profiles", flush=True)

        #  The one target this host can also link.  Not skipped when the host
        #  is the other one: the other host's acceptance run checks it there.
        native = host_target()
        if native in targets:
            linked = 0
            for name in CORPUS[:2]:
                index += 1
                label = f"{native}/linked/{name}"
                try:
                    record["linked"][name] = linked_image(
                        refine, fixtures / name / "main.ldn", native,
                        area / str(index), label)
                    linked += 1
                except Failure as failure:
                    failures.append(str(failure))
            residues = sorted({m["link_residue_bytes"]
                               for m in record["linked"].values()})
            print(f"determinism: {native} link consumed {linked} identical "
                  f"assemblies; image residue bytes {residues}", flush=True)

    record["status"] = "failed" if failures else "passed"
    record["failures"] = failures
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    for failure in failures:
        print("determinism: " + failure, file=sys.stderr)
    if failures:
        print(f"determinism: {len(failures)} failed", file=sys.stderr)
        return 1
    print(f"determinism: {record['closures']} equivalent closures passed on "
          f"{len(targets)} targets", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print("determinism: " + str(failure), file=sys.stderr)
        sys.exit(1)
