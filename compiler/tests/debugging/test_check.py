#!/usr/bin/env python3
"""Regressions for the scripted debugger's transcript acceptance."""
from __future__ import annotations

import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest import mock
import tempfile

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


class HostedTranscriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lines = {"sample": 51, "sample-updated": 52, "text": 73}
        sections = []
        for name, function, filename in (("sample", "sample_keep", "filter.ldn"),
                                         ("sample-updated", "sample_keep", "filter.ldn"),
                                         ("text", "text_emit", "dest.ldn")):
            line = self.lines[name]
            callers = (("emit_retry", "process", "run_logged", "run", "main")
                       if name == "text" else
                       ("process", "run_logged", "run", "main"))
            stack = "".join(f"#{index} {caller} ()\n"
                            for index, caller in enumerate(callers, 1))
            sections.append(
                f"LANDIN-BEGIN hosted-{name}\n"
                f"#0 {function} () at {filename}:{line}\n"
                f'Line {line} of "{filename}"\n'
                f"{stack}LANDIN-END hosted-{name}\n")
        sections.extend(("LANDIN-VALUE hosted-sample.seen=0\n",
                         "LANDIN-VALUE hosted-sample.every=2\n",
                         "LANDIN-VALUE hosted-sample-updated.seen=1\n",
                         "LANDIN-VALUE hosted-text.delivered=0\n",
                         "LANDIN-BEGIN inferior-exit\n"
                         "[Inferior 1 exited with code 052]\n"
                         "LANDIN-END inferior-exit\n"))
        self.transcript = "".join(sections)

    def test_valid_runtime_provider_transcript(self) -> None:
        CHECK.check_hosted_transcript(self.transcript, self.lines)

    def test_wrong_provider_is_rejected(self) -> None:
        for provider in ("sample_keep", "text_emit"):
            with self.subTest(provider=provider):
                with self.assertRaisesRegex(ValueError, "outside"):
                    CHECK.check_hosted_transcript(self.transcript.replace(
                        provider, "unrelated_provider"), self.lines)

    def test_missing_application_frame_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "source stack"):
            CHECK.check_hosted_transcript(self.transcript.replace(
                "#1 process", "#1 test_dispatch"), self.lines)

    def test_missing_text_retry_frame_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "source stack"):
            CHECK.check_hosted_transcript(self.transcript.replace(
                "#1 emit_retry", "#1 process"), self.lines)

    def test_wrong_provider_source_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "filter.ldn"):
            CHECK.check_hosted_transcript(self.transcript.replace(
                "filter.ldn", "unrelated.ldn"), self.lines)

    def test_wrong_source_line_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "source line"):
            CHECK.check_hosted_transcript(self.transcript.replace(
                "Line 51", "Line 999"), self.lines)

    def test_wrong_or_unavailable_state_is_rejected(self) -> None:
        for name, value in (("sample.seen", 0), ("sample.every", 2),
                            ("sample-updated.seen", 1), ("text.delivered", 0)):
            for replacement in ("999", "<optimized out>"):
                with self.subTest(name=name, replacement=replacement):
                    with self.assertRaisesRegex(ValueError, "did not report"):
                        CHECK.check_hosted_transcript(self.transcript.replace(
                            f"hosted-{name}={value}", f"hosted-{name}={replacement}"),
                            self.lines)

    def test_wrong_final_status_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "did not return 42"):
            CHECK.check_hosted_transcript(self.transcript.replace(
                "exited with code 052", "exited with code 01"), self.lines)


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


class ParserTranscriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lines = CHECK.parser_lines()
        sections = []
        for name, functions in (
                ("digits", ("parse_digits", "parse_digits", "parse_entry", "parse_sequence")),
                ("recovery", ("recover_to_boundary", "parse_entry", "parse_sequence")),
                ("nested", ("parse_sequence", "parse_entry", "parse_sequence")),
                ("done", ("main",))):
            stack = functions if name == "done" else (*functions, "parse_file", "main")
            sections.append(f"LANDIN-BEGIN parser-{name}\n")
            for index, function in enumerate(stack):
                path = ("compiler/tests/fixtures/runtime/derived-parser/main.ldn"
                        if function == "main" else
                        "examples/config_parser/parser/parser.ldn")
                sections.append(f"#{index} {function} () at {path}:{self.lines[name]}\n")
            sections.append(f'Line {self.lines[name]} of "parser.ldn"\n')
            sections.append(f"LANDIN-END parser-{name}\n")
        for name, value in (
                ("digits.accumulated", 4), ("digits.cursor", 27), ("digits.ends", 28),
                ("digits-caller.accumulated", 0), ("digits-caller.cursor", 26),
                ("recovery.depth", 0), ("recovery.look", 1),
                ("recovery.begins", 36), ("recovery.ends", 38),
                ("nested.depth", 1), ("nested.look", 6), ("nested.begins", 48),
                ("nested.source_length", 92), ("done.valid", 1),
                ("done.source_length", 92), ("done.saw_out_of_memory", 1),
                ("done.saw_io_failure", 1)):
            sections.append(f"LANDIN-VALUE parser-{name}={value}\n")
        sections.extend(("LANDIN-BEGIN inferior-output\n",
                         (CHECK.PARSER_FIXTURE / "output.txt").read_text(),
                         "LANDIN-END inferior-output\n",
                         "LANDIN-BEGIN inferior-exit\n",
                         "[Inferior 1 exited with code 052]\n",
                         "LANDIN-END inferior-exit\n"))
        self.transcript = "".join(sections)

    def test_valid_complete_parser_transcript(self) -> None:
        CHECK.check_parser_transcript(self.transcript, self.lines)

    def test_wrong_or_missing_recursive_frame_is_rejected(self) -> None:
        for old, new in (("#1 parse_digits", "#1 unrelated"),
                         ("#1 parse_entry", "#1 unrelated"),
                         ("parse_file", "unrelated")):
            with self.subTest(old=old), self.assertRaisesRegex(ValueError, "stack"):
                CHECK.check_parser_transcript(self.transcript.replace(old, new), self.lines)

    def test_missing_nested_stop_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "section parser-nested"):
            CHECK.check_parser_transcript(self.transcript.replace(
                "LANDIN-BEGIN parser-nested", "LANDIN-BEGIN absent"), self.lines)

    def test_wrong_source_and_line_are_rejected(self) -> None:
        for old, new in (("parser.ldn", "unrelated.ldn"),
                         (f"Line {self.lines['recovery']}", "Line 99999")):
            with self.subTest(old=old), self.assertRaises(ValueError):
                CHECK.check_parser_transcript(self.transcript.replace(old, new), self.lines)

    def test_unavailable_or_wrong_state_is_rejected(self) -> None:
        for name, value in (("digits-caller.accumulated", 0), ("recovery.look", 1),
                            ("nested.depth", 1), ("nested.source_length", 92),
                            ("done.valid", 1), ("done.saw_out_of_memory", 1),
                            ("done.saw_io_failure", 1)):
            for replacement in ("999", "<optimized out>"):
                with self.subTest(name=name, replacement=replacement):
                    with self.assertRaisesRegex(ValueError, "did not report"):
                        CHECK.check_parser_transcript(self.transcript.replace(
                            f"parser-{name}={value}", f"parser-{name}={replacement}"),
                            self.lines)

    def test_exact_diagnostic_output_is_required(self) -> None:
        original = (CHECK.PARSER_FIXTURE / "output.txt").read_text()
        for changed in ("", original + "unexpected stdout\n",
                        original.replace("E:65:", "E:64:"),
                        "\n".join(reversed(original.splitlines())) + "\n"):
            with self.subTest(changed=changed):
                with self.assertRaisesRegex(ValueError, "diagnostics differ"):
                    CHECK.check_parser_transcript(self.transcript.replace(
                        original, changed), self.lines)

    def test_wrong_final_status_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "did not return 42"):
            CHECK.check_parser_transcript(self.transcript.replace(
                "exited with code 052", "exited with code 01"), self.lines)


class WorkloadRegistrationTests(unittest.TestCase):
    def test_default_measures_every_complete_prototype_in_every_profile(self) -> None:
        calls = []
        result = CHECK.measure_workloads(lambda name, profile:
                                        calls.append((name, profile)) or {})
        profiles = (("none-off", "none", "off"), ("size-auto", "size", "auto"),
                    ("size-all", "size", "all"))
        self.assertEqual(calls, [(name, profile) for name in
                                ("parser", "containers", "hosted") for profile in profiles])
        self.assertEqual(tuple(result), ("parser", "containers", "hosted"))

    def test_developer_selection_is_exact_and_keeps_all_profiles(self) -> None:
        calls = []
        CHECK.measure_workloads(lambda name, profile: calls.append((name, profile)) or {},
                                "parser")
        self.assertEqual([name for name, _ in calls], ["parser"] * 3)
        self.assertEqual([profile[0] for _, profile in calls],
                         ["none-off", "size-auto", "size-all"])
        with self.assertRaisesRegex(ValueError, "unknown"):
            CHECK.measure_workloads(lambda *_: {}, "parse")


class ParserTransportTests(unittest.TestCase):
    def test_native_argv_and_exact_output_are_separate_from_debugger_prose(self) -> None:
        expected = (CHECK.PARSER_FIXTURE / "output.txt").read_text()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            script, transcript = path / "session.gdb", path / "session.txt"

            def debugger(args, cwd, retained):
                self.assertEqual(args[-3:], ["--args", "/parser", "/input"])
                terminal = next(line.removeprefix("set inferior-tty ") for line in
                                script.read_text().splitlines()
                                if line.startswith("set inferior-tty "))
                descriptor = os.open(terminal, os.O_WRONLY | os.O_NOCTTY)
                try:
                    os.write(descriptor, expected.encode())
                finally:
                    os.close(descriptor)
                return "debugger prose\n"

            with mock.patch.object(CHECK, "run_gdb_process", side_effect=debugger):
                actual = CHECK.run_gdb("gdb", Path("/parser"), script, transcript,
                                      path, "native", None, path,
                                      lambda start: "\n".join(start),
                                      ("/input",), expected)
            self.assertEqual(CHECK.marker_section(actual, "inferior-output"), expected)
            self.assertEqual(transcript.read_text(), actual)

    def test_qemu_argv_and_exact_output_survive_in_retained_transcript(self) -> None:
        expected = (CHECK.PARSER_FIXTURE / "output.txt").read_text()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            script, transcript = path / "session.gdb", path / "session.txt"
            process = mock.Mock()
            process.stdout = io.StringIO(expected)
            process.poll.side_effect = [None, 42]
            process.wait.return_value = 42

            def spawn(args, **_kwargs):
                self.assertEqual(args, ["qemu", "-g", str(path / "gdb.sock"),
                                        "/parser", "/input"])
                (path / "gdb.sock").touch()
                return process

            with mock.patch.object(CHECK.subprocess, "Popen", side_effect=spawn), \
                 mock.patch.object(CHECK, "run_gdb_process", return_value="debugger prose\n"):
                actual = CHECK.run_gdb("gdb", Path("/parser"), script, transcript,
                                      path, "qemu", "qemu", path,
                                      lambda start: "\n".join(start),
                                      ("/input",), expected)
            self.assertEqual(CHECK.marker_section(actual, "inferior-output"), expected)
            self.assertEqual(transcript.read_text(), actual)


if __name__ == "__main__":
    unittest.main()
