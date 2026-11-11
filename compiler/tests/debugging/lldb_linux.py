#!/usr/bin/env python3
"""Run the shared LLDB sessions against Linux images on this Linux host.

The sessions are lldb_batch.py's, the ones FreeBSD's lane runs in its VM:
the source session over compiler/tests/freebsd/debug.ldn and the stack
switch's (D469), each at the four standard profiles.  Here they run
against Linux images of this host's own architecture, with the `lldb`
`nix develop` puts on PATH, so a change to a session, to its verdict or
to switch_frames.py's LLDB reader is run before the gate's FreeBSD and
Darwin jobs run it.  It is evidence about the sessions and about LLDB on
a Linux image, and none about FreeBSD or Darwin.

    python3 compiler/tests/debugging/lldb_linux.py --refine REFINE --output DIR

DIR must not exist, or be empty; it receives each image, its command file,
its transcript and summary.json.  Every session runs, and the status is 1
if any failed.
"""
import argparse
import json
import platform
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import lldb_batch  # noqa: E402
import switch_frames  # noqa: E402

PROFILES = (("none", "off"), ("size", "off"), ("size", "auto"), ("speed", "auto"))
HOST_TARGET = {"x86_64": "linux-x86-64", "aarch64": "linux-arm64"}


def run(argv, log, timeout=900):
    result = subprocess.run([str(word) for word in argv], cwd=ROOT,
                            capture_output=True, timeout=timeout)
    text = (result.stdout + result.stderr).decode(errors="replace")
    log.write_text(text)
    if result.returncode != 0:
        raise lldb_batch.Mismatch("%s: status %d\n%s" % (log.stem, result.returncode,
                                                         text[-4000:]))
    return result.stdout.decode(errors="replace")


def sessions(args, target):
    """(label, kind, command file, image) of every session, each built."""
    built = []
    lines = lldb_batch.source_lines()
    for optimize, specialize in PROFILES:
        flags = ["--target=" + target, "--debug=full", "--emit=exe",
                 "--optimize=" + optimize, "--specialize=" + specialize]
        label = "debug-%s-%s" % (optimize, specialize)
        image = args.output / label
        run([args.refine, *flags, lldb_batch.SOURCE, "-o", image],
            args.output / (label + "-build.log"))
        built.append((label, "source", lldb_batch.source_commands(lines), image, lines))
        label = "switch-%s-%s" % (optimize, specialize)
        image = args.output / label
        run([args.refine, *flags, "--root=" + str(ROOT), switch_frames.FIXTURE, "-o", image],
            args.output / (label + "-build.log"))
        listing = run([args.objdump, "-d", "--disassemble-symbols=" + switch_frames.SWITCH,
                       image], args.output / (label + "-switch-disassembly.log"))
        symbols = run([args.nm, "-n", image], args.output / (label + "-symbols.log"))
        shadows = switch_frames.shadowing_symbols(symbols)
        lldb_batch.require(not shadows, label + ": " + "; ".join(shadows))
        count = switch_frames.instruction_count(listing)
        built.append((label, "switch", lldb_batch.switch_commands(count), image, count))
    return built


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="a new or empty directory for images and transcripts")
    parser.add_argument("--target", choices=sorted(HOST_TARGET.values()),
                        help="this host's own Linux target, which is the default")
    parser.add_argument("--lldb", default="lldb")
    parser.add_argument("--objdump", default="llvm-objdump-19")
    parser.add_argument("--nm", default="llvm-nm-19")
    args = parser.parse_args(argv)
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts'))
    import refine_revision
    refine_revision.warn(args.refine)  # is it this checkout's?
    host = HOST_TARGET.get(platform.machine())
    if platform.system() != "Linux" or host is None:
        parser.error("LLDB runs these images natively, so this needs a Linux"
                     " x86-64 or arm64 host; FreeBSD's sessions run through"
                     " compiler/tests/freebsd/check.py --kind=debugger")
    target = args.target or host
    if target != host:
        parser.error("%s is not this host's target, %s: LLDB runs the image"
                     " natively" % (target, host))
    for tool in (args.lldb, args.objdump, args.nm):
        if shutil.which(tool) is None:
            parser.error("no %s on PATH; nix develop provides it" % tool)
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("%s is not empty" % args.output)
    args.output.mkdir(parents=True, exist_ok=True)
    args.output = args.output.resolve()
    args.refine = args.refine.resolve()
    version = subprocess.run([args.lldb, "--version"], capture_output=True,
                             text=True).stdout.strip()
    summary = {"target": target, "lldb": version, "sessions": []}
    failed = 0
    try:
        built = sessions(args, target)
    except lldb_batch.Mismatch as error:
        print("lldb_linux: " + str(error), file=sys.stderr)
        return 1
    for label, kind, commands, image, detail in built:
        script = args.output / (label + ".lldb")
        script.write_text("\n".join(commands) + "\n")
        result = {"label": label, "kind": kind}
        try:
            completed = subprocess.run([args.lldb, "--batch", "-s", str(script), str(image)],
                                       cwd=ROOT, capture_output=True, timeout=300)
            text = (completed.stdout + completed.stderr).decode(errors="replace")
            (args.output / (label + "-session.log")).write_text(text)
            lldb_batch.require(completed.returncode == 0,
                               label + ": LLDB failed\n" + text[-4000:])
            if kind == "source":
                lldb_batch.check_source(text, detail, label)
                said = "source stops, frames, locals and unwinding"
            else:
                result["frames"] = lldb_batch.check_switch(text, label, target)
                result["switch_instructions"] = detail
                said = "backtraces through the stack switch"
            result["status"] = "passed"
            print("%s: %s %s passed" % (target, label, said), flush=True)
        except (lldb_batch.Mismatch, subprocess.TimeoutExpired) as error:
            result["status"] = "failed"
            result["error"] = str(error)
            failed += 1
            print("%s: %s FAILED: %s" % (target, label, error), file=sys.stderr, flush=True)
        summary["sessions"].append(result)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("%s: %d of %d LLDB sessions passed with %s; summary in %s"
          % (target, len(built) - failed, len(built), version.splitlines()[0] if version else "lldb",
             args.output / "summary.json"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
