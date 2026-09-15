#!/usr/bin/env python3
"""Regenerate the binding differential corpus for the pinned Apple target."""
import argparse
import json
from pathlib import Path
import platform
import shutil
import shlex
import sys

from check import ROOT, Run, hash_file, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(platform.system() == "Darwin" and platform.machine() == "arm64",
            "native Darwin arm64 required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    refine = args.refine.resolve()
    run = Run(output)
    summary = {"schema": 1, "status": "failed", "refine_sha256": hash_file(refine)}
    try:
        _, sdk, _ = run.command(["xcrun", "--show-sdk-path"], "sdk", ROOT)
        _, resource, _ = run.command(["/usr/bin/clang", "-print-resource-dir"], "resource", ROOT)
        sdk = Path(sdk.decode().strip())
        resource = Path(resource.decode().strip())
        fixture = ROOT / "compiler/tests/fixtures/abi/r440-bindings-generated"
        inputs = output / "inputs"
        inputs.mkdir()
        for name in ("r440-bindings.h", "program.ldn", "peer.c"):
            shutil.copyfile(fixture / name, inputs / name)
        policy = json.loads((fixture / "policy.json").read_text())
        policy["abi"]["target"] = "arm64-apple-macos26.0.0"
        (inputs / "policy.json").write_text(json.dumps(policy, indent=2) + "\n")
        generated = output / "generated"
        run.command([sys.executable, ROOT / "bindings/generate.py", "--clang", "/usr/bin/clang",
                     "--target", policy["abi"]["target"], "--sysroot", sdk,
                     "--header", "r440-bindings.h=" + str(inputs / "r440-bindings.h"),
                     "--policy", inputs / "policy.json", "--out-dir", generated,
                     "--system-include-dir", resource / "include",
                     "--system-include-dir", sdk / "usr/include"], "generate", ROOT)
        require("compiler.assert(compiler.c_darwin_lp64)" in
                (generated / "bindings.ldn").read_text(), "missing Darwin guard")
        shutil.copyfile(inputs / "program.ldn", generated / "program.ldn")
        assembly = output / "bindings.s"
        executable = output / "bindings-native"
        run.command([refine, "--target=darwin-arm64", "--root=" + str(ROOT),
                     "--emit=asm", "-o", assembly, generated], "emit", ROOT)
        run.command(["/usr/bin/clang", "-arch", "arm64", "-std=c11", "-O2",
                     "-Wall", "-Wextra", "-Werror", "-pthread", "-I", generated,
                     "-I", inputs, assembly, generated / "adapters.c", inputs / "peer.c",
                     "-o", executable], "link", ROOT)
        run.command([executable], "execute", ROOT, expected=42, timeout=30)
        # Apple -l searches can prefer a dylib. The language requests an
        # archive, so prove the native driver passes the exact .a operand.
        peer = output / "archive.c"
        peer.write_text("int r530_probe(void) { return 42; }\n")
        run.command(["/usr/bin/clang", "-arch", "arm64", "-c", peer,
                     "-o", output / "archive.o"], "archive-compile", output)
        archive = output / "libr530_probe.a"
        run.command(["/usr/bin/ar", "rcs", archive, output / "archive.o"], "archive-create", output)
        dynamic = output / "dynamic.c"
        dynamic.write_text("int r530_probe(void) { return 1; }\n")
        run.command(["/usr/bin/clang", "-arch", "arm64", "-dynamiclib", dynamic,
                     "-o", output / "libr530_probe.dylib"], "dylib-create", output)
        source = output / "archive.ldn"
        source.write_text('linker.library("r530_probe")\n'
                          'extern(c) r530_probe: () -> (r: i32)\n'
                          'public main: () -> (code: i32) =\n'
                          '    code = r530_probe()\nend main\n')
        linked = output / "archive-native"
        run.command([refine, "--target=darwin-arm64", "--emit=exe", source,
                     "-o", linked], "archive-link", output)
        run.command([linked], "archive-execute", output, expected=42)
        archive.rename(output / "retained-probe.a")
        missing = output / "missing-native"
        _, _, diagnostic = run.command([refine, "--target=darwin-arm64", "--emit=exe",
                                       source, "-o", missing], "archive-missing", output, expected=1)
        require(b"cannot resolve Darwin archive" in diagnostic and not missing.exists(),
                "missing archive silently selected the dylib")
        selected = output / "archive with spaces.a"
        (output / "retained-probe.a").rename(selected)
        driver = output / "selected-driver"
        driver.write_text('#!/bin/sh\ncase "$1" in\n'
                          '-print-file-name=libr530_probe.a) printf \'%s\\n\' '
                          + shlex.quote(str(selected)) + ' ;;\n'
                          '*) exec /usr/bin/clang "$@" ;;\nesac\n')
        driver.chmod(0o755)
        overridden = output / "selected-native"
        run.command([refine, "--target=darwin-arm64", "--emit=exe", source,
                     "--toolchain=" + str(driver), "-o", overridden], "selected-link", output)
        run.command([overridden], "selected-execute", output, expected=42)
        summary["archive_selection"] = "passed"
        summary["status"] = "passed"
    finally:
        summary["files"] = {str(p.relative_to(output)): hash_file(p)
                            for p in sorted(output.rglob("*")) if p.is_file()}
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("Darwin generated bindings: passed")


if __name__ == "__main__":
    main()
