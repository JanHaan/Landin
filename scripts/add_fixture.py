#!/usr/bin/env python3
"""Make a new fixture known everywhere a fixture has to be known.

    python3 scripts/add_fixture.py CLASS/NAME... [--reason=TEXT] [--refine=PATH]

Write the fixture first, `compiler/tests/fixtures/CLASS/NAME/fixture.meta`
and its files, as compiler/tests/README.md says.  Several fixtures may be
named at once; steps 1 to 3 are taken for each in turn, step 4 once for
them all, and steps 5 and 6 say what is left for each.  `--refuse`,
`--reason` and `--stops` describe one fixture's row, so they take one
fixture.  This then

1. reads its metadata as the test program does, and stops on any fault;
2. for a runtime or ABI fixture without one, adds its row to
   compiler/tests/cortex-m/corpus.json.  A runtime fixture is compiled for
   Cortex-M0 with refine, the one `--refine` names or the newest this
   checkout built: one it compiles gets `execute`, and one it refuses gets
   `refuse` with the distinct codes refine gave, sorted, as the corpus
   compares them.  An ABI fixture is compiled the same way, and one that
   compiles and names cortex-m0 gets `execute`, its C peers built
   freestanding by the corpus.  `--stops=WHAT` makes either a
   `restriction` instead, naming what stops it on Cortex-M0, which the
   corpus holds its build to (D986).  Each restriction, and each refusal
   but one whose only code is L0015, takes the `--reason` it is given; the
   corpus reads an L0015 refusal's modules from the refusal itself, so its
   reason says only why, if anything.  `--refuse` still names the codes by
   hand, held to refine's own;
3. puts a positive, runtime or ABI fixture's sources in the layout
   `refine fmt` gives, which `formatting/the corpus is formatted` holds
   them to, unless the fixture names [1750] and its layout is its
   evidence;
4. regenerates every file a fixture is read into, `check.py --generate`:
   the coverage, the matrices, the diagnostic catalogue's owners and the
   tokens among them;
5. says what is left that only a person can decide: a Linux x86-64
   runtime or ABI fixture that does not name `linux-arm64` needs a record
   in compiler/tests/linux-arm64/parity.json saying why and what runs on
   arm64 instead;
6. names, for the fixture's class, every step left, in order.  The
   recordings come first: `--record=lowering` for a positive fixture,
   whose lowering compiler/tests/lowering.ir holds, and
   `--record=CLASS/NAME` for one whose `expect` file is not written yet.
   Only the test program records, and several new fixtures' recordings
   belong in one run of it, so this names them rather than running them.
   Then the one run of the fixture and of every corpus case that reads
   it, the highlighters' integration pass for a source the editor grammar
   parses, and `python3 check.py`.
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "compiler/tests"))

import fixture_meta  # noqa: E402

CORPUS = ROOT / "compiler/tests/cortex-m/corpus.json"
#  The fixtures `formatting/the corpus is formatted` exempts by name, beside
#  every one naming [1750]: their layout is what they show.
LAYOUT_EVIDENCE = ("value-continued-at-any-indentation",
                   "r490-lexical-module-observation")
ARM64_PARITY = ROOT / "compiler/tests/linux-arm64/parity.json"
GENERATED = ("--generate",)


def built_refine():
    """The newest refine this checkout built, or None."""
    found = sorted(ROOT.glob("compiler/ada/build/*/*/bin/refine"),
                   key=lambda path: path.stat().st_mtime, reverse=True)
    return found[0] if found else None


def cortex_codes(meta, directory, refine):
    """The distinct codes refine refuses the fixture with on Cortex-M0,
    sorted as the corpus compares them; [] when it compiles."""
    with tempfile.TemporaryDirectory() as scratch:
        ran = subprocess.run(
            [str(refine), *meta.module_arguments(str(directory)),
             "--target=cortex-m0", "--emit=asm", "-o",
             str(Path(scratch) / "refused.s")],
            capture_output=True, text=True, timeout=900)
    said = ran.stdout + ran.stderr
    if ran.returncode == 0:
        return []
    codes = sorted(set(re.findall(r"error\[(L\d+)\]", said)))
    if ran.returncode != 1 or not codes:
        raise SystemExit("%s: refine ended with %d compiling it for"
                         " Cortex-M0 and gave no diagnostic code:\n%s"
                         % (meta.label, ran.returncode, said))
    if "L0006" in codes:
        raise SystemExit("%s: refine %s found no module it imports (L0006),"
                         " so no library is beside it; pass the built"
                         " compiler with --refine=PATH:\n%s"
                         % (meta.label, refine, said))
    return codes


def held_to_layout(meta):
    """Whether the corpus formatting case holds the fixture's sources to
    the layout refine fmt gives: a positive, runtime or ABI fixture's are,
    unless the fixture's layout is its evidence."""
    return (meta.cls in ("positive", "runtime", "abi")
            and "1750" not in meta.get("constructs", "")
            and meta.name not in LAYOUT_EVIDENCE)


def format_sources(meta, directory, refine):
    """Put the fixture's sources in refine fmt's layout, and return the
    paths of those it changed."""
    sources = sorted(path for path in directory.rglob("*.ldn")
                     if not any(part.startswith(".") for part in
                                path.relative_to(directory).parts))
    before = {path: path.read_bytes() for path in sources}
    ran = subprocess.run([str(refine), "fmt", str(directory)],
                         capture_output=True, text=True, timeout=300)
    if ran.returncode != 0:
        raise SystemExit("%s: refine fmt could not lay out its sources, and"
                         " formatting/the corpus is formatted holds them to"
                         " that layout:\n%s"
                         % (meta.label, ran.stdout + ran.stderr))
    return [path for path in sources if path.read_bytes() != before[path]]


def remaining_steps(meta, expect_written, unformatted=None):
    """What only the test program or another tool does for a fixture of
    META's class, in order: each a command line.

    EXPECT_WRITTEN says whether the fixture's `expect` file exists, and
    UNFORMATTED names the fixture's directory when no refine was here to
    put its sources in the layout."""
    steps = []
    if unformatted:
        steps.append("refine fmt %s, with the refine ./scripts/dev-build.sh"
                     " --compiler-only builds" % unformatted)
    records = []
    if meta.cls == "positive":
        records.append("--record=lowering")
    if meta.get("expect") and not expect_written:
        records.append("--record=" + meta.label)
    if records:
        steps.append("./scripts/dev-test.sh " + " ".join(records))
    #  --fixture runs a program class, or any fixture with a recorded
    #  report.
    cases = []
    if (meta.cls in ("positive", "negative", "runtime", "abi")
            or meta.get("expect")):
        cases.append("--fixture=" + meta.label)
    if meta.cls in ("positive", "negative"):
        cases.append("--case='lexer/agrees with the corpus'")
        if meta.get("program"):
            cases.append("--case='parser/agrees with the corpus'")
    if meta.cls == "positive":
        cases.append("--case='lowering/the recorded corpus is current'")
    if meta.cls in ("positive", "runtime", "abi"):
        cases.append("--case='formatting/the corpus is formatted'")
    if cases:
        steps.append("./scripts/dev-test.sh " + " ".join(cases))
    if meta.cls in ("positive", "runtime", "abi"):
        steps.append("./highlight/test.sh --integration, inside nix develop")
    steps.append("python3 check.py")
    return steps


def combined_steps(each):
    """Several fixtures' remaining steps as one list in the same order: the
    recordings in one run of the test program and the cases in another, as
    the test program takes several selections at once, and every other
    step once."""
    test = "./scripts/dev-test.sh "
    records, cases, others = [], [], []
    for steps in each:
        for step in steps:
            if step.startswith(test):
                into = records if step.startswith(test + "--record") else cases
                for part in re.split(r" (?=--)", step[len(test):]):
                    if part not in into:
                        into.append(part)
            elif step not in others:
                others.append(step)
    #  A layout fix comes before the test program, and the highlighters and
    #  check.py after it, as remaining_steps orders them for one fixture.
    first = [step for step in others if step.startswith("refine fmt")]
    rest = [step for step in others if step not in first]
    return (first + ([test + " ".join(records)] if records else [])
            + ([test + " ".join(cases)] if cases else []) + rest)


def restriction_stops():
    """What may stop a `restriction` row's fixture on Cortex-M0, as the
    corpus names it (environments/cortex-m/backend_corpus.py's STOPS)."""
    sys.path.insert(0, str(ROOT / "environments/cortex-m"))
    import backend_corpus
    return backend_corpus.STOPS


def corpus_row(meta, refuse, reason, refused=None, stops=None):
    """The Cortex-M corpus row a new runtime or ABI fixture starts with.

    REFUSED is the codes Cortex-M0 compilation refused it with, [] when it
    compiled, or None when it was not compiled; REFUSE the codes written
    by hand instead, which must be refine's.  STOPS names what stops a
    restriction (D986), which the corpus holds its build to.
    """
    if stops:
        known = restriction_stops()
        if stops not in known or not reason:
            raise SystemExit(
                "%s: a restriction names what stops it, --stops= one of %s,"
                " and why, --reason=TEXT" % (meta.label, ", ".join(known)))
        return {"mode": "restriction", "reason": reason, "stops": stops}
    if meta.cls == "abi" and not (refused or refuse) \
            and not meta.applies_to("cortex-m0"):
        raise SystemExit(
            "%s: Cortex-M0 compiles it, and the corpus builds its C peers"
            " freestanding and runs it: name cortex-m0 in its targets: and"
            " it gets an execute row, or say what stops it there with"
            " --stops= one of %s and why with --reason=TEXT"
            % (meta.label, ", ".join(restriction_stops())))
    codes = refused or []
    if refuse:
        #  The corpus compares the distinct codes, sorted, so the row holds
        #  those whatever order and repeats a report gave them in.
        codes = sorted({one.strip() for one in refuse.split(",") if one.strip()})
        if refused is not None and codes != refused:
            raise SystemExit(
                "%s: --refuse names %s, and refine refuses it on Cortex-M0"
                " with %s" % (meta.label, ", ".join(codes),
                              ", ".join(refused) or "nothing"))
    if codes:
        #  An import outside the target's namespace scope explains itself:
        #  the corpus reads the refused modules from the refusal.
        if not reason and codes != ["L0015"]:
            raise SystemExit(
                "%s: Cortex-M0 refuses it with %s, and a refusal needs"
                " --reason=TEXT saying why unless its only code is L0015"
                % (meta.label, ", ".join(codes)))
        row = {"codes": codes, "mode": "refuse"}
        if reason:
            row["reason"] = reason
        return row
    hosted = [key + ":" for key in ("stdin", "run_args", "run_files",
                                    "run_expect") if meta.get(key)]
    if hosted:
        raise SystemExit(
            "%s names %s, which firmware cannot give a program, and Cortex-M0"
            " compiles it; give it a status oracle, or make it a restriction"
            " with --stops=oracle and --reason=TEXT"
            % (meta.label, " and ".join(hosted)))
    return {"mode": "execute"}


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("fixtures", metavar="CLASS/NAME", nargs="+")
    parser.add_argument("--refuse", metavar="CODES",
                        help="the codes Cortex-M0 refuses a runtime fixture"
                             " with, comma separated, held to refine's own")
    parser.add_argument("--reason", help="why Cortex-M0 does not run it")
    parser.add_argument("--stops", metavar="WHAT",
                        help="what stops a restriction on Cortex-M0, which the"
                             " corpus holds its build to (D986)")
    parser.add_argument("--refine", type=Path,
                        help="the refine that compiles a runtime or ABI"
                             " fixture for Cortex-M0; the newest this checkout"
                             " built by default")
    args = parser.parse_args(argv)
    if len(args.fixtures) > 1 and (args.refuse or args.reason or args.stops):
        raise SystemExit("--refuse, --reason and --stops describe one"
                         " fixture's row; add %s in a run of its own each"
                         % " and ".join(args.fixtures))

    added = []
    for fixture in args.fixtures:
        directory = ROOT / "compiler/tests/fixtures" / fixture
        if not (directory / fixture_meta.NAME).is_file():
            raise SystemExit("%s has no %s; write the fixture first, as"
                             " compiler/tests/README.md says"
                             % (directory.relative_to(ROOT), fixture_meta.NAME))
        try:
            added.append((directory, fixture_meta.read(directory)))
        except fixture_meta.FixtureError as error:
            raise SystemExit(str(error))

    refine = args.refine or built_refine()
    unformatted = {}
    for directory, meta in added:
        if meta.cls in ("runtime", "abi"):
            record = json.loads(CORPUS.read_text(encoding="utf-8"))
            if meta.label in record["fixtures"]:
                print("%s already has its row in %s" % (
                    meta.label, CORPUS.relative_to(ROOT)), flush=True)
            else:
                refused = None
                if not args.stops:
                    if refine is None:
                        raise SystemExit(
                            "no refine is built here to compile %s for"
                            " Cortex-M0; build it with ./scripts/dev-build.sh"
                            " --compiler-only, or pass --refine=PATH"
                            % meta.label)
                    refused = cortex_codes(meta, directory, refine)
                record["fixtures"][meta.label] = corpus_row(
                    meta, args.refuse, args.reason, refused, args.stops)
                record["fixtures"] = dict(sorted(record["fixtures"].items()))
                CORPUS.write_text(json.dumps(record, indent=2) + "\n",
                                  encoding="utf-8")
                print("added %s to %s as %s" % (
                    meta.label, CORPUS.relative_to(ROOT),
                    record["fixtures"][meta.label]["mode"]), flush=True)

        unformatted[meta.label] = None
        if held_to_layout(meta):
            if refine is None:
                unformatted[meta.label] = str(directory.relative_to(ROOT))
            else:
                for path in format_sources(meta, directory, refine):
                    print("put %s in refine fmt's layout"
                          % path.relative_to(ROOT), flush=True)

    for flag in GENERATED:
        ran = subprocess.run([sys.executable, str(ROOT / "check.py"), flag],
                             cwd=ROOT)
        if ran.returncode != 0:
            raise SystemExit("check.py %s failed; fix what it says and run"
                             " this again" % flag)

    left = []
    parity = json.loads(ARM64_PARITY.read_text(encoding="utf-8"))
    for directory, meta in added:
        if (meta.cls in ("runtime", "abi")
                and meta.applies_to("linux-x86-64")
                and not meta.applies_to("linux-arm64")
                and meta.label not in parity["differences"]):
            left.append(
                "%s: name linux-arm64 in its targets, or give it a record in"
                " %s with the reason it cannot run there and the counterpart"
                " that does" % (meta.label, ARM64_PARITY.relative_to(ROOT)))
    for one in left:
        print("left to do: " + one)
    steps = []
    for directory, meta in added:
        expect_written = bool(meta.get("expect")) and (
            directory / meta["expect"]).is_file()
        steps.append(remaining_steps(meta, expect_written,
                                     unformatted[meta.label]))
    for one in combined_steps(steps):
        print("then run: " + one)
    return 1 if left else 0

if __name__ == "__main__":
    sys.exit(main())
