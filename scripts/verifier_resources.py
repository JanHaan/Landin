#!/usr/bin/env python3
"""Record representative compiler resources on native supported hosts.

This is not the full scaling gate or a verifier-only memory/stack measurement.
Five normal-stack samples must compile and report positive memory. Low-stack
probes are observations, not a new source limit or required stack threshold.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import resource
import signal
import statistics
import subprocess
import sys
import time

import scaling

RUNS = 5
STACK_KIB = (1024, 2048, 4096, 8192)
ROOT = Path(__file__).resolve().parent.parent


def workloads():
    # Keep the existing scaling and backend-scale sources at their full sizes.
    scalar = ("public run: (x: i64) -> (r: i64) = r = x\n"
              + "r +%= 1\n" * 24000 + "end run\n")
    pointers = ["public run: (key: u32, cell: ptr mut u32) -> (value: u32) =",
                "value = 0"]
    pointers += [f"p{i}: ptr mut u32 = cell" for i in range(64)]
    for i in range(128):
        pointers += [f"if key == {i % 251} then",
                     f"value +%= p{i % 64}.val", "else",
                     f"value +%= p{(i + 1) % 64}.val", "end if"]
    pointers.append("end run")
    return {"branches-16000": scaling.branches(16000),
            "large-routine-24000": {"main.ldn": scalar},
            "pointers64-128": {"main.ldn": "\n".join(pointers) + "\n"}}


def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as source:
        while chunk := source.read(65536):
            result.update(chunk)
    return result.hexdigest()



def retain_assembly_identity(report):
    """Keep identity instead of redundant successful emitted assembly."""
    assembly = Path(str(report) + ".s")
    identity = {"sha256": digest(assembly), "bytes": assembly.stat().st_size}
    assembly.unlink()
    return identity


def probe_limits(stack_kib):
    """Set only the child soft stack limit; never raise a host hard limit."""
    _, hard = resource.getrlimit(resource.RLIMIT_STACK)
    wanted = stack_kib * 1024
    if hard != resource.RLIM_INFINITY and wanted > hard:
        raise ValueError("requested stack exceeds the host hard limit")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_STACK, (wanted, hard))


def stack_probe(command, stack_kib, timeout):
    _, hard = resource.getrlimit(resource.RLIMIT_STACK)
    if hard != resource.RLIM_INFINITY and stack_kib * 1024 > hard:
        return {"stack_kib": stack_kib, "status": "skipped-hard-limit"}
    started = time.monotonic()
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True,
                          preexec_fn=lambda: probe_limits(stack_kib)) as child:
        try:
            stdout, stderr = child.communicate(timeout=timeout)
            status = child.returncode
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = child.communicate()
            status = "timeout"
    return {"stack_kib": stack_kib, "status": status,
            "wall_seconds": time.monotonic() - started,
            "stdout": stdout.decode("utf-8", "replace"),
            "stderr": stderr.decode("utf-8", "replace")}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    refine = Path(args.refine).resolve()
    if not os.access(refine, os.X_OK):
        parser.error("--refine must name an executable")
    output = Path(args.output).resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be absent or empty")
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    # Disable core files for normal runs as well as reduced-stack probes.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    manifest = refine.parent.parent / "source-manifest.txt"
    record = {"refine": str(refine), "binary_sha256": digest(refine),
              "source_revision": subprocess.check_output(
                  ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "source_status": subprocess.check_output(
                  ["git", "status", "--short"], cwd=ROOT, text=True),
              "source_manifest": manifest.read_text() if manifest.exists() else None,
              "script_sha256": digest(__file__),
              "scaling_sha256": digest(ROOT / "scripts/scaling.py"),
              "host": platform.platform(), "machine": platform.machine(),
              "python": platform.python_version(), "cpu_count": os.cpu_count(),
              "load_before": os.getloadavg(),
              "stack_limits_bytes": resource.getrlimit(resource.RLIMIT_STACK),
              "runs": RUNS, "workloads": {}, "failures": [],
              "interpretation": "Whole-process CPU/RSS and coarse stack-limit "
              "observations; not verifier-only usage, a source cap, a universal "
              "memory bound, or the full scaling gate."}

    def save():
        record["wall_seconds"] = time.monotonic() - started
        record["load_after"] = os.getloadavg()
        (output / "resources.json").write_text(json.dumps(record, indent=2) + "\n")

    try:
        launcher = scaling.build_launcher(str(output))
        for name, files in workloads().items():
            directory = output / name
            scaling.write_program(str(directory), files)
            row = {"source_sha256": {
                path: hashlib.sha256(text.encode()).hexdigest()
                for path, text in files.items()}, "samples": [], "stack_probes": []}
            record["workloads"][name] = row
            for index in range(RUNS):
                report = directory / f"normal-{index}.json"
                try:
                    sample = scaling.measure(str(refine), str(directory),
                                             str(directory), str(report),
                                             args.timeout, launcher)
                    sample["assembly"] = retain_assembly_identity(report)
                    row["samples"].append(sample)
                except (OSError, RuntimeError, subprocess.TimeoutExpired,
                        ValueError, KeyError) as error:
                    failure = f"{name} sample {index}: {error}"
                    row["samples"].append({"error": failure})
                    record["failures"].append(failure)
                save()
            if not any("error" in sample for sample in row["samples"]):
                row["summary"] = {
                    "frontend_seconds_median": statistics.median(
                        sample["frontend"] for sample in row["samples"]),
                    "emission_seconds_median": statistics.median(
                        sample["emission"] for sample in row["samples"]),
                    "peak_kib_max": max(sample["peak_kib"]
                                        for sample in row["samples"])}
            for stack in STACK_KIB:
                report = directory / f"stack-{stack}.json"
                command = [launcher, str(refine), "--root=" + str(directory),
                           "--stage-report=" + str(report), "--emit=asm",
                           "-o", str(report) + ".s", str(directory)]
                probe = stack_probe(command, stack, args.timeout)
                if probe["status"] == 0:
                    probe["assembly"] = retain_assembly_identity(report)
                row["stack_probes"].append(probe)
                save()
            print(f"{name}: {row.get('summary', 'normal measurement failed')}")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        record["failures"].append(str(error))
    finally:
        save()
    print(f"resources: {record['wall_seconds']:.3f}s; {output / 'resources.json'}")
    return 1 if record["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
