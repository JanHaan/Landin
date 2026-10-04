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
artifacts are made.  Every fixture with `args` also gets a `recorded` entry:
its exact invocation is run from `compiler/ada`, including fixtures without
a program.  That entry compares status and both output streams; the recorded
invocation does not request the extra artifacts of a manifest compilation.

The two revisions must see the same bytes under the same spellings, so the
fixtures are read from one ROOT for both.  Manifest compilations run from
each fixture directory and write under WORK; recorded invocations run from
ROOT/compiler/ada, as the fixture harness does.  Tier 2 of the determinism
contract holds under exactly that relation.

    emit REFINE ROOT WORK OUT.json   write this compiler's manifest
    emit --targets=A,B REFINE ROOT WORK OUT.json
                                     for those targets only, so a compiler
                                     that predates a target is compared on
                                     the ones it has
    compare A.json B.json            require the two to agree
    compare --report-only A.json B.json
                                     require them to agree except where a
                                     report gained help lines or warnings

A change that adds to reports -- a fix a diagnostic offers, a warning a
lint raises -- is held to adding and to nothing else.  Each entry records
`errors`, the report with every `  = help:` line and every whole
`warning[...]` block removed, and `stderr_base64`, the raw report needed
to check direction.  `--report-only` requires every other field equal and
checks that the old report remains in order, with only new help lines or
whole warning blocks inserted.  Entries whose reports grew are named.

    compare --layout-only A.json B.json
                                     require them to agree except where a
                                     source's space changed

A change to the space of the sources themselves -- `refine fmt` over a
module -- moves byte offsets and columns and nothing else, and is compared
with one compiler over the two trees.  Each entry also records `layout`:
the assembly with `.loc` columns, DWARF source line/column attributes and the
compilation directory, the build identity and every panic site's number
removed; the build report with its source digests and byte spans removed; and
the source map with its digests,
lengths, line offsets and panic bases removed.  `--layout-only` requires
status, output and report equal as they are, and `layout` equal where the
raw artefacts differ.  A line that moved would show in a `.loc`'s line and
in a report's line numbers, so both still count.

Manifest compilations use each target's default CPU feature level, which the
build report names as `"level"`.  That member is taken out before the report
is digested, so a compiler that names the level and one that predates levels
are compared on everything else; the level itself is recorded as `level`,
and a manifest that has it is compared with one that does not as though it
were absent only when it is the default.  Recorded invocations use any level
selected by their `args`.
"""
import base64
import binascii
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

TARGETS = ("linux-x86-64", "linux-arm64", "darwin-arm64", "cortex-m0")
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


def text_digest(data):
    return hashlib.sha256(data).hexdigest()


DIAGNOSTIC = re.compile(rb"(?:error|warning|note)\[L\d{4}\]: ")


def report_parts(report):
    """Return (bytes, may_be_added) units of a rendered report.

    A diagnostic's block begins with its level and code, `error[`,
    `warning[` or `note[`, at the start of a line; a warning's runs until
    the next such line.  Not every other line is indented: a snippet's
    gutter holds its line number, which reaches the first column once the
    number is as wide as the gutter.  Help lines are indented, one per
    fix, after the notes.
    """
    parts = []
    warning = []
    for line in report.splitlines(keepends=True):
        if DIAGNOSTIC.match(line):
            if warning:
                parts.append((b"".join(warning), True))
                warning = []
            if line.startswith(b"warning["):
                warning.append(line)
                continue
        if warning:
            warning.append(line)
            continue
        parts.append((line, line.startswith(b"  = help: ")))
    if warning:
        parts.append((b"".join(warning), True))
    return parts


def without_additions(report):
    """A report with its help lines and warning blocks taken out."""
    return b"".join(data for data, allowed in report_parts(report)
                    if not allowed)


def report_bytes(entry):
    """Decode and verify a report; old digest-only manifests fail closed."""
    try:
        report = base64.b64decode(entry["stderr_base64"], validate=True)
    except (KeyError, TypeError, ValueError, binascii.Error):
        return None
    if (text_digest(report) != entry.get("stderr") or
            text_digest(without_additions(report)) != entry.get("errors")):
        return None
    return report


def only_report_additions(old, new):
    """Keep every old unit in order; skip only newly added allowed units.

    A warning is a unit when it is newly added, but an existing warning may
    gain help lines among its existing lines.  Keep multiple possible matches
    so repeated warnings do not make the choice of an added block ambiguous.
    """
    old_parts = report_parts(old)
    new_parts = report_parts(new)
    positions = {0}
    for data, allowed in new_parts:
        following = set()
        for position in positions:
            if position < len(old_parts):
                old_data = old_parts[position][0]
                if data == old_data or (
                        data.startswith(b"warning[") and
                        old_data.startswith(b"warning[") and
                        help_added_to_warning(old_data, data)):
                    following.add(position + 1)
            if allowed:
                following.add(position)
        if not following:
            return False
        positions = following
    return len(old_parts) in positions


def help_added_to_warning(old, new):
    """Require every old warning line in order; allow only new help lines."""
    old_lines = old.splitlines(keepends=True)
    position = 0
    for line in new.splitlines(keepends=True):
        if position < len(old_lines) and line == old_lines[position]:
            position += 1
        elif not line.startswith(b"  = help: "):
            return False
    return position == len(old_lines)


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
#  The full-debug emitter writes a routine's source, line and column after
#  its frame-base expression. Parameters and locals put them between a type
#  reference and a location-list reference. Preserve the source number and
#  every other DIE byte. Cortex-M's line-only DIE spells the three operands
#  on one line instead.
DWARF_ROUTINE = re.compile(
    rb"(^[ \t]*\.quad [^\n]*debug_end_[^\n]*\n"
    rb"[ \t]*\.uleb128 1\n[ \t]*\.byte (?:0x[0-9a-f]+|\d+)\n"
    rb"[ \t]*\.uleb128 \d+\n[ \t]*\.uleb128 )\d+"
    rb"(\n[ \t]*\.uleb128 )\d+(?=\n)", re.M)
DWARF_VARIABLE = re.compile(
    rb"(^[ \t]*\.long [^\n]*debug_type_[^\n]*\n"
    rb"[ \t]*\.uleb128 \d+\n[ \t]*\.uleb128 )\d+"
    rb"(\n[ \t]*\.uleb128 )\d+"
    rb"(?=\n[ \t]*\.long [^\n]*debug_(?:alias_)?loc_)", re.M)
DWARF_LINE_ROUTINE = re.compile(
    rb"(^[ \t]*\.(?:long|quad) [^\n]*debug_begin_[^\n]*\n"
    rb"[ \t]*\.(?:long|quad) [^\n]*debug_end_[^\n]*\n"
    rb"[ \t]*\.uleb128 \d+,)\d+,\d+(?=\r?$)", re.M)
#  Manifest revisions compile from distinct fixture trees. The CU directory
#  reflects that path, while the following DIEs still describe the program.
DWARF_COMP_DIR = re.compile(
    rb'(^[ \t]*\.uleb128 1\n'
    rb'[ \t]*\.asciz "Landin refine(?: \(lines\))?"\n'
    rb'[ \t]*\.short 0x0002\n[ \t]*\.asciz [^\n]+\n'
    rb'[ \t]*\.asciz )[^\n]+', re.M)
LEVEL = re.compile(rb',"level":"([^"]*)"')
SPANS = re.compile(rb'"(?:sha256|source_sha256|assembly_sha256|build_id|'
                   rb'first|last|byte_length|panic_base)":\s*("[^"]*"|\d+)')
OFFSETS = re.compile(rb'"line_offsets":\[[^\]]*\]')


def normalize_layout_assembly(assembly):
    """Discard the build ID and normalize only source location fields."""
    kept, section, last = [], b"", 0

    def keep(part):
        if b"landin_id" in section:
            return b""
        if b".debug_info" in section or b"__debug_info" in section:
            part = DWARF_COMP_DIR.sub(rb'\g<1>"DIRECTORY"', part)
            part = DWARF_ROUTINE.sub(rb"\g<1>LINE\g<2>COLUMN", part)
            part = DWARF_VARIABLE.sub(rb"\g<1>LINE\g<2>COLUMN", part)
            part = DWARF_LINE_ROUTINE.sub(rb"\g<1>LINE,COLUMN", part)
        return part

    for found in SECTION.finditer(assembly):
        kept.append(keep(assembly[last:found.start()]))
        section = found.group(0)
        last = found.start()
    kept.append(keep(assembly[last:]))
    return b"".join(kept)


def layout_digest(assembly, report, maps):
    """The artefacts with what a change of space moves taken out."""
    code = IDENTITY.sub(b"", assembly)
    code = normalize_layout_assembly(code)
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
    assembly = asm.read_bytes() if asm.exists() else None
    built = report.read_bytes() if report.exists() else None
    named = LEVEL.search(built) if built is not None else None
    if named:
        built = LEVEL.sub(b"", built, count=1)
    entry = {
        "status": result.returncode,
        "stdout": text_digest(result.stdout),
        "stderr": text_digest(result.stderr),
        "stderr_base64": base64.b64encode(result.stderr).decode("ascii"),
        "errors": text_digest(without_additions(result.stderr)),
        "asm": "absent" if assembly is None else text_digest(assembly),
        "report": "absent" if built is None else text_digest(built),
    }
    if named:
        entry["level"] = named.group(1).decode()
    maps = sorted(p for p in out.iterdir() if p.name not in
                  ("out.s", "build.json"))
    artifacts = [(extra.name, extra.read_bytes()) for extra in maps]
    for name, data in artifacts:
        entry["file:" + name] = text_digest(data)
    entry["layout"] = layout_digest(
        assembly if assembly is not None else b"",
        built if built is not None else b"",
        [data for _, data in artifacts])
    shutil.rmtree(out)
    return entry


def run_recorded(refine, root, args):
    """The fixture harness's invocation, without manifest-only options."""
    result = subprocess.run([str(refine)] + args.split(), capture_output=True,
                            cwd=root / "compiler/ada")
    return {
        "status": result.returncode,
        "stdout": text_digest(result.stdout),
        "stderr": text_digest(result.stderr),
        "stderr_base64": base64.b64encode(result.stderr).decode("ascii"),
        "errors": text_digest(without_additions(result.stderr)),
    }


def emit(refine, root, work, out, targets=TARGETS):
    refine = Path(refine).resolve()
    root = Path(root).resolve()
    work = Path(work).resolve()
    if work.exists():
        shutil.rmtree(work)
    jobs = []
    recorded = []
    for klass in CLASSES:
        for fixture in sorted((root / "compiler/tests/fixtures" / klass)
                              .iterdir()):
            if not fixture.is_dir():
                continue
            meta = meta_of(fixture)
            if "args" in meta:
                recorded.append((fixture, meta["args"]))
            if not meta.get("program"):
                continue
            sources = operands(meta)
            variants = ("plain",) if klass == "negative" else (
                "plain", "debug")
            for target in targets:
                for variant in variants:
                    jobs.append((fixture, sources, target, variant))
    manifest = {}
    workers = max(1, (os.cpu_count() or 2) - 2)
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        futures = {
            pool.submit(run_one, refine, f, s, t, v, work):
            "%s/%s|%s|%s" % (f.parent.name, f.name, t, v)
            for f, s, t, v in jobs}
        futures.update({
            pool.submit(run_recorded, refine, root, args):
            "%s/%s|recorded" % (f.parent.name, f.name)
            for f, args in recorded})
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


#  Default levels for manifest compilations without an explicit level.
DEFAULT_LEVEL = {"linux-x86-64": "x86-64-v1", "linux-arm64": "armv8-a",
                 "darwin-arm64": "armv8-a", "cortex-m0": "armv6-m"}

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
            continue
        target = key.split("|")[1]
        for entry in (a[key], b[key]):
            if "level" in entry and entry["level"] == DEFAULT_LEVEL.get(target):
                entry.pop("level")
        if a[key] != b[key]:
            fields = sorted(f for f in set(a[key]) | set(b[key])
                            if a[key].get(f) != b[key].get(f))
            if report_only and fields == ["stderr", "stderr_base64"]:
                old_report = report_bytes(a[key])
                new_report = report_bytes(b[key])
                if (old_report is not None and new_report is not None and
                        only_report_additions(old_report, new_report)):
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
    if len(argv) == 7 and argv[1] == "emit" and argv[2].startswith(
            "--targets="):
        chosen = tuple(argv[2][len("--targets="):].split(","))
        unknown = [t for t in chosen if t not in TARGETS]
        if unknown or not chosen:
            print("driver_manifest.py: unknown target %s"
                  % ", ".join(unknown or ["(none)"]), file=sys.stderr)
            return 2
        return emit(*argv[3:], targets=chosen)
    if len(argv) == 4 and argv[1] == "compare":
        return compare(argv[2], argv[3])
    if len(argv) == 5 and argv[1:3] == ["compare", "--report-only"]:
        return compare(argv[3], argv[4], report_only=True)
    if len(argv) == 5 and argv[1:3] == ["compare", "--layout-only"]:
        return compare(argv[3], argv[4], layout_only=True)
    print("usage: driver_manifest.py emit [--targets=A,B] REFINE ROOT WORK"
          " OUT.json", file=sys.stderr)
    print("       driver_manifest.py compare [--report-only | --layout-only]"
          " A.json B.json", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
