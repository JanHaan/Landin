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
    compare --report-only A.json B.json
                                     require them to agree except where a
                                     report gained help lines or warnings

A change that adds to reports -- a fix a diagnostic offers, a warning a
lint raises -- is held to adding and to nothing else.  Each entry also
records `errors`, the report with every `  = help:` line and every whole
`warning[...]` block removed, and `--report-only` requires that and every
other field equal, except `stderr` itself, which it lists instead: the
entries whose reports grew are named, and every other difference fails.

    compare --layout-only A.json B.json
                                     require them to agree except where a
                                     source's space changed

A change to the space of the sources themselves -- `refine fmt` over a
module -- moves byte offsets and columns and nothing else, and is compared
with one compiler over the two trees.  Each entry also records `layout`:
the assembly with every `.loc` column, every debug section, the build
identity and every panic site's number removed, the build report with its
source digests and byte spans removed, and the source map with its digests,
lengths, line offsets and panic bases removed.  `--layout-only` requires
status, output and report equal as they are, and `layout` equal where the
raw artefacts differ.  A line that moved would show in a `.loc`'s line and
in a report's line numbers, so both still count.
"""
import concurrent.futures
import hashlib
import json
import os
import re
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


def without_additions(report):
    """A report with its help lines and warning blocks taken out.

    A diagnostic's block begins with its level and code, `error[`,
    `warning[` or `note[`, at the start of a line; a warning's runs until
    the next such line.  Not every other line is indented: a snippet's
    gutter holds its line number, which reaches the first column once the
    number is as wide as the gutter.  Help lines are indented, one per
    fix, after the notes.
    """
    kept = []
    in_warning = False
    for line in report.splitlines(keepends=True):
        if re.match(rb"(?:error|warning|note)\[L\d{4}\]: ", line):
            in_warning = line.startswith(b"warning[")
        if in_warning or line.startswith(b"  = help: "):
            continue
        kept.append(line)
    return b"".join(kept)


#  What a change of space may move, taken out.  See the module header.
LOCATION = re.compile(rb"^(\s*\.loc \d+ \d+) \d+", re.M)
#  A panic site is the handler's second argument, loaded just before the
#  call: %esi on x86-64, x1 on arm64 and r1 on Cortex-M0.  Its number is a
#  byte offset into a source, so a change of space moves it.
SITE = re.compile(rb"^(\s*(?:movl\s+\$|movz\s+x1,\s*#|movk\s+x1,\s*#|"
                  rb"ldr\s+r1,\s*=|movs\s+r1,\s*#))\d+((?:,\s*lsl\s*#\d+)?"
                  rb"(?:,\s*%esi)?)\s*$"
                  rb"(?=(?:\n\s*(?:mov\w*|ldr)\s+[^\n]*)*\n\s*"
                  rb"(?:call|bl|blx)\s+_?panic_handler)", re.M)
SECTION = re.compile(rb"^\s*(?:\.section|\.text|\.data|\.bss)\b.*$", re.M)
IDENTITY = re.compile(rb"^# Landin caller files [0-9a-f]+\n", re.M)
SPANS = re.compile(rb'"(?:sha256|source_sha256|assembly_sha256|build_id|'
                   rb'first|last|byte_length|panic_base)":\s*("[^"]*"|\d+)')
OFFSETS = re.compile(rb'"line_offsets":\[[^\]]*\]')


def without_debug_sections(assembly):
    """The assembly with every section that is debug information, or the
    build identity, removed whole: from its directive to the next one."""
    kept, dropping, last = [], False, 0
    for found in SECTION.finditer(assembly):
        if not dropping:
            kept.append(assembly[last:found.start()])
        line = found.group(0)
        dropping = b"debug" in line or b"landin_id" in line
        last = found.start()
    if not dropping:
        kept.append(assembly[last:])
    return b"".join(kept)


def layout_digest(assembly, report, maps):
    """The artefacts with what a change of space moves taken out."""
    code = IDENTITY.sub(b"", assembly)
    code = without_debug_sections(code)
    code = LOCATION.sub(rb"\1", code)
    code = SITE.sub(rb"\1SITE\2", code)
    parts = [code, SPANS.sub(b"", report)]
    for extra in maps:
        parts.append(OFFSETS.sub(b"", SPANS.sub(b"", extra)))
    return text_digest(b"\0".join(parts))


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
        "errors": text_digest(without_additions(result.stderr)),
        "asm": digest(asm),
        "report": digest(report),
    }
    maps = sorted(p for p in out.iterdir() if p.name not in
                  ("out.s", "build.json"))
    for extra in maps:
        entry["file:" + extra.name] = digest(extra)
    entry["layout"] = layout_digest(
        asm.read_bytes() if asm.exists() else b"",
        report.read_bytes() if report.exists() else b"",
        [extra.read_bytes() for extra in maps])
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


#  What a change of space may move, per field; `layout` stands for them.
MOVED_BY_LAYOUT = {"asm", "report"}


def compare(first, second, report_only=False, layout_only=False):
    a = json.loads(Path(first).read_text())
    b = json.loads(Path(second).read_text())
    faults = []
    grown = []
    moved = []
    for key in sorted(set(a) | set(b)):
        if key not in a or key not in b:
            faults.append("%s: only in one manifest" % key)
        elif a[key] != b[key]:
            fields = sorted(f for f in set(a[key]) | set(b[key])
                            if a[key].get(f) != b[key].get(f))
            if report_only and fields == ["stderr"]:
                grown.append(key)
                continue
            if layout_only and "layout" not in fields and all(
                    f in MOVED_BY_LAYOUT or f.startswith("file:")
                    for f in fields):
                moved.append(key)
                continue
            faults.append("%s: %s differ" % (key, ", ".join(fields)))
    if report_only:
        print("compare: %d reports grew by help lines or warnings"
              % len(grown))
        for line in grown:
            print("  " + line)
    if layout_only:
        print("compare: %d entries moved only by layout" % len(moved))
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
    if len(argv) == 5 and argv[1:3] == ["compare", "--report-only"]:
        return compare(argv[3], argv[4], report_only=True)
    if len(argv) == 5 and argv[1:3] == ["compare", "--layout-only"]:
        return compare(argv[3], argv[4], layout_only=True)
    print("usage: driver_manifest.py emit REFINE ROOT WORK OUT.json",
          file=sys.stderr)
    print("       driver_manifest.py compare [--report-only | --layout-only]"
          " A.json B.json", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
