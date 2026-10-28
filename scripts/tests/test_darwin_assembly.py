#!/usr/bin/env python3
"""Darwin parity frame negative controls."""
import importlib.util
import os
import re
from pathlib import Path
import signal
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "darwin_parity_check", ROOT / "compiler/tests/darwin/check.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

FRAME = ["stp x29, x30, [sp, #-16]!", "mov x29, sp", "ret"]


def routine(name, instructions):
    return name + ":\n" + "".join("\t" + line + "\n" for line in instructions)


def assembly(name, instructions):
    return ".text\n" + routine("_main", FRAME) + routine(name, instructions)


class DarwinAssemblyTests(unittest.TestCase):
    def test_ordinary_frames(self):
        text = ".text\n" + routine("_main", FRAME)
        text += routine("__landin_host_initialize_arguments", FRAME)
        text += ".data\n_unframed_data:\n\t.quad 0\n"
        CHECK.assembly_contract(text)

    def test_missing_ordinary_frames(self):
        for name in ("_ordinary", "__landin_host_initialize_arguments", "_open"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "missing frame record"):
                CHECK.assembly_contract(assembly(name, ["b _open"]))

    def test_each_required_frame_instruction(self):
        for body in (["mov x29, sp", "ret"], ["stp x29, x30, [sp, #-16]!", "ret"]):
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "missing frame record"):
                CHECK.assembly_contract(assembly("_ordinary", body))

    def test_only_the_start_routine_opens_no_frame(self):
        start = ["nop", "mov x0, x20", "blr x19", "brk #1"]
        CHECK.assembly_contract(assembly("_landin.stack_start", start))
        CHECK.assembly_contract(assembly("_landin.stack_switch", FRAME))
        for name in ("_landin.stack_switch", "_landin.stack_start_", "_stack_start"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "missing frame record"):
                CHECK.assembly_contract(assembly(name, start))

    def test_reserved_register_still_refused(self):
        for register in ("w18", "x18"):
            with self.subTest(register=register), self.assertRaisesRegex(ValueError, "reserved x18"):
                CHECK.assembly_contract(assembly("_ordinary", FRAME + ["mov " + register + ", #0"]))

    def test_no_routines_still_refused(self):
        with self.assertRaisesRegex(ValueError, "no emitted routine frames"):
            CHECK.assembly_contract(".data\n_data:\n\t.quad 0\n")


class DarwinLargeImageTests(unittest.TestCase):
    META = {"status": "42", "stream": "merged"}
    MESSAGE = b"syscall to map cache into shared region failed"

    def verdict(self, generated, control, expected=None, meta=None):
        return CHECK.large_image_outcome(
            self.META if meta is None else meta, *generated, expected, *control)

    def test_both_execute_original_status_oracle(self):
        self.assertEqual(self.verdict((42, b"", b""), (42, b"", b"")), "passed")
        with self.assertRaisesRegex(ValueError, "expected status 43"):
            self.verdict((42, b"", b""), (42, b"", b""),
                         meta={"status": "43", "stream": "merged"})

    def test_both_demonstrate_loader_refusal(self):
        self.assertEqual(self.verdict(
            (-signal.SIGABRT, self.MESSAGE, b""),
            (-signal.SIGABRT, b"", self.MESSAGE)), "platform-limited")

    def test_asymmetric_wrong_status_and_wrong_signal_refused(self):
        success = (42, b"", b"")
        refusal = (-signal.SIGABRT, self.MESSAGE, b"")
        for generated, control in ((success, refusal), (refusal, success)):
            with self.subTest(generated=generated, control=control), self.assertRaises(ValueError):
                self.verdict(generated, control)
        for status in (0, 1, 41, 43, -signal.SIGKILL, -signal.SIGSEGV, -signal.SIGTRAP):
            wrong = (status, self.MESSAGE, b"")
            for generated, control in ((wrong, wrong), (wrong, refusal), (refusal, wrong)):
                with self.subTest(generated=generated, control=control), self.assertRaises(ValueError):
                    self.verdict(generated, control)

    def test_each_refusal_requires_exact_loader_diagnostic(self):
        refusal = (-signal.SIGABRT, self.MESSAGE, b"")
        for message in (b"", b"some other dyld error", self.MESSAGE.upper()):
            wrong = (-signal.SIGABRT, message, b"")
            for generated, control in ((wrong, refusal), (refusal, wrong), (wrong, wrong)):
                with self.subTest(generated=generated, control=control), self.assertRaises(ValueError):
                    self.verdict(generated, control)

    def test_success_requires_original_output_and_silent_control(self):
        success = (42, b"", b"")
        for output in ((42, b"unexpected", b""), (42, b"", b"unexpected")):
            for generated, control in ((output, success), (success, output)):
                with self.subTest(generated=generated, control=control), self.assertRaises(ValueError):
                    self.verdict(generated, control)
        self.assertEqual(self.verdict((42, b"expected", b""), success, b"expected"), "passed")
        with self.assertRaisesRegex(ValueError, "output mismatch"):
            self.verdict(success, success, b"expected")



class DarwinStandardInputTests(unittest.TestCase):
    def test_a_fixture_input_is_the_program_standard_input(self):
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            (base / "given.txt").write_bytes(b"one two\n")
            run = CHECK.Run(base)
            echo = [sys.executable, "-c",
                    "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())"]
            given = CHECK.standard_input(base, {"stdin": "given.txt"})
            _, stdout, _ = run.command(echo, "fed", base, stdin=given)
            self.assertEqual(stdout, b"one two\n")
            #  No `stdin:` key is an empty input, never this script's own.
            self.assertEqual(CHECK.standard_input(base, {}), os.devnull)
            _, stdout, _ = run.command(echo, "empty", base)
            self.assertEqual(stdout, b"")

class StreamDefaultTests(unittest.TestCase):
    """A fixture without `stream:` is merged on every lane."""

    TRAP = b"main.ldn:4:9: trap: out_of_range\n"

    def test_an_unnamed_stream_is_merged(self):
        CHECK.outcome({"status": "0"}, 0, b"out\n", b"err\n",
                      expected=b"out\nerr\n")
        CHECK.outcome({"traps": "yes", "trap_report": self.TRAP.decode().strip()},
                      -signal.SIGTRAP, b"", self.TRAP)

    def test_a_separate_stream_still_requires_an_empty_standard_error(self):
        with self.assertRaisesRegex(ValueError, "unexpected stderr"):
            CHECK.outcome({"status": "0", "stream": "output"}, 0, b"", b"err\n")
        #  The test program excuses no trap report there, and neither
        #  does this lane.
        with self.assertRaisesRegex(ValueError, "unexpected stderr"):
            CHECK.outcome({"traps": "yes", "stream": "output",
                           "trap_report": self.TRAP.decode().strip()},
                          -signal.SIGTRAP, b"", self.TRAP)

    def test_every_lane_reads_the_same_default(self):
        lanes = [ROOT / "compiler/tests" / lane / "check.py"
                 for lane in ("darwin", "freebsd", "rv64")]
        lanes += [ROOT / "compiler/tests/darwin/diagnostics.py",
                  ROOT / "check.py"]
        #  Each lane spells its own reading of `stream:`.  A read that
        #  names a default names `merged`; one that names none may only
        #  ask whether the key says `output`, which an absent key does not.
        for path in lanes:
            text = path.read_text()
            with self.subTest(lane=str(path.relative_to(ROOT))):
                reads = re.findall(
                    r"""get\((['"])stream\1([^)]*)\)\s*(?:[=!]=\s*(['"])(\w+)\3)?""",
                    text)
                self.assertTrue(reads or "merged(meta)" in text)
                for _, default, _, compared in reads:
                    if default:
                        self.assertRegex(default, r"""^,\s*(['"])merged\1$""")
                    else:
                        self.assertEqual(compared, "output")
        ada = (ROOT / "compiler/ada/tests/src/landin-testing-fixtures.ads").read_text()
        self.assertIn("Stream    : Stream_Choice := Merged;", ada)


if __name__ == "__main__":
    unittest.main()
