#!/usr/bin/env python3
"""The host-independence check: one manifest per host, compared across them.

`compiler/tests/test_determinism.py` states the equivalence relation two
compilations must agree on, and lets them differ in the build directory, the
working directory, the output path, the environment and the ordering.  It
says nothing about the HOST, because a single machine cannot answer that
question.  This is the other half: every host emits the same manifest, or
the compiler is reading something off the machine it runs on.

The property matters more than it looks.  Nothing outside `Landin.Targets`
may ask the host how wide a pointer is, and layout arithmetic counts target
bytes rather than the host compiler's `Natural`; if that ever slips, a
32-bit target silently follows the host it was built on.  It also decides
the shape of the build matrix: when emission is host-neutral, a target is
checked once wherever it can run, and each host only has to agree on the
bytes.  Hosts plus targets, rather than hosts times targets.

Emission needs no target assembler, linker or emulator, so `emit` runs
anywhere the compiler builds -- including a host with no cross toolchain
for any of the targets it is emitting for.

One input to the equivalence relation is easy to miss.  Tier 2 of the
contract is only deterministic under a fixed SOURCE-PATH SPELLING, and
`caller` locations put a digest of the caller files into the assembly.  The
first run of this check passed absolute paths and six of 1446 entries
differed for that reason alone; the same two paths disagree the same way on
one host, which is how it was identified as the check's fault rather than
the compiler's.  So each fixture is compiled from its own directory under
the bare spellings its `fixture.meta` names -- `program`, then `with` in the
order written, or `--root` and the directory itself -- which are the same
strings on every host.  The fixture record decides what is compiled, as it
does for the harness; a fixture this check could not read would be a
fixture it silently stopped checking, which is how 27 of them went
unexamined while the header said "every positive fixture".

The manifest covers each independent optimization and specialization control
in both build modes.  Each digest's key names its exact profile so that a
host disagreement identifies the path that produced it.

    emit REFINE ROOT OUT.json     write this host's manifest
    compare A.json B.json [...]   require every manifest to agree
"""
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

TARGETS = ("linux-x86-64", "linux-arm64", "darwin-arm64", "cortex-m0",
           "freebsd-x86-64", "freebsd-arm64")
MODES = ("debug", "release")
OPTIMIZATIONS = ("none", "size", "speed")
SPECIALIZATIONS = ("off", "auto", "all")
MAX_WORKERS = 4

#  These source/target pairs deliberately refuse in both modes.  Most use
#  target-specific C or machine facilities; the fixed-conditional fixtures
#  select an x86-64-only declaration.  Keep this list explicit: a new shared
#  refusal must not become evidence of equal assembly merely by agreeing on
#  every host.
REFUSAL_PAIRS = {
    ("external-scalar-c-boundary", "cortex-m0"),
    ("fixed-conditional-cross-file-forward", "cortex-m0"),
    ("fixed-conditional-cross-file-forward", "darwin-arm64"),
    ("fixed-conditional-cross-file-forward", "linux-arm64"),
    ("fixed-conditional-cross-file-forward", "freebsd-arm64"),
    ("fixed-conditional-generic-activity", "cortex-m0"),
    ("fixed-conditional-generic-activity", "darwin-arm64"),
    ("fixed-conditional-generic-activity", "linux-arm64"),
    ("fixed-conditional-generic-activity", "freebsd-arm64"),
    ("fixed-conditional-nested-inactive", "cortex-m0"),
    ("fixed-conditional-nested-inactive", "darwin-arm64"),
    ("fixed-conditional-nested-inactive", "linux-arm64"),
    ("fixed-conditional-nested-inactive", "freebsd-arm64"),
    ("fixed-conditional-selects-declarations", "cortex-m0"),
    ("fixed-conditional-selects-declarations", "darwin-arm64"),
    ("fixed-conditional-selects-declarations", "linux-arm64"),
    ("fixed-conditional-selects-declarations", "freebsd-arm64"),
    ("r440-array-callback-type-argument", "cortex-m0"),
    ("r440-c-aliases", "cortex-m0"),
    ("r440-c-aliases", "darwin-arm64"),
    ("r440-c-aliases", "linux-arm64"),
    ("r440-c-aliases", "freebsd-arm64"),
    ("r440-c-layout-recursive-callback", "cortex-m0"),
    ("r440-c-signatures", "cortex-m0"),
    ("r440-checker-helper-normalized-imports", "cortex-m0"),
    ("r440-checker-recursive-callback-contexts", "cortex-m0"),
    ("r440-checker-recursive-contexts", "cortex-m0"),
    ("r440-compatible-link-declarations", "cortex-m0"),
    ("r440-external-float", "cortex-m0"),
    ("r491-generic-pointee-layout", "cortex-m0"),
    ("r491-symbolic-c-layout", "cortex-m0"),
    ("r630-memory-scalars", "cortex-m0"),
    ("r660-machine-directives", "cortex-m0"),
}
BASE_EXPECTED_REFUSALS = {
    "%s|%s|%s" % (fixture, target, mode)
    for fixture, target in REFUSAL_PAIRS for mode in MODES
} | {
    #  This fixture asserts that the build mode is debug.
    "r430-fixed-options|%s|release" % target for target in TARGETS
}
EXPECTED_REFUSALS = {
    f"{key}|optimize={optimize}|specialize={specialize}"
    for key in BASE_EXPECTED_REFUSALS for optimize in OPTIMIZATIONS
    for specialize in SPECIALIZATIONS
}
DIGEST = re.compile(r"[0-9a-f]{64}\Z")


def evidence_faults(manifest):
    """Reject a shared refusal wherever assembly is promised."""
    faults = []
    emitted = 0
    for key, value in sorted(manifest.items()):
        if isinstance(value, str) and DIGEST.fullmatch(value):
            emitted += 1
        elif value == "refused:1" and key in EXPECTED_REFUSALS:
            continue
        else:
            faults.append("%s has unexpected emission result %r" % (key, value))
    if not emitted:
        faults.insert(0, "no assembly digest was emitted")
    return faults


def report_faults(faults):
    for line in faults[:40]:
        print("  " + line, file=sys.stderr)
    if len(faults) > 40:
        print("  ... and %d more" % (len(faults) - 40), file=sys.stderr)


def operands(fixture):
    """The operands the harness hands `refine` for FIXTURE, relative to it.

    `compiler/tests/README.md` defines the keys: a `root` makes the
    directory the entry module and is passed first as `--root`; otherwise
    `program` is the file the fixture is named for and `with` is the rest
    of the module after it.  A fixture that names no program is a fault
    here rather than a skip.
    """
    meta = {}
    for line in (fixture / "fixture.meta").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and ":" in line:
            key, value = line.split(":", 1)
            meta[key.strip()] = value.strip()
    if not meta.get("program"):
        raise SystemExit("%s: fixture.meta names no program" % fixture.name)
    if meta.get("root"):
        return ["--root=" + meta["root"], "."]
    rest = [one.strip() for one in meta.get("with", "").split(",") if one.strip()]
    return [meta["program"]] + rest


def compile_one(job):
    """Compile one entry in its own directory, including any sidecars."""
    key, refine, fixture, sources, target, mode, optimize, specialize, asm = job
    asm.parent.mkdir()
    #  cwd and operands preserve the source-path spelling on every host.
    result = subprocess.run(
        [str(refine), "--target=" + target, "--build-mode=" + mode,
         "--optimize=" + optimize, "--specialize=" + specialize, "--emit=asm",
         "-o", str(asm)] + sources,
        capture_output=True, cwd=fixture)
    if result.returncode != 0 or not asm.exists():
        return key, "refused:%d" % result.returncode
    return key, hashlib.sha256(asm.read_bytes()).hexdigest()


def emit(refine, root, out, workers=None):
    refine = Path(refine).resolve()
    fixtures = sorted(
        p for p in (Path(root).resolve() / "compiler/tests/fixtures/positive").iterdir()
        if p.is_dir())
    if workers is None:
        workers = min(MAX_WORKERS, os.cpu_count() or 1)
    manifest, refused = {}, 0
    with tempfile.TemporaryDirectory() as tmp:
        jobs = []
        for fixture in fixtures:
            sources = operands(fixture)
            for target in TARGETS:
                for mode in MODES:
                    for optimize in OPTIMIZATIONS:
                        for specialize in SPECIALIZATIONS:
                            key = (f"{fixture.name}|{target}|{mode}|"
                                   f"optimize={optimize}|specialize={specialize}")
                            asm = Path(tmp) / str(len(jobs)) / "out.s"
                            jobs.append((key, refine, fixture, sources, target,
                                         mode, optimize, specialize, asm))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            # Preserve inventory order regardless of completion order.
            for key, value in pool.map(compile_one, jobs):
                manifest[key] = value
                refused += value.startswith("refused:")
    Path(out).write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    print("fixtures %d  entries %d  emitted %d  refused %d"
          % (len(fixtures), len(manifest), len(manifest) - refused, refused))
    print("manifest sha256:", hashlib.sha256(Path(out).read_bytes()).hexdigest())
    faults = evidence_faults(manifest)
    if faults:
        print("manifest lacks required assembly evidence: %d fault(s)" % len(faults),
              file=sys.stderr)
        report_faults(faults)
        return 1
    return 0


def compare(paths):
    """Every manifest agrees, entry by entry, and says which one does not."""
    loaded = [(Path(p).name, json.loads(Path(p).read_text())) for p in paths]
    if len(loaded) < 2:
        print("compare: needs at least two manifests", file=sys.stderr)
        return 2
    (first_name, first), rest = loaded[0], loaded[1:]
    faults = []
    for name, manifest in loaded:
        faults.extend("%s: %s" % (name, fault)
                      for fault in evidence_faults(manifest))
    for name, other in rest:
        missing = sorted(set(first) - set(other))
        added = sorted(set(other) - set(first))
        for key in missing:
            faults.append("%s: %s is absent" % (name, key))
        for key in added:
            faults.append("%s: %s is not in %s" % (name, key, first_name))
        for key in sorted(set(first) & set(other)):
            if first[key] != other[key]:
                faults.append("%s: %s is %s, %s has %s"
                              % (name, key, other[key][:16], first_name, first[key][:16]))
    if faults:
        print("emission is not host-neutral evidence: %d fault(s)" % len(faults),
              file=sys.stderr)
        report_faults(faults)
        return 1
    print("%d manifests agree on all %d entries" % (len(loaded), len(first)))
    return 0


def main(argv):
    if len(argv) == 5 and argv[1] == "emit":
        return emit(argv[2], argv[3], argv[4])
    #  One manifest reaches compare() rather than the usage text, so that
    #  "a comparison needs two sides" is said by the check and not by an
    #  argument count.  A shell glob that matched one file is exactly how
    #  this arrives, and it must not look like a pass.
    if len(argv) >= 3 and argv[1] == "compare":
        return compare(argv[2:])
    print("usage: emit_manifest.py emit REFINE ROOT OUT.json", file=sys.stderr)
    print("       emit_manifest.py compare A.json B.json [...]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
