#!/usr/bin/env python3
"""Where a workload's code goes: its routines' bytes and stack traffic.

The ranked costs of compiler/tests/measure/findings.md attribute a
cost by measuring the same workload with and without the construct that
pays it, at one configuration.  This builds the workloads of
compiler/tests/measure/workloads.json, or any fixture, at the named
configurations exactly as scripts/measure.py does, and reads two things:
the build report's per-routine counters, which count emission sites, and
each routine's bytes from the linked image's symbol table.

    measure_costs.py routines --refine R --target T [--level L ...]
                              [--profile OPT-SPEC ...] [--workload NAME ...]
                              [--fixture DIR ...] [--library DIR] --output DIR
        build each configuration, write DIR/costs.json and print one line
        a configuration: its .text bytes, the report's instructions, its
        stack loads and stores and their share of the instructions; a
        refine copied out of its checkout, a base to compare with, finds no
        library of its own and needs --library ROOT for a firmware target
    measure_costs.py top IMAGE [--report REPORT] [--count N]
        IMAGE's largest routines by bytes, with the report's counters for
        the routine of that name where REPORT is given
    measure_costs.py classify IMAGE --target T [--symbol S]
        IMAGE's instructions, or symbol S's, by class from the target's
        objdump: stack loads and stores, the instructions that form a
        stack address, the extra instructions of far jumps, and the rest

Levels default to every level `refine targets --json` gives the target,
profiles to size-auto and speed-auto, and workloads to the target's set.
A `--fixture` directory is measured as a workload named after it, with
the firmware entry a firmware target's workloads take.  The stack-traffic
share is the report's: a load or store through the stack or frame
pointer, a push, a pop, and x86-64's call and return
(compiler/ada/README.md, "The build report").  Standard library only.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare_images  # noqa: E402
import measure  # noqa: E402

require = measure.require


def elf_functions(image: Path) -> list[tuple[str, int, int]]:
    """Every sized routine in IMAGE's symbol table as (name, address,
    bytes), in address order, read by compare_images.py."""
    try:
        symbols = compare_images.Image(image).symbols
    except compare_images.NotAnImage as problem:
        raise measure.Failure(f"{image}: {problem}") from None
    return sorted(((name, at, size) for (kind, name, _), (at, size)
                   in symbols.items() if kind == "routine" and size),
                  key=lambda one: one[1])


def report_routines(report: dict) -> list[dict]:
    """The build report's routine rows, each with its item's name."""
    names = {item["item"]: item["name"] for item in report["items"]}
    return [{**row, "name": names.get(row["item"], "?")}
            for row in report["build"]["routines"]]


def totals(rows: list[dict]) -> dict:
    """The rows' summed counters and the share of their instructions that
    are stack loads and stores, in percent."""
    sums = {field: sum(row[field] for row in rows)
            for field in ("instructions", "stack_loads", "stack_stores",
                          "direct_calls", "indirect_calls", "spill_bytes",
                          "frame_bytes")}
    traffic = sums["stack_loads"] + sums["stack_stores"]
    sums["routines"] = len(rows)
    sums["stack_share"] = (round(100 * traffic / sums["instructions"], 1)
                           if sums["instructions"] else 0.0)
    return sums


def by_symbol(rows: list[dict]) -> dict[str, dict]:
    """The rows by the name an image's symbol table gives their routine:
    the item's whole name, and its last component where only one routine
    has it."""
    named: dict[str, dict] = {}
    last: dict[str, list[dict]] = {}
    for row in rows:
        named[row["name"]] = row
        last.setdefault(row["name"].rsplit(".", 1)[-1], []).append(row)
    for short, ones in last.items():
        if len(ones) == 1:
            named.setdefault(short, ones[0])
    return named


def top(image: Path, report: dict | None, count: int) -> list[dict]:
    rows = by_symbol(report_routines(report)) if report else {}
    largest = sorted(elf_functions(image), key=lambda one: -one[2])
    result = []
    for name, _, bytes_ in largest[:count]:
        row = rows.get(name, {})
        result.append({"symbol": name, "bytes": bytes_,
                       **{field: row[field] for field in
                          ("instructions", "stack_loads", "stack_stores")
                          if field in row}})
    return result


#  Each target's disassembler, from the pinned environment.
OBJDUMP = {"linux-x86-64": "objdump", "freebsd-x86-64": "objdump",
           "linux-arm64": "aarch64-linux-gnu-objdump",
           "freebsd-arm64": "aarch64-linux-gnu-objdump",
           "linux-rv64": "riscv64-linux-gnu-objdump",
           "cortex-m0": "arm-eabi-objdump", "rv32": "riscv64-elf-objdump",
           "xtensa": "xtensa-esp32-elf-objdump"}

#  What a disassembled instruction is, by target.  `stack` is a load or
#  store whose base is the stack or frame pointer, or a register set from
#  one since the last label or call, and a push or pop; `address` sets such
#  a register, as Cortex-M's `mov r6, sp` and `adds r6, #N` do; `far` is
#  one instruction of a jump or call that takes more than one, Cortex-M's
#  literal load and `bx r7` and RISC-V's `auipc`/`addi`/`jr` through s10.
#  Anything else is `other`.  Routines whose names begin with `__`, the C
#  compiler's runtime helpers, are not counted.
FAMILY = {"cortex-m0": "thumb", "rv32": "riscv", "linux-rv64": "riscv",
          "xtensa": "xtensa", "linux-arm64": "arm64", "freebsd-arm64": "arm64",
          "darwin-arm64": "arm64", "linux-x86-64": "x86", "freebsd-x86-64": "x86"}
#  The registers that always hold a stack address.
BASES = {"thumb": {"sp"}, "riscv": {"sp", "s0"}, "xtensa": {"a1", "a7"},
         "arm64": {"sp", "x29"}, "x86": {"%rsp", "%rbp"}}
#  Mnemonics whose first operand is read, not written.
READS_FIRST = {
    "thumb": ("str", "strb", "strh", "strd", "vstr", "stm", "stmia", "push",
              "cmp", "cmn", "tst", "vcmp", "vcmpe", "bx", "blx", "b", "bl",
              "cbz", "cbnz"),
    "riscv": ("sb", "sh", "sw", "sd", "fsw", "fsd", "c.sw", "c.sd",
              "c.swsp", "c.sdsp", "jr", "j", "jal", "jalr", "ret", "call"),
    "xtensa": ("s8i", "s16i", "s32i", "s32i.n", "s32e", "j", "jx", "call0",
               "call8", "callx8", "callx0", "ret", "ret.n", "retw", "retw.n"),
}


def memory_base(family: str, mnemonic: str, operands: str) -> str | None:
    """The base register of a load or store, or None for any other."""
    if family in ("thumb", "arm64"):
        if mnemonic.startswith(("ldm", "stm")):
            return operands.split(",")[0].rstrip("!")
        if mnemonic.startswith(("ld", "st", "vld", "vst")) and "[" in operands:
            return operands.split("[", 1)[1].split(",")[0].split("]")[0]
        return None
    if family == "riscv":
        if "(" in operands and not mnemonic.startswith(("j", "b")):
            return operands.split("(", 1)[1].split(")")[0]
        return None
    if family == "xtensa":
        if mnemonic.startswith(("l8", "l16", "l32", "s8", "s16", "s32")):
            fields = operands.split(",")
            return fields[1] if len(fields) > 1 else None
        return None
    if "(" in operands:  # x86
        return operands.split("(", 1)[1].split(",")[0].split(")")[0]
    return None


def classify(target: str, text: str) -> dict:
    """Each class's count over the instructions in an objdump listing."""
    family = FAMILY.get(target)
    require(family is not None, f"no instruction classes for {target}")
    counts = {"stack": 0, "address": 0, "far": 0, "other": 0}
    bases = BASES[family]
    held: set[str] = set()
    counted = True
    for line in text.splitlines():
        if line.endswith(">:") and " <" in line:
            name = line.split(" <", 1)[1][:-2]
            counted = not name.startswith("__")
            held = set()
            continue
        parts = line.split("\t")
        if len(parts) < 2 or not parts[0].strip().endswith(":"):
            continue
        if family == "x86":
            mnemonic, _, operands = parts[1].strip().partition(" ")
        else:
            mnemonic, operands = parts[1].strip(), (parts[2] if len(parts) > 2 else "")
        if not mnemonic or mnemonic.startswith(".") or not counted:
            continue
        #  The comment objdump appends: Arm's after `@`, where `#` marks an
        #  immediate, and RISC-V's after `#`.
        operands = operands.split("@" if family in ("thumb", "arm64") else "#")[0]
        operands = operands.replace(" ", "")
        fields = operands.split(",")
        target_register = fields[0]
        kind = "other"
        base = memory_base(family, mnemonic, operands)
        if mnemonic.startswith(("push", "pop")) or (
                base is not None and (base in bases or base in held)):
            kind = "stack"
        elif family == "thumb" and (mnemonic == "ldr" and operands.startswith("r7,[pc")
                                    or mnemonic == "bx" and operands == "r7"):
            kind = "far"
        elif family == "riscv" and (
                mnemonic == "auipc" and target_register == "s10"
                or mnemonic == "addi" and operands.startswith("s10,s10,")
                or mnemonic == "jr" and operands == "s10"):
            kind = "far"
        elif family in ("thumb", "riscv", "xtensa") and len(fields) >= 2 and (
                mnemonic in ("mov", "mv", "mov.n") and fields[1] in bases
                or mnemonic in ("add", "adds", "sub", "subs", "addi", "addi.n",
                                "add.n", "addmi", "c.addi")
                and any(one in bases or one in held for one in fields[1:])
                or mnemonic in ("adds", "subs", "c.addi") and len(fields) == 2
                and fields[0] in held):
            kind = "address"
        counts[kind] += 1
        if family in READS_FIRST and mnemonic not in READS_FIRST[family] \
                and not mnemonic.startswith(("b", "c.b")):
            if kind == "address":
                held.add(target_register)
            else:
                held.discard(target_register)
        if mnemonic in ("bl", "blx", "jal", "jalr", "call", "call8", "callx8",
                        "call0", "callx0"):
            held = set()
    total = sum(counts.values())
    counts["instructions"] = total
    for name in ("stack", "address", "far"):
        counts[f"{name}_share"] = round(100 * counts[name] / total, 1) if total else 0.0
    return counts


def disassemble(target: str, image: Path, symbol: str | None) -> str:
    tool = OBJDUMP.get(target)
    require(tool is not None, f"no disassembler for {target}")
    command = [tool, "-d", "--no-show-raw-insn",
               *([f"--disassemble={symbol}"] if symbol else []), str(image)]
    done = subprocess.run(command, capture_output=True, text=True)
    require(done.returncode == 0, f"{' '.join(command)}: {done.stderr.strip()}")
    return done.stdout


def workload_list(target: str, names: list[str], fixtures: list[str]) -> list[dict]:
    kind = "firmware" if target in measure.FIRMWARE else "hosted"
    sets = measure.workloads()[kind]
    chosen = [one for one in sets if not names or one["name"] in names]
    require(not names or len(chosen) == len(names),
            f"{target}: no {kind} workload named {sorted(set(names) - {one['name'] for one in chosen})}")
    for given in fixtures:
        path = Path(given).resolve()
        fixtures_root = measure.ROOT / "compiler/tests/fixtures"
        require(path.is_relative_to(fixtures_root),
                f"{given}: a fixture lives under {fixtures_root}")
        chosen.append({"name": path.name,
                       "fixture": str(path.relative_to(fixtures_root))})
    return chosen


def routines(args) -> int:
    given = measure.targets(Path(args.refine))
    require(args.target in given, f"refine gives no emitting target {args.target}")
    levels = args.level or list(given[args.target])
    profiles = [tuple(one.split("-", 1)) for one in args.profile or ["size-auto", "speed-auto"]]
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    result = []
    for level in levels:
        require(level in given[args.target], f"{args.target} has no level {level}")
        for profile in profiles:
            require(profile in measure.PROFILES, f"no profile {'-'.join(profile)}")
            for workload in workload_list(args.target, args.workload, args.fixture):
                image, _, _ = measure.build(args.refine, args.target, level, profile,
                                            workload, out, None, args.library)
                report = json.loads(Path(f"{image}.json").read_text())
                sections, _ = measure.image_sections(image)
                one = {"key": measure.key(level, profile, workload["name"]),
                       "text": sections.get(".text", 0),
                       **totals(report_routines(report))}
                result.append(one)
                print(f"{args.target} {one['key']}: .text {one['text']},"
                      f" {one['instructions']} instructions,"
                      f" {one['stack_loads']} stack loads,"
                      f" {one['stack_stores']} stack stores"
                      f" ({one['stack_share']}%)", flush=True)
    (out / "costs.json").write_text(json.dumps(
        {"schema": 1, "target": args.target, "entries": result}, indent=1) + "\n")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n", 1)[0],
        epilog=__doc__.split("\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    built = commands.add_parser("routines", help="build and sum the counters")
    built.add_argument("--refine", required=True)
    built.add_argument("--target", required=True)
    built.add_argument("--level", action="append", default=[])
    built.add_argument("--profile", action="append", default=[],
                       help="OPTIMIZE-SPECIALIZE, such as size-auto")
    built.add_argument("--workload", action="append", default=[])
    built.add_argument("--fixture", action="append", default=[])
    built.add_argument("--output", required=True)
    built.add_argument("--library", type=lambda text: str(Path(text).resolve()),
                       help="the directory holding core, hosted and platform that"
                       " refine compiles against, a checkout's root: a refine copied"
                       " out of its checkout finds no library of its own, and so no"
                       " firmware reference profile")
    largest = commands.add_parser("top", help="an image's largest routines")
    largest.add_argument("image")
    largest.add_argument("--report")
    largest.add_argument("--count", type=int, default=20)
    kinds = commands.add_parser("classify", help="an image's instruction classes")
    kinds.add_argument("image")
    kinds.add_argument("--target", required=True)
    kinds.add_argument("--symbol")
    args = parser.parse_args(argv)
    if getattr(args, "refine", None):
        import refine_revision
        refine_revision.warn(args.refine)  # is it this checkout's?
    try:
        if args.command == "routines":
            return routines(args)
        if args.command == "classify":
            counts = classify(args.target, disassemble(
                args.target, Path(args.image), args.symbol))
            print(" ".join(f"{name} {value}" for name, value in counts.items()))
            return 0
        report = json.loads(Path(args.report).read_text()) if args.report else None
        for row in top(Path(args.image), report, args.count):
            counters = "".join(f" {field} {row[field]}" for field in
                               ("instructions", "stack_loads", "stack_stores")
                               if field in row)
            print(f"{row['bytes']:7} {row['symbol']}{counters}")
        return 0
    except measure.Failure as failure:
        print(f"measure_costs.py: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
