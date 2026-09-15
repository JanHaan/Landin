#!/usr/bin/env python3
"""Native Darwin lowering/ABI execution; R5.50 owns the full parity corpus."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import re
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
PROFILES = json.loads((HERE / "cases.json").read_text())
sys.path.insert(0, str(ROOT / "scripts"))
from macos_environment import stop_session


def require(condition, message):
    if not condition:
        raise ValueError(message)


def hash_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def outcome(meta, status, stdout, stderr, expected=None):
    if meta.get("traps") == "yes":
        require(status == -signal.SIGTRAP, f"expected synchronous BRK, got {status}")
    else:
        require(status == int(meta["status"]), f"expected status {meta['status']}, got {status}")
    if expected is not None:
        actual = stdout + stderr if meta.get("stream") == "merged" else stdout
        require(actual == expected, f"output mismatch: {actual[:400]!r}")
    if meta.get("stream") != "merged":
        require(not stderr, f"unexpected stderr: {stderr[:400]!r}")


def assembly_contract(text):
    """Check every emitted function's frame record and the reserved register."""
    require(not re.search(r"\b[wx]18\b", text), "reserved x18 used")
    in_code = False
    lines = text.splitlines()
    count = 0
    for index, line in enumerate(lines):
        if line.strip() == ".text":
            in_code = True
        elif line.strip() == ".data" or line.strip().startswith(".section"):
            in_code = False
        if in_code and re.fullmatch(r"_[A-Za-z0-9_.$]+:", line):
            require([entry.strip() for entry in lines[index + 1:index + 3]] ==
                    ["stp x29, x30, [sp, #-16]!", "mov x29, sp"],
                    "missing frame record: " + line)
            count += 1
    require(count > 0, "no emitted routine frames")


class Run:
    def __init__(self, directory):
        self.directory = directory
        self.commands = []

    def command(self, argv, name, cwd, *, expected=0, timeout=180):
        def limits():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        started = time.monotonic()
        stdout = self.directory / (name + ".stdout")
        stderr = self.directory / (name + ".stderr")
        with stdout.open("wb") as out, stderr.open("wb") as err:
            process = subprocess.Popen(list(map(str, argv)), cwd=cwd, stdout=out, stderr=err,
                                       start_new_session=True, preexec_fn=limits)
            expired = False
            try:
                status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                expired = True
                stop_session(process.pid)
                status = process.wait()
        self.commands.append({"argv": list(map(str, argv)), "cwd": str(cwd),
                              "status": status, "timeout": expired,
                              "seconds": time.monotonic() - started,
                              "stdout": stdout.name, "stderr": stderr.name})
        (self.directory / "commands.json").write_text(json.dumps(self.commands, indent=2) + "\n")
        require(not expired, f"{name}: timeout")
        if expected is not None:
            require(status == expected, f"{name}: status {status}: {stderr.read_text(errors='replace')[:1500]}")
        return status, stdout.read_bytes(), stderr.read_bytes()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", action="append", help="exact name; development only")
    parser.add_argument("--profile", choices=["none", "size", "speed"], help="development only")
    args = parser.parse_args(argv)
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "native Darwin arm64 required")
    require(subprocess.check_output(["sysctl", "-n", "sysctl.proc_translated"]).strip() == b"0",
            "translated execution is not Darwin acceptance")
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    refine = args.refine.resolve()
    run = Run(directory)
    summary = {"schema": 1, "scope": "filtered" if args.case or args.profile else "R5.30",
               "refine_sha256": hash_file(refine), "cases_sha256": hash_file(HERE / "cases.json"),
               "results": [], "status": "failed"}
    try:
        candidates = []
        for name in PROFILES["fixtures"]:
            base = ROOT / "compiler/tests/fixtures" / name
            meta = dict(line.split(": ", 1) for line in (base / "fixture.meta").read_text().splitlines()
                        if ": " in line and not line.startswith("#"))
            candidates.append((name, base, meta))
        for case in PROFILES["darwin"]:
            candidates.append((case["name"], HERE,
                               {**case, "class": case.get("class", "abi"),
                                "c-sources": case.get("c", "")}))
        names = {name for name, _, _ in candidates}
        require(not args.case or set(args.case) <= names, "unknown exact case")
        for name, base, meta in candidates:
            if args.case and name not in args.case:
                continue
            for optimize, specialize in PROFILES["profiles"]:
                if args.profile and optimize != args.profile:
                    continue
                label = name.replace("/", "-") + "-" + optimize
                print("darwin: " + label, flush=True)
                assembly = directory / (label + ".s")
                object_file = directory / (label + ".o")
                executable = directory / label
                source = base / meta["program"]
                sources = (["--root=" + str((base / meta["root"]).resolve()), str(source.parent)]
                           if "root" in meta else [str(source)])
                sources += [str(base / part.strip()) for part in meta.get("with", "").split(",") if part.strip()]
                argv = [refine, "--target=darwin-arm64", "--optimize=" + optimize,
                        "--specialize=" + specialize, *sources]
                cwd = ROOT / "compiler/ada"
                # Runtime cases exercise refine's native driver selection;
                # ABI cases retain a separate Apple-assembled Mach-O object.
                if meta["class"] == "runtime":
                    run.command([*argv, "--emit=exe", "-o", executable], label + "-build", cwd)
                    produced = Path(str(executable) + ".s")
                    if produced.exists() and produced != assembly:
                        produced.rename(assembly)
                else:
                    run.command([*argv, "--emit=asm", "-o", assembly], label + "-emit", cwd)
                    run.command(["/usr/bin/clang", "-arch", "arm64", "-c", assembly, "-o", object_file],
                                label + "-assemble", cwd)
                    companions = [base / part.strip() for part in meta["c-sources"].split(",")]
                    run.command(["/usr/bin/clang", "-arch", "arm64", "-std=c11", "-O2",
                                 *shlex.split(meta.get("c-args", "")), object_file, *companions,
                                 "-o", executable], label + "-link", cwd)
                _, file_output, _ = run.command(["/usr/bin/file", executable], label + "-file", cwd)
                assembly_contract(assembly.read_text())
                require(b"Mach-O 64-bit executable arm64" in file_output, "wrong executable target")
                status, stdout, stderr = run.command([executable, *shlex.split(meta.get("run_args", ""))],
                                                     label + "-execute", cwd, expected=None, timeout=30)
                expected = ((base / meta["run_expect"]).read_bytes() if "run_expect" in meta
                            else meta["stdout"].encode() if "stdout" in meta else None)
                outcome(meta, status, stdout, stderr, expected)
                summary["results"].append({"case": name, "optimize": optimize, "specialize": specialize,
                                           "status": "passed", "exit": status})
        summary["status"] = "passed"
    finally:
        summary["files"] = {p.name: hash_file(p) for p in sorted(directory.iterdir()) if p.is_file()}
        (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Darwin {summary['scope']}: {len(summary['results'])} executions passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("darwin: " + str(error), file=sys.stderr)
        raise SystemExit(1)
