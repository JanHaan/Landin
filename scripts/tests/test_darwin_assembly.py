#!/usr/bin/env python3
"""Darwin parity frame and exact tail-forwarder negative controls."""
import importlib.util
from pathlib import Path
import signal
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
    def test_exact_tail_bridges_and_ordinary_frames(self):
        text = ".text\n" + routine("_main", FRAME)
        for name, body in CHECK.TAIL_BRIDGES.items():
            text += "\t.p2align 2\n\t.globl " + name + "\n"
            text += "\t.private_extern " + name + "\n" + routine(name, body)
        text += ".data\n_unframed_data:\n\t.quad 0\n"
        CHECK.assembly_contract(text)

    def test_missing_ordinary_and_non_tail_bridge_frames(self):
        for name in ("_ordinary", "__landin_host_open_write", "__landin_host_errno",
                     "__landin_host_heap_allocate", "__landin_host_argument_at"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "missing frame record"):
                CHECK.assembly_contract(assembly(name, ["b _open"]))

    def test_each_required_frame_instruction(self):
        for body in (["mov x29, sp", "ret"], ["stp x29, x30, [sp, #-16]!", "ret"]):
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "missing frame record"):
                CHECK.assembly_contract(assembly("_ordinary", body))

    def test_tail_target_and_call_changes(self):
        for name, body in CHECK.TAIL_BRIDGES.items():
            for last in (body[-1].replace("b ", "bl "), "b _wrong", "ret"):
                with self.subTest(name=name, last=last), self.assertRaisesRegex(ValueError, "invalid tail bridge"):
                    CHECK.assembly_contract(assembly(name, body[:-1] + [last]))

    def test_tail_bridges_cannot_mutate_frame_or_hide_extra_instructions(self):
        for name, body in CHECK.TAIL_BRIDGES.items():
            for extra in ("sub sp, sp, #16", "mov x29, sp", "mov x30, x0", "nop", ".inst 0xd503201f"):
                for changed in ([extra] + body, body + [extra]):
                    with self.subTest(name=name, extra=extra), self.assertRaisesRegex(ValueError, "invalid tail bridge"):
                        CHECK.assembly_contract(assembly(name, changed))

    def test_tail_argument_adaptation_is_exact(self):
        for name, body in CHECK.TAIL_BRIDGES.items():
            if len(body) > 1:
                for changed in (body[1:], ["mov w1, #1"] + body[1:]):
                    with self.subTest(name=name), self.assertRaisesRegex(ValueError, "invalid tail bridge"):
                        CHECK.assembly_contract(assembly(name, changed))

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


if __name__ == "__main__":
    unittest.main()
