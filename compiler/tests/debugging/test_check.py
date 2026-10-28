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

    def cmp_frame(function: str, line: int) -> str:
        return (f"#0 {function} () at core/cmp/cmp.ldn:{line}\n"
                f"Line {line} of \"cmp.ldn\"")

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
                cmp_frame(provider, lines[instance + "-provider"]) +
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


class GenericSteppingTests(unittest.TestCase):
    def test_optimized_implicit_return_uses_closing_line(self):
        closing = CHECK.source_line(CHECK.MAIN_SOURCE, "end debug_generic")
        declaration = CHECK.source_line(CHECK.MAIN_SOURCE, "debug_generic: (")
        for line in (closing, declaration):
            text = ("LANDIN-BEGIN generic-next-line\n"
                    f"#0 debug_generic () at main.ldn:{line}\n"
                    f'Line {line} of "main.ldn"\n'
                    "LANDIN-END generic-next-line\n")
            if line == closing:
                CHECK.expect_one_of_lines(text, "generic-next-line",
                                          CHECK.GENERIC_NEXT_LINES, "debug_generic")
            else:
                with self.assertRaises(ValueError):
                    CHECK.expect_one_of_lines(text, "generic-next-line",
                                              CHECK.GENERIC_NEXT_LINES, "debug_generic")


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
        changed = body.replace("cmp.ldn", "unrelated.ldn")
        with self.assertRaisesRegex(ValueError, "cmp.ldn"):
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
            callers = ("process", "run_logged", "run", "main")
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
            self.table("./examples/map"), ("./examples/map/map.ldn",)), [4])

    def test_normalized_rooted_directory_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "wrong directory"):
            CHECK.check_line_table(
                self.table("examples/map"), ("./examples/map/map.ldn",))

    def test_unprefixed_directory_still_matches(self) -> None:
        self.assertEqual(CHECK.check_line_table(
            self.table("examples/map"), ("examples/map/map.ldn",)), [4])

    def test_other_directory_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "wrong directory"):
            CHECK.check_line_table(
                self.table("./examples/vec"), ("./examples/map/map.ldn",))

    def test_library_file_is_recorded_under_the_prefix(self) -> None:
        # D422: however a library file was read, it is recorded by its
        # module path under /landin-library, never as it was spelled.
        for spelling in ("./core/map/map.ldn", "core/map/map.ldn",
                         str(CHECK.ROOT / "core/map/map.ldn")):
            with self.subTest(spelling=spelling):
                self.assertEqual(CHECK.check_line_table(
                    self.table("/landin-library/core/map"), (spelling,)), [4])
                with self.assertRaisesRegex(ValueError, "wrong directory"):
                    CHECK.check_line_table(
                        self.table(os.path.dirname(spelling)), (spelling,))


class ParserTranscriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lines = CHECK.parser_lines()
        sections = []
        for name, functions in (
                ("digits", ("parse_digits", "parse_digits", "parse_entry",
                            "parse_and_append", "parse_sequence")),
                ("recovery", ("recover_to_boundary", "parse_entry",
                              "parse_and_append", "parse_sequence")),
                ("nested", ("parse_sequence", "parse_entry",
                            "parse_and_append", "parse_sequence")),
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
                ("recovery.depth", 0), ("recovery.look", "number"),
                ("recovery.begins", 36), ("recovery.ends", 38),
                ("nested.depth", 1), ("nested.look", "newline"),
                ("nested.begins", 48),
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
                         ("parse_and_append", "unrelated"),
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
        for name, value in (("digits-caller.accumulated", 0),
                            ("recovery.look", "number"),
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


def register_transcript(lines: dict[str, int], pc: str = "0x401063",
                        held: str = "42", leaf: str = "inline_leaf") -> str:
    source = "compiler/tests/debugging/registers.ldn"

    def section(name: str, body: str) -> str:
        return f"LANDIN-BEGIN {name}\n{body}\nLANDIN-END {name}"

    def frame(function: str, line: int) -> str:
        return (f"#0  {function} (argument=...) at {source}:{line}\n"
                f"Line {line} of \"{source}\" starts at address 0x0")

    return "\n".join((
        section("register-pick-ready-line",
                frame("register_pick", lines["pick-ready"])),
        section("register-pick-ready-pc", pc),
        section("register-pick-ready-chosen-address",
                'Symbol "chosen" is multi-location:\n'
                "  Base address 0x0  Range 0x40104d-0x401064: a variable in $rbx\n."),
        "LANDIN-VALUE register-pick-ready.chosen=41",
        "LANDIN-VALUE register-pick-ready.picked=41",
        section("register-inner-ready-line",
                frame("register_inner", lines["inner-ready"])),
        section("register-inner-ready-pc", "0x401019"),
        "LANDIN-VALUE register-inner-ready.argument=41",
        f"LANDIN-VALUE register-inner-ready.held={held}",
        section("register-inner-ready-caller",
                f"#1  0x000000000040106a in register_pick (argument=...) at {source}:18"),
        "LANDIN-VALUE register-inner-ready-caller.picked=41",
        section("register-leaf-ready-line",
                frame(leaf, lines["leaf-ready"])),
        section("register-leaf-ready-pc", "0x401121"),
        "LANDIN-VALUE register-leaf-ready.base=2",
        "LANDIN-VALUE register-leaf-ready.doubled=4",
        section("register-leaf-ready-caller",
                f"#1  inline_outer (start=<optimized out>) at {source}:36"),
        "LANDIN-VALUE register-leaf-ready-caller.first=2",
        section("register-leaf-ready-backtrace",
                f"#0  {leaf} (base=2) at {source}:{lines['leaf-ready']}\n"
                f"#1  inline_outer (start=<optimized out>) at {source}:36\n"
                f"#2  0x0000000000401161 in main () at {source}:47"),
        section("inferior-exit", "[Inferior 1 (process 1) exited with code 052]"),
    )) + "\n"


class RegisterTranscriptTests(unittest.TestCase):
    lines = CHECK.REGISTER_LINES

    def test_registers_past_their_last_use_are_accepted(self) -> None:
        CHECK.check_register_transcript(register_transcript(self.lines), self.lines)

    def test_a_range_ending_before_the_stop_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "chosen is not in a register"):
            CHECK.check_register_transcript(
                register_transcript(self.lines, pc="0x401064"), self.lines)

    def test_an_unavailable_variable_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "held=42"):
            CHECK.check_register_transcript(
                register_transcript(self.lines, held="<optimized out>"), self.lines)

    def test_a_copy_described_as_its_caller_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "stopped outside inline_leaf"):
            CHECK.check_register_transcript(
                register_transcript(self.lines, leaf="inline_outer"), self.lines)

    def test_a_backtrace_without_the_inlined_frame_is_rejected(self) -> None:
        transcript = register_transcript(self.lines).replace(
            "#0  inline_leaf (base=2)", "#0  inline_outer (start=1)")
        with self.assertRaisesRegex(ValueError, "leaf-ready backtrace"):
            CHECK.check_register_transcript(transcript, self.lines)

    def test_memory_is_not_a_register(self) -> None:
        self.assertFalse(CHECK.register_at(
            "Range 0x10-0x20: a variable at frame base reg $rbp offset 0+-40", 0x18))
        self.assertTrue(CHECK.register_at(
            'Symbol "chosen" is a variable in $x19.', 0x18))

    def test_the_session_starts_after_its_first_breakpoint(self) -> None:
        script = CHECK.register_gdb_script(["run"], self.lines).splitlines()
        self.assertLess(script.index("tbreak compiler/tests/debugging/registers.ldn:"
                                     + str(self.lines["pick-ready"])),
                        script.index("run"))
        self.assertIn("info address chosen", script)


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


class WorkloadSourceInventoryTests(unittest.TestCase):
    def test_a_differing_closure_names_its_files_and_the_regenerating_command(self) -> None:
        recorded = CHECK.json.loads((CHECK.HERE / "workload-sources.json").read_text())
        built = [name for name in recorded["parser"] if name != recorded["parser"][1]]
        built.append("core/io/added.ldn")
        CHECK.check_workload_sources("parser", recorded["parser"])
        with self.assertRaises(ValueError) as refused:
            CHECK.check_workload_sources("parser", built)
        text = str(refused.exception)
        self.assertIn("added   core/io/added.ldn", text)
        self.assertIn("removed " + recorded["parser"][1], text)
        self.assertIn("workload_sources.py --refine REFINE --write", text)


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


PANIC_SPEC = importlib.util.spec_from_file_location(
    "debugging_panic", Path(__file__).with_name("panic.py"))
assert PANIC_SPEC is not None and PANIC_SPEC.loader is not None
PANIC = importlib.util.module_from_spec(PANIC_SPEC)
PANIC_SPEC.loader.exec_module(PANIC)


class StageOutputTests(unittest.TestCase):
    """A second run replaces its own output and refuses anything else."""

    def test_new_and_empty_directories_are_taken(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for path in (Path(tmp) / "new" / "panic", Path(tmp) / "empty"):
                path.parent.mkdir(exist_ok=True)
                if path.name == "empty":
                    path.mkdir()
                made = PANIC.fresh(path)
                self.assertEqual(made, path.resolve())
                self.assertEqual([p.name for p in made.iterdir()],
                                 [PANIC.STAGE_MARK])

    def test_own_earlier_output_is_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            panic = Path(tmp) / "debugging" / "panic"
            PANIC.fresh(panic)
            (panic / "commands.json").write_text("earlier run\n")
            (panic / "nested").mkdir()
            again = PANIC.fresh(panic)
            self.assertEqual([p.name for p in again.iterdir()],
                             [PANIC.STAGE_MARK])

    def test_another_directory_is_refused_naming_it_and_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            foreign = Path(tmp) / "mine"
            foreign.mkdir()
            (foreign / "notes.txt").write_text("not a debugger run's\n")
            with self.assertRaises(FileExistsError) as raised:
                PANIC.fresh(foreign)
            self.assertIn(str(foreign.resolve()), str(raised.exception))
            self.assertIn("--output", str(raised.exception))
            self.assertTrue((foreign / "notes.txt").is_file())


FRAMES_SPEC = importlib.util.spec_from_file_location(
    "debugging_frames", Path(__file__).with_name("workload_frames.py"))
assert FRAMES_SPEC is not None and FRAMES_SPEC.loader is not None
FRAMES = importlib.util.module_from_spec(FRAMES_SPEC)
FRAMES_SPEC.loader.exec_module(FRAMES)


class WorkloadFrames(unittest.TestCase):
    """Where each expected frame is declared is found again, or refused."""

    RECORD = {"w": {"stops": {"s": ["leaf", "main"]}, "declared": {}}}

    def computed(self, files: dict[str, str], record=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, text in files.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text)
            return FRAMES.computed(record or self.RECORD,
                                   {"w": sorted(files)}, root)

    def test_the_record_is_current(self) -> None:
        record = CHECK.FRAMES
        closures = __import__("json").loads(
            Path(__file__).with_name("workload-sources.json").read_text())
        declared, problems = FRAMES.computed(record, closures)
        self.assertEqual(problems, [])
        for workload, entry in record.items():
            self.assertEqual(entry["declared"], declared[workload], workload)

    def test_a_moved_routine_is_found_again(self) -> None:
        declared, problems = self.computed(
            {"a/a.ldn": "public leaf: () -> none =\nend leaf\n",
             "main.ldn": "public main: () -> (code: i32) =\nend main\n"})
        self.assertEqual(problems, [])
        self.assertEqual(declared["w"], {"leaf": "a/a.ldn", "main": "main.ldn"})

    def test_a_renamed_routine_is_refused(self) -> None:
        _, problems = self.computed(
            {"a/a.ldn": "leaf_renamed: () -> none =\nend leaf_renamed\n",
             "main.ldn": "public main: () -> (code: i32) =\nend main\n"})
        self.assertEqual(problems, ["w: no source the workload is built from"
                                    " declares leaf"])

    def test_two_declarations_need_the_record_to_choose(self) -> None:
        files = {"a/a.ldn": "leaf: () -> none =\nend leaf\n",
                 "b/b.ldn": "leaf: () -> none =\nend leaf\n",
                 "main.ldn": "public main: () -> (code: i32) =\nend main\n"}
        _, problems = self.computed(files)
        self.assertIn("by hand", problems[0])
        chosen = {"w": {"stops": {"s": ["leaf", "main"]},
                        "declared": {"leaf": "b/b.ldn"}}}
        declared, problems = self.computed(files, chosen)
        self.assertEqual(problems, [])
        self.assertEqual(declared["w"]["leaf"], "b/b.ldn")


import switch_frames as SWITCH  # noqa: E402  (the module beside check.py)


def gdb_switch(names=None, swap_at=3, beneath_start=(), short=False) -> str:
    """A GDB transcript of the stack switch session, as gdb_commands makes
    it: a fibre stop, then each switch stepped from its first instruction
    to the first past its return, the stack pointer moving at `swap_at`."""
    switch = (names or {}).get("switch", SWITCH.SWITCH)
    start = (names or {}).get("start", SWITCH.START)

    def bt(frames):
        return "".join(f"#{i}  0x0000000000401000 in {name} ()\n"
                       for i, name in enumerate(frames))

    def fix(frames):
        return [start if name == SWITCH.START else name for name in frames]

    fibre = fix(SWITCH.STOPS["fibre"] + [SWITCH.START]) + list(beneath_start)
    text = ["LANDIN-SWITCH-BEGIN fibre", bt(fibre).rstrip("\n")]
    if short:
        text.append("Backtrace stopped: previous frame inner to this frame")
    text.append("LANDIN-SWITCH-END fibre")
    instructions = ["push %rbp", "push %rbx", "mov %rsp,(%rdi)",
                    "mov %rsi,%rsp", "pop %rbx", "pop %rbp", "ret"]
    for each in SWITCH.SWITCHES:
        text.append("LANDIN-SWITCH-BEGIN " + each["name"])
        for offset, instruction in enumerate(instructions):
            above = fix(each["leaving"] if offset <= swap_at else each["resumed"])
            text += ["LANDIN-SWITCH-STEP",
                     f"=> 0x401{offset:03x} <{switch}+{offset}>:\t{instruction}",
                     bt([switch] + above).rstrip("\n")]
        text += ["LANDIN-SWITCH-STEP", "=> 0x400200 <hand_over+40>:\tmov $0,%eax",
                 bt(fix(each["resumed"])).rstrip("\n"),
                 "LANDIN-SWITCH-END " + each["name"]]
    return "\n".join(text) + "\n"


class SwitchFramesTests(unittest.TestCase):
    """The stack switch session's verdict, without a debugger."""

    def check(self, text: str) -> dict:
        return SWITCH.check(SWITCH.gdb_stops(text), "x86-64")

    def test_the_expected_frames_pass(self) -> None:
        shown = self.check(gdb_switch())
        self.assertEqual(shown["second-to-first"]["turn"], 4)
        self.assertEqual(shown["first-to-main"]["swap"], "mov %rsi,%rsp")

    def test_an_unnamed_switch_routine_is_refused(self) -> None:
        with self.assertRaises(SWITCH.Mismatch):
            self.check(gdb_switch({"switch": "??"}))

    def test_an_unnamed_start_routine_is_refused(self) -> None:
        with self.assertRaisesRegex(SWITCH.Mismatch, "inside the fibre"):
            self.check(gdb_switch({"start": "??"}))

    def test_frames_beneath_the_start_routine_are_refused(self) -> None:
        with self.assertRaisesRegex(SWITCH.Mismatch, "nothing beneath"):
            self.check(gdb_switch(beneath_start=("main",)))

    def test_a_backtrace_stopped_short_is_refused(self) -> None:
        with self.assertRaisesRegex(SWITCH.Mismatch, "short"):
            self.check(gdb_switch(short=True))

    def test_frames_that_change_off_the_swap_are_refused(self) -> None:
        with self.assertRaisesRegex(SWITCH.Mismatch, "does not load"):
            self.check(gdb_switch(swap_at=1))

    def test_a_misread_return_is_refused_where_debuggers_read_it(self) -> None:
        #  LLDB 19.1.7 on FreeBSD arm64 at the switch's `ret`: one frame
        #  skipped, the resumed fibre's routine where hand_over should be.
        text = gdb_switch()
        ret = text.index(":\tret\n")
        end = text.index("LANDIN-SWITCH-STEP", ret)
        skipped = [SWITCH.SWITCH] + SWITCH.SWITCHES[0]["resumed"][1:]
        text = (text[:ret] + ":\tret\n"
                + "".join(f"#{i}  0x0000000000401000 in {name} ()\n"
                          for i, name in enumerate(skipped))
                + text[end:])
        with self.assertRaisesRegex(SWITCH.Mismatch, "ret"):
            SWITCH.check(SWITCH.gdb_stops(text), "x86-64", "linux-x86-64")
        shown = SWITCH.check(SWITCH.gdb_stops(text), "x86-64", "freebsd-arm64")
        self.assertIn("not judged", shown[SWITCH.SWITCHES[0]["name"]])

    def test_only_the_final_return_is_exempt(self) -> None:
        with self.assertRaisesRegex(SWITCH.Mismatch, "does not load"):
            SWITCH.check(SWITCH.gdb_stops(gdb_switch(swap_at=1)),
                         "x86-64", "freebsd-arm64")

    def test_frames_that_never_change_are_refused(self) -> None:
        with self.assertRaisesRegex(SWITCH.Mismatch, "every instruction"):
            self.check(gdb_switch(swap_at=10))

    #  D475: the symbol tables of gate run 40697578977's FreeBSD image,
    #  where LLDB named the switch `.Ldebug_end_11_0`, and of its fix.
    SHADOWED = ("00000000002023d4 t .L11_1_stack_limit\n"
                "00000000002023ea 0000000000000027 t landin.stack_switch\n"
                "00000000002023ea t .Ldebug_end_11_0\n"
                "0000000000202411 0000000000000040 t landin.stack_start\n"
                "0000000000202412 t .Llandin_stack_entered\n"
                "                 U write\n")
    CLEAN = ("00000000002116f0 t $x\n"
             "00000000002116f0 0000000000000078 t landin.stack_switch\n"
             "0000000000211768 0000000000000020 t landin.stack_start\n"
             "0000000000211788 t $x\n"
             "00000000002108b0 T .L_1_1\n")

    def test_a_label_at_the_switch_routine_is_refused(self) -> None:
        shadows = SWITCH.shadowing_symbols(self.SHADOWED)
        self.assertIn(".Ldebug_end_11_0 at landin.stack_switch's address"
                      " 0x2023ea", shadows)
        self.assertIn("2 private labels at code addresses", shadows[-1])

    def test_a_discarded_image_passes_with_mapping_and_global_dot_names(self) -> None:
        self.assertEqual(SWITCH.shadowing_symbols(self.CLEAN), [])

    def test_a_missing_routine_symbol_is_refused(self) -> None:
        self.assertEqual(SWITCH.shadowing_symbols("0000000000001000 T main\n"),
                         ["the image has no symbol landin.stack_start",
                          "the image has no symbol landin.stack_switch"])

    def test_mach_o_names_take_the_underscore_and_private_prefixes(self) -> None:
        image = ("00000001000007b0 t _landin.stack_switch\n"
                 "0000000100000828 t _landin.stack_start\n"
                 "0000000100000848 t llandin_trap_report\n")
        self.assertEqual(SWITCH.shadowing_symbols(image, "mach-o"),
                         ["1 private labels at code addresses, such as"
                          " llandin_trap_report at 0x100000848"])
        self.assertEqual(SWITCH.shadowing_symbols(image.rsplit("0000000100000848", 1)[0],
                                                  "mach-o"), [])

    def test_an_lldb_transcript_reads_the_same(self) -> None:
        def bt(frames):
            return "".join(f"  frame #{i}: 0x0000000000401000 program`{name}"
                           + ("(save=0x1) at main.ldn:28:5" if name == "hand_over"
                              else " + 7" if name == SWITCH.START else "")
                           + "\n" for i, name in enumerate(frames))
        lines = ["(lldb) run", "(lldb) thread backtrace",
                 bt(SWITCH.STOPS["fibre"] + [SWITCH.START]),
                 "(lldb) breakpoint delete --force"]
        instructions = ["pushq %rbp", "movq %rsp, (%rdi)", "movq %rsi, %rsp",
                        "popq %rbp", "retq"]
        for each in SWITCH.SWITCHES:
            for offset, instruction in enumerate(instructions + [None]):
                lines.append("(lldb) " + ("continue" if offset == 0
                                          else "thread step-inst"))
                if instruction is None:
                    lines += ["(lldb) thread backtrace", bt(each["resumed"])]
                    continue
                lines.append(f"->  0x401{offset:03x} <+{offset}>: {instruction}")
                above = each["leaving"] if offset <= 2 else each["resumed"]
                lines += ["(lldb) thread backtrace", bt([SWITCH.SWITCH] + above)]
        stops = SWITCH.lldb_stops("\n".join(lines))
        self.assertEqual(SWITCH.check(stops, "x86-64")["second-to-first"]["turn"], 3)


class BuildSourceTests(unittest.TestCase):
    """A copied compiler reaches its library through a symlinked prefix."""

    def test_a_library_behind_a_symlinked_prefix_is_this_checkout(self) -> None:
        named = ("compiler/tests/debugging/main.ldn",)
        library = sorted(str(path) for path in
                         (CHECK.ROOT / "platform/linux").glob("*.ldn"))
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary) / "copied"
            (prefix / "lib").mkdir(parents=True)
            (prefix / "lib/landin").symlink_to(CHECK.ROOT)
            reported = named + tuple(
                str(prefix / "lib/landin" / Path(path).relative_to(CHECK.ROOT))
                for path in library)
            CHECK.check_build_sources(reported, named + tuple(library))

    def test_another_library_is_refused_naming_both_paths(self) -> None:
        named = ("compiler/tests/debugging/main.ldn",)
        library = sorted(str(path) for path in
                         (CHECK.ROOT / "platform/linux").glob("*.ldn"))
        with tempfile.TemporaryDirectory() as temporary:
            other = Path(temporary).resolve() / "base"
            (other / "platform/linux").mkdir(parents=True)
            link = Path(temporary) / "linked"
            link.symlink_to(other)
            reported = named + tuple(str(link / "platform/linux" / Path(path).name)
                                     for path in library)
            with self.assertRaises(ValueError) as refused:
                CHECK.check_build_sources(reported, named + tuple(library))
        text = str(refused.exception)
        self.assertIn(f"{reported[1]} -> {other / 'platform/linux' / Path(library[0]).name}",
                      text)
        self.assertIn(library[0], text)
        self.assertIn("reported:", text)
        self.assertIn("expected:", text)


if __name__ == "__main__":
    unittest.main()
