#!/usr/bin/env python3
"""What `refine` does with every fixture, as one manifest to compare.

A change that should not change the compiler's behaviour -- how it holds or
frees its storage, how fast a pass is -- is checked by building the compiler
before and after it and requiring the two manifests to agree entry by entry.
`emit_manifest.py` asks a different question, whether two HOSTS agree, and
covers only the positive fixtures' target code; this one is run on one host
against two revisions, and records everything the driver hands back: the exit
status, standard output, the rendered report on standard error, the emitted
assembly, the build report and the source/panic map.

Every fixture that names a program is compiled, whatever its class, on every
target: a negative fixture's verdict is its report, and a program a target
refuses is a verdict too.  Each is compiled once with `--emit=asm` and the
build report, and each program that is not a negative is compiled again with
debugging information and the panic map, where the source-identifying
artifacts are made.

The two revisions must see the same bytes under the same spellings, so the
fixtures are read from one ROOT for both, each is compiled from its own
directory under the operands its `fixture.meta` names, and every output goes
to the same path under WORK.  Tier 2 of the determinism contract holds under
exactly that relation.

    emit REFINE ROOT WORK OUT.json   write this compiler's manifest
    compare A.json B.json            require the two to agree
"""
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

TARGETS = ("linux-x86-64", "darwin-arm64", "cortex-m0")
CLASSES = ("positive", "negative", "runtime", "abi", "end-to-end")


def meta_of(fixture):
    meta = {}
    for line in (fixture / "fixture.meta").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and ":" in line:
            key, value = line.split(":", 1)
            meta[key.strip()] = value.strip()
    return meta


def operands(meta):
    if meta.get("root"):
        return ["--root=" + meta["root"], "."]
    rest = [one.strip() for one in meta.get("with", "").split(",")
            if one.strip()]
    return [meta["program"]] + rest


def digest(path):
    if not path.exists():
        return "absent"
    return hashlib.sha256(path.read_bytes()).hexdigest()


def text_digest(data):
    return hashlib.sha256(data).hexdigest()


def run_one(refine, fixture, sources, target, variant, work):
    """One compilation, and every artifact it produced, as digests."""
    out = work / fixture.parent.name / fixture.name / target / variant
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    asm = out / "out.s"
    report = out / "build.json"
    command = [str(refine), "--target=" + target, "--emit=asm",
               "-o", str(asm), "--build-report=" + str(report)]
    if variant == "debug":
        command += ["--build-mode=debug", "--panic-map",
                    "--debug=" + ("lines" if target == "cortex-m0"
                                  else "full")]
    else:
        command += ["--build-mode=release"]
    result = subprocess.run(command + sources, capture_output=True,
                            cwd=fixture)
    entry = {
        "status": result.returncode,
        "stdout": text_digest(result.stdout),
        "stderr": text_digest(result.stderr),
        "asm": digest(asm),
        "report": digest(report),
    }
    maps = sorted(p for p in out.iterdir() if p.name not in
                  ("out.s", "build.json"))
    for extra in maps:
        entry["file:" + extra.name] = digest(extra)
    shutil.rmtree(out)
    return entry


def emit(refine, root, work, out):
    refine = Path(refine).resolve()
    root = Path(root).resolve()
    work = Path(work).resolve()
    if work.exists():
        shutil.rmtree(work)
    jobs = []
    for klass in CLASSES:
        for fixture in sorted((root / "compiler/tests/fixtures" / klass)
                              .iterdir()):
            if not fixture.is_dir():
                continue
            meta = meta_of(fixture)
            if not meta.get("program"):
                continue
            sources = operands(meta)
            variants = ("plain",) if klass == "negative" else (
                "plain", "debug")
            for target in TARGETS:
                for variant in variants:
                    jobs.append((fixture, sources, target, variant))
    manifest = {}
    workers = max(1, (os.cpu_count() or 2) - 2)
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        futures = {
            pool.submit(run_one, refine, f, s, t, v, work):
            "%s/%s|%s|%s" % (f.parent.name, f.name, t, v)
            for f, s, t, v in jobs}
        for done in concurrent.futures.as_completed(futures):
            manifest[futures[done]] = done.result()
    shutil.rmtree(work, ignore_errors=True)
    Path(out).write_text(json.dumps(manifest, indent=1, sort_keys=True)
                         + "\n")
    refused = sum(1 for e in manifest.values() if e["status"] != 0)
    print("entries %d  accepted %d  refused %d"
          % (len(manifest), len(manifest) - refused, refused))
    print("manifest sha256:",
          hashlib.sha256(Path(out).read_bytes()).hexdigest())
    return 0


def compare(first, second):
    a = json.loads(Path(first).read_text())
    b = json.loads(Path(second).read_text())
    faults = []
    for key in sorted(set(a) | set(b)):
        if key not in a or key not in b:
            faults.append("%s: only in one manifest" % key)
        elif a[key] != b[key]:
            fields = sorted(f for f in set(a[key]) | set(b[key])
                            if a[key].get(f) != b[key].get(f))
            faults.append("%s: %s differ" % (key, ", ".join(fields)))
    if faults:
        print("compare: %d of %d entries differ" % (len(faults), len(a)),
              file=sys.stderr)
        for line in faults[:40]:
            print("  " + line, file=sys.stderr)
        if len(faults) > 40:
            print("  ... and %d more" % (len(faults) - 40), file=sys.stderr)
        return 1
    print("compare: %d entries agree" % len(a))
    return 0


def main(argv):
    if len(argv) == 6 and argv[1] == "emit":
        return emit(*argv[2:])
    if len(argv) == 4 and argv[1] == "compare":
        return compare(argv[2], argv[3])
    print("usage: driver_manifest.py emit REFINE ROOT WORK OUT.json",
          file=sys.stderr)
    print("       driver_manifest.py compare A.json B.json",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
