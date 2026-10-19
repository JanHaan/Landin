#!/usr/bin/env python3
"""Make a new fixture known everywhere a fixture has to be known.

    python3 scripts/add_fixture.py CLASS/NAME [--refuse=L0015 --reason=TEXT]

Write the fixture first, `compiler/tests/fixtures/CLASS/NAME/fixture.meta`
and its files, as compiler/tests/README.md says.  This then

1. reads its metadata as the test program does, and stops on any fault;
2. for a runtime or ABI fixture without one, adds its row to
   compiler/tests/cortex-m/corpus.json: `execute` for a runtime fixture,
   `refuse` with the codes `--refuse` names for one the Cortex-M0 source
   check refuses, and for an ABI fixture, which needs a hosted C peer, a
   `restriction` row whose witness is its own metadata -- each refusal and
   restriction with the `--reason` it is given;
3. regenerates the files the corpus is read into, `check.py --coverage`,
   `--matrix` and `--tokens`;
4. says what is left that only a person can decide: a Linux x86-64
   runtime or ABI fixture that does not name `linux-arm64` needs a record
   in compiler/tests/linux-arm64/parity.json saying why and what runs on
   arm64 instead.

Then run its own lane, `./scripts/dev-test.sh --fixture=CLASS/NAME`, and
`python3 check.py`.  A Cortex-M row it guessed wrong is found by the
Cortex-M corpus, which says what row to write instead.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "compiler/tests"))

import fixture_meta  # noqa: E402

CORPUS = ROOT / "compiler/tests/cortex-m/corpus.json"
ARM64_PARITY = ROOT / "compiler/tests/linux-arm64/parity.json"
GENERATED = ("--coverage", "--matrix", "--tokens")


def corpus_row(meta, refuse, reason):
    """The Cortex-M corpus row a new runtime or ABI fixture starts with."""
    if meta.cls == "abi":
        if not reason:
            raise SystemExit(
                "%s: an ABI fixture's C peer is hosted, so the Cortex-M"
                " corpus records it as a restriction; say why with"
                " --reason=TEXT" % meta.label)
        return {"mode": "restriction", "reason": reason,
                "witness": "compiler/tests/fixtures/%s/fixture.meta"
                           % meta.label}
    if refuse:
        if not reason:
            raise SystemExit("%s: a refusal needs --reason=TEXT"
                             % meta.label)
        return {"codes": [one.strip() for one in refuse.split(",")],
                "mode": "refuse", "reason": reason}
    if meta.get("stdin"):
        raise SystemExit(
            "%s reads standard input, which firmware has none of; name the"
            " codes its Cortex-M0 compilation refuses it with,"
            " --refuse=CODES --reason=TEXT, as runtime/word-count's row"
            " does" % meta.label)
    return {"mode": "execute"}


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("fixture", metavar="CLASS/NAME")
    parser.add_argument("--refuse", metavar="CODES",
                        help="the codes Cortex-M0 refuses a runtime fixture"
                             " with, comma separated")
    parser.add_argument("--reason", help="why Cortex-M0 does not run it")
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
            record["fixtures"][meta.label] = corpus_row(
                meta, args.refuse, args.reason)
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
