#!/usr/bin/env python3
"""Make a new fixture known everywhere a fixture has to be known.

    python3 scripts/add_fixture.py CLASS/NAME [--reason=TEXT] [--refine=PATH]

Write the fixture first, `compiler/tests/fixtures/CLASS/NAME/fixture.meta`
and its files, as compiler/tests/README.md says.  This then

1. reads its metadata as the test program does, and stops on any fault;
2. for a runtime or ABI fixture without one, adds its row to
   compiler/tests/cortex-m/corpus.json.  A runtime fixture is compiled for
   Cortex-M0 with refine, the one `--refine` names or the newest this
   checkout built: one it compiles gets `execute`, and one it refuses gets
   `refuse` with the distinct codes refine gave, sorted, as the corpus
   compares them.  An ABI fixture, which needs a hosted C peer, gets a
   `restriction` row whose witness is its own metadata.  Each restriction,
   and each refusal but one whose only code is L0015, takes the `--reason`
   it is given; the corpus reads an L0015 refusal's modules from the
   refusal itself, so its reason says only why, if anything.  `--refuse`
   still names the codes by hand, held to refine's own;
3. regenerates every file a fixture is read into, `check.py --generate`:
   the coverage, the matrices, the diagnostic catalogue's owners and the
   tokens among them;
4. says what is left that only a person can decide: a Linux x86-64
   runtime or ABI fixture that does not name `linux-arm64` needs a record
   in compiler/tests/linux-arm64/parity.json saying why and what runs on
   arm64 instead.

Then run its own lane, `./scripts/dev-test.sh --fixture=CLASS/NAME`, and
`python3 check.py`.
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


def corpus_row(meta, refuse, reason, refused=None):
    """The Cortex-M corpus row a new runtime or ABI fixture starts with.

    REFUSED is the codes Cortex-M0 compilation refused it with, [] when it
    compiled, or None when it was not compiled; REFUSE the codes written
    by hand instead, which must be refine's.
    """
    if meta.cls == "abi":
        if not reason:
            raise SystemExit(
                "%s: an ABI fixture's C peer is hosted, so the Cortex-M"
                " corpus records it as a restriction; say why with"
                " --reason=TEXT" % meta.label)
        return {"mode": "restriction", "reason": reason,
                "witness": "compiler/tests/fixtures/%s/fixture.meta"
                           % meta.label}
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
            " compiles it; give it a status oracle, or write a restriction"
            " row with its reason in %s"
            % (meta.label, " and ".join(hosted), CORPUS.relative_to(ROOT)))
    return {"mode": "execute"}


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("fixture", metavar="CLASS/NAME")
    parser.add_argument("--refuse", metavar="CODES",
                        help="the codes Cortex-M0 refuses a runtime fixture"
                             " with, comma separated, held to refine's own")
    parser.add_argument("--reason", help="why Cortex-M0 does not run it")
    parser.add_argument("--refine", type=Path,
                        help="the refine that compiles a runtime fixture for"
                             " Cortex-M0; the newest this checkout built by"
                             " default")
    args = parser.parse_args(argv)

    directory = ROOT / "compiler/tests/fixtures" / args.fixture
    if not (directory / fixture_meta.NAME).is_file():
        raise SystemExit("%s has no %s; write the fixture first, as"
                         " compiler/tests/README.md says"
                         % (directory.relative_to(ROOT), fixture_meta.NAME))
    try:
        meta = fixture_meta.read(directory)
    except fixture_meta.FixtureError as error:
        raise SystemExit(str(error))

    if meta.cls in ("runtime", "abi"):
        record = json.loads(CORPUS.read_text(encoding="utf-8"))
        if meta.label in record["fixtures"]:
            print("%s already has its row in %s" % (
                meta.label, CORPUS.relative_to(ROOT)), flush=True)
        else:
            refused = None
            if meta.cls == "runtime":
                refine = args.refine or built_refine()
                if refine is None:
                    raise SystemExit(
                        "no refine is built here to compile %s for"
                        " Cortex-M0; build it with ./scripts/dev-build.sh"
                        " --compiler-only, or pass --refine=PATH"
                        % meta.label)
                refused = cortex_codes(meta, directory, refine)
            record["fixtures"][meta.label] = corpus_row(
                meta, args.refuse, args.reason, refused)
            record["fixtures"] = dict(sorted(record["fixtures"].items()))
            CORPUS.write_text(json.dumps(record, indent=2) + "\n",
                              encoding="utf-8")
            print("added %s to %s as %s" % (
                meta.label, CORPUS.relative_to(ROOT),
                record["fixtures"][meta.label]["mode"]), flush=True)

    for flag in GENERATED:
        ran = subprocess.run([sys.executable, str(ROOT / "check.py"), flag],
                             cwd=ROOT)
        if ran.returncode != 0:
            raise SystemExit("check.py %s failed; fix what it says and run"
                             " this again" % flag)

    left = []
    if (meta.cls in ("runtime", "abi")
            and meta.applies_to("linux-x86-64")
            and not meta.applies_to("linux-arm64")):
        parity = json.loads(ARM64_PARITY.read_text(encoding="utf-8"))
        if meta.label not in parity["differences"]:
            left.append(
                "name linux-arm64 in its targets, or give it a record in %s"
                " with the reason it cannot run there and the counterpart"
                " that does" % ARM64_PARITY.relative_to(ROOT))
    for one in left:
        print("left to do: " + one)
    print("now run ./scripts/dev-test.sh --fixture=%s and python3 check.py"
          % meta.label)
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())
