#!/usr/bin/env python3
"""Linux object-quality acceptance, not a benchmark or a golden recorder."""
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
PROFILES = (("none", "off"), ("size", "off"),
            ("size", "auto"), ("speed", "auto"))


def run(args: list[str], *, empty_output: bool = False,
        expected_status: int = 0) -> str:
    completed = subprocess.run(args, check=False, capture_output=True,
                               text=True, timeout=120,
                               env={**os.environ, "LC_ALL": "C"})
    require(completed.returncode == expected_status,
            f"command returned {completed.returncode}, expected {expected_status}: "
            f"{args!r}\n"
            f"{completed.stdout}{completed.stderr}")
    if empty_output:
        require(completed.stdout == "" and completed.stderr == "",
                "quality program produced unexpected stdout or stderr")
    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="")
    return completed.stdout


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def instructions(disassembly: str, symbol: str) -> list[str]:
    match = re.search(r"^[0-9a-f]+ <" + re.escape(symbol)
                      + r">:\n(.*?)(?=^[0-9a-f]+ <|\Z)",
                      disassembly, re.M | re.S)
    require(match is not None, f"missing measured symbol {symbol}")
    return [m.group(1).strip() for m in re.finditer(
        r"^\s*[0-9a-f]+:\s+(.+)$", match.group(1), re.M)]


def stack_traffic(body: list[str]) -> int:
    # Static memory instruction sites, not dynamic executions. LEA forms an
    # address and does not read its source memory. Prologue traffic is included.
    return sum(bool(re.search(r"\(%r(?:bp|sp)\)", line))
               and not line.startswith("lea") for line in body)


def frame_bytes(body: list[str]) -> int:
    # The small scalar probes use a fixed frame, not a page-probing loop.
    require(body[:2] == ["push   %rbp", "mov    %rsp,%rbp"],
            "measured scalar routine lost its frame pointer")
    match = re.fullmatch(r"sub\s+\$0x([0-9a-f]+),%rsp", body[2])
    return int(match.group(1), 16) if match else 0


def measure(refine: Path, tools: dict[str, str], source: Path,
            destination: Path, profile: tuple[str, str],
            expected_status: int = 0) -> dict:
    assembly = destination.with_suffix(".s")
    report = destination.with_suffix(".json")
    obj = destination.with_suffix(".o")
    args = [str(refine), str(source), "--emit=asm", "-o", str(assembly),
            f"--optimize={profile[0]}", f"--specialize={profile[1]}",
            f"--build-report={report}"]
    run(args)
    first_assembly, first_report = assembly.read_bytes(), report.read_bytes()
    run(args)
    require(assembly.read_bytes() == first_assembly,
            f"nondeterministic assembly: {source.name}/{profile}")
    require(report.read_bytes() == first_report,
            f"nondeterministic report: {source.name}/{profile}")
    parsed = json.loads(first_report)
    require(parsed["schema"] == 1, "unknown report schema")
    build = parsed["build"]
    require((build["optimize"], build["specialize"]) == profile,
            "report profile differs from request")
    require(build["target"] == "linux-x86-64", "wrong report target")
    require(bool(build["routines"]), "empty routine evidence")
    run([tools["gcc"], "-c", str(assembly), "-o", str(obj)])
    sizes = run([tools["size"], "-A", str(obj)])
    section_bytes = {m.group(1): int(m.group(2)) for m in re.finditer(
        r"^(\.\S+)\s+(\d+)\s+", sizes, re.M)}
    text_bytes = sum(size for name, size in section_bytes.items()
                     if name == ".text" or name.startswith(".text."))
    require(text_bytes > 0, "object contains no measured text")
    symbols = run([tools["objdump"], "-t", str(obj)])
    function_bytes = {m.group(2): int(m.group(1), 16) for m in re.finditer(
        r"^[0-9a-f]+\s+.*\bF\s+\.text(?:\.\S+)?\s+([0-9a-f]+)\s+(\S+)$",
        symbols, re.M)}
    disassembly = run([tools["objdump"], "-d", "--no-show-raw-insn", str(obj)])
    destination.with_suffix(".disassembly").write_text(disassembly)
    destination.with_suffix(".size").write_text(sizes)
    # Execute the identical assembly that was measured, rather than a second
    # compiler request which could use another policy.
    run([tools["gcc"], "-no-pie", str(obj), "-o", str(destination)])
    run([str(destination)], empty_output=True, expected_status=expected_status)
    return {"text_bytes": text_bytes, "build": build,
            "section_bytes": section_bytes, "function_bytes": function_bytes,
            "symbol_output": symbols, "expected_status": expected_status,
            "object_sha256": hashlib.sha256(obj.read_bytes()).hexdigest(),
            "size_output": sizes,
            "disassembly": disassembly,
            "assembly_sha256": hashlib.sha256(first_assembly).hexdigest()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True,
                        help="checksum-pinned Linux GNAT installation")
    parser.add_argument("--output", type=Path, required=True,
                        help="directory for retained measurement evidence")
    args = parser.parse_args()
    require(platform.system() == "Linux" and platform.machine() == "x86_64",
            "object quality requires Linux x86-64; no skip is a pass")
    refine = args.refine.resolve(strict=True)
    home = args.toolchain.resolve(strict=True)
    tools = {}
    for name in ("gcc", "objdump", "size"):
        candidates = [home / "bin" / ("x86_64-pc-linux-gnu-" + name),
                      home / "bin" / name]
        selected = next((p for p in candidates if p.is_file()), None)
        require(selected is not None, f"pinned installation lacks {name}")
        tools[name] = str(selected)
    versions = {name: run([path, "--version"]).splitlines()[0]
                for name, path in tools.items()}
    args.output.mkdir(parents=True, exist_ok=True)
    # A fresh private directory prevents stale output from satisfying a check.
    # Private artifacts need local filesystem identities; a shared build
    # mount can report distinct paths as aliases. Retain evidence below.
    with tempfile.TemporaryDirectory(prefix="quality-") as tmp:
        scratch = Path(tmp)
        sources = {name: HERE / f"{name}.ldn" for name in
                   ("scalars", "layout", "specialization", "folding")}
        expected_status = {}
        for name in ("insertion-sort", "sieve-of-eratosthenes"):
            fixture = HERE.parent / "fixtures" / "runtime" / name
            metadata = dict(line.split(":", 1) for line in
                            (fixture / "fixture.meta").read_text().splitlines()
                            if ":" in line and not line.startswith("#"))
            sources[name] = fixture / metadata["program"].strip()
            expected_status[name] = int(metadata["status"])
        sources["threshold"] = (HERE.parent / "fixtures" / "runtime"
                                / "r450-specialization-threshold" / "main.ldn")
        template = (HERE / "arrays.ldn.in").read_text()
        for count in (4, 4096):
            path = scratch / f"array-{count}.ldn"
            path.write_text(template.replace("@COUNT@", str(count)))
            sources[f"array-{count}"] = path
        evidence = {}
        for name, source in sources.items():
            evidence[name] = {}
            profiles = PROFILES
            if name in ("specialization", "folding", "threshold"):
                profiles += (("none", "all"), ("speed", "all"))
            for profile in profiles:
                key = "-".join(profile)
                evidence[name][key] = measure(
                    refine, tools, source, scratch / f"{name}-{key}", profile,
                    expected_status.get(name, 0))
        base = evidence["scalars"]["none-off"]
        for key in ("size-off", "size-auto", "speed-auto"):
            optimized = evidence["scalars"][key]
            for symbol in ("quality_chain", "quality_loop"):
                before = instructions(base["disassembly"], symbol)
                after = instructions(optimized["disassembly"], symbol)
                require(stack_traffic(before) > 0, f"empty baseline: {symbol}")
                require(stack_traffic(after) * 2 <= stack_traffic(before),
                        f"{key}/{symbol}: less than 50% stack-traffic reduction")
                require(len(after) * 5 <= len(before) * 4,
                        f"{key}/{symbol}: less than 20% instruction reduction")
                require(frame_bytes(before) > 0
                        and frame_bytes(after) * 2 <= frame_bytes(before),
                        f"{key}/{symbol}: less than 50% frame reduction")
                require(optimized["function_bytes"][symbol]
                        <= base["function_bytes"][symbol],
                        f"{key}/{symbol}: function object bytes grew")
            require(optimized["text_bytes"] <= base["text_bytes"],
                    f"{key}: scalar object text grew")
            require(sum(r["frame_bytes"] for r in optimized["build"]["routines"])
                    <= sum(r["frame_bytes"] for r in base["build"]["routines"]),
                    f"{key}: total scalar frame bytes grew")
            leaf_before = instructions(base["disassembly"], "quality_leaf")
            leaf_after = instructions(optimized["disassembly"], "quality_leaf")
            require(len(leaf_after) <= len(leaf_before)
                    and optimized["function_bytes"]["quality_leaf"]
                    <= base["function_bytes"]["quality_leaf"]
                    and frame_bytes(leaf_after) <= frame_bytes(leaf_before),
                    f"{key}: tiny leaf gained instructions, bytes or frame")
            require(not any(re.search(r"%(?:rbx|r1[2-5])\b", line)
                            for line in leaf_after),
                    f"{key}: tiny leaf acquired callee-save overhead")
        for name in ("insertion-sort", "sieve-of-eratosthenes"):
            reference = evidence[name]["none-off"]
            for key in ("size-off", "size-auto", "speed-auto"):
                require(evidence[name][key]["text_bytes"] * 10
                        <= reference["text_bytes"] * 11,
                        f"{name}/{key}: existing workload text grew over 10%")
        for profile in PROFILES:
            key = "-".join(profile)
            small = instructions(evidence["array-4"][key]["disassembly"],
                                 "quality_array")
            large = instructions(evidence["array-4096"][key]["disassembly"],
                                 "quality_array")
            require(len(large) <= len(small) + 32,
                    f"{key}: array body grew with element count")
            require(any(re.search(r"\bsub\w*\s+\$0x1000,%rsp", line)
                        for line in large)
                    and any(re.search(r"\bor\w*\s+\$0x0,\(%rsp\)", line)
                            for line in large),
                    f"{key}: large frame lacks page-by-page stack touches")
            require(evidence["array-4096"][key]["text_bytes"]
                    <= evidence["array-4"][key]["text_bytes"] + 2048,
                    f"{key}: array object text is not compact")
            plans = evidence["layout"][key]["build"]["layouts"]
            require(any(p["policy"] == "optimal" and p["size"] == 16
                        and p["natural_size"] == 24 and p["saved_bytes"] == 8
                        and p["offsets"] == [8, 0, 9] for p in plans),
                    f"{key}: missing factual optimal placement")
        dispatch_base = evidence["specialization"]["none-off"]
        call_pattern = r"^\s*[0-9a-f]+:\s+call\w*\s+\*"
        baseline_indirect = len(re.findall(
            call_pattern, dispatch_base["disassembly"], re.M))
        require(baseline_indirect > 0, "static-dispatch baseline is not indirect")
        for key, measured in evidence["specialization"].items():
            actual_indirect = len(re.findall(
                call_pattern, measured["disassembly"], re.M))
            if key.endswith("-off"):
                require(actual_indirect == baseline_indirect,
                        f"{key}: off specialized a dispatch")
            else:
                require(actual_indirect == 0,
                        f"{key}: proved single-instance dispatch stayed indirect")
                decisions = measured["build"]["specializations"]
                require(any(d["direct_calls_made"] > 0
                            and d["retains_evidence_abi"] for d in decisions),
                        f"{key}: direct dispatch lacks retained-ABI evidence")
                require(measured["text_bytes"]
                        <= dispatch_base["text_bytes"] + 128,
                        f"{key}: single-instance specialization grew over 128 bytes")
        # This source-level witness supplements the hand-built IR policy test.
        # Exact cost inputs pin what lowering actually supplies to the policy.
        for key, measured in evidence["threshold"].items():
            decisions = measured["build"]["specializations"]
            require(len(decisions) == 2, f"{key}: expected two source instances")
            selected = key in ("speed-auto", "none-all", "speed-all")
            for decision in decisions:
                require((decision["entry_calls"], decision["loop_depth"],
                         decision["represented_bytes"], decision["benefit"],
                         decision["estimated_growth"]) == (8, 4, 4, 321, 209),
                        f"{key}: source specialization cost inputs changed")
                require(decision["action"] ==
                        ("specialized" if selected else "declined")
                        and decision["direct_calls_made"] == (8 if selected else 0),
                        f"{key}: source specialization threshold decision is wrong")
                reason = ("disabled" if key.endswith("-off") else
                          "forced" if key.endswith("-all") else
                          "profitable" if selected else "cost-threshold")
                require(decision["reason"] == reason,
                        f"{key}: specialization reason is not factual")
            actual_indirect = len(re.findall(
                call_pattern, measured["disassembly"], re.M))
            # The unspecialized instances share one evidence-driven body;
            # sixteen semantic sites therefore occupy eight machine sites.
            routines = measured["build"]["routines"]
            require(actual_indirect == (0 if selected else 8)
                    and actual_indirect == sum(r["indirect_calls"]
                                               for r in routines),
                    f"{key}: emitted dispatch disagrees with source decisions")
            require(sum(r["shared_with"] != 0 for r in routines)
                    == (0 if selected else 1),
                    f"{key}: threshold witness lost its shared fallback")
        fold_base = evidence["folding"]["none-off"]
        for key in ("size-off", "size-auto", "speed-auto", "speed-all"):
            folded = evidence["folding"][key]
            require(any(r["shared_with"] != 0
                        for r in folded["build"]["routines"]),
                    f"{key}: identical private bodies did not fold")
            require(folded["text_bytes"] < fold_base["text_bytes"],
                    f"{key}: folding probe did not shrink object text")
        # Keep measured disassembly and size output in durable evidence, even
        # though the private executable/object scratch directory is removed.
        # The result contains actual observations, never auto-updated thresholds.
        result = {"schema": 1, "tools": versions,
                  "compiler_sha256": hashlib.sha256(refine.read_bytes()).hexdigest(),
                  "measurements": evidence}
        (args.output / "measurements.json").write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        print(f"object quality: {error}", file=sys.stderr)
        sys.exit(1)
