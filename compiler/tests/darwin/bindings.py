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
    parser.add_argument("--parity", action="store_true")
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
        profiles = [('none', 'off'), ('size', 'off'), ('size', 'auto'), ('speed', 'auto')] if args.parity else [('none', 'off')]
        summary['scope'] = 'parity' if args.parity else 'selected'
        summary['profiles'] = []
        for optimize, specialize in profiles:
            label = 'bindings-' + optimize + '-' + specialize if args.parity else 'bindings'
            assembly = output / (label + '.s')
            executable = output / (label + '-native')
            run.command([refine, "--target=darwin-arm64", "--root=" + str(ROOT),
                         "--optimize=" + optimize, "--specialize=" + specialize,
                         "--emit=asm", "-o", assembly, generated], label + '-emit', ROOT)
            objects = []
            for index, source in enumerate((assembly, generated / 'adapters.c', inputs / 'peer.c')):
                obj = output / (label + '-' + str(index) + '.o')
                run.command(["/usr/bin/clang", "-arch", "arm64", "-std=c11", "-O2",
                             "-Wall", "-Wextra", "-Werror", "-pthread", "-I", generated,
                             "-I", inputs, '-c', source, '-o', obj], label + '-object-' + str(index), ROOT)
                objects.append(obj)
            run.command(["/usr/bin/clang", "-arch", "arm64", '-pthread', *objects,
                         "-o", executable], label + '-link', ROOT)
            _, stdout, stderr = run.command([executable], label + '-execute', ROOT, expected=42, timeout=30)
            require(not stdout and not stderr, 'unexpected binding output')
            summary['profiles'].append(dict(optimize=optimize, specialize=specialize,
                assembly=hash_file(assembly), objects=[hash_file(o) for o in objects],
                executable=hash_file(executable)))
        # D523: a linker.library is the driver's own -lNAME, which it
        # resolves as it would for C; D524: -L and linker.directory say
        # where, each also the executable's run-time path; D525: a library
        # no searched directory holds is L0509.  First an archive found only
        # through -L, in a directory whose name has a space, so the driver
        # must receive it as one argument.
        peer = output / "archive.c"
        peer.write_text("int r530_probe(void) { return 42; }\n")
        run.command(["/usr/bin/clang", "-arch", "arm64", "-c", peer,
                     "-o", output / "archive.o"], "archive-compile", output)
        libraries = output / "probe libraries"
        libraries.mkdir()
        run.command(["/usr/bin/ar", "rcs", libraries / "libr530_probe.a", output / "archive.o"],
                    "archive-create", output)
        source = output / "archive.ldn"
        source.write_text('linker.library("r530_probe")\n'
                          'extern(c) r530_probe: () -> (r: i32)\n'
                          'public main: () -> (code: i32) =\n'
                          '    code = r530_probe()\nend main\n')
        # The driver records each command it is given, one argument a line
        # and a line of its own after the last, before it runs Clang.
        recorded = output / "archive-driver.arguments"
        recorder = output / "archive-driver"
        recorder.write_text('#!/bin/sh\nprintf \'%s\\n\' "$@" >>' + shlex.quote(str(recorded))
                            + '\nprintf \'%s\\n\' "<end>" >>' + shlex.quote(str(recorded))
                            + '\nexec /usr/bin/clang -save-temps=obj "$@"\n')
        recorder.chmod(0o755)
        linked = output / "archive-native"
        run.command([refine, "--target=darwin-arm64", "--emit=exe", "-L", libraries, source,
                     "--toolchain=" + str(recorder), "-o", linked], "archive-link", output)
        run.command([linked], "archive-execute", output, expected=42)
        commands = [command.split("\n") for command in
                    recorded.read_text().split("\n<end>\n") if command]
        link = [command for command in commands if "-lr530_probe" in command]
        require(len(link) == 1, "the driver was not given -lr530_probe once: " + repr(commands))
        require("-L" + str(libraries) in link[0]
                and "-Wl,-rpath," + str(libraries) in link[0],
                "the -L directory did not reach the driver whole: " + repr(link[0]))
        require(not any(one.endswith(".a") for one in link[0]),
                "the driver was given an archive refine resolved: " + repr(link[0]))
        # The same program with no directory to look in: the link fails,
        # and refine names the library at its directive.
        missing = output / "missing-native"
        _, _, diagnostic = run.command([refine, "--target=darwin-arm64", "--emit=exe",
                                       source, "-o", missing], "archive-missing", output, expected=1)
        require(b"error[L0509]" in diagnostic and b"r530_probe" in diagnostic
                and not missing.exists(), "a missing library was not L0509")
        # A directory linker.directory names beside the source, holding the
        # archive and a dylib of the same name: refine's program takes the
        # one a C program linked from the same directory takes, and finds a
        # dylib at run time through the directory's run-time path.
        shared = output / "shared"
        shared.mkdir()
        run.command(["/usr/bin/ar", "rcs", shared / "libr530_probe.a", output / "archive.o"],
                    "directory-archive-create", output)
        dynamic = output / "dynamic.c"
        dynamic.write_text("int r530_probe(void) { return 7; }\n")
        run.command(["/usr/bin/clang", "-arch", "arm64", "-dynamiclib",
                     "-install_name", "@rpath/libr530_probe.dylib", dynamic,
                     "-o", shared / "libr530_probe.dylib"], "dylib-create", output)
        directed = output / "directory.ldn"
        directed.write_text('linker.library("r530_probe")\n'
                            'linker.directory("shared")\n'
                            'extern(c) r530_probe: () -> (r: i32)\n'
                            'public main: () -> (code: i32) =\n'
                            '    code = r530_probe()\nend main\n')
        native = output / "directory-native"
        run.command([refine, "--target=darwin-arm64", "--emit=exe", directed,
                     "--toolchain=" + str(recorder), "-o", native], "directory-link", output)
        landin_status, _, _ = run.command([native], "directory-execute", output, expected=None)
        control = output / "control.c"
        control.write_text("int r530_probe(void);\nint main(void) { return r530_probe(); }\n")
        run.command(["/usr/bin/clang", "-arch", "arm64", control, "-L" + str(shared),
                     "-Wl,-rpath," + str(shared), "-lr530_probe", "-o", output / "control-native"],
                    "control-link", output)
        c_status, _, _ = run.command([output / "control-native"], "control-execute", output,
                                     expected=None)
        require(landin_status == c_status and c_status in (7, 42),
                f"refine's program returned {landin_status} and C's {c_status}")
        summary["directory_selection"] = "dylib" if c_status == 7 else "archive"
        summary["archive_selection"] = "passed"
        summary["status"] = "passed"
    finally:
        summary["files"] = {str(p.relative_to(output)): hash_file(p)
                            for p in sorted(output.rglob("*")) if p.is_file()}
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("Darwin generated bindings: passed")


if __name__ == "__main__":
    main()
