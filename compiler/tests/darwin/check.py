#!/usr/bin/env python3
"""Native Darwin lowering/ABI execution, and with --parity the full hosted parity corpus."""
import argparse
from concurrent.futures import ThreadPoolExecutor
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
import threading
import time

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
PROFILES = json.loads((HERE / "cases.json").read_text())
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "compiler/tests"))
from macos_environment import stop_session
import fixture_meta


def require(condition, message):
    if not condition:
        raise ValueError(message)


def hash_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


#  D361: the line a trap with no panic handler writes to standard error
#  before its terminal instruction.  A fixture's `trap_report:` is that
#  line exactly: the file is named relative to its module's root, so where
#  the lane put the fixture cannot change it.
def reports_trap(output, line):
    wanted = line.encode()
    return wanted in output.split(b"\n")


def merged(meta):
    """Whether a program's two streams are read as one.

    `merged` is the default, as compiler/tests/README.md says and the test
    program, the FreeBSD and the RV64 lanes take it: only `stream: output`
    separates them, and then standard error must be empty, a trap's report
    included, exactly as there.
    """
    return meta.get("stream", "merged") == "merged"


def as_meta(meta):
    """META as fixture metadata: a fixture's own, or a lane's case or
    overlay written as a plain dict."""
    return fixture_meta.as_metadata(meta)


def outcome(meta, status, stdout, stderr, expected=None):
    meta = as_meta(meta)
    if meta.get("traps") == "yes":
        require(status == -signal.SIGTRAP, f"expected synchronous BRK, got {status}")
        if meta.get("trap_report"):
            require(reports_trap(stdout + stderr, meta["trap_report"]),
                    f"trap report missing: {meta['trap_report']!r} in {(stdout + stderr)[:400]!r}")
    else:
        require(status == meta.status, f"expected status {meta.status}, got {status}")
    if expected is not None:
        actual = stdout + stderr if merged(meta) else stdout
        require(actual == expected, f"output mismatch: {actual[:400]!r}")
    if not merged(meta):
        require(not stderr, f"unexpected stderr: {stderr[:400]!r}")


def large_image_outcome(meta, status, stdout, stderr, expected,
                        control_status, control_out, control_err):
    """Require the same demonstrated outcome from Landin and native Clang."""
    if status == control_status == 42:
        outcome(meta, status, stdout, stderr, expected if expected is not None else b"")
        require(not control_out and not control_err, "unexpected large-image control output")
        return "passed"
    message = b"syscall to map cache into shared region failed"
    require(status == control_status == -signal.SIGABRT
            and message in stdout + stderr and message in control_out + control_err,
            "large-image outcome does not match the demonstrated native loader limit")
    return "platform-limited"


FUNCTION_LABEL = r"_[A-Za-z0-9_.$]+:"
#  The one routine that opens no frame record: a prepared stack's first
#  frame returns into the start routine, whose return address is undefined
#  so that a debugger's walk ends there (D447, D469).  A record would give
#  the walk a frame beneath it.  The switch routine has one (D475).
UNFRAMED = {"_landin.stack_start:"}


def assembly_contract(text):
    """Check function frames and the reserved register.  Every routine is
    Landin's own, the hosted library's included, so each keeps a frame,
    but for the start routine of a stack that ends the chain."""
    require(not re.search(r"\b[wx]18\b", text), "reserved x18 used")
    in_code = False
    lines = text.splitlines()
    count = 0
    for index, line in enumerate(lines):
        if line.strip() == ".text":
            in_code = True
        elif line.strip() == ".data" or line.strip().startswith(".section"):
            in_code = False
        if in_code and re.fullmatch(FUNCTION_LABEL, line) and line not in UNFRAMED:
            require([entry.strip() for entry in lines[index + 1:index + 3]] ==
                    ["stp x29, x30, [sp, #-16]!", "mov x29, sp"],
                    "missing frame record: " + line)
            count += 1
    require(count > 0, "no emitted routine frames")


#  The Darwin arm64 CPU feature levels (D255) above the default, each with
#  the sysctl that says this Mac's processor has it and what the executed
#  image must then contain and lack.
LEVELS = {"armv8.1-a": {"sysctl": "hw.optional.arm.FEAT_LSE",
                        "present": r"\b(?:ldadd|swp|cas)al[bh]?\b",
                        "absent": r"\b(?:ldxr|stxr)[bh]?\b"}}


def levels_of(meta):
    """The arm64 levels a fixture's `levels:` names beyond the default."""
    return [one for one in as_meta(meta).levels_for("darwin-arm64") if one in LEVELS]


def host_has(level):
    """Whether this Mac's processor has the level, which it must before a
    build for that level is run: a level above it is refused, not hoped."""
    probe = subprocess.run(["sysctl", "-n", LEVELS[level]["sysctl"]],
                           capture_output=True, text=True)
    return probe.returncode == 0 and probe.stdout.strip() == "1"


def level_lowering(executable, level, cwd, run, label):
    """The executed image's own instructions, so the level is shown to have
    reached the bytes that ran and not only the assembly refine wrote."""
    _, listing, _ = run.command(["/usr/bin/objdump", "-d", "--no-show-raw-insn", executable],
                                label + "-disassemble", cwd)
    text = listing.decode(errors="replace")
    present = len(re.findall(LEVELS[level]["present"], text))
    require(present > 0, level + ": the image has no instruction of the level")
    require(not re.search(LEVELS[level]["absent"], text),
            level + ": the image still holds the default level's sequence")
    return {"level_instructions": present}


def workers():
    """How many fixtures run at once: LANDIN_DARWIN_JOBS, default 1.

    macOS vets every newly created executable on its first launch, a few
    tenths of a second each, and admits roughly one at a time; every profile
    here links a new program, so launches queue there however many workers
    wait.  Measured on an eight-core Mac, 1,465 s at one worker and 755 s at
    four and at eight alike.
    """
    value = os.environ.get("LANDIN_DARWIN_JOBS", "1")
    require(value.isdigit() and 1 <= int(value) <= 64, "LANDIN_DARWIN_JOBS must be 1 to 64")
    return int(value)


def standard_input(base, meta):
    """The file a fixture's `stdin:` names below BASE, or an empty input."""
    return as_meta(meta).standard_input(base)


class Run:
    def __init__(self, directory):
        self.directory = directory
        self.commands = []
        #  Workers share one command record; appending to it and rewriting
        #  commands.json are one step, or two workers interleave the file.
        self.lock = threading.Lock()

    def command(self, argv, name, cwd, *, expected=0, timeout=180, merged=False,
                stdin=os.devnull):
        def limits():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        started = time.monotonic()
        stdout = self.directory / (name + ".stdout")
        stderr = self.directory / (name + ".stderr")
        #  A program reads the file its fixture names, or an empty input;
        #  never this script's own, which may be a terminal.
        with stdout.open("wb") as out, stderr.open("wb") as err, \
                open(stdin, "rb") as given:
            process = subprocess.Popen(list(map(str, argv)), cwd=cwd, stdin=given, stdout=out,
                                       stderr=subprocess.STDOUT if merged else err,
                                       start_new_session=True, preexec_fn=limits)
            expired = False
            try:
                status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                expired = True
                stop_session(process.pid)
                status = process.wait()
        with self.lock:
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
            meta = fixture_meta.read(base)
            #  A fixture that does not name macOS arm64 is another lane's,
            #  as compiler/tests/README.md says of every target; one with a
            #  replacement or overlay below still names it or is replaced.
            if (args.parity and name not in differences
                    and not meta.applies_to("darwin-arm64")):
                continue
            if args.parity and name in differences:
                if "replacement" in differences[name]:
                    continue
                #  The overlay is JSON, so a status is a number there; the
                #  metadata reader reads text, as from a fixture.meta.
                meta.update({k: str(v) for k, v in differences[name].items() if k != "reason"})
            candidates.append((name, base, meta))
        for case in PROFILES["darwin"]:
            #  A rooted module is its program's directory, as a rooted
            #  fixture is its own; so a case whose program sits below
            #  HERE is read from that directory, its root relative to it.
            fields = {k: str(v) for k, v in case.items()}
            case_base = HERE / Path(fields["program"]).parent
            fields["program"] = Path(fields["program"]).name
            if "root" in fields:
                fields["root"] = os.path.relpath(HERE / fields["root"], case_base)
            candidates.append((case["name"], case_base, fixture_meta.Metadata.of(
                {**fields, "class": case.get("class", "abi"), "c-sources": case.get("c", "")},
                case.get("class", "abi") + "/" + case["name"])))
        names = {name for name, _, _ in candidates}
        require(not args.case or set(args.case) <= names, "unknown exact case")
        def fixture(item):
            #  A fixture's labels print only once all its profiles pass, so a
            #  failure names the profile it met; the log alone would point at
            #  the last fixture that passed.
            labels = []
            try:
                return fixture_runs(item, labels)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                raise ValueError(f"{labels[-1] if labels else item[0]}: {error}") from error

        def fixture_runs(item, labels):
            #  One fixture's profiles run in order: a program may name a fixed
            #  file, and two of its own profiles would race on it.
            name, base, meta = item
            results = []
            profiles = PROFILES["profiles"]
            if args.parity:
                profiles = [("none", "off"), ("size", "off"), ("size", "auto"), ("speed", "auto")]
                if meta.get("profiles") == "specialization":
                    profiles += [("none", "all"), ("speed", "all")]
            levels = [None] + (levels_of(meta) if args.parity and meta["class"] == "runtime" else [])
            for level in levels:
                require(level is None or host_has(level), "this Mac cannot run " + str(level))
            for level, (optimize, specialize) in [(lv, p) for lv in levels for p in profiles]:
                if args.profile and optimize != args.profile:
                    continue
                label = (name.replace("/", "-") + "-" + optimize + ("-" + specialize if args.parity else "")
                         + ("-" + level if level else ""))
                labels.append(label)
                assembly = directory / (label + ".s")
                object_file = directory / (label + ".o")
                executable = directory / label
                argv = [refine, "--target=darwin-arm64", "--optimize=" + optimize,
                        "--specialize=" + specialize, *(["--level=" + level] if level else []),
                        *meta.module_arguments(base)]
                cwd = ROOT / "compiler/ada"
                # Runtime cases exercise refine's native driver selection;
                # ABI cases retain a separate Apple-assembled Mach-O object.
                if meta["class"] == "runtime" and not meta.get("c-sources"):
                    driver_args = ["--toolchain=" + str(retained_driver)] if args.parity else []
                    run.command([*argv, *driver_args, "--emit=exe", "--keep-asm", "-o", executable],
                                label + "-build", cwd, timeout=900)
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
                #  `c-shared:` sources become dylibs the program loads, their
                #  paths its first arguments; an undefined symbol is left for
                #  the loader, as an ELF shared object's is
                #  (compiler/tests/README.md).
                shared = []
                for part in [p.strip() for p in meta.get("c-shared", "").split(",") if p.strip()]:
                    dylib = directory / (label + "-" + Path(part).stem + ".dylib")
                    run.command(["/usr/bin/clang", "-arch", "arm64", "-std=c11", "-O2",
                                 "-Wall", "-Wextra", "-Werror", "-fPIC", "-dynamiclib",
                                 "-Wl,-undefined,dynamic_lookup", base / part, "-o", dylib],
                                label + "-shared-" + Path(part).stem, cwd)
                    shared.append(dylib)
                status, stdout, stderr = run.command(meta.program_arguments(base, [executable, *shared]),
                                                     label + "-execute", cwd, expected=None, timeout=30,
                                                     merged=merged(meta),
                                                     stdin=standard_input(base, meta))
                expected = (meta.run_expected(base) if "run_expect" in meta
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
                    verdict = large_image_outcome(
                        meta, status, stdout, stderr, expected,
                        control_status, control_out, control_err)
                else:
                    outcome(meta, status, stdout, stderr, expected)
                lowering = level_lowering(executable, level, cwd, run, label) if level else {}
                if args.parity:
                    require(object_file.is_file(), "linked object was not retained")
                results.append({"case": name, "optimize": optimize, "specialize": specialize,
                                **({"level": level, **lowering} if level else {}),
                                "status": verdict, "exit": status,
                                **({"assembly": hash_file(assembly), "object": hash_file(object_file),
                                    "executable": hash_file(executable)} if args.parity else {})})
            return results, labels

        selected = [c for c in candidates if not args.case or c[0] in args.case]
        #  Every fixture has its own labelled files; results report in the
        #  sequential order whatever order the workers finished in.
        with ThreadPoolExecutor(max_workers=workers()) as pool:
            for results, labels in pool.map(fixture, selected):
                for label in labels:
                    print("darwin: " + label, flush=True)
                summary["results"] += results
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
