#!/usr/bin/env python3
"""Emit fixtures for every target but the host's and assemble what is emitted.

Whether a backend change's emission still assembles for another target had
no local command.  The gate's lanes for that target were the only callers:
the Darwin ones need a Mac, the FreeBSD ones a sysroot and a guest, and
the route found was a hand loop of `refine compile --emit=asm` and an
assembler invocation read out of a lane's source.  This is that loop, with
the development shell's own assemblers, and needs no VM, Mac, sysroot or
emulator: an assembler reads the text and writes an object, and nothing is
linked or run.

    python3 scripts/assemble_targets.py REFINE ROOT [TARGETS] [options]

REFINE is the compiler, ROOT the checkout whose fixtures are compiled, and
TARGETS a comma-separated list, by default every target but the host's.
Run it inside `nix develop`, which carries each assembler; one that is
missing is named before anything is compiled.

    --corpus=positive|runtime|cortex-m   the corpora compiled, repeatable;
                                         positive alone by default
    --fixture=KIND/NAME                  only these, repeatable
    --profile=OPTIMIZE-SPECIALIZE        the profile, `size-auto` by default
    --jobs=N                             compilations at once; every core
                                         by default
    --keep=DIR                           keep each failing assembly and the
                                         assembler's words under DIR

The fixtures, their operands, levels and targets are the ones
`scripts/emit_manifest.py` compiles, and a refusal it expects is expected
here; any other refusal is a fault, as is every assembly its assembler
refuses.  The exit status is 0 when everything emitted assembled.

A positive fixture is only ever compiled by the gate, so its emission for
a target can be text no assembler takes without any lane noticing.
KNOWN_REJECTIONS records the ones found when this was written, each with
why; they are counted apart, and one that assembles after all is a fault,
so the record cannot outlive its reason.

What this is evidence of, and what it is not.  Each target's assembler is
the one ASSEMBLERS names, with the machine arguments `refine` gives that
target's driver at its default level (`Landin.Backend.Toolchain`; a
control holds the two together).  The cross GCC drivers and their GNU
assemblers are the pinned ones the cross and firmware lanes use.  For
Darwin and FreeBSD arm64 the assembler is the shell's Clang 19 with the
target's triple, as the FreeBSD lane drives it, but not Apple's `as` nor
the guest's toolchain; FreeBSD x86-64, which `refine` assembles with GNU
as, is given the host's.  So a pass says the emitted text is accepted by
an assembler of the right kind for the target, which is what a spelling
or directive change breaks; the gate's lanes remain the evidence that the
target's own toolchain accepts it, links it and runs it.
"""
import argparse
import concurrent.futures
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_lock  # noqa: E402
import emit_manifest  # noqa: E402
import fixture_meta  # noqa: E402

OBJECT = ("-x", "assembler", "-c")
#  Target, or (target, level) where the level has a driver of its own: the
#  command that assembles its emission, before the assembly and `-o OUT`.
#  The machine arguments are `refine`'s for the default level.
ASSEMBLERS = {
    "linux-x86-64": ("x86_64-unknown-linux-gnu-gcc",) + OBJECT,
    "linux-arm64": ("aarch64-linux-gnu-gcc",) + OBJECT,
    "linux-rv64": ("riscv64-linux-gnu-gcc", "-march=rv64gc", "-mabi=lp64d",
                   "-Wa,--fatal-warnings") + OBJECT,
    "darwin-arm64": ("clang-19", "--target=arm64-apple-macos13") + OBJECT,
    "freebsd-x86-64": ("as", "--64"),
    "freebsd-arm64": ("clang-19", "--target=aarch64-unknown-freebsd14",
                      "-Wa,-L") + OBJECT,
    "cortex-m0": ("arm-eabi-gcc", "-mcpu=cortex-m0", "-mthumb",
                  "-mfloat-abi=soft", "-mabi=aapcs",
                  "-Wa,--fatal-warnings") + OBJECT,
    "rv32": ("riscv64-elf-gcc", "-march=rv32imc_zicsr_zifencei",
             "-mabi=ilp32", "-Wa,--fatal-warnings") + OBJECT,
    ("xtensa", "xtensa-esp32"): (
        "xtensa-esp32-elf-gcc", "-mabi=windowed", "-Wa,--abi-windowed",
        "-Wa,--auto-litpools", "-Wa,--longcalls",
        "-Wa,--fatal-warnings") + OBJECT,
    ("xtensa", "xtensa-esp32s3"): (
        "xtensa-esp32s3-elf-gcc", "-mabi=windowed", "-Wa,--abi-windowed",
        "-Wa,--auto-litpools", "-Wa,--longcalls",
        "-Wa,--fatal-warnings") + OBJECT,
}
#  (fixture, target): why its assembler refuses what refine emits today.
KNOWN_REJECTIONS = {
    ("assembly-operand-forms", "linux-rv64"):
        "the fixture has no RV64 arm, so RV64 selects its last, whose text "
        "is arm64's; refine does not read an assembly block's opcodes",
    ("fixed-array-bound-zero", "cortex-m0"):
        "a zero-size datum is emitted as `.zero 0`, which GNU as for Arm "
        "warns it ignores, and firmware assembly makes warnings fatal",
    ("generic-zero-nominal-array-signatures", "cortex-m0"):
        "a zero-size datum is emitted as `.zero 0`, which GNU as for Arm "
        "warns it ignores, and firmware assembly makes warnings fatal",
}
HOSTS = {("Linux", "x86_64"): "linux-x86-64", ("Linux", "aarch64"): "linux-arm64",
         ("Linux", "riscv64"): "linux-rv64", ("Darwin", "arm64"): "darwin-arm64",
         ("FreeBSD", "amd64"): "freebsd-x86-64",
         ("FreeBSD", "arm64"): "freebsd-arm64"}


def host_target():
    """The target this host's own lanes cover, or None for another host."""
    return HOSTS.get((platform.system(), platform.machine()))


def assembler(target, level):
    """The command for TARGET at LEVEL, or None when none is named.

    A level with no entry of its own is assembled as the target's default
    is: the fixtures that fix a level name instructions above it only
    where they also name `-march` to the linker, which nothing here runs,
    so such an entry is skipped rather than assembled with a wrong one.
    """
    return ASSEMBLERS.get((target, level)) or (
        ASSEMBLERS.get(target) if not level or target == "xtensa" else None)


def missing_tools(targets):
    """{tool: targets} for each assembler TARGETS need that PATH lacks."""
    lacking = {}
    for key, command in ASSEMBLERS.items():
        target = key if isinstance(key, str) else key[0]
        if target in targets and shutil.which(command[0]) is None:
            lacking.setdefault(command[0], [])
            if target not in lacking[command[0]]:
                lacking[command[0]].append(target)
    return lacking


def one(job):
    """Emit and assemble one entry: (key, outcome, what was said).

    The outcome is `assembled`, `refused:N` when refine emitted nothing,
    `skipped` when no assembler is named for the entry's level, or
    `rejected` when the assembler refused the assembly.
    """
    key, refine, directory, sources, target, level, optimize, specialize, \
        scratch, keep = job
    scratch.mkdir()
    asm, obj = scratch / "out.s", scratch / "out.o"
    emitted = subprocess.run(
        [str(refine), "--target=" + target]
        + (["--level=" + level] if level else [])
        + ["--optimize=" + optimize, "--specialize=" + specialize,
           "--emit=asm", "-o", str(asm)] + sources,
        capture_output=True, cwd=directory)
    if emitted.returncode != 0 or not asm.exists():
        return key, "refused:%d" % emitted.returncode, \
            emit_manifest.first_diagnostic(emitted)
    command = assembler(target, level)
    if command is None:
        return key, "skipped", None
    built = subprocess.run(list(command) + [str(asm), "-o", str(obj)],
                           capture_output=True, text=True, errors="replace")
    if built.returncode == 0 and obj.exists():
        return key, "assembled", None
    said = (built.stderr.strip() or built.stdout.strip()
            or "the assembler ended with status %d and wrote no object"
            % built.returncode)
    if keep is not None:
        kept = keep / key.replace("/", "_").replace("|", "_")
        kept.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(asm, kept / "out.s")
        (kept / "assembler.txt").write_text(
            " ".join(command) + "\n\n" + said + "\n")
    return key, "rejected", said


def assemble(refine, root, targets, corpora=("positive",), fixtures=(),
             profile=("size", "auto"), workers=None, keep=None, out=sys.stdout):
    build_lock.reading(refine)
    refine = Path(refine).resolve()
    entries = emit_manifest.corpus_entries(root, targets, corpora, fixtures)
    expected = emit_manifest.runtime_refusals(root)
    optimize, specialize = profile
    counts = {"assembled": 0, "refused": 0, "skipped": 0, "known": 0}
    faults = []
    with tempfile.TemporaryDirectory(prefix="landin-assemble-") as tmp:
        jobs = []
        for name, directory, sources, wanted, level in entries:
            shown = name.split("/", 1)[1] if name.startswith("positive/") else name
            link = (fixture_meta.read(directory, strict=False).get("link")
                    if name.startswith("runtime/") else None)
            for target in wanted:
                for selected in emit_manifest.configured_levels(
                        target, level.get(target)):
                    key = "%s|%s%s" % (shown, target,
                                       "|level=" + selected if selected else "")
                    arguments = (["--link=" + link] if link and target
                                 not in emit_manifest.FIRMWARE_TARGETS
                                 else []) + sources
                    jobs.append((key, refine, directory, arguments, target,
                                 selected, optimize, specialize,
                                 Path(tmp) / str(len(jobs)), keep))
        with concurrent.futures.ThreadPoolExecutor(
                max_workers=workers or os.cpu_count() or 1) as pool:
            for key, outcome, said in pool.map(one, jobs):
                name, target = key.split("|")[:2]
                known = KNOWN_REJECTIONS.get((name, target))
                if known and outcome == "rejected":
                    counts["known"] += 1
                elif known and outcome == "assembled":
                    faults.append("%s: assembles, and KNOWN_REJECTIONS still "
                                  "records that it does not (%s); remove the "
                                  "record" % (key, known))
                elif outcome in counts:
                    counts[outcome] += 1
                elif outcome == "refused:1" and (
                        (name, target) in emit_manifest.REFUSAL_PAIRS
                        or (name, target) in expected):
                    counts["refused"] += 1
                elif outcome == "rejected":
                    faults.append("%s: its assembler refuses the assembly:\n"
                                  "      %s" % (key, "\n      ".join(
                                      said.splitlines()[:6])))
                else:
                    faults.append("%s: refine %s, which is not an expected "
                                  "refusal%s" % (key, outcome,
                                                 ": " + said if said else ""))
    print("targets %s" % ", ".join(targets), file=out)
    print("fixtures %d  requests %d  assembled %d  refused as expected %d  "
          "skipped for a level with no assembler named %d  "
          "rejected as recorded %d  faults %d"
          % (len(entries), len(jobs), counts["assembled"], counts["refused"],
             counts["skipped"], counts["known"], len(faults)), file=out)
    if not counts["assembled"] and not faults:
        faults.append("nothing was assembled")
    if faults:
        print("emission that does not assemble, or was not emitted: "
              "%d fault(s)" % len(faults), file=sys.stderr)
        for line in faults[:40]:
            print("  " + line, file=sys.stderr)
        if len(faults) > 40:
            print("  ... and %d more" % (len(faults) - 40), file=sys.stderr)
        if keep is not None:
            print("each rejected assembly is kept under %s" % keep,
                  file=sys.stderr)
        return 1
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n", 1)[0],
        epilog="See the module's own text for what a pass is evidence of.")
    parser.add_argument("refine")
    parser.add_argument("root")
    parser.add_argument("targets", nargs="?")
    parser.add_argument("--corpus", action="append", default=[],
                        choices=emit_manifest.CORPORA)
    parser.add_argument("--fixture", action="append", default=[])
    parser.add_argument("--profile", type=lambda text: emit_manifest.profile(text),
                        default=("size", "auto"))
    parser.add_argument("--jobs", type=lambda text: emit_manifest.jobs(text))
    parser.add_argument("--keep", type=Path)
    args = parser.parse_args(argv[1:])
    known = tuple(emit_manifest.TARGETS)
    host = host_target()
    if args.targets is None:
        targets = tuple(target for target in known if target != host)
    else:
        targets = tuple(args.targets.split(","))
        wrong = [target for target in targets if target not in known]
        if wrong or len(set(targets)) != len(targets) or not targets:
            parser.error("TARGETS is a comma-separated list, each once, of: "
                         + ", ".join(known))
    lacking = missing_tools(targets)
    if lacking:
        for tool, wanted in sorted(lacking.items()):
            print("assemble_targets: %s, the assembler for %s, is not on PATH"
                  % (tool, ", ".join(wanted)), file=sys.stderr)
        print("assemble_targets: run this inside nix develop, which carries "
              "every one, or name the targets to assemble", file=sys.stderr)
        return 2
    corpora = tuple(dict.fromkeys(
        args.corpus or sorted({name.split("/", 1)[0] for name in args.fixture})
        or ("positive",)))
    unknown = sorted(set(args.fixture) - emit_manifest.known_names(args.root))
    if unknown:
        parser.error("no such fixture: %s; spell one KIND/NAME, as "
                     "positive/NAME, runtime/NAME or cortex-m/NAME"
                     % ", ".join(unknown))
    return assemble(args.refine, args.root, targets, corpora,
                    tuple(args.fixture), args.profile, args.jobs, args.keep)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
