#!/usr/bin/env python3
"""Native Darwin lowering/ABI execution, and with --parity the full hosted parity corpus."""
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

    def command(self, argv, name, cwd, *, expected=0, timeout=180, merged=False):
        def limits():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        started = time.monotonic()
        stdout = self.directory / (name + ".stdout")
        stderr = self.directory / (name + ".stderr")
        with stdout.open("wb") as out, stderr.open("wb") as err:
            process = subprocess.Popen(list(map(str, argv)), cwd=cwd, stdout=out,
                                       stderr=subprocess.STDOUT if merged else err,
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
    parser.add_argument("--parity", action="store_true", help="complete shared hosted corpus")
    args = parser.parse_args(argv)
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "native Darwin arm64 required")
    require(subprocess.check_output(["sysctl", "-n", "sysctl.proc_translated"]).strip() == b"0",
            "translated execution is not Darwin acceptance")
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    refine = args.refine.resolve()
    run = Run(directory)
    retained_driver = directory / "retain-clang"
    if args.parity:
        retained_driver.write_text('#!/bin/sh\nexec /usr/bin/clang -save-temps=obj -x assembler "$@"\n')
        retained_driver.chmod(0o755)
    summary = {"schema": 1, "scope": "filtered" if args.case or args.profile else "parity" if args.parity else "selected",
               "refine_sha256": hash_file(refine), "cases_sha256": hash_file(HERE / "cases.json"),
               "results": [], "status": "failed"}
    try:
        candidates = []
        fixture_names = PROFILES["fixtures"]
        if args.parity:
            differences = json.loads((HERE / "parity.json").read_text())["differences"]
            summary["differences"] = differences
            fixture_names = sorted(str(p.parent.relative_to(ROOT / "compiler/tests/fixtures"))
                                   for cls in ("runtime", "abi")
                                   for p in (ROOT / "compiler/tests/fixtures" / cls).glob("*/fixture.meta"))
        for name in fixture_names:
            base = ROOT / "compiler/tests/fixtures" / name
            meta = dict(line.split(": ", 1) for line in (base / "fixture.meta").read_text().splitlines()
                        if ": " in line and not line.startswith("#"))
            meta.setdefault("stream", "merged")
            if args.parity and name in differences:
                if "replacement" in differences[name]:
                    continue
                meta.update({k: v for k, v in differences[name].items() if k != "reason"})
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
            profiles = PROFILES["profiles"]
            if args.parity:
                profiles = [("none", "off"), ("size", "off"), ("size", "auto"), ("speed", "auto")]
                if meta.get("profiles") == "specialization":
                    profiles += [("none", "all"), ("speed", "all")]
            for optimize, specialize in profiles:
                if args.profile and optimize != args.profile:
                    continue
                label = name.replace("/", "-") + "-" + optimize + ("-" + specialize if args.parity else "")
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
                if meta["class"] == "runtime" and not meta.get("c-sources"):
                    driver_args = ["--toolchain=" + str(retained_driver)] if args.parity else []
                    run.command([*argv, *driver_args, "--emit=exe", "-o", executable], label + "-build", cwd, timeout=900)
                    produced = Path(str(executable) + ".s")
                    if produced.exists() and produced != assembly:
                        produced.rename(assembly)
                else:
                    run.command([*argv, "--emit=asm", "-o", assembly], label + "-emit", cwd, timeout=900)
                    run.command(["/usr/bin/clang", "-arch", "arm64", "-c", assembly, "-o", object_file],
                                label + "-assemble", cwd)
                    companions = [base / part.strip() for part in meta["c-sources"].split(",")]
                    c_args = shlex.split(meta.get("c-args", ""))
                    if args.parity:
                        c_args = [arg.replace("-Wl,--wrap=", "-Wl,-alias,___wrap_") + ",_" + arg.split("=")[1]
                                  if arg.startswith("-Wl,--wrap=") else arg for arg in c_args]
                        objects = []
                        for index, companion in enumerate(companions):
                            peer_object = directory / (label + f"-peer-{index}.o")
                            run.command(["/usr/bin/clang", "-arch", "arm64", "-std=c11", "-O2",
                                         "-Wall", "-Wextra", "-Werror",
                                         *[a for a in c_args if not a.startswith("-Wl,")],
                                         "-c", companion, "-o", peer_object], label + f"-peer-{index}", cwd)
                            objects.append(peer_object)
                        companions = objects
                    run.command(["/usr/bin/clang", "-arch", "arm64", "-std=c11", "-O2",
                                 "-Wall", "-Wextra", "-Werror", *c_args, object_file, *companions,
                                 "-o", executable], label + "-link", cwd)
                _, file_output, _ = run.command(["/usr/bin/file", executable], label + "-file", cwd)
                assembly_contract(assembly.read_text())
                require(b"Mach-O 64-bit executable arm64" in file_output, "wrong executable target")
                status, stdout, stderr = run.command([executable, *shlex.split(meta.get("run_args", ""))],
                                                     label + "-execute", cwd, expected=None, timeout=30,
                                                     merged=meta.get("stream") == "merged")
                expected = ((base / meta["run_expect"]).read_bytes() if "run_expect" in meta
                            else meta["stdout"].encode() if "stdout" in meta else None)
                verdict = "passed"
                if args.parity and meta.get("limit") == "darwin-shared-region":
                    control_object = directory / (label + "-control.o")
                    control = directory / (label + "-control")
                    run.command(["/usr/bin/clang", "-arch", "arm64", "-O2", "-c",
                                 HERE / "large_image.c", "-o", control_object], label + "-control-compile", cwd)
                    run.command(["/usr/bin/clang", "-arch", "arm64", control_object, "-o", control],
                                label + "-control-link", cwd)
                    control_status, control_out, control_err = run.command(
                        [control], label + "-control-execute", cwd, expected=None, timeout=30, merged=True)
                    message = b"syscall to map cache into shared region failed"
                    require(status == control_status == -signal.SIGABRT
                            and message in stdout + stderr and message in control_out + control_err,
                            "large-image outcome does not match the demonstrated native loader limit")
                    verdict = "platform-limited"
                else:
                    outcome(meta, status, stdout, stderr, expected)
                if args.parity:
                    require(object_file.is_file(), "linked object was not retained")
                summary["results"].append({"case": name, "optimize": optimize, "specialize": specialize,
                                           "status": verdict, "exit": status,
                                           **({"assembly": hash_file(assembly), "object": hash_file(object_file),
                                               "executable": hash_file(executable)} if args.parity else {})})
        summary["status"] = "passed"
    finally:
        summary["files"] = {p.name: hash_file(p) for p in sorted(directory.iterdir()) if p.is_file()}
        (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Darwin {summary['scope']}: {len(summary['results'])} outcomes verified")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("darwin: " + str(error), file=sys.stderr)
        raise SystemExit(1)
