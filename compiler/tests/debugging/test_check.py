#!/usr/bin/env python3
"""Regressions for the scripted debugger's transcript acceptance."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "debugging_check", Path(__file__).with_name("check.py"))
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def transcript(lines: dict[str, int]) -> str:
    sections = []

    def section(name: str, body: str) -> None:
        sections.append(f"LANDIN-BEGIN {name}\n{body}\nLANDIN-END {name}")

    def frame(function: str, line: int) -> str:
        return (f"#0 {function} () at examples/derived_containers/workload/"
                f"workload.ldn:{line}\nLine {line} of \"workload.ldn\"")

    for name, function in (("sorted", "numbers_path"),
                           ("done", "containers_run")):
        section(f"container-{name}", frame(function, lines[name]))
    for instance, provider, left, right, result_name in (
            ("signed", "less_i32", -1, 1, "signed_order"),
            ("unsigned", "less_u32", 4294967295, 1, "unsigned_order_ok")):
        scope = f"container-{instance}"
        section(scope, frame("evidence_less", lines["evidence"]))
        sections.extend((f"LANDIN-VALUE {scope}.left={left}",
                         f"LANDIN-VALUE {scope}.right={right}"))
        section(scope + "-dispatch",
                frame(provider, lines[instance + "-provider"]) +
                "\n#1 evidence_less ()\n#2 containers_run ()\n#3 main ()")
        section(scope + "-provider-return", frame("evidence_less", lines["evidence"]))
        section(scope + "-return", frame("containers_run", lines[instance + "-call"]))
        section(scope + "-ready", frame("containers_run", lines[instance + "-ready"]))
        sections.append(f"LANDIN-VALUE {scope}.{result_name}=1")
    for name, value in (("count", 20), ("first", 1), ("last", 20)):
        sections.append(f"LANDIN-VALUE container-sorted.{name}={value}")
    for name in CHECK.CONTAINER_DONE_VALUES:
        sections.append(f"LANDIN-VALUE container-done.{name}=1")
    section("inferior-exit", "[Inferior 1 exited with code 052]")
    return "\n".join(sections) + "\n"


class ContainerTranscriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lines = CHECK.container_lines()
        self.transcript = transcript(self.lines)

    def test_valid_provider_specific_transcript(self) -> None:
        CHECK.check_container_transcript(self.transcript, self.lines)

    def test_wrong_unsigned_provider_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "source stack|outside less_u32"):
            CHECK.check_container_transcript(
                self.transcript.replace("#0 less_u32", "#0 less_i32"), self.lines)

    def test_missing_provider_frame_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "source stack"):
            CHECK.check_container_transcript(
                self.transcript.replace("#0 less_u32", "#4 less_u32"), self.lines)

    def test_wrong_provider_line_is_rejected(self) -> None:
        line = self.lines["unsigned-provider"]
        with self.assertRaisesRegex(ValueError, "source line"):
            CHECK.check_container_transcript(
                self.transcript.replace(f"Line {line} of", "Line 99999 of"),
                self.lines)

    def test_wrong_provider_source_is_rejected(self) -> None:
        name = "container-unsigned-dispatch"
        body = CHECK.marker_section(self.transcript, name)
        changed = body.replace("workload.ldn", "unrelated.ldn")
        with self.assertRaisesRegex(ValueError, "workload.ldn"):
            CHECK.check_container_transcript(
                self.transcript.replace(body, changed), self.lines)

    def test_wrong_unwind_frame_is_rejected(self) -> None:
        for suffix in ("-provider-return", "-return", "-ready"):
            with self.subTest(suffix=suffix):
                body = CHECK.marker_section(self.transcript, "container-unsigned" + suffix)
                with self.assertRaisesRegex(ValueError, "caller frame"):
                    CHECK.check_container_transcript(self.transcript.replace(
                        body, body.replace("#0", "#1")), self.lines)

    def test_wrong_unwind_line_is_rejected(self) -> None:
        for suffix in ("-provider-return", "-return", "-ready"):
            with self.subTest(suffix=suffix):
                body = CHECK.marker_section(self.transcript, "container-unsigned" + suffix)
                with self.assertRaisesRegex(ValueError, "source line"):
                    CHECK.check_container_transcript(self.transcript.replace(
                        body, body.replace("Line ", "Line 99999")), self.lines)

    def test_wrong_caller_result_is_rejected(self) -> None:
        for instance, name in (("signed", "signed_order"),
                               ("unsigned", "unsigned_order_ok")):
            with self.subTest(instance=instance):
                value = f"container-{instance}.{name}"
                with self.assertRaisesRegex(ValueError, value + "=1"):
                    CHECK.check_container_transcript(self.transcript.replace(
                        value + "=1", value + "=0"), self.lines)

    def test_unavailable_caller_result_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "container-signed.signed_order=1"):
            CHECK.check_container_transcript(self.transcript.replace(
                "container-signed.signed_order=1",
                "container-signed.signed_order=<optimized out>"), self.lines)

    def test_unsigned_value_is_not_signed(self) -> None:
        with self.assertRaisesRegex(ValueError, "left=4294967295"):
            CHECK.check_container_transcript(self.transcript.replace(
                "container-unsigned.left=4294967295", "container-unsigned.left=-1"),
                self.lines)

    def test_unsigned_gdb_output_uses_unsigned_format(self) -> None:
        script = CHECK.container_gdb_script(["run"], self.lines)
        self.assertIn('printf "LANDIN-VALUE container-signed.left="\noutput/d left',
                      script)
        self.assertIn('printf "LANDIN-VALUE container-unsigned.left="\noutput/u left',
                      script)


class LineTableTests(unittest.TestCase):
    @staticmethod
    def table(directory: str) -> str:
        return ("  DWARF Version: 4\n"
                " The Directory Table (offset 0x1b):\n"
                f"  1\t{directory}\n\n"
                " The File Name Table (offset 0x25):\n"
                "  Entry Dir Time Size Name\n"
                "  1 1 0 0 map.ldn\n\n")

    def test_rooted_directory_spelling_is_preserved(self) -> None:
        self.assertEqual(CHECK.check_line_table(
            self.table("./core/map"), ("./core/map/map.ldn",)), [4])

    def test_normalized_rooted_directory_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "wrong directory"):
            CHECK.check_line_table(
                self.table("core/map"), ("./core/map/map.ldn",))

    def test_unprefixed_directory_still_matches(self) -> None:
        self.assertEqual(CHECK.check_line_table(
            self.table("core/map"), ("core/map/map.ldn",)), [4])

    def test_other_directory_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "wrong directory"):
            CHECK.check_line_table(
                self.table("./core/vec"), ("./core/map/map.ldn",))


if __name__ == "__main__":
    unittest.main()
