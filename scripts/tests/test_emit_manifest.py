#!/usr/bin/env python3
"""`emit_manifest.py emit` as a before-and-after tool: its library option
and its progress line, over a stand-in compiler and a two-fixture root."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "compiler/tests"))
_spec = importlib.util.spec_from_file_location(
    "emit_manifest", ROOT / "scripts/emit_manifest.py")
EMIT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(EMIT)

#  A compiler that writes its own arguments as the assembly, so the digest
#  of an entry is a digest of how it was asked for.
REFINE = '''#!/bin/sh
out=
previous=
for argument
do
    if [ "$previous" = -o ]; then out=$argument; fi
    previous=$argument
done
for argument
do
    case $argument in
        --library=*) echo "$argument" >> "$(dirname -- "$0")/libraries" ;;
    esac
done
echo "assembly" > "$out"
'''


class Emit(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        for name in ("one", "two"):
            fixture = self.root / "compiler/tests/fixtures/positive" / name
            fixture.mkdir(parents=True)
            (fixture / "program.ldn").write_text("x: u8 = 1\n")
            (fixture / "fixture.meta").write_text(
                "class: positive\nsummary: a program\nprogram: program.ldn\n"
                "constructs: 0380\ntargets: linux-x86-64\n")
        self.refine = self.root / "refine"
        self.refine.write_text(REFINE)
        self.refine.chmod(0o755)
        self.library = self.root / "library"
        (self.library / "core").mkdir(parents=True)

    def run_main(self, *arguments):
        said, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(said), \
                contextlib.redirect_stderr(errors):
            status = EMIT.main(["emit_manifest.py", "emit", str(self.refine),
                                str(self.root), str(self.root / "out.json"),
                                "linux-x86-64", "--profile=none-off",
                                "--mode=debug", "--jobs=1", *arguments])
        return status, said.getvalue(), errors.getvalue()

    def test_a_named_library_reaches_every_compilation(self):
        status, said, errors = self.run_main("--library=" + str(self.library))
        self.assertEqual(status, 0, errors)
        self.assertIn("fixtures 2  entries 2  emitted 2  refused 0", said)
        self.assertEqual(
            (self.root / "libraries").read_text().splitlines(),
            ["--library=" + str(self.library)] * 2)
        self.assertEqual(len(json.loads(
            (self.root / "out.json").read_text())), 2)

    def test_without_one_refine_finds_its_own(self):
        status, _, errors = self.run_main()
        self.assertEqual(status, 0, errors)
        self.assertFalse((self.root / "libraries").exists())

    def test_a_directory_that_is_no_library_is_refused(self):
        status, _, errors = self.run_main("--library=" + str(self.root))
        self.assertEqual(status, 2)
        self.assertIn("holds no core, hosted or platform directory", errors)
        self.assertFalse((self.root / "out.json").exists())

    def test_a_long_run_says_how_far_it_is(self):
        ticks = iter(range(0, 10000, 40))
        errors = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(errors):
            status = EMIT.emit(
                self.refine, self.root, self.root / "out.json", workers=1,
                targets=("linux-x86-64",), profiles=(("none", "off"),),
                build_modes=("debug",), clock=lambda: next(ticks))
        self.assertEqual(status, 0)
        self.assertEqual(errors.getvalue(),
                         "emit: 1 of 2 entries\nemit: 2 of 2 entries\n")

    def test_a_short_run_says_nothing_more(self):
        status, _, errors = self.run_main()
        self.assertEqual((status, errors), (0, ""))

    def test_the_text_says_how_the_earlier_compiler_is_kept(self):
        for said in ("git worktree add ../before BASE", "--library=DIR",
                     "--profile=none-off --mode=debug",
                     "emit: 41200 of 199674 entries"):
            self.assertIn(said, EMIT.__doc__)


if __name__ == "__main__":
    unittest.main()
