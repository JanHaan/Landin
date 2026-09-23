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

    emit REFINE ROOT OUT.json     write this host's manifest
    compare A.json B.json [...]   require every manifest to agree
"""
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

TARGETS = ("linux-x86-64", "darwin-arm64", "cortex-m0")
MODES = ("debug", "release")


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


def emit(refine, root, out):
    refine = Path(refine).resolve()
    fixtures = sorted(
        p for p in (Path(root).resolve() / "compiler/tests/fixtures/positive").iterdir()
        if p.is_dir())
    manifest, refused = {}, 0
    with tempfile.TemporaryDirectory() as tmp:
        asm = Path(tmp) / "out.s"
        for fixture in fixtures:
            sources = operands(fixture)
            for target in TARGETS:
                for mode in MODES:
                    if asm.exists():
                        asm.unlink()
                    #  cwd is the fixture, and the operands are relative,
                    #  so the source-path spelling is identical everywhere.
                    result = subprocess.run(
                        [str(refine), "--target=" + target, "--build-mode=" + mode,
                         "--optimize=size", "--specialize=auto", "--emit=asm",
                         "-o", str(asm)] + sources,
                        capture_output=True, cwd=fixture)
                    key = "%s|%s|%s" % (fixture.name, target, mode)
                    if result.returncode != 0 or not asm.exists():
                        manifest[key] = "refused:%d" % result.returncode
                        refused += 1
                    else:
                        manifest[key] = hashlib.sha256(asm.read_bytes()).hexdigest()
    Path(out).write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    print("fixtures %d  entries %d  emitted %d  refused %d"
          % (len(fixtures), len(manifest), len(manifest) - refused, refused))
    print("manifest sha256:", hashlib.sha256(Path(out).read_bytes()).hexdigest())
    return 0


def compare(paths):
    """Every manifest agrees, entry by entry, and says which one does not."""
    loaded = [(Path(p).name, json.loads(Path(p).read_text())) for p in paths]
    if len(loaded) < 2:
        print("compare: needs at least two manifests", file=sys.stderr)
        return 2
    (first_name, first), rest = loaded[0], loaded[1:]
    faults = []
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
        print("emission is not host-neutral: %d disagreement(s)" % len(faults),
              file=sys.stderr)
        for line in faults[:40]:
            print("  " + line, file=sys.stderr)
        if len(faults) > 40:
            print("  ... and %d more" % (len(faults) - 40), file=sys.stderr)
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
