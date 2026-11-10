#!/usr/bin/env python3
"""scripts/assemble_targets.py emits for other targets and assembles each.

A stub compiler and stub assemblers stand for the real ones, so what is
held is the command's own conduct: which targets it takes, that a missing
assembler is named before anything is compiled, that an assembly its
assembler refuses is a fault that names the entry and keeps the text, and
that an expected refusal is not one.  The machine arguments it gives each
assembler are held to the ones `refine` gives the target's driver, read
from the Ada source, and the documented command is held to this file.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/assemble_targets.py"
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "compiler/tests"))
spec = importlib.util.spec_from_file_location("assemble_targets", SCRIPT)
ASSEMBLE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ASSEMBLE)

#  Seconds before a stubbed run, which ends at once, is called hung.
HANG = 300

#  Writes the target as its assembly; refuses a fixture named `refused`.
REFINE = """#!%s
import pathlib, sys
args = sys.argv[1:]
if pathlib.Path.cwd().name == "refused":
    sys.stderr.write("main.ldn:1:1: error: L0346 no C ABI here\\n")
    sys.exit(1)
target = next(a for a in args if a.startswith("--target="))
pathlib.Path(args[args.index("-o") + 1]).write_text(
    target + " " + pathlib.Path.cwd().name + "\\n")
""" % sys.executable

#  Records its arguments; refuses an assembly that says `broken`.
ASSEMBLER = """#!%s
import os, pathlib, sys
args = sys.argv[1:]
out = pathlib.Path(args[args.index("-o") + 1])
source = pathlib.Path(args[args.index("-o") - 1])
with open(os.environ["CALLS"], "a") as calls:
    calls.write(os.path.basename(sys.argv[0]) + " " + " ".join(
        a for a in args if a not in (str(out), str(source))) + "\\n")
if "broken" in source.read_text():
    sys.stderr.write("out.s: Error: no such instruction: `frobnicate'\\n")
    sys.exit(1)
out.write_text("object")
""" % sys.executable


class AssembleTargets(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="landin-assemble-test-")
        self.addCleanup(temporary.cleanup)
        self.area = Path(temporary.name)
        self.tools = self.area / "tools"
        self.tools.mkdir()
        self.refine = self.area / "refine"
        self.refine.write_text(REFINE)
        self.refine.chmod(0o755)
        self.calls = self.area / "calls"
        self.fixture("positive/plain")

    def fixture(self, name):
        directory = self.area / "compiler/tests/fixtures" / name
        directory.mkdir(parents=True)
        (directory / "fixture.meta").write_text("program: main.ldn\n")
        (directory / "main.ldn").write_text("unused by the stub\n")

    def tool(self, name, text=ASSEMBLER):
        (self.tools / name).write_text(text)
        (self.tools / name).chmod(0o755)

    def every_tool(self):
        for command in ASSEMBLE.ASSEMBLERS.values():
            self.tool(command[0])

    def run_script(self, *arguments):
        #  Only the stubs and the interpreter's own directory are on PATH.
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.refine), str(self.area),
             *arguments], capture_output=True, text=True, timeout=HANG,
            env={**os.environ, "CALLS": str(self.calls),
                 "PATH": str(self.tools)})

    def test_every_target_but_the_hosts_is_assembled_by_its_own_assembler(self):
        self.every_tool()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        host = ASSEMBLE.host_target()
        others = [target for target in ASSEMBLE.emit_manifest.TARGETS
                  if target != host]
        self.assertIn("targets " + ", ".join(others), result.stdout)
        #  Xtensa is two configurations, each with its chip's driver.
        self.assertIn("fixtures 1  requests %d  assembled %d  "
                      % (len(others) + 1, len(others) + 1), result.stdout)
        called = self.calls.read_text().splitlines()
        self.assertEqual(len(called), len(others) + 1)
        for key, command in ASSEMBLE.ASSEMBLERS.items():
            target = key if isinstance(key, str) else key[0]
            line = " ".join(command) + " -o"
            self.assertEqual(line in called, target != host, line)

    def test_a_missing_assembler_is_named_before_anything_is_compiled(self):
        self.tool("clang-19")
        result = self.run_script("darwin-arm64,rv32")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("riscv64-elf-gcc, the assembler for rv32, is not on "
                      "PATH", result.stderr)
        self.assertIn("run this inside nix develop", result.stderr)
        self.assertFalse(self.calls.exists())
        #  Only the targets asked for need their assembler.
        result = self.run_script("darwin-arm64,freebsd-arm64")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_assembly_its_assembler_refuses_is_named_and_kept(self):
        self.tool("clang-19")
        self.fixture("positive/broken")
        kept = self.area / "kept"
        result = self.run_script("darwin-arm64", "--keep=" + str(kept))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("assembled 1  refused as expected 0", result.stdout)
        self.assertIn("faults 1", result.stdout)
        self.assertIn("broken|darwin-arm64: its assembler refuses the "
                      "assembly:", result.stderr)
        self.assertIn("no such instruction: `frobnicate'", result.stderr)
        self.assertEqual((kept / "broken_darwin-arm64/out.s").read_text(),
                         "--target=darwin-arm64 broken\n")
        self.assertIn("clang-19 --target=arm64-apple-macos13",
                      (kept / "broken_darwin-arm64/assembler.txt").read_text())

    def test_only_an_expected_refusal_is_no_fault(self):
        self.tool("riscv64-elf-gcc")
        self.fixture("positive/refused")
        result = self.run_script("rv32")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("refused|rv32: refine refused:1, which is not an "
                      "expected refusal: main.ldn:1:1: error: L0346",
                      result.stderr)
        #  The same refusal, where emit_manifest.py's list expects one.
        name, target = sorted(
            pair for pair in ASSEMBLE.emit_manifest.REFUSAL_PAIRS
            if pair[1] == "rv32")[0]
        os.rename(self.area / "compiler/tests/fixtures/positive/refused",
                  self.area / "compiler/tests/fixtures/positive" / name)
        self.refine.write_text(REFINE.replace('"refused"', repr(name)))
        result = self.run_script("rv32")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("assembled 1  refused as expected 1", result.stdout)

    def test_a_recorded_rejection_is_counted_and_a_stale_record_is_a_fault(self):
        self.tool("riscv64-linux-gnu-gcc")
        (name, target), why = next(
            item for item in sorted(ASSEMBLE.KNOWN_REJECTIONS.items())
            if item[0][1] == "linux-rv64")
        self.fixture("positive/" + name)
        #  Its assembly is refused, as recorded: counted, and no fault.
        self.refine.write_text(REFINE.replace(
            'target + " "', '"broken " + target + " "'))
        result = self.run_script(target, "--fixture=positive/" + name)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("rejected as recorded 1  faults 0", result.stdout)
        self.assertIn("nothing was assembled", result.stderr)
        result = self.run_script(target)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("rejected as recorded 1  faults 1", result.stdout)
        self.assertIn("plain|linux-rv64: its assembler refuses", result.stderr)
        #  Once it assembles, the record is what is wrong.
        self.refine.write_text(REFINE)
        result = self.run_script(target)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("%s|%s: assembles, and KNOWN_REJECTIONS still records "
                      "that it does not" % (name, target), result.stderr)
        self.assertIn("remove the record", result.stderr)

    def test_every_recorded_rejection_names_a_fixture_and_says_why(self):
        for (name, target), why in ASSEMBLE.KNOWN_REJECTIONS.items():
            self.assertTrue((ROOT / "compiler/tests/fixtures/positive"
                             / name).is_dir(), name)
            self.assertIn(target, ASSEMBLE.emit_manifest.TARGETS)
            self.assertGreater(len(why), 40)

    def test_an_unknown_target_or_fixture_is_refused(self):
        self.every_tool()
        for arguments, said in ((("linux-sparc64",), "TARGETS is a"),
                                (("--fixture=positive/absent",),
                                 "no such fixture: positive/absent")):
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn(said, result.stderr)

    def test_the_machine_arguments_are_the_ones_refine_gives_the_driver(self):
        #  A second spelling of the arguments would drift: each one here
        #  is found in the unit that composes the driver's command, whole
        #  or as the parts that unit joins.
        source = (ROOT / "compiler/ada/src/backend"
                  / "landin-backend-toolchain.adb").read_text()
        joined = {"-march=rv32imc_zicsr_zifencei": ('"-march="',
                                                    '"_zicsr_zifencei"'),
                  "-march=rv64gc": ('"-march="', '"-mabi=lp64d"')}
        for key, command in ASSEMBLE.ASSEMBLERS.items():
            for argument in command[1:]:
                if argument in ASSEMBLE.OBJECT or argument in (
                        "--64",) or argument.startswith("--target="):
                    continue
                with self.subTest(target=key, argument=argument):
                    for part in joined.get(argument, ('"%s"' % argument,)):
                        self.assertIn(part, source)

    def test_every_target_has_an_assembler(self):
        named = {key if isinstance(key, str) else key[0]
                 for key in ASSEMBLE.ASSEMBLERS}
        self.assertEqual(named, set(ASSEMBLE.emit_manifest.TARGETS))
        for level in ASSEMBLE.emit_manifest.configured_levels("xtensa"):
            self.assertIsNotNone(ASSEMBLE.assembler("xtensa", level))
        #  A fixed level with no entry of its own is skipped, not guessed.
        self.assertIsNone(ASSEMBLE.assembler("linux-x86-64", "x86-64-v3"))
        self.assertIsNotNone(ASSEMBLE.assembler("linux-x86-64", None))

    def test_the_command_reference_gives_this_command(self):
        text = (ROOT / "docs/process.md").read_text()
        self.assertIn("python3 scripts/assemble_targets.py ", text)


if __name__ == "__main__":
    unittest.main()
