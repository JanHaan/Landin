#!/usr/bin/env python3
"""Regenerate the committed bindings for Linux arm64 and run them there.

The generated fixture under compiler/tests/fixtures/abi/r440-bindings-generated
is SysV's: its bindings assert compiler.c_sysv_lp64 and its metadata names
x86_64-pc-linux-gnu, so it cannot be the standard AAPCS64's evidence.  This
regenerates the same header under the same policy for
aarch64-unknown-linux-gnu, holds the output to D256's fact and unsigned
plain char, and then compiles, links and runs the same Landin program and C
peer against it at every standard profile -- natively, on an arm64 Linux
host, which is the only place the result is evidence.  It is the
counterpart compiler/tests/linux-arm64/parity.json names for that fixture.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "compiler/tests/fixtures/abi/r440-bindings-generated"
TARGET = "aarch64-unknown-linux-gnu"
PROFILES = (("none", "off"), ("size", "off"), ("size", "auto"),
            ("speed", "auto"))


def require(condition, message):
    if not condition:
        raise SystemExit("linux-arm64 bindings: " + message)


def run(args, *, cwd=ROOT, expected=0, capture=True):
    completed = subprocess.run([str(a) for a in args], cwd=cwd, check=False,
                               stdout=subprocess.PIPE if capture else None,
                               stderr=subprocess.STDOUT if capture else None,
                               text=True, timeout=600)
    require(completed.returncode == expected,
            "%s returned %d, expected %d\n%s"
            % (args[0], completed.returncode, expected, completed.stdout or ""))
    return completed.stdout or ""


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--clang", default=os.environ.get("CLANG", "clang"))
    parser.add_argument("--driver", default="aarch64-linux-gnu-gcc",
                        help="the C driver that links the program")
    parser.add_argument("--sysroot", type=Path, default=Path("/"),
                        help="the aarch64 sysroot Clang reads headers from")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require((platform.system(), platform.machine()) == ("Linux", "aarch64"),
            "native Linux arm64 required; no skip is a pass")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    refine = args.refine.resolve(strict=True)
    clang = shutil.which(args.clang)
    require(clang is not None, "Clang %r is not on PATH" % args.clang)
    resource = Path(run([clang, "-print-resource-dir"]).strip())

    inputs = output / "inputs"
    inputs.mkdir()
    for name in ("r440-bindings.h", "program.ldn", "peer.c"):
        shutil.copyfile(FIXTURE / name, inputs / name)
    policy = json.loads((FIXTURE / "policy.json").read_text())
    policy["abi"]["target"] = TARGET
    policy["abi"]["plain_char"] = "unsigned"
    (inputs / "policy.json").write_text(json.dumps(policy, indent=2) + "\n")

    generated = output / "generated"
    include = args.sysroot / "usr/include"
    run([sys.executable, ROOT / "bindings/generate.py", "--clang", clang,
         "--target", TARGET, "--sysroot", args.sysroot,
         "--header", "r440-bindings.h=" + str(inputs / "r440-bindings.h"),
         "--policy", inputs / "policy.json", "--out-dir", generated,
         "--system-include-dir", resource / "include",
         "--system-include-dir", include / "aarch64-linux-gnu",
         "--system-include-dir", include])
    bindings = (generated / "bindings.ldn").read_text()
    require("compiler.assert(compiler.c_aapcs64_lp64)" in bindings,
            "the bindings do not assert the standard AAPCS64's fact")
    metadata = json.loads((generated / "bindings.json").read_text())["abi"]
    require((metadata["target"], metadata["calling_convention"],
             metadata["plain_char"]) == (TARGET, "aapcs64", "unsigned"),
            "the metadata does not describe the standard AAPCS64: %r" % metadata)
    shutil.copyfile(inputs / "program.ldn", generated / "program.ldn")

    results = []
    for optimize, specialize in PROFILES:
        label = "bindings-%s-%s" % (optimize, specialize)
        assembly = output / (label + ".s")
        executable = output / label
        run([refine, "--target=linux-arm64", "--root=" + str(ROOT),
             "--optimize=" + optimize, "--specialize=" + specialize,
             "--emit=asm", "-o", assembly, generated])
        run([args.driver, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
             "-I", generated, "-I", inputs, assembly, generated / "adapters.c",
             inputs / "peer.c", "-o", executable])
        said = run([executable], expected=42)
        require(said == "", "%s produced output: %r" % (label, said))
        results.append({"profile": label, "assembly": digest(assembly),
                        "executable": digest(executable)})
        print("linux-arm64 bindings: %s passed" % label, flush=True)

    summary = {"schema": 1, "status": "passed", "target": TARGET,
               "refine_sha256": digest(refine),
               "clang": run([clang, "--version"]).splitlines()[0],
               "generated": {name: digest(generated / name) for name in
                             ("bindings.ldn", "adapters.c", "exports.h",
                              "bindings.json")},
               "profiles": results}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("linux-arm64 generated bindings: passed")


if __name__ == "__main__":
    main()
