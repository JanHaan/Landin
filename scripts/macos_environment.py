#!/usr/bin/env python3
"""Capture R5.10 native bootstrap evidence; never approve a Linux revision."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import signal
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "environments/macos-arm64/policy.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def native_host(system, machine, translated):
    require((system, machine, translated) == ("Darwin", "arm64", "0"),
            "R5.10 requires native macOS arm64 without translation")


def probe_source(kind, count):
    if kind == "aliases":
        return ("".join(f"a{i}: type = a{i + 1}\n" for i in range(count))
                + f"a{count}: type = i32\nx: a0 = 1\n")
    if kind == "values":
        return ("".join(f"v{i}: i32 = v{i + 1}\n" for i in range(count))
                + f"v{count}: i32 = 1\n")
    require(kind in ("flow", "flow-wide"), "unknown probe")
    # Widest_Struct sizes every flow row, including scalar declarations.
    # Keep a narrow control and exercise the D-by-W matrix with 64 fields.
    prefix = ("wide: type = struct\n"
              + "".join(f"    field{i}: i32\n" for i in range(64))
              + "end wide\n") if kind == "flow-wide" else ""
    return (prefix + "f: (flag: bool) -> (r: i32) =\n"
            + "".join(f"    mut v{i}: i32 = 0\n" for i in range(count))
            + "    if flag then\n" * 16
            + "        v0 = 1\n" + "    end if\n" * 16
            + "    r = v0\nend f\n")


def classify(code, output, timed_out=False):
    if timed_out:
        return "timeout"
    if code == -signal.SIGXCPU:
        return "cpu-limit"
    if code < 0:
        return "signal"
    if code == 0 and not output.strip():
        return "accepted"
    if code == 71 and "host resources exhausted" in output:
        return "reported-exhaustion"
    if "STORAGE_ERROR" in output or "Call stack traceback" in output:
        return "raw-exception"
    if code == 1 and re.search(r"error\[L\d{4}\]", output):
        return "diagnostic"
    return "unexpected-failure"


def harness_result(code, output, timed_out=False, host_only=False):
    """Host scope is explicit; full historical runs retain the Linux refusal."""
    require(not timed_out, "native harness exceeded its wall limit")
    require("FILTERED" not in output, "filtered harness is not R5.10 evidence")
    summaries = re.findall(
        r"^cases (\d+), passed (\d+), failed (\d+), checks (\d+)$",
        output, re.M)
    require(len(summaries) == 1, "missing or duplicate harness summary")
    cases, passed, failed, checks = map(int, summaries[0])
    failures = re.findall(r"^  FAIL  (.+)$", output, re.M)
    banner = "HOST-ONLY compiler checks; target workload emission/execution excluded"
    if host_only:
        require(output.count(banner) == 1 and code == 0 and not failures
                and failed == 0 and cases == passed and passed > 0 and checks > 0,
                "incomplete or failed compiler-host harness")
        return {"scope": "compiler-host", "cases": cases, "passed": passed,
                "failed": failed, "checks": checks}
    require("HOST-ONLY" not in output, "host-only run is not a full harness")
    require(code == 1 and failures == ["runtime fixtures execute"]
            and failed == 1 and cases == passed + 1 and passed > 0
            and checks > 0, "unexpected native harness failure")
    details = output.split("  FAIL  runtime fixtures execute\n", 1)[1]
    details = re.split(r"^  (?:pass|FAIL)  |^cases ", details, maxsplit=1,
                       flags=re.M)[0]
    # Check every failure in that case, not just the case name: a compiler
    # defect or metadata regression must not hide among missing-driver errors.
    missing = (
        r"      failed: runtime/[^\n]+: producer failed to complete output\n"
        r"error\[L0500\]: cannot run x86_64-pc-linux-gnu-gcc for target linux-x86-64\n"
        r"  --> <unknown source>\n"
        r"  = note: install a toolchain named x86_64-pc-linux-gnu-gcc, "
        r"or name another with --toolchain=NAME\n"
        r"|      failed: abi/[^\n]+ C link: producer could not be run: "
        r"x86_64-pc-linux-gnu-gcc\n")
    remaining, count = re.subn(missing, "", details)
    require(count > 0 and not remaining.strip(),
            "runtime case failed for a reason other than the absent Linux driver")
    return {"cases": cases, "passed": passed, "failed": failed,
            "checks": checks, "expected_failure": failures[0]}


def stop_session(leader):
    """The harness creates tool groups inside our isolated command session."""
    groups = {leader}
    try:
        try:
            os.killpg(leader, signal.SIGSTOP)
        except ProcessLookupError:
            pass
        pids = subprocess.check_output(["ps", "-axo", "pid="], text=True,
                                       timeout=5).split()
        for word in pids:
            pid = int(word)
            try:
                if os.getsid(pid) == leader:
                    groups.add(os.getpgid(pid))
            except (ProcessLookupError, PermissionError):
                pass
    finally:
        # Group kills also include children forked during the snapshot.
        for group in sorted(groups - {leader}) + [leader]:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass


class Capture:
    def __init__(self, directory):
        self.directory = directory
        self.records = []

    def run(self, name, argv, *, env=None, cwd=ROOT, timeout=30,
            check=True, stress=False):
        print(f"macos: {name}", flush=True)
        stdout = self.directory / f"{name}.stdout"
        stderr = self.directory / f"{name}.stderr"

        def limits():
            # Keep the inherited stack. Bound runaway work and suppress cores.
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            resource.setrlimit(resource.RLIMIT_CPU, (20, 20))

        started = time.monotonic()
        with stdout.open("wb") as out, stderr.open("wb") as err:
            process = subprocess.Popen(
                list(map(str, argv)), cwd=cwd, env=env, stdout=out, stderr=err,
                start_new_session=True, preexec_fn=limits if stress else None)
            timed_out = False
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    stop_session(process.pid)
                finally:
                    code = process.wait()
        record = {"name": name, "argv": list(map(str, argv)),
                  "cwd": str(cwd), "returncode": code,
                  "timeout": timed_out, "seconds": time.monotonic() - started}
        self.records.append(record)
        (self.directory / "commands.json").write_text(
            json.dumps(self.records, indent=2) + "\n")
        output = stdout.read_text(errors="replace") + stderr.read_text(errors="replace")
        if check:
            require(code == 0 and not timed_out, f"{name} failed; see {self.directory}")
        return code, output.strip(), timed_out

    def text(self, name, argv):
        return self.run(name, argv)[1]


def validate(capture):
    policy = json.loads(POLICY.read_text())
    native_host(platform.system(), platform.machine(), capture.text(
        "translation", ["sysctl", "-n", "sysctl.proc_translated"]))
    version = capture.text("macos-version", ["sw_vers", "-productVersion"])
    require(version.split(".")[0] == policy["macos_major"], "macOS outside policy")
    capture.text("macos-build", ["sw_vers", "-buildVersion"])
    capture.text("kernel", ["uname", "-a"])
    capture.text("developer-directory", ["xcode-select", "-p"])
    for key, option in (("sdk_version", "--show-sdk-version"),
                        ("sdk_build", "--show-sdk-build-version")):
        require(capture.text(key, ["xcrun", "--sdk", "macosx", option]) == policy[key],
                f"{key} differs from native environment policy")
    sdk = capture.text("sdk-path", ["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    tools = {}
    for label, tool, args in (
        ("clang", "clang", ["--version"]),
        ("assembler", "as", ["--version"]),
        ("linker", "ld", ["-version_details"]),
        ("debugger", "lldb", ["--version"]),
        ("dsymutil", "dsymutil", ["--version"]),
        ("dwarfdump", "dwarfdump", ["--version"]),
    ):
        path = capture.text(f"{label}-path", ["xcrun", "--sdk", "macosx", "--find", tool])
        response = capture.text(f"{label}-version", [path, *args])
        actual = (json.loads(response)["version"] if label == "linker"
                  else response.splitlines()[0])
        require(actual == policy[label], f"{label} differs from native environment policy")
        tools[label] = {"path": path, "sha256": sha256(path)}
    pins = dict(re.findall(r"^(LANDIN_\w+)=([^\n]+)$",
                           (ROOT / "environments/pins.sh").read_text(), re.M))
    for tool, key, pattern in (
        ("gnatls", "LANDIN_GNAT_VERSION", r"GNATLS (\S+)"),
        ("gprbuild", "LANDIN_GPRBUILD_VERSION", r"GPRBUILD (\S+)"),
    ):
        path = shutil.which(tool)
        require(path is not None, f"{tool} missing; use scripts/macos.sh and the pinned homes")
        response = capture.text(f"{tool}-version", [path, "--version"])
        match = re.search(pattern, response)
        require(match and match[1] == pins[key].rsplit("-", 1)[0], f"{tool} differs from pins")
        tools[tool] = {"path": path, "sha256": sha256(path)}
    gcc = shutil.which("gcc")
    require(gcc is not None, "native GCC is missing")
    version = capture.text("gcc-version", [gcc, "-dumpfullversion"])
    require(version == pins["LANDIN_GNAT_VERSION"].rsplit("-", 1)[0],
            "native GCC differs from GNAT pin")
    tools["gcc"] = {"path": gcc, "sha256": sha256(gcc)}
    triplet = capture.text("ada-target", [gcc, "-dumpmachine"])
    require(re.fullmatch(r"aarch64-apple-darwin[\d.]*", triplet), "Ada compiler is not native")
    return policy, sdk, tools


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="new directory for retained logs, probes and summary")
    parser.add_argument("--mode", choices=("debug", "release"),
                        help="validate one compiler mode; omit for both")
    parser.add_argument("--full-harness", action="store_true",
                        help="also attempt Linux runtime fixtures (historical slow scope)")
    args = parser.parse_args()
    modes = (args.mode,) if args.mode else ("debug", "release")
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    capture = Capture(directory)
    summary = {"schema": 1, "status": "failed",
               "started_utc": datetime.now(timezone.utc).isoformat(),
               "requested_modes": list(modes), "stack_limit":
               resource.getrlimit(resource.RLIMIT_STACK), "modes": {}}
    try:
        policy, sdk, identities = validate(capture)
        if args.full_harness:
            require(shutil.which("x86_64-pc-linux-gnu-gcc") is None,
                    "full Mac harness expects the Linux driver to be absent")
        summary.update(policy=policy, tools=identities)
        capture.text("revision", ["git", "rev-parse", "HEAD"])
        capture.text("worktree", ["git", "status", "--porcelain"])
        capture.text("diff", ["git", "diff", "--binary", "HEAD"])
        # Record source identities including new, untracked implementation files.
        paths = capture.text("inventory", ["git", "ls-files", "-co", "--exclude-standard", "-z"])
        summary["sources"] = {p: sha256(ROOT / p) for p in sorted(set(paths.split("\0")))
                              if p and (ROOT / p).is_file()}
        smoke = directory / "native.s"
        smoke.write_text(".text\n.globl _main\n.p2align 2\n_main:\n    mov w0, #0\n    ret\n")
        obj, exe = directory / "native.o", directory / "native"
        capture.run("assemble", [identities["assembler"]["path"], "-arch", "arm64",
                                 "-o", obj, smoke])
        capture.run("link", [identities["clang"]["path"], "-arch", "arm64",
                             "-isysroot", sdk, obj, "-o", exe])
        capture.run("execute", [exe])
        _, debug, _ = capture.run("lldb-smoke", [identities["debugger"]["path"],
            "--batch", "-o", "breakpoint set --name main", "-o", "run",
            "-o", "continue", str(exe)])
        require("stop reason = breakpoint" in debug and "exited with status = 0" in debug,
                "LLDB did not stop and resume the native smoke program")
        base_env = {**os.environ, "LANDIN_BUILD_INCREMENTAL": "no", "SDKROOT": sdk}
        # A fresh tag isolates this run without removing any developer objects.
        tag = "macos-" + directory.name.lower()
        require(re.fullmatch(r"[a-z0-9_-][a-z0-9._-]*", tag) and ".." not in tag,
                "output directory basename must be a valid build tag suffix")
        require(not (ROOT / "compiler/ada/build" / tag).exists(), "build tag already exists")
        base_env["LANDIN_BUILD_TAG"] = tag
        for mode in modes:
            env = {**base_env, "LANDIN_BUILD_MODE": mode}
            capture.run(f"{mode}-build", ["./scripts/build.sh", "-q", "-j8"],
                        env=env, timeout=1200)
            for source, name in (
                (ROOT / "compiler/ada/build" / tag / mode / "source-manifest.txt",
                 f"{mode}-source-manifest.txt"),
                (ROOT / "compiler/ada/.build-locks" / f"{tag}-{mode}.cgpr",
                 f"{mode}-configuration.cgpr"),
            ):
                shutil.copyfile(source, directory / name)
            binary = ROOT / "compiler/ada/build" / tag / mode / "bin/refine"
            require(capture.text(f"{mode}-architecture", ["lipo", "-archs", binary]) == "arm64",
                    "refine is not a native arm64 executable")
            capture.run(f"{mode}-identify", [binary, "--identify"])
            command = ["./scripts/test.sh"] + ([] if args.full_harness else ["--host"])
            code, output, expired = capture.run(f"{mode}-harness", command,
                                               env=env, timeout=7200, check=False)
            result = harness_result(code, output, expired, host_only=not args.full_harness)
            result["refine_sha256"] = sha256(binary)
            result["probes"] = []
            summary["modes"][mode] = result
            for kind in ("aliases", "values", "flow", "flow-wide"):
                for count in (8, 256, 1024, 4096):
                    name = f"{mode}-{kind}-{count}"
                    source = directory / f"{name}.ldn"
                    source.write_text(probe_source(kind, count))
                    code, output, expired = capture.run(name, [binary, source],
                                                       check=False, stress=True)
                    verdict = classify(code, output, expired)
                    result["probes"].append({"kind": kind, "count": count,
                                             "outcome": verdict, "returncode": code})
                    require(count != 8 or verdict == "accepted", f"{name} control failed")
        summary["status"] = "passed"
    except (OSError, ValueError) as error:
        summary["error"] = str(error)
        raise
    finally:
        summary["artifacts"] = {str(p.relative_to(directory)): sha256(p)
                                for p in sorted(directory.rglob("*")) if p.is_file()}
        (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"macos: native {'/'.join(modes)} environment passed; evidence in {directory}")


if __name__ == "__main__":
    main()
