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

The manifest says nothing about how `refine` itself was built: every host
emits with its debug compiler.  The release compiler is the one people run,
and a debug and a release build of one tree once disagreed on the bytes of
every program that decoded text by codepoint, because Ada leaves the order
of a call's actuals open and the two builds emitted two of them in opposite
orders.  `modes` is that half: both builds compile the positive and runtime
corpora, the firmware corpus and the Cortex-M counterparts, at the four
standard profiles, and every result has to agree.

    emit REFINE ROOT OUT.json     write this host's manifest
    compare A.json B.json [...]   require every manifest to agree
    modes DEBUG RELEASE ROOT      require the two compiler builds to agree

The same manifest is how a change that should alter no emitted byte is
shown to: `emit` once with a compiler built before the change and once
with one built after it, both over the same ROOT, then `compare` the two.
For that use `emit` takes selectors, none of which the gate passes, so the
host manifest stays what it is:

    --corpus=positive|runtime|cortex-m   the corpora compiled, repeatable;
                                         positive alone by default.  A
                                         runtime fixture is compiled for
                                         the targets `modes` compiles it
                                         for, linked as its `link:` says
                                         on a hosted one, and
                                         a Cortex-M counterpart for each
                                         firmware target
    --fixture=KIND/NAME                  only these, repeatable, as the
                                         harness's `--fixture=` spells them
    --profile=OPTIMIZE-SPECIALIZE        only these, repeatable, `-` or `/`
    --mode=debug|release                 only this build mode, repeatable
    --debug-info                         every entry again with the
                                         target's source debugging,
                                         `--debug=full` hosted and
                                         `--debug=lines` on firmware,
                                         keyed `|debug=full` or
                                         `|debug=lines`
    --jobs=N                             compilations at once; every core
                                         by default
    --library=DIR                        the library every compilation
                                         uses, the directory that holds
                                         core/, hosted/ and platform/

The earlier compiler has to find a library, and `refine` looks for one
beside itself, so a copy of its executable alone answers every entry with
"no library holding platform/linux was found".  Either keep it where it
was built, in a worktree of the earlier commit:

    git worktree add ../before BASE
    (cd ../before && ./scripts/build.sh --compiler-only)
    emit ../before/compiler/ada/build/TAG/debug/bin/refine ROOT before.json

or copy the executable anywhere and name the library with `--library=DIR`,
for both runs alike when the change leaves the library as it was.  ROOT is
the same checkout both times: it supplies the fixtures, not the compiler.

The whole manifest is about 200,000 compilations, seventy minutes on a
loaded 32-core host, and a comparison needs it twice.  A proof about one
target, profile or fixture names it and takes seconds:

    emit REFINE ROOT OUT.json linux-x86-64 --profile=none-off --mode=debug

While it runs `emit` writes a line to standard error at most every thirty
seconds, `emit: 41200 of 199674 entries`, so a long run is told from a
stuck one.

A manifest is also held to its own expectations: an entry is assembly, or
a refusal that is expected.  For a positive fixture the expected refusals
are the list below; for a runtime fixture they are the ones the firmware
corpus's inventory, `compiler/tests/cortex-m/corpus.json`, records for the
target, which `emit` reads under ROOT and `compare` under the checkout
this script is in.  `compare` reports the two things apart: entries on
which the manifests differ, and entries on which a manifest fails its own
expectations, once when every manifest fails the same ones.

Debug information names the directory it was compiled in, the fixture's
own, and a caller-file digest that follows it, so a `|debug=` entry is
comparable only with one emitted over a ROOT at the same path.  That holds
for a before-and-after on one checkout, and not across hosts, whose
checkouts sit at different paths: the gate's manifest has no such entry.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "compiler/tests"))
import build_lock  # noqa: E402
import fixture_meta  # noqa: E402

TARGETS = ("linux-x86-64", "linux-arm64", "darwin-arm64", "cortex-m0",
           "freebsd-x86-64", "freebsd-arm64", "linux-rv64", "rv32", "xtensa")
MODES = ("debug", "release")
OPTIMIZATIONS = ("none", "size", "speed")
SPECIALIZATIONS = ("off", "auto", "all")
PROFILES = tuple((optimize, specialize) for optimize in OPTIMIZATIONS
                 for specialize in SPECIALIZATIONS)
CORPORA = ("positive", "runtime", "cortex-m")

#  These source/target pairs deliberately refuse in both modes.  Most use
#  target-specific C or machine facilities; the fixed-conditional fixtures
#  select an x86-64-only declaration; from-c imports hosted services Cortex-M
#  has none of; and r440-c-signatures declares the variadic C signatures
#  Cortex-M's AAPCS32 does not call (D922), while its other C signatures and
#  records compile there (D920).  Keep this list explicit: a new shared
#  refusal must not become evidence of equal assembly merely by agreeing on
#  every host.
REFUSAL_PAIRS = {
    #  An array of 2**31 - 1 elements is no object of a 32-bit target.
    ("array-longer-than-a-host-natural", "cortex-m0"),
    ("array-longer-than-a-host-natural", "rv32"),
    ("fixed-conditional-cross-file-forward", "cortex-m0"),
    ("fixed-conditional-cross-file-forward", "darwin-arm64"),
    ("fixed-conditional-cross-file-forward", "linux-arm64"),
    ("fixed-conditional-cross-file-forward", "freebsd-arm64"),
    ("fixed-conditional-cross-file-forward", "linux-rv64"),
    ("fixed-conditional-generic-activity", "cortex-m0"),
    ("fixed-conditional-generic-activity", "darwin-arm64"),
    ("fixed-conditional-generic-activity", "linux-arm64"),
    ("fixed-conditional-generic-activity", "freebsd-arm64"),
    ("fixed-conditional-generic-activity", "linux-rv64"),
    ("fixed-conditional-nested-inactive", "cortex-m0"),
    ("fixed-conditional-nested-inactive", "darwin-arm64"),
    ("fixed-conditional-nested-inactive", "linux-arm64"),
    ("fixed-conditional-nested-inactive", "freebsd-arm64"),
    ("fixed-conditional-nested-inactive", "linux-rv64"),
    ("fixed-conditional-selects-declarations", "cortex-m0"),
    ("fixed-conditional-selects-declarations", "darwin-arm64"),
    ("fixed-conditional-selects-declarations", "linux-arm64"),
    ("fixed-conditional-selects-declarations", "freebsd-arm64"),
    ("fixed-conditional-selects-declarations", "linux-rv64"),
    ("r440-c-aliases", "cortex-m0"),
    ("r440-c-aliases", "darwin-arm64"),
    ("r440-c-aliases", "linux-arm64"),
    ("r440-c-aliases", "freebsd-arm64"),
    ("r440-c-aliases", "linux-rv64"),
    ("r440-c-signatures", "cortex-m0"),
    ("from-c", "cortex-m0"),
    ("r630-memory-scalars", "cortex-m0"),
    ("r660-machine-directives", "cortex-m0"),
    #  A vector placement needs --firmware-entry (L0502), which the
    #  manifest's assembly, an object's, does not name.
    ("firmware-image-from-a-handler", "cortex-m0"),
    #  rv32 has no enabled C ABI (D660, D920), so it refuses every C
    #  fixture cortex-m0 once refused, and r630-memory-scalars' read-modify-write at its
    #  default rv32imc (D690).  assembly-operand-forms has no rv32 arm, and
    #  its last arm's u64 operand is wider than an rv32 register.
    ("assembly-operand-forms", "rv32"),
    ("c-packed-records", "rv32"),
    ("external-scalar-c-boundary", "rv32"),
    ("fixed-conditional-cross-file-forward", "rv32"),
    ("fixed-conditional-generic-activity", "rv32"),
    ("fixed-conditional-nested-inactive", "rv32"),
    ("fixed-conditional-selects-declarations", "rv32"),
    ("from-c", "rv32"),
    ("hosted-initializer-normalized", "rv32"),
    ("r440-array-callback-type-argument", "rv32"),
    ("r440-c-aliases", "rv32"),
    ("r440-c-layout-recursive-callback", "rv32"),
    ("r440-c-signatures", "rv32"),
    ("r440-checker-recursive-callback-contexts", "rv32"),
    ("r440-checker-recursive-contexts", "rv32"),
    ("r440-compatible-link-declarations", "rv32"),
    ("r440-external-float", "rv32"),
    ("r491-generic-pointee-layout", "rv32"),
    ("r491-symbolic-c-layout", "rv32"),
    ("r630-memory-scalars", "rv32"),
    ("written-type-c-function", "rv32"),
}
# Xtensa's firmware surface has the same C-boundary refusals. The default
# configuration also has no read-modify-write atomics or foreign asm arm.
REFUSAL_PAIRS |= {(name, "xtensa") for name, target in REFUSAL_PAIRS
                  if target == "rv32"}
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


def runtime_refusals(root):
    """The (runtime fixture, firmware target) pairs ROOT's corpus refuses.

    The firmware corpus's inventory records them, and `modes` already
    expects them; without them every manifest of the runtime corpus failed
    its own expectations, 96 faults on an unchanged tree.  A ROOT without
    the inventory has none.
    """
    inventory = Path(root).resolve() / "compiler/tests/cortex-m/corpus.json"
    if not inventory.is_file():
        return frozenset()
    return frozenset(pair for pair in mode_refusals(root, FIRMWARE_TARGETS)
                     if pair[0].startswith("runtime/"))


def evidence_faults(manifest, diagnostics=None, runtime=frozenset()):
    """Reject a shared refusal wherever assembly is promised.

    DIAGNOSTICS, where `emit` has them, holds the first diagnostic of each
    refusal, so a fault says why rather than only that it refused.  A
    `|debug=` entry refuses where its entry without debug information does.
    RUNTIME is `runtime_refusals`' pairs, expected at every profile.
    """
    faults = []
    emitted = 0
    for key, value in sorted(manifest.items()):
        bare = re.sub(r"\|level=[^|]+", "", key).split("|debug=")[0]
        if isinstance(value, str) and DIGEST.fullmatch(value):
            emitted += 1
        elif value == "refused:1" and (
                bare in EXPECTED_REFUSALS
                or tuple(bare.split("|")[:2]) in runtime):
            continue
        else:
            said = (diagnostics or {}).get(key)
            faults.append("%s has unexpected emission result %r%s"
                          % (key, value, ": " + said if said else ""))
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
    meta = fixture_meta.read(fixture, strict=False)
    if not meta.get("program"):
        raise SystemExit("%s: fixture.meta names no program" % fixture.name)
    return meta.module_arguments(".")


def levels(fixture):
    """{target: level} for the level FIXTURE's `args` request (D658).

    A fixture is compiled for every target at its default level, except
    the one its `args` name with a `--level`, which is compiled at that
    level as the harness compiles it: a level decides which code is
    emitted, so the default would leave the level's code unchecked.
    """
    args = fixture_meta.read(fixture, strict=False).args
    target = [a.split("=", 1)[1] for a in args if a.startswith("--target=")]
    level = [a.split("=", 1)[1] for a in args if a.startswith("--level=")]
    return {target[-1]: level[-1]} if target and level else {}


def own_target(fixture):
    """The one target FIXTURE is compiled for, or None (D740).

    A fixture whose `targets:` names one target and whose `args` choose it
    with `--target=` is that target's: the harness compiles it there alone,
    and the others refuse it or compile a program nobody runs.  So it is
    compiled for that target only, and a new fixture of one target needs no
    refusal listed for every other.
    """
    meta = fixture_meta.read(fixture, strict=False)
    chosen = [a.split("=", 1)[1] for a in meta.args if a.startswith("--target=")]
    if chosen and tuple(meta.targets) == (chosen[-1],):
        return chosen[-1]
    return None


def first_diagnostic(result):
    """The first diagnostic a refusal printed, with its notes, on one line.

    A refusal is recorded as `refused:STATUS` alone, which is the same
    string on every host; what it said is for the reader of a fault, who
    otherwise has a status and no reason.
    """
    lines = (result.stderr + result.stdout).decode("utf-8", "replace").splitlines()
    said = []
    for line in lines:
        if not line.strip():
            if said:
                break
            continue
        if not said:
            said.append(line.strip())
        elif not line[0].isspace() and not line[0].isdigit():
            break
        elif line.strip().startswith(("-->", "= ")):
            #  Where it is and what to do; the quoted source is neither.
            said.append(line.strip())
    return " ".join(said)


#  `emit --library=DIR`, as an absolute path, since each compilation runs
#  in its fixture's directory; empty when refine finds its own.
LIBRARY = []

#  Seconds between two progress lines of `emit`.
PROGRESS_EVERY = 30.0


def compile_one(job):
    """Compile one entry in its own directory, including any sidecars."""
    (key, refine, fixture, sources, target, level, mode, optimize, specialize,
     debug, asm) = job
    asm.parent.mkdir()
    #  cwd and operands preserve the source-path spelling on every host.
    result = subprocess.run(
        [str(refine), "--target=" + target]
        + (["--level=" + level] if level else [])
        + ["--build-mode=" + mode]
        + ["--optimize=" + optimize, "--specialize=" + specialize]
        + (["--debug=" + debug] if debug else [])
        + (["--library=" + LIBRARY[0]] if LIBRARY else [])
        + ["--emit=asm", "-o", str(asm)] + sources,
        capture_output=True, cwd=fixture)
    if result.returncode != 0 or not asm.exists():
        return key, "refused:%d" % result.returncode, first_diagnostic(result)
    return key, hashlib.sha256(asm.read_bytes()).hexdigest(), None


def configured_levels(target, requested=None):
    """Both independent Xtensa configurations, unless the fixture fixes one."""
    return (requested,) if requested or target != "xtensa" else (
        "xtensa-esp32", "xtensa-esp32s3")


def level_key(target, level):
    return "|level=" + level if target == "xtensa" else ""


def debug_information(target):
    """The source debugging TARGET emits: lines on firmware, full hosted."""
    return "lines" if target in FIRMWARE_TARGETS else "full"


def emit(refine, root, out, workers=None, targets=TARGETS, corpora=("positive",),
         fixtures=(), profiles=PROFILES, build_modes=MODES, debug_info=False,
         library=None, clock=time.monotonic):
    LIBRARY[:] = [str(Path(library).resolve())] if library else []
    #  A rebuild of this build waits until the manifest is written, rather
    #  than replace refine between two of its requests.
    build_lock.reading(refine)
    refine = Path(refine).resolve()
    entries = corpus_entries(root, targets, corpora, fixtures)
    if workers is None:
        workers = os.cpu_count() or 1
    manifest, diagnostics, refused = {}, {}, 0
    with tempfile.TemporaryDirectory() as tmp:
        jobs = []
        for name, directory, sources, wanted, level in entries:
            #  A positive fixture's key is its bare name, as it always was,
            #  so the host manifest the gate compares is unchanged.
            shown = name.split("/", 1)[1] if name.startswith("positive/") else name
            #  A runtime fixture links as its `link:` says on a hosted lane,
            #  and compiled without it can be another program or none.
            link = (fixture_meta.read(directory, strict=False).get("link")
                    if name.startswith("runtime/") else None)
            for target in wanted:
                for selected_level in configured_levels(target, level.get(target)):
                    for debug in (None, debug_information(target)) if debug_info else (None,):
                        for mode in build_modes:
                            for optimize, specialize in profiles:
                                key = (f"{shown}|{target}|{mode}|"
                                       f"optimize={optimize}|specialize={specialize}"
                                       + level_key(target, selected_level)
                                       + (f"|debug={debug}" if debug else ""))
                                asm = Path(tmp) / str(len(jobs)) / "out.s"
                                jobs.append((key, refine, directory,
                                             (["--link=" + link] if link and target
                                              not in FIRMWARE_TARGETS else [])
                                             + sources, target,
                                             selected_level, mode, optimize,
                                             specialize, debug, asm))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            # Preserve inventory order regardless of completion order.
            said_at = clock()
            for key, value, said in pool.map(compile_one, jobs):
                manifest[key] = value
                if clock() - said_at >= PROGRESS_EVERY:
                    said_at = clock()
                    print("emit: %d of %d entries" % (len(manifest), len(jobs)),
                          file=sys.stderr, flush=True)
                refused += value.startswith("refused:")
                if said:
                    diagnostics[key] = said
    Path(out).write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    print("fixtures %d  entries %d  emitted %d  refused %d"
          % (len(entries), len(manifest), len(manifest) - refused, refused))
    print("manifest sha256:", hashlib.sha256(Path(out).read_bytes()).hexdigest())
    faults = evidence_faults(manifest, diagnostics, runtime_refusals(root))
    if faults:
        print("manifest lacks required assembly evidence: %d fault(s)" % len(faults),
              file=sys.stderr)
        report_faults(faults)
        return 1
    return 0


def merge(out, paths):
    """One host's manifest from the parts it emitted, target by target.

    The gate emits each host's targets in two jobs so neither waits for
    the other; compare() holds whole manifests, so the parts are joined
    first, and a key in two parts or a target in none is a fault rather
    than a smaller manifest.
    """
    manifest, faults = {}, []
    for path in paths:
        for key, value in json.loads(Path(path).read_text()).items():
            if key in manifest:
                faults.append("%s: %s is in two parts" % (Path(path).name, key))
            manifest[key] = value
    present = {key.split("|")[1] for key in manifest}
    faults.extend("no part emitted %s" % target
                  for target in TARGETS if target not in present)
    faults.extend("%s is not a target this check emits" % target
                  for target in sorted(present - set(TARGETS)))
    if faults:
        print("parts do not make one manifest: %d fault(s)" % len(faults),
              file=sys.stderr)
        report_faults(faults)
        return 1
    Path(out).write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    print("%d parts make %s: %d entries" % (len(paths), Path(out).name, len(manifest)))
    return 0


def compare(paths, root=Path(__file__).resolve().parents[1]):
    """Every manifest agrees, entry by entry, and says which one does not.

    Two findings are reported apart.  The manifests differ: an entry is
    absent from one, or has another value.  A manifest fails its own
    expectations: an entry is neither assembly nor an expected refusal,
    whatever the other manifests say.  Byte-identical manifests can only
    do the second, and were once told they disagreed.
    """
    loaded = [(Path(p).name, json.loads(Path(p).read_text())) for p in paths]
    if len(loaded) < 2:
        print("compare: needs at least two manifests", file=sys.stderr)
        return 2
    (first_name, first), rest = loaded[0], loaded[1:]
    runtime = runtime_refusals(root)
    own = [(name, evidence_faults(manifest, runtime=runtime))
           for name, manifest in loaded]
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
        #  Two hosts' manifests or two compilers' on one checkout: the
        #  same disagreement means a host leak in one, a change in the other.
        print("the manifests differ, so emission is not host-neutral evidence"
              " or the compilers emit differently: %d difference(s)"
              % len(faults), file=sys.stderr)
        report_faults(faults)
    else:
        print("%d manifests agree on all %d entries" % (len(loaded), len(first)))
    failing = [(name, found) for name, found in own if found]
    if failing and len(failing) == len(own) and all(
            found == failing[0][1] for _, found in failing):
        print("every manifest fails its own expectations, on the same "
              "entries, so this is no difference between them: %d fault(s)"
              % len(failing[0][1]), file=sys.stderr)
        report_faults(failing[0][1])
    else:
        for name, found in failing:
            print("%s fails its own expectations: %d fault(s)"
                  % (name, len(found)), file=sys.stderr)
            report_faults(found)
    return 1 if faults or failing else 0


#  The build-mode comparison: the request is fixed, so only the compiler's
#  own build differs.  One target per backend, and each firmware target,
#  whose program is a different image; the standard profiles are the
#  runtime corpus's own, so each pair is one the harness also executes.
MODE_TARGETS = ("linux-x86-64", "linux-arm64", "cortex-m0", "rv32", "xtensa")
#  The targets the firmware corpus runs its inventory on (D658).
FIRMWARE_TARGETS = ("cortex-m0", "rv32", "xtensa")
STANDARD_PROFILES = (("none", "off"), ("size", "off"), ("size", "auto"),
                     ("speed", "auto"))
def corpus_entries(root, targets, corpora=CORPORA, names=()):
    """(name, directory, operands, targets, levels) for each source compiled.

    A positive fixture is compiled for every target, at the level its `args`
    request on the target they name; a runtime fixture for the targets its
    `targets:` names and for each firmware target the firmware corpus
    executes it on, which is every `execute` row of its inventory, since
    no runtime fixture's `targets:` names rv32 or needs to name cortex-m0
    for the corpus to run it; and a Cortex-M counterpart, which has no
    fixture record and replaces its row's fixture there, for each firmware
    target.  CORPORA chooses among the three, and NAMES, spelt
    `positive/NAME`, `runtime/NAME` or `cortex-m/NAME`, keeps only those.
    """
    tests = Path(root).resolve() / "compiler/tests"
    firmware = tuple(t for t in targets if t in FIRMWARE_TARGETS)
    executed = set()
    if firmware and "runtime" in corpora:
        rows = json.loads((tests / "cortex-m/corpus.json").read_text())["fixtures"]
        executed = {name for name, row in rows.items()
                    if row["mode"] == "execute" and "counterpart" not in row}
    wanted_names = set(names)
    entries = []
    for kind in (one for one in ("positive", "runtime") if one in corpora):
        for fixture in sorted(p for p in (tests / "fixtures" / kind).iterdir()
                              if p.is_dir()):
            if wanted_names and kind + "/" + fixture.name not in wanted_names:
                continue
            own = own_target(fixture) if kind == "positive" else None
            wanted = tuple(t for t in targets if own in (None, t))
            if kind == "runtime":
                #  `targets:` spells each as `--target` does.
                named = fixture_meta.read(fixture, strict=False).targets
                corpus = "runtime/" + fixture.name in executed
                wanted = tuple(t for t in targets if t in named
                               or (corpus and t in firmware))
            if wanted:
                entries.append((kind + "/" + fixture.name, fixture,
                                operands(fixture), wanted, levels(fixture)))
    if firmware and "cortex-m" in corpora:
        for case in sorted(p for p in (tests / "cortex-m/cases").iterdir()
                           if p.is_dir()):
            if wanted_names and "cortex-m/" + case.name not in wanted_names:
                continue
            entries.append(("cortex-m/" + case.name, case, ["main.ldn"],
                            firmware, {}))
    return entries


def mode_entries(root, targets):
    """Every source `modes` compares: the three corpora whole."""
    return corpus_entries(root, targets)


def known_names(root):
    """Every name `--fixture=` may give: each corpus's sources, by kind."""
    tests = Path(root).resolve() / "compiler/tests"
    found = set()
    for kind, where in (("positive", tests / "fixtures/positive"),
                        ("runtime", tests / "fixtures/runtime"),
                        ("cortex-m", tests / "cortex-m/cases")):
        if where.is_dir():
            found.update(kind + "/" + p.name for p in where.iterdir() if p.is_dir())
    return found


def emit_both(job):
    """One request through both compilers: each result, then the key."""
    key, compilers, directory, sources, target, level, optimize, specialize, tmp = job
    results = []
    for n, refine in enumerate(compilers):
        asm = Path(tmp) / ("%d.s" % n)
        result = subprocess.run(
            [str(refine), "--target=" + target]
            + (["--level=" + level] if level else []) + ["--optimize=" + optimize,
             "--specialize=" + specialize, "--emit=asm", "-o", str(asm)]
            + sources, capture_output=True, cwd=directory)
        if result.returncode != 0 or not asm.exists():
            #  A refusal agrees only with the same refusal, said the same way.
            results.append("refused:%d:%s" % (
                result.returncode,
                hashlib.sha256(result.stdout + result.stderr).hexdigest()))
        else:
            results.append(hashlib.sha256(asm.read_bytes()).hexdigest())
        asm.unlink(missing_ok=True)
    return key, results


#  The firmware corpus's lane that runs at the level `--target=rv32` builds
#  when no `--level` is given, rv32imc (D690): the lane whose refusals the
#  inventory records for that request.
MODE_LANES = {"rv32": "esp32c3"}


def mode_refusals(root, targets):
    """What `modes` expects both compilers to refuse, as (source, target).

    They are the positive fixtures `emit` expects refused, and each
    runtime fixture the firmware corpus executes on its reference and
    records as refused on another firmware target, in its inventory's
    `lanes` or `targets`.  Nothing else may be refused by both: a shared
    refusal outside this list is a program the corpus expects to compile.
    """
    found = {("positive/" + fixture, target)
             for fixture, target in REFUSAL_PAIRS}
    inventory = Path(root).resolve() / "compiler/tests/cortex-m/corpus.json"
    if any(target in FIRMWARE_TARGETS for target in targets):
        rows = json.loads(inventory.read_text())["fixtures"]
        for name, row in rows.items():
            if row["mode"] != "execute":
                continue
            for target in targets:
                own = (row.get("lanes", {}).get(MODE_LANES[target])
                       if target in MODE_LANES
                       else row.get("targets", {}).get(target))
                if own and own.get("mode") == "refuse":
                    found.add((name, target))
    return found


def modes(debug, release, root, workers=None, targets=MODE_TARGETS):
    for compiler in (debug, release):
        build_lock.reading(compiler)
    compilers = (Path(debug).resolve(), Path(release).resolve())
    if workers is None:
        workers = os.cpu_count() or 1
    entries = mode_entries(root, targets)
    expected = mode_refusals(root, targets)
    disagree, unexpected, emitted, refused = [], [], 0, 0
    with tempfile.TemporaryDirectory() as tmp:
        jobs = []
        for name, directory, sources, wanted, level in entries:
            link = (fixture_meta.read(directory, strict=False).get("link")
                    if name.startswith("runtime/") else None)
            for target in wanted:
                for selected_level in configured_levels(target, level.get(target)):
                    for optimize, specialize in STANDARD_PROFILES:
                        key = (f"{name}|{target}|"
                               f"optimize={optimize}|specialize={specialize}"
                               + level_key(target, selected_level))
                        scratch = Path(tmp) / str(len(jobs))
                        scratch.mkdir()
                        arguments = (["--link=" + link] if link and target
                                     not in FIRMWARE_TARGETS else []) + sources
                        jobs.append((key, compilers, directory, arguments, target,
                                     selected_level, optimize, specialize, scratch))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            for key, (first, second) in pool.map(emit_both, jobs):
                if first != second:
                    disagree.append("%s: debug %s, release %s"
                                    % (key, first[:24], second[:24]))
                elif first.startswith("refused:"):
                    #  Agreeing is not enough.  Two compilers that both
                    #  crash, or both refuse a program the corpus expects
                    #  to compile, agree too, and would pass as evidence
                    #  that the builds compile alike.
                    status = first.split(":")[1]
                    name, target = key.split("|")[:2]
                    if status != "1":
                        unexpected.append(
                            "%s: both compilers ended with status %s, which "
                            "is no refusal" % (key, status))
                    elif (name, target) not in expected:
                        unexpected.append(
                            "%s: both compilers refuse it, and it is not in "
                            "the expected refusals" % key)
                    else:
                        refused += 1
                else:
                    emitted += 1
    print("sources %d  requests %d  emitted %d  refused as expected %d  "
          "unexpected %d  disagree %d"
          % (len(entries), len(jobs), emitted, refused, len(unexpected),
             len(disagree)))
    faults = sorted(disagree) + sorted(unexpected)
    if not emitted:
        faults.insert(0, "no assembly digest was emitted")
    if faults:
        print("the debug and release compilers do not emit the same bytes: "
              "%d fault(s)" % len(faults), file=sys.stderr)
        report_faults(faults)
        return 1
    return 0


def target_list(text, command):
    """TEXT's comma-separated targets, or None after saying what is wrong."""
    targets = tuple(text.split(","))
    if not text or not set(targets) <= set(TARGETS) or len(set(targets)) != len(targets):
        print("%s: TARGETS must be distinct names from %s" % (command, ", ".join(TARGETS)),
              file=sys.stderr)
        return None
    return targets


def profile(text):
    """`size-auto` or `size/auto` as ("size", "auto"), for argparse."""
    pair = tuple(text.replace("/", "-").split("-", 1))
    if pair not in PROFILES:
        raise argparse.ArgumentTypeError(
            "unknown profile %s; the profiles are %s, written with - or /"
            % (text, ", ".join("-".join(one) for one in PROFILES)))
    return pair


def jobs(text):
    count = int(text)
    if count < 1:
        raise argparse.ArgumentTypeError("--jobs needs one or more")
    return count


def main(argv):
    if len(argv) >= 2 and argv[1] == "emit":
        parser = argparse.ArgumentParser(
            prog="emit_manifest.py emit", allow_abbrev=False,
            description="Write this host's manifest; the selectors make a"
            " smaller one for a before-and-after proof.")
        parser.add_argument("refine")
        parser.add_argument("root")
        parser.add_argument("out")
        parser.add_argument("targets", nargs="?", default=",".join(TARGETS))
        parser.add_argument("--corpus", action="append", choices=CORPORA)
        parser.add_argument("--fixture", action="append", default=[])
        parser.add_argument("--profile", action="append", type=profile)
        parser.add_argument("--mode", action="append", choices=MODES)
        parser.add_argument("--debug-info", action="store_true")
        parser.add_argument("--jobs", type=jobs)
        parser.add_argument("--library")
        given = parser.parse_args(argv[2:])
        targets = target_list(given.targets, "emit")
        if targets is None:
            return 2
        if given.library and not any(
                (Path(given.library) / part).is_dir()
                for part in ("core", "hosted", "platform")):
            print("emit: --library=%s holds no core, hosted or platform"
                  " directory; name the directory that holds them, a"
                  " checkout's root" % given.library, file=sys.stderr)
            return 2
        unknown = sorted(set(given.fixture) - known_names(given.root))
        if unknown:
            print("emit: unknown fixture %s; a fixture is KIND/NAME, a directory"
                  " under compiler/tests/fixtures/positive or runtime, or under"
                  " compiler/tests/cortex-m/cases for KIND cortex-m"
                  % ", ".join(unknown), file=sys.stderr)
            return 2
        #  A named fixture brings its corpus; without names, positive alone.
        corpora = tuple(given.corpus or ()) + tuple(
            name.split("/")[0] for name in given.fixture)
        return emit(given.refine, given.root, given.out, workers=given.jobs,
                    targets=targets, corpora=corpora or ("positive",),
                    fixtures=tuple(given.fixture),
                    profiles=tuple(dict.fromkeys(given.profile or PROFILES)),
                    build_modes=tuple(m for m in MODES if m in (given.mode or MODES)),
                    debug_info=given.debug_info, library=given.library)
    if len(argv) >= 2 and argv[1] == "modes":
        parser = argparse.ArgumentParser(prog="emit_manifest.py modes",
                                         allow_abbrev=False)
        parser.add_argument("debug")
        parser.add_argument("release")
        parser.add_argument("root")
        parser.add_argument("targets", nargs="?", default=",".join(MODE_TARGETS))
        parser.add_argument("--jobs", type=jobs)
        given = parser.parse_args(argv[2:])
        targets = target_list(given.targets, "modes")
        if targets is None:
            return 2
        return modes(given.debug, given.release, given.root, workers=given.jobs,
                     targets=targets)
    if len(argv) >= 4 and argv[1] == "merge":
        return merge(argv[2], argv[3:])
    #  One manifest reaches compare() rather than the usage text, so that
    #  "a comparison needs two sides" is said by the check and not by an
    #  argument count.  A shell glob that matched one file is exactly how
    #  this arrives, and it must not look like a pass.
    if len(argv) >= 3 and argv[1] == "compare":
        return compare(argv[2:])
    print("usage: emit_manifest.py emit REFINE ROOT OUT.json [TARGET,...]\n"
          "           [--corpus=positive|runtime|cortex-m]... [--fixture=KIND/NAME]...\n"
          "           [--profile=OPTIMIZE-SPECIALIZE]... [--mode=debug|release]...\n"
          "           [--debug-info] [--jobs=N]", file=sys.stderr)
    print("       emit_manifest.py merge OUT.json PART.json [...]", file=sys.stderr)
    print("       emit_manifest.py compare A.json B.json [...]", file=sys.stderr)
    print("       emit_manifest.py modes DEBUG RELEASE ROOT [TARGET,...] [--jobs=N]",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
