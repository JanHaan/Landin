#!/usr/bin/env python3
"""Scripted Linux source-debugging acceptance, not a debug-info golden."""
from __future__ import annotations

import argparse
from collections.abc import Callable
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MAIN_SOURCE = HERE / "main.ldn"
ODD_SOURCE = HERE / 'caller"\\path.ldn'
SOURCES = (MAIN_SOURCE, ODD_SOURCE)
CONTAINER_SOURCE = ROOT / "examples/derived_containers/workload/workload.ldn"
CONTAINER_FIXTURE = HERE.parent / "fixtures/runtime/derived-containers"
HOSTED_SOURCE = ROOT / "examples/derived_hosted/app/app.ldn"
HOSTED_FIXTURE = HERE.parent / "fixtures/runtime/derived-hosted-memory"
WORKLOAD_COMPILE_TIMEOUT = 900
CONTAINER_DONE_VALUES = (
    "signed_order", "unsigned_order_ok", "numbers_ok", "arrays_ok", "raw_ok",
    "vector_ok", "small_ok", "map_ok", "reference_entries_ok",
    "map_first_failure_ok", "map_second_failure_ok", "map_third_failure_ok",
    "tree_ok", "drawables_ok",
)
PRIMARY_PROFILES = (("none-off", "none", "off"),
                    ("size-auto", "size", "auto"))
FALLBACK_PROFILE = ("size-all", "size", "all")
DEBUG_SECTIONS = (".debug_info", ".debug_abbrev", ".debug_line",
                  ".debug_loc", ".debug_frame")


class Native_Transport_Unavailable(ValueError):
    """The host cannot provide ptrace even though the test remains failed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def run(args: list[str], *, cwd: Path | None = None,
        expected_status: int = 0, empty_output: bool = False,
        timeout: int = 120) -> str:
    completed = subprocess.run(args, cwd=cwd, check=False,
                               stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True,
                               timeout=timeout,
                               env={**os.environ, "LC_ALL": "C"})
    require(completed.returncode == expected_status,
            f"command returned {completed.returncode}, expected "
            f"{expected_status}: {args!r}\n{completed.stdout}")
    if empty_output:
        require(completed.stdout == "",
                f"program produced unexpected output: {completed.stdout!r}")
    return completed.stdout


def tool(home: Path, name: str) -> str:
    candidates = (home / "bin" / f"x86_64-pc-linux-gnu-{name}",
                  home / "bin" / name)
    selected = next((path for path in candidates if path.is_file()), None)
    require(selected is not None, f"pinned installation lacks {name}")
    return str(selected)


def command(name: str) -> str:
    selected = shutil.which(name)
    require(selected is not None, f"{name} is not on PATH")
    return selected


def source_line(path: Path, needle: str, occurrence: int = 0) -> int:
    matches = [number for number, line in enumerate(
               path.read_text().splitlines(), 1) if needle in line]
    require(len(matches) > occurrence,
            f"source marker {needle!r} is absent from {path.name}")
    return matches[occurrence]


def gas_string(value: bytes) -> str:
    escaped = []
    for byte in value:
        if byte in (ord('"'), ord("\\")):
            escaped.append("\\" + chr(byte))
        elif 32 <= byte <= 126:
            escaped.append(chr(byte))
        else:
            escaped.append(f"\\{byte:03o}")
    return "".join(escaped)


def marker_section(transcript: str, name: str) -> str:
    match = re.search(r"^LANDIN-BEGIN " + re.escape(name) +
                      r"\n(.*?)^LANDIN-END " + re.escape(name) + r"$",
                      transcript, re.M | re.S)
    require(match is not None, f"GDB transcript lacks section {name}")
    return match.group(1)


def emit_section(lines: list[str], name: str, commands: list[str]) -> None:
    lines.append(f'printf "LANDIN-BEGIN {name}\\n"')
    lines.extend(commands)
    lines.append(f'printf "LANDIN-END {name}\\n"')


def emit_value(lines: list[str], name: str, expression: str,
               unsigned: bool = False) -> None:
    lines.append(f'printf "LANDIN-VALUE {name}="')
    lines.append(f"output/{'u' if unsigned else 'd'} {expression}")
    lines.append('printf "\\n"')


def emit_values(lines: list[str], scope: str,
                values: tuple[tuple[str, str], ...]) -> None:
    for name, expression in values:
        emit_value(lines, f"{scope}.{name}", expression)


def gdb_setup() -> list[str]:
    return [
        "set pagination off",
        "set confirm off",
        "set width 0",
        "set print pretty off",
        "set print elements 0",
        "set print frame-arguments none",
        "set multiple-symbols all",
        "set breakpoint pending off",
        "set debuginfod enabled off",
        "set disable-randomization off",
        "set startup-with-shell off",
        "set sysroot /",
    ]


def gdb_script(start_commands: list[str], source_lines: dict[str, int]) -> str:
    source_name = os.path.relpath(MAIN_SOURCE, ROOT)
    lines = [
        *gdb_setup(),
        "break debug_outer",
        *start_commands,
    ]
    emit_section(lines, "outer-function", ["frame", "info args", "info line"])
    lines.extend(["delete breakpoints",
                  f"tbreak {source_name}:{source_lines['outer-ready']}",
                  "continue"])
    emit_section(lines, "outer-ready-line", ["frame", "info line"])
    emit_section(lines, "outer-source",
                 [f"list {source_lines['outer-ready']},{source_lines['outer-ready']}"])
    emit_section(lines, "outer-locals", ["info args", "info locals"])
    emit_values(lines, "outer", (
        ("call_file", "call_site.file_id"),
        ("call_line", "call_site.line"),
        ("call_column", "call_site.column"),
        ("scalar_param", "scalar_param"),
        ("pointee", "*pointer_param"),
        ("record_tiny", "record_param.tiny"),
        ("record_huge", "record_param.huge"),
        ("record_middle", "record_param.middle"),
        ("array_0", "array_param[0]"),
        ("array_1", "array_param[1]"),
        ("array_2", "array_param[2]"),
        ("scalar_local", "scalar_local"),
        ("local_pointee", "*pointer_local"),
        ("local_record_huge", "record_local.huge"),
        ("local_array_2", "array_local[2]"),
        ("saved_a", "saved_a"),
        ("saved_b", "saved_b"),
        ("saved_c", "saved_c"),
    ))
    emit_section(lines, "outer-variant", ["output variant_param", "printf \"\\n\"",
                                            "output variant_local", "printf \"\\n\""])
    emit_values(lines, "outer", (
        ("variant_param.choice.tag", "variant_param.choice.tag"),
        ("variant_param.choice.payload.record.tiny",
         "variant_param.choice.payload.record.tiny"),
        ("variant_param.choice.payload.record.huge",
         "variant_param.choice.payload.record.huge"),
        ("variant_param.choice.payload.record.middle",
         "variant_param.choice.payload.record.middle"),
        ("variant_param.choice.payload.values[0]",
         "variant_param.choice.payload.values[0]"),
        ("variant_param.choice.payload.values[1]",
         "variant_param.choice.payload.values[1]"),
        ("variant_param.choice.payload.values[2]",
         "variant_param.choice.payload.values[2]"),
        ("variant_local.choice.tag", "variant_local.choice.tag"),
        ("variant_local.choice.payload.record.tiny",
         "variant_local.choice.payload.record.tiny"),
        ("variant_local.choice.payload.record.huge",
         "variant_local.choice.payload.record.huge"),
        ("variant_local.choice.payload.record.middle",
         "variant_local.choice.payload.record.middle"),
        ("variant_local.choice.payload.values[0]",
         "variant_local.choice.payload.values[0]"),
        ("variant_local.choice.payload.values[1]",
         "variant_local.choice.payload.values[1]"),
        ("variant_local.choice.payload.values[2]",
         "variant_local.choice.payload.values[2]"),
    ))
    lines.append("step")
    emit_section(lines, "inner-entry", ["frame", "info line"])
    emit_section(lines, "nested-stack", ["bt 8"])
    lines.append("frame 1")
    emit_values(lines, "saved-outer", (
        ("call_file", "call_site.file_id"),
        ("call_line", "call_site.line"),
        ("call_column", "call_site.column"),
        ("scalar_param", "scalar_param"),
        ("pointee", "*pointer_param"),
        ("record_huge", "record_param.huge"),
        ("array_1", "array_param[1]"),
        ("scalar_local", "scalar_local"),
        ("local_record_middle", "record_local.middle"),
        ("local_array_2", "array_local[2]"),
        ("saved_a", "saved_a"),
        ("saved_b", "saved_b"),
        ("saved_c", "saved_c"),
    ))
    lines.extend(["frame 0",
                  f"tbreak {source_name}:{source_lines['inner-ready']}",
                  "continue"])
    emit_section(lines, "inner-ready-line", ["frame", "info line"])
    emit_section(lines, "inner-source",
                 [f"list {source_lines['inner-ready']},{source_lines['inner-ready']}"])
    emit_section(lines, "inner-locals", ["info args", "info locals"])
    emit_values(lines, "inner", (
        ("scalar_param", "scalar_param"),
        ("pointee", "*pointer_param"),
        ("record_tiny", "record_param.tiny"),
        ("record_huge", "record_param.huge"),
        ("record_middle", "record_param.middle"),
        ("array_0", "array_param[0]"),
        ("array_1", "array_param[1]"),
        ("array_2", "array_param[2]"),
        ("scalar_local", "scalar_local"),
        ("local_pointee", "*pointer_local"),
        ("local_record_tiny", "record_local.tiny"),
        ("local_record_huge", "record_local.huge"),
        ("local_record_middle", "record_local.middle"),
        ("local_array_0", "array_local[0]"),
        ("local_array_1", "array_local[1]"),
        ("local_array_2", "array_local[2]"),
        ("saved_a", "saved_a"),
        ("saved_b", "saved_b"),
        ("saved_c", "saved_c"),
    ))
    emit_section(lines, "inner-record-type", ["ptype record_param"])
    emit_section(lines, "inner-pointer-type", ["ptype pointer_param"])
    emit_section(lines, "inner-array-type", ["ptype array_param"])
    emit_section(lines, "inner-variant-type", ["ptype variant_param"])
    emit_section(lines, "inner-variant", ["output variant_param", "printf \"\\n\"",
                                            "output variant_local", "printf \"\\n\""])
    emit_values(lines, "inner", (
        ("variant_param.choice.tag", "variant_param.choice.tag"),
        ("variant_param.choice.payload.record.tiny",
         "variant_param.choice.payload.record.tiny"),
        ("variant_param.choice.payload.record.huge",
         "variant_param.choice.payload.record.huge"),
        ("variant_param.choice.payload.record.middle",
         "variant_param.choice.payload.record.middle"),
        ("variant_param.choice.payload.values[0]",
         "variant_param.choice.payload.values[0]"),
        ("variant_param.choice.payload.values[1]",
         "variant_param.choice.payload.values[1]"),
        ("variant_param.choice.payload.values[2]",
         "variant_param.choice.payload.values[2]"),
        ("variant_local.choice.tag", "variant_local.choice.tag"),
        ("variant_local.choice.payload.record.tiny",
         "variant_local.choice.payload.record.tiny"),
        ("variant_local.choice.payload.record.huge",
         "variant_local.choice.payload.record.huge"),
        ("variant_local.choice.payload.record.middle",
         "variant_local.choice.payload.record.middle"),
        ("variant_local.choice.payload.values[0]",
         "variant_local.choice.payload.values[0]"),
        ("variant_local.choice.payload.values[1]",
         "variant_local.choice.payload.values[1]"),
        ("variant_local.choice.payload.values[2]",
         "variant_local.choice.payload.values[2]"),
    ))
    lines.append("next")
    emit_section(lines, "inner-next-line", ["frame", "info line"])
    lines.extend([f"tbreak {source_name}:{source_lines['inner-lexical']}",
                  "continue"])
    emit_section(lines, "inner-lexical-line", ["frame", "info line"])
    emit_section(lines, "inner-lexical-source",
                 [f"list {source_lines['inner-lexical']},{source_lines['inner-lexical']}"])
    emit_section(lines, "inner-lexical-locals", ["info locals"])
    emit_values(lines, "inner-lexical", (
        ("param_record_huge", "param_record.huge"),
        ("param_values_1", "param_values[1]"),
        ("local_record_middle", "local_record.middle"),
        ("local_values_2", "local_values[2]"),
    ))
    emit_section(lines, "generic-functions", ["info functions debug_generic"])
    lines.append("break debug_generic")
    emit_section(lines, "generic-breakpoints", ["info breakpoints"])
    lines.append("continue")
    emit_section(lines, "generic-entry", ["frame", "info args", "info line"])
    lines.extend([f"tbreak {source_name}:{source_lines['generic-ready']}",
                  "continue"])
    emit_section(lines, "generic-ready-line", ["frame", "info line"])
    emit_section(lines, "generic-source",
                 [f"list {source_lines['generic-ready']},{source_lines['generic-ready']}"])
    emit_section(lines, "generic-locals", ["info args", "info locals"])
    emit_values(lines, "generic", (
        ("param", "generic_param"),
        ("bound", "generic_bound"),
        ("local", "generic_local"),
    ))
    emit_section(lines, "generic-stack", ["bt 8"])
    lines.append("next")
    emit_section(lines, "generic-next-line", ["frame", "info line"])
    lines.extend(["delete breakpoints", "break debug_multiple", "continue"])
    emit_section(lines, "multiple-entry", ["frame", "info args", "info line"])
    lines.extend(["delete breakpoints",
                  f"tbreak {source_name}:{source_lines['multiple-ready']}",
                  "continue"])
    emit_section(lines, "multiple-ready-line", ["frame", "info line"])
    emit_section(lines, "multiple-source",
                 [f"list {source_lines['multiple-ready']},"
                  f"{source_lines['multiple-ready']}"])
    emit_section(lines, "multiple-locals", ["info args", "info locals"])
    emit_values(lines, "multiple", (
        ("base", "base"),
        ("first", "first"),
        ("second", "second"),
    ))
    lines.extend([f"tbreak {source_name}:{source_lines['aliases-ready']}",
                  "continue"])
    emit_section(lines, "aliases-ready-line", ["frame", "info line"])
    emit_section(lines, "aliases-source",
                 [f"list {source_lines['aliases-ready']},"
                  f"{source_lines['aliases-ready']}"])
    emit_section(lines, "aliases-locals", ["info args", "info locals"])
    emit_values(lines, "aliases", (
        ("renamed_left", "renamed_left"),
        ("renamed_right", "renamed_right"),
    ))
    lines.extend([f"tbreak {source_name}:{source_lines['loop-element']}",
                  "continue"])
    emit_section(lines, "loop-element-line", ["frame", "info line"])
    emit_section(lines, "loop-element-source",
                 [f"list {source_lines['loop-element']},"
                  f"{source_lines['loop-element']}"])
    emit_section(lines, "loop-element-locals", ["info locals"])
    emit_values(lines, "loop", (
        ("element", "loop_element"),
        ("sum", "loop_sum"),
    ))
    lines.append("delete breakpoints")
    emit_section(lines, "inferior-exit", ["continue"])
    return "\n".join(lines) + "\n"


def container_lines() -> dict[str, int]:
    source = CONTAINER_SOURCE.read_text().splitlines()
    result = {}
    for name, marker in (("evidence", "R470_DEBUG_EVIDENCE_ENTRY"),
                         ("sorted", "R470_DEBUG_SORTED_LIST"),
                         ("done", "R470_DEBUG_CONTAINERS_DONE")):
        matches = [index for index, line in enumerate(source) if marker in line]
        require(len(matches) == 1, f"container marker {marker} is not unique")
        index = matches[0] + 1
        require(index < len(source) and source[index].strip()
                and not source[index].lstrip().startswith("--"),
                f"container marker {marker} does not precede executable source")
        result[name] = index + 1
    for occurrence, instance in enumerate(("signed", "unsigned")):
        result[instance + "-provider"] = source_line(
            CONTAINER_SOURCE, "yes = left < right", occurrence)
    result["signed-call"] = source_line(CONTAINER_SOURCE, "signed_order: bool =")
    result["unsigned-call"] = source_line(CONTAINER_SOURCE, "unsigned_order_ok: bool =")
    result["signed-ready"] = result["unsigned-call"]
    result["unsigned-ready"] = source_line(CONTAINER_SOURCE, "numbers_ok: bool =")
    return result


def container_gdb_script(start_commands: list[str],
                         source_lines: dict[str, int]) -> str:
    source_name = os.path.relpath(CONTAINER_SOURCE, ROOT)
    lines = gdb_setup()
    # These real workload stops may precede or follow the two evidence calls.
    # Breakpoint commands record them without prescribing application order.
    for name in ("sorted", "done"):
        line = source_lines[name]
        lines.extend([f"break {source_name}:{line}", "commands", "silent"])
        emit_section(lines, f"container-{name}",
                     ["frame", "info line", f"list {line},{line}", "info locals"])
        if name == "sorted":
            emit_values(lines, "container-sorted", (
                ("count", "count"), ("first", "first"), ("last", "last")))
        else:
            emit_values(lines, "container-done",
                        tuple((name, name) for name in CONTAINER_DONE_VALUES))
        lines.extend(["continue", "end"])
    lines.append(f"break {source_name}:{source_lines['evidence']}")
    emit_section(lines, "container-evidence-breakpoints", ["info breakpoints"])
    lines.extend(start_commands)
    for instance in ("signed", "unsigned"):
        scope = f"container-{instance}"
        emit_section(lines, scope, ["frame", "info line", "info args"])
        for name in ("left", "right"):
            emit_value(lines, scope + "." + name, name,
                       unsigned=instance == "unsigned")
        lines.append("step")
        emit_section(lines, scope + "-dispatch", ["frame", "info line", "bt 8"])
        emit_section(lines, scope + "-provider-return", ["finish", "frame", "info line"])
        emit_section(lines, scope + "-return", ["finish", "frame", "info line"])
        # Observe the source binding after its assignment, not GDB's optional
        # return-value prose or an ABI-specific result register.
        emit_section(lines, scope + "-ready", ["next", "frame", "info line"])
        result_name = "signed_order" if instance == "signed" else "unsigned_order_ok"
        emit_value(lines, scope + "." + result_name, result_name)
        if instance == "signed":
            lines.append("continue")
    emit_section(lines, "inferior-exit", ["continue"])
    return "\n".join(lines) + "\n"


def check_container_transcript(transcript: str,
                               source_lines: dict[str, int]) -> None:
    for phrase in ("No symbol ", "No source file named", "Cannot access memory",
                   "Cannot find bounds", "not defined"):
        require(phrase not in transcript,
                f"container GDB transcript contains {phrase!r}\n{transcript}")
    for name, function in (("sorted", "numbers_path"),
                           ("done", "containers_run")):
        expect_line(transcript, f"container-{name}", source_lines[name],
                    function, "workload.ldn")
    for instance, provider, left, right, result_name in (
            ("signed", "less_i32", -1, 1, "signed_order"),
            ("unsigned", "less_u32", 4294967295, 1, "unsigned_order_ok")):
        scope = f"container-{instance}"
        expect_line(transcript, scope, source_lines["evidence"],
                    "evidence_less", "workload.ldn")
        expect_value(transcript, scope + ".left", left)
        expect_value(transcript, scope + ".right", right)
        expect_line(transcript, scope + "-dispatch",
                    source_lines[instance + "-provider"], provider, "workload.ldn")
        stack = marker_section(transcript, scope + "-dispatch")
        require(re.search(r"#0\s+.*\b" + provider + r"\b", stack) is not None
                and re.search(r"#1\s+.*\bevidence_less\b", stack) is not None
                and re.search(r"#2\s+.*\bcontainers_run\b", stack) is not None
                and re.search(r"#3\s+.*\bmain\b", stack) is not None,
                f"container evidence step lost its source stack: {stack!r}")
        for suffix, function, line in (
                ("-provider-return", "evidence_less", source_lines["evidence"]),
                ("-return", "containers_run", source_lines[instance + "-call"]),
                ("-ready", "containers_run", source_lines[instance + "-ready"])):
            expect_line(transcript, scope + suffix, line, function, "workload.ldn")
            returned = marker_section(transcript, scope + suffix)
            require(re.search(r"#0\s+.*\b" + function + r"\b", returned) is not None,
                    f"container evidence lost its caller frame: {returned!r}")
        expect_value(transcript, scope + "." + result_name, 1)
    for name, value in (("count", 20), ("first", 1), ("last", 20)):
        expect_value(transcript, f"container-sorted.{name}", value)
    for name in CONTAINER_DONE_VALUES:
        expect_value(transcript, f"container-done.{name}", 1)
    inferior_exit = marker_section(transcript, "inferior-exit")
    require(re.search(r"exited with code (?:052|42)\b", inferior_exit) is not None,
            f"debugged container program did not return 42: {inferior_exit!r}")


def hosted_lines() -> dict[str, int]:
    result = {}
    for name, filename, marker in (
            ("sample", "filter.ldn", "R480_DEBUG_SAMPLE"),
            ("text", "dest.ldn", "R480_DEBUG_TEXT")):
        source = (HOSTED_SOURCE.parent / filename).read_text().splitlines()
        matches = [index for index, line in enumerate(source) if marker in line]
        require(len(matches) == 1, f"hosted marker {marker} is not unique")
        index = matches[0] + 1
        require(index < len(source) and source[index].strip()
                and not source[index].lstrip().startswith("--"),
                f"hosted marker {marker} does not precede executable source")
        result[name] = index + 1
    result["sample-updated"] = source_line(
        HOSTED_SOURCE.parent / "filter.ldn", "yes = self.val.seen")
    return result


def hosted_gdb_script(start_commands: list[str],
                      source_lines: dict[str, int]) -> str:
    lines = gdb_setup()
    for name, filename, values in (
            ("sample", "filter.ldn", (("seen", "self->seen"),
                                      ("every", "self->every"))),
            ("sample-updated", "filter.ldn", (("seen", "self->seen"),)),
            ("text", "dest.ldn", (("delivered", "line.delivered"),))):
        source = os.path.relpath(HOSTED_SOURCE.parent / filename, ROOT)
        line = source_lines[name]
        lines.extend([f"tbreak {source}:{line}", "commands", "silent"])
        emit_section(lines, f"hosted-{name}",
                     ["frame", "info line", f"list {line},{line}",
                      "info args", "info locals", "bt 12"])
        emit_values(lines, f"hosted-{name}", values)
        lines.extend(["continue", "end"])
    emit_section(lines, "inferior-exit", start_commands)
    return "\n".join(lines) + "\n"


def check_hosted_transcript(transcript: str,
                            source_lines: dict[str, int]) -> None:
    for phrase in ("No symbol ", "No source file named", "Cannot access memory",
                   "Cannot find bounds", "not defined"):
        require(phrase not in transcript,
                f"hosted GDB transcript contains {phrase!r}\n{transcript}")
    for name, function, filename in (("sample", "sample_keep", "filter.ldn"),
                                     ("sample-updated", "sample_keep", "filter.ldn"),
                                     ("text", "text_emit", "dest.ldn")):
        scope = f"hosted-{name}"
        expect_line(transcript, scope, source_lines[name], function, filename)
        stack = marker_section(transcript, scope)
        functions = (function, *(("emit_retry",) if name == "text" else ()),
                     "process", "run_logged", "run", "main")
        require(all(re.search(rf"#{index}\s+.*\b{expected}\b", stack) is not None
                    for index, expected in enumerate(functions)),
                f"hosted runtime dispatch lost its source stack: {stack!r}")
    for name, value in (("sample.seen", 0), ("sample.every", 2),
                        ("sample-updated.seen", 1), ("text.delivered", 0)):
        expect_value(transcript, "hosted-" + name, value)
    inferior_exit = marker_section(transcript, "inferior-exit")
    require(re.search(r"exited with code (?:052|42)\b", inferior_exit) is not None,
            f"debugged hosted program did not return 42: {inferior_exit!r}")


def expect_value(transcript: str, name: str, value: int) -> None:
    require(re.search(r"^LANDIN-VALUE " + re.escape(name) + "=" +
                      re.escape(str(value)) + r"$", transcript, re.M) is not None,
            f"GDB did not report {name}={value}")


def expect_line(transcript: str, section_name: str, line: int,
                function: str, source_name: str = "main.ldn") -> None:
    section = marker_section(transcript, section_name)
    require(re.search(rf"\b{re.escape(function)}\b", section) is not None,
            f"{section_name} stopped outside {function}: {section!r}")
    require(re.search(rf"\bLine {line}\b", section) is not None,
            f"{section_name} did not identify source line {line}: {section!r}")
    require(source_name in section,
            f"{section_name} did not identify {source_name}: {section!r}")


def expect_one_of_lines(transcript: str, section_name: str,
                        lines: tuple[int, ...], function: str) -> None:
    section = marker_section(transcript, section_name)
    require(re.search(rf"\b{re.escape(function)}\b", section) is not None,
            f"{section_name} stopped outside {function}: {section!r}")
    require(any(re.search(rf"\bLine {line}\b", section) is not None
                for line in lines),
            f"{section_name} did not identify one of source lines "
            f"{lines!r}: {section!r}")
    require("main.ldn" in section,
            f"{section_name} did not identify main.ldn: {section!r}")


def check_transcript(transcript: str, source_lines: dict[str, int],
                     caller_line: int, caller_column: int) -> None:
    forbidden = ("No symbol ", "No source file named",
                 "Cannot access memory", "Cannot find bounds", "not defined")
    for phrase in forbidden:
        require(phrase not in transcript,
                f"GDB transcript contains {phrase!r}\n{transcript}")
    expect_line(transcript, "outer-function", source_lines["outer-entry"],
                "debug_outer")
    expect_line(transcript, "outer-ready-line", source_lines["outer-ready"],
                "debug_outer")
    expect_line(transcript, "inner-entry", source_lines["inner-entry"],
                "debug_inner")
    expect_line(transcript, "inner-ready-line", source_lines["inner-ready"],
                "debug_inner")
    expect_line(transcript, "inner-next-line", source_lines["inner-next"],
                "debug_inner")
    expect_line(transcript, "inner-lexical-line", source_lines["inner-lexical"],
                "debug_inner")
    expect_line(transcript, "generic-entry", source_lines["generic-entry"],
                "debug_generic")
    expect_line(transcript, "generic-ready-line", source_lines["generic-ready"],
                "debug_generic")
    expect_one_of_lines(transcript, "generic-next-line", GENERIC_NEXT_LINES,
                        "debug_generic")
    expect_line(transcript, "multiple-entry", source_lines["multiple-entry"],
                "debug_multiple")
    expect_line(transcript, "multiple-ready-line",
                source_lines["multiple-ready"], "debug_multiple")
    expect_line(transcript, "aliases-ready-line", source_lines["aliases-ready"],
                "debug_aliases")
    expect_line(transcript, "loop-element-line", source_lines["loop-element"],
                "debug_aliases")
    for section_name, source_text in (
            ("outer-source", "inner_result: i32 = debug_inner("),
            ("inner-source", "step_local: i32 = scalar_local"),
            ("inner-lexical-source", "and param_record.huge"),
            ("generic-source", "generic_result = t.less"),
            ("multiple-source", "multiple_ready: i32 = first + second"),
            ("aliases-source", "aliases_ready: i32 = renamed_left + renamed_right"),
            ("loop-element-source", "loop_sum += loop_element")):
        section = marker_section(transcript, section_name)
        require(source_text in section,
                f"{section_name} cannot list emitted source: {section!r}")
    inferior_exit = marker_section(transcript, "inferior-exit")
    require(re.search(r"exited with code (?:052|42)\b", inferior_exit) is not None,
            f"debugged inferior did not exit with status 42: {inferior_exit!r}")
    stack = marker_section(transcript, "nested-stack")
    require(re.search(r"#0\s+.*\bdebug_inner\b", stack) is not None and
            re.search(r"#1\s+.*\bdebug_outer\b", stack) is not None and
            re.search(r"#2\s+.*\bmain\b", stack) is not None and
            ODD_SOURCE.name in stack,
            f"nested Landin stack is incomplete: {stack!r}")
    generic_functions = marker_section(transcript, "generic-functions")
    require("debug_generic" in generic_functions,
            f"GDB does not index debug_generic: {generic_functions!r}")
    generic_breakpoints = marker_section(transcript, "generic-breakpoints")
    breakpoint_addresses = set(re.findall(
        r"^\s*\d+\.\d+\s+.*?\b(0x[0-9a-fA-F]+)\b"
        r".*\bdebug_generic\b", generic_breakpoints, re.M))
    require(len(breakpoint_addresses) >= 2,
            f"source-name breakpoint does not cover both generic instances: "
            f"{generic_breakpoints!r}")
    generic_stack = marker_section(transcript, "generic-stack")
    require(re.search(r"#0\s+.*\bdebug_generic\b", generic_stack) is not None
            and re.search(r"#1\s+.*\bmain\b", generic_stack) is not None,
            f"specialized generic stack is incomplete: {generic_stack!r}")
    expected = {
        "outer.call_file": 2, "outer.call_line": caller_line,
        "outer.call_column": caller_column, "outer.scalar_param": 37,
        "outer.pointee": 41, "outer.record_tiny": 7,
        "outer.record_huge": 7000000000, "outer.record_middle": 901,
        "outer.array_0": 111, "outer.array_1": 222, "outer.array_2": 333,
        "outer.scalar_local": 37, "outer.local_pointee": 41,
        "outer.local_record_huge": 7000000000, "outer.local_array_2": 333,
        "outer.saved_a": 51, "outer.saved_b": 52, "outer.saved_c": 53,
        "saved-outer.call_file": 2, "saved-outer.call_line": caller_line,
        "saved-outer.call_column": caller_column,
        "saved-outer.scalar_param": 37, "saved-outer.pointee": 41,
        "saved-outer.record_huge": 7000000000,
        "saved-outer.array_1": 222, "saved-outer.scalar_local": 37,
        "saved-outer.local_record_middle": 901,
        "saved-outer.local_array_2": 333,
        "saved-outer.saved_a": 51, "saved-outer.saved_b": 52,
        "saved-outer.saved_c": 53,
        "inner.scalar_param": 37, "inner.pointee": 41,
        "inner.record_tiny": 7, "inner.record_huge": 7000000000,
        "inner.record_middle": 901, "inner.array_0": 111,
        "inner.array_1": 222, "inner.array_2": 333,
        "inner.scalar_local": 38, "inner.local_pointee": 41,
        "inner.local_record_tiny": 7,
        "inner.local_record_huge": 7000000000,
        "inner.local_record_middle": 901,
        "inner.local_array_0": 111, "inner.local_array_1": 222,
        "inner.local_array_2": 333, "inner.saved_a": 51,
        "inner.saved_b": 52, "inner.saved_c": 53,
        "inner-lexical.param_record_huge": 7000000000,
        "inner-lexical.param_values_1": 222,
        "inner-lexical.local_record_middle": 901,
        "inner-lexical.local_values_2": 333,
        "generic.param": -1, "generic.bound": 1, "generic.local": -1,
        "multiple.base": 5, "multiple.first": 15, "multiple.second": 25,
        "aliases.renamed_left": 15, "aliases.renamed_right": 25,
        "loop.element": 3, "loop.sum": 0,
    }
    variant_members = {
        "choice.tag": 1,
        "choice.payload.record.tiny": 7,
        "choice.payload.record.huge": 7000000000,
        "choice.payload.record.middle": 901,
        "choice.payload.values[0]": 111,
        "choice.payload.values[1]": 222,
        "choice.payload.values[2]": 333,
    }
    for scope in ("outer", "inner"):
        for variable in ("variant_param", "variant_local"):
            for member, value in variant_members.items():
                expected[f"{scope}.{variable}.{member}"] = value
    for name, value in expected.items():
        expect_value(transcript, name, value)
    for section_name, names in (
            ("outer-locals", ("scalar_param", "pointer_param", "record_param",
                              "variant_param", "array_param", "scalar_local",
                              "pointer_local", "record_local", "variant_local",
                              "array_local", "inner_result", "result")),
            ("inner-locals", ("scalar_param", "pointer_param", "record_param",
                              "variant_param", "array_param", "scalar_local",
                              "pointer_local", "record_local", "variant_local",
                              "array_local", "step_local", "next_local", "result")),
            ("inner-lexical-locals", ("param_record", "param_values",
                                      "local_record", "local_values")),
            ("generic-locals", ("generic_param", "generic_bound",
                                "generic_local", "generic_result")),
            ("multiple-locals", ("first", "second")),
            ("aliases-locals", ("renamed_left", "renamed_right")),
            ("loop-element-locals", ("loop_element", "loop_sum"))):
        section = marker_section(transcript, section_name)
        for name in names:
            require(re.search(r"\b" + re.escape(name) + r"\b", section),
                    f"{section_name} omits {name}: {section!r}")
    record_type = marker_section(transcript, "inner-record-type")
    for name in ("debug_record", "tiny", "huge", "middle"):
        require(name in record_type, f"record type omits {name}: {record_type!r}")
    pointer_type = marker_section(transcript, "inner-pointer-type")
    require("i32" in pointer_type and ("*" in pointer_type or
                                       "ptr" in pointer_type),
            f"pointer type is not inspectable: {pointer_type!r}")
    array_type = marker_section(transcript, "inner-array-type")
    require(re.search(r"\bu16\b", array_type) is not None and
            (re.search(r"\[\s*3\s*\]", array_type) is not None or
             re.search(r"\[\s*0\s*\.\.\s*2\s*\]", array_type) is not None),
            f"fixed-array type is not inspectable: {array_type!r}")
    variant_type = marker_section(transcript, "inner-variant-type")
    variant_values = (marker_section(transcript, "outer-variant") +
                      marker_section(transcript, "inner-variant"))
    for name in ("debug_choice", "empty", "payload", "record", "values"):
        require(name in variant_type or name in variant_values,
                f"variant debug view omits {name}")
    require(re.search(r"\btag = 1\b", variant_values) is not None,
            "variant debug view omits the active payload tag")
    for value in ("7000000000", "111", "222", "333"):
        require(value in variant_values,
                f"variant payload debug view omits {value}")


def check_line_table(raw_lines: str,
                     source_args: tuple[str, ...]) -> list[int]:
    versions = [int(version) for version in re.findall(
        r"^\s*DWARF Version:\s*(\d+)\s*$", raw_lines, re.M)]
    require(versions and all(version in (3, 4) for version in versions),
            f"line tables use unsupported versions: {versions!r}")
    directory_section = re.search(
        r"^\s*The Directory Table .*?:\n(.*?)(?=\n\n)",
        raw_lines, re.M | re.S)
    file_section = re.search(
        r"^\s*The File Name Table .*?:\n.*?\n(.*?)(?=\n\n)",
        raw_lines, re.M | re.S)
    require(directory_section is not None and file_section is not None,
            "raw line table omits its directory or file-name table")
    directories = {
        int(match.group(1)): match.group(2)
        for match in re.finditer(r"^\s*(\d+)\s+(.*?)\s*$",
                                 directory_section.group(1), re.M)
    }
    files = {
        int(match.group(1)): (int(match.group(2)), match.group(3))
        for match in re.finditer(
            r"^\s*(\d+)\s+(\d+)\s+\d+\s+\d+\s+(.*?)\s*$",
            file_section.group(1), re.M)
    }
    require(set(files) == set(range(1, len(source_args) + 1)),
            f"line-table file IDs differ from Source_Id order: {files!r}")
    for expected_id, source_arg in enumerate(source_args, 1):
        directory_id, basename = files[expected_id]
        require(basename == Path(source_arg).name,
                f"line-table file {expected_id} has wrong basename {basename!r}")
        # Path.parent normalizes away the leading ./ of rooted imports,
        # but the assembler's directory table retains that source spelling.
        require(directories.get(directory_id) == (os.path.dirname(source_arg) or "."),
                f"line-table file {expected_id} has wrong directory entry")
    return versions


def check_dwarf_versions(debug_info: str, frames: str) -> dict[str, list[int]]:
    unit_versions = [int(version) for version in re.findall(
        r"^\s*Version:\s*(\d+)\s*$", debug_info, re.M)]
    require(unit_versions and all(version == 4 for version in unit_versions),
            f"debug-info compilation units are not all DWARF 4: "
            f"{unit_versions!r}")
    compilation_directories = re.findall(
        r"DW_AT_comp_dir\s*:\s*(.*?)\s*$", debug_info, re.M)
    require(compilation_directories == [str(ROOT)],
            f"debug-info compilation directory differs from {ROOT}: "
            f"{compilation_directories!r}")
    frame_section = re.search(
        r"^Contents of the \.debug_frame section:\n(.*?)"
        r"(?=^Contents of |\Z)", frames, re.M | re.S)
    require(frame_section is not None, "readelf did not decode .debug_frame")
    frame_text = frame_section.group(1)
    cie_count = len(re.findall(r"\bCIE\s*$", frame_text, re.M))
    cie_versions = [int(version) for version in re.findall(
        r"^\s*Version:\s*(\d+)\s*$", frame_text, re.M)]
    require(cie_count > 0 and len(cie_versions) == cie_count and
            all(version in (1, 3, 4) for version in cie_versions),
            f".debug_frame CIEs use unsupported versions: {cie_versions!r}")
    return {"debug_info_units": unit_versions,
            "debug_frame_cies": cie_versions}


def read_build_id(readelf: str, executable: Path) -> str:
    notes = run([readelf, "-n", str(executable)])
    match = re.search(r"Build ID:\s*([0-9a-fA-F]+)", notes)
    require(match is not None, f"{executable.name} has no GNU build ID")
    return match.group(1).lower()


def check_debug_sections(readelf: str, executable: Path,
                         present: bool, log_path: Path) -> str:
    sections = run([readelf, "-SW", str(executable)])
    log_path.write_text(sections)
    found = {}
    for line in sections.splitlines():
        match = re.match(r"^\s*\[\s*\d+\]\s+(\.debug_\S+)\s+", line)
        if match is None:
            continue
        tokens = line.split()
        candidate = tokens[-4] if len(tokens) >= 4 else ""
        flags = candidate if re.fullmatch(r"[A-Z]+", candidate) else ""
        found[match.group(1)] = flags
    for name, flags in found.items():
        require("A" not in flags,
                f"{executable.name}: {name} has allocatable flags {flags}")
    for name in DEBUG_SECTIONS:
        require((name in found) == present,
                f"{executable.name}: debug section {name} "
                f"is {'absent' if present else 'still present'}")
    if not present:
        require(not found,
                f"{executable.name}: strip left debug sections {sorted(found)}")
    return sections


def check_source_map(table_path: Path, executable_id: str,
                     source_args: tuple[str, ...], assembly: Path,
                     sources: tuple[Path, ...] = SOURCES) -> dict:
    table = json.loads(table_path.read_text(encoding="ascii"))
    require(table["build_id"] == executable_id,
            "source map build ID differs from its executable")
    assembly_sha256 = hashlib.sha256(assembly.read_bytes()).hexdigest()
    require(table["assembly_sha256"] == assembly_sha256,
            "source map assembly SHA-256 differs from the emitted bytes")
    entries = table["files"]
    require(len(entries) == len(sources) == len(source_args),
            "full debug source map does not inventory every compilation source")
    assembly_lines = assembly.read_text().splitlines()
    for expected_id, (entry, source, source_arg) in enumerate(
            zip(entries, sources, source_args), 1):
        require(entry["file_id"] == expected_id,
                "source map is not in Source_Id order")
        source_arg_bytes = os.fsencode(source_arg)
        require(bytes.fromhex(entry["path_hex"]) == source_arg_bytes,
                f"source {expected_id} path bytes differ from compiler input")
        file_directive = f'\t.file {expected_id} "{gas_string(source_arg_bytes)}"'
        require(file_directive in assembly_lines,
                f"assembly omits exact Source_Id .file directive {file_directive!r}")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        require(entry["source_sha256"] == digest,
                f"source {expected_id} snapshot hash differs from exact bytes")
    return table


def has_concrete_specialization(build: dict) -> bool:
    return any(decision["action"] == "specialized" and
               decision["direct_calls_made"] > 0
               for decision in build["specializations"])


def check_specialization(report_path: Path, optimize: str,
                         specialize: str) -> dict:
    report = json.loads(report_path.read_text())
    build = report["build"]
    require((build["optimize"], build["specialize"]) ==
            (optimize, specialize), "build report profile differs from request")
    require(build["target"] == "linux-x86-64", "build report has wrong target")
    decisions = build["specializations"]
    require(len(decisions) >= 2,
            "constrained two-instance generic produced no specialization evidence")
    for decision in decisions:
        action = decision["action"]
        direct_calls = decision["direct_calls_made"]
        require(action in ("declined", "specialized"),
                f"specialization report has unknown action {action!r}")
        require((action == "specialized") == (direct_calls > 0),
                "specialization action disagrees with direct_calls_made")
        if action == "specialized":
            require(decision["retains_evidence_abi"],
                    "specialization report dropped its evidence ABI")
    if specialize == "off":
        require(all(decision["action"] == "declined" and
                    decision["reason"] == "disabled"
                    for decision in decisions),
                "specialization-off report is not factual")
    elif specialize == "all":
        require(has_concrete_specialization(build),
                f"{optimize}/{specialize} did not specialize a constrained entry")
    return build


def guest_command(executable: Path, runner: str,
                  qemu: str | None) -> list[str]:
    if runner == "native":
        return [str(executable)]
    require(qemu is not None, "qemu runner has no qemu-x86_64 command")
    return [qemu, str(executable)]


def run_gdb(gdb: str, executable: Path, script_path: Path,
            transcript_path: Path, debugger_cwd: Path, runner: str,
            qemu: str | None, transport_dir: Path,
            script: Callable[[list[str]], str]) -> str:
    gdb_args = [gdb, "-q", "-nx", "--batch", str(executable),
                "-x", str(script_path)]
    if runner == "native":
        script_path.write_text(script(["run"]))
        transcript = run_gdb_process(gdb_args, debugger_cwd, transcript_path)
        if re.search(r"PTRACE_GETREGS|Couldn't get CS register|ptrace:",
                     transcript, re.I):
            raise Native_Transport_Unavailable(
                "host ptrace cannot read the inferior registers")
        return transcript
    require(qemu is not None, "qemu runner has no qemu-x86_64 command")
    socket_path = transport_dir / "gdb.sock"
    qemu_process = subprocess.Popen(
        [qemu, "-g", str(socket_path), str(executable)],
        cwd=debugger_cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, env={**os.environ, "LC_ALL": "C"})
    try:
        deadline = time.monotonic() + 15
        while not socket_path.exists() and qemu_process.poll() is None:
            if time.monotonic() >= deadline:
                raise ValueError("qemu did not create its GDB Unix socket")
            time.sleep(0.02)
        if qemu_process.poll() is not None:
            output = qemu_process.stdout.read() if qemu_process.stdout else ""
            raise ValueError(f"qemu exited before GDB connected: {output}")
        script_path.write_text(script(
            [f"target remote {socket_path}", "continue"]))
        transcript = run_gdb_process(gdb_args, debugger_cwd, transcript_path)
        try:
            status = qemu_process.wait(timeout=15)
        except subprocess.TimeoutExpired as error:
            raise ValueError("qemu remained alive after the debugger session") from error
        qemu_output = qemu_process.stdout.read() if qemu_process.stdout else ""
        require(status == 42,
                f"qemu debug inferior returned {status}, expected 42: {qemu_output}")
        require(qemu_output == "",
                f"qemu debug inferior produced output: {qemu_output!r}")
        return transcript
    finally:
        if qemu_process.poll() is None:
            qemu_process.terminate()
            try:
                qemu_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qemu_process.kill()
                qemu_process.wait()


def run_gdb_process(args: list[str], cwd: Path,
                    transcript_path: Path) -> str:
    completed = subprocess.run(args, cwd=cwd, check=False,
                               stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True,
                               timeout=120,
                               env={**os.environ, "LC_ALL": "C"})
    transcript = completed.stdout
    transcript_path.write_text(transcript)
    if re.search(r"PTRACE_GETREGS|Couldn't get CS register|ptrace:",
                 transcript, re.I):
        raise Native_Transport_Unavailable(
            "host ptrace cannot read the inferior registers")
    require(completed.returncode == 0,
            f"GDB returned {completed.returncode}\n{transcript}")
    return transcript


SOURCE_LINES = {
    "outer-entry": source_line(
        MAIN_SOURCE, "scalar_local: i32 = scalar_param", occurrence=1),
    "outer-ready": source_line(MAIN_SOURCE, "inner_result: i32 = debug_inner("),
    "inner-entry": source_line(MAIN_SOURCE, "scalar_local: i32 = scalar_param + 1"),
    "inner-ready": source_line(MAIN_SOURCE, "step_local: i32 = scalar_local"),
    "inner-next": source_line(MAIN_SOURCE, "next_local: i32 = step_local"),
    "inner-lexical": source_line(MAIN_SOURCE, "and param_record.huge"),
    "generic-entry": source_line(MAIN_SOURCE, "generic_local: t = generic_param"),
    "generic-ready": source_line(MAIN_SOURCE, "generic_result = t.less"),
    "multiple-entry": source_line(MAIN_SOURCE, "first = base + 10"),
    "multiple-ready": source_line(MAIN_SOURCE, "multiple_ready: i32 ="),
    "aliases-ready": source_line(MAIN_SOURCE, "aliases_ready: i32 ="),
    "loop-element": source_line(MAIN_SOURCE, "loop_sum += loop_element"),
}
GENERIC_NEXT_LINES = tuple(
    source_line(MAIN_SOURCE, "break", occurrence=index) for index in range(4))
CALLER_LINE = source_line(ODD_SOURCE, "code = debug_outer(")
CALLER_COLUMN = next(line.index("debug_outer") + 1 for line in
                     ODD_SOURCE.read_text().splitlines()
                     if "code = debug_outer(" in line)


def measure(refine: Path, tools: dict[str, str], gdb: str,
            runner: str, qemu: str | None, retained: Path, scratch: Path,
            profile: tuple[str, str, str], containers: bool = False,
            hosted: bool = False) -> dict:
    key, optimize, specialize = profile
    require(not (containers and hosted), "choose one debugger workload")
    if containers:
        key = "containers-" + key
    elif hosted:
        key = "hosted-" + key
    executable = scratch / f"debug-{key}"
    assembly = scratch / f"debug-{key}.s"
    report = scratch / f"report-{key}.json"
    sources = SOURCES
    source_args = tuple(os.path.relpath(source, ROOT) for source in sources)
    fixture = HOSTED_FIXTURE if hosted else CONTAINER_FIXTURE
    inputs = ([os.path.relpath(fixture, ROOT), "--root=."]
              if containers or hosted else list(source_args))
    profile_args = [f"--optimize={optimize}",
                    f"--specialize={specialize}"]
    compiler_args = [str(refine), "--target=linux-x86-64", "--debug=full",
                     *inputs, "--emit=exe", "-o", str(executable),
                     *profile_args, f"--build-report={report}"]
    assembly_args = [str(refine), "--target=linux-x86-64", "--debug=full",
                     *inputs, "--emit=asm", "-o", str(assembly),
                     *profile_args]
    # The rooted client takes over two minutes to compile even natively;
    # executable and debugger timeouts remain independent and unchanged.
    compile_timeout = WORKLOAD_COMPILE_TIMEOUT if containers or hosted else 120
    run(compiler_args, cwd=ROOT, timeout=compile_timeout)
    run(assembly_args, cwd=ROOT, timeout=compile_timeout)
    if containers or hosted:
        inventory = json.loads(report.read_text())["sources"]
        source_args = tuple(os.fsdecode(bytes.fromhex(entry["path_hex"]))
                            for entry in inventory)
        sources = tuple((ROOT / path).resolve() for path in source_args)
        workload_source = HOSTED_SOURCE if hosted else CONTAINER_SOURCE
        require(workload_source in sources and fixture / "main.ldn" in sources,
                "workload report omits its entry or application source")
    if containers:
        families = {source.parent.name for source in sources
                    if source.parent.parent == ROOT / "core"}
        require({"vec", "small", "map", "tree", "sort"} <= families,
                "container debug build did not reach every core container")
    require(executable.is_file(), f"compiler did not create {executable.name}")
    require(assembly.is_file(), f"compiler did not create {assembly.name}")
    map_path = executable.with_suffix(".sources.json")
    assembly_map_path = Path(str(assembly) + ".sources.json")
    require(map_path.is_file(), f"compiler did not create {map_path.name}")
    require(assembly_map_path.is_file(),
            f"compiler did not create {assembly_map_path.name}")
    shutil.copy2(assembly, retained / f"{key}.s")
    shutil.copy2(executable, retained / f"{key}.elf")
    shutil.copy2(map_path, retained / f"{key}.sources.json")
    shutil.copy2(assembly_map_path, retained / f"{key}.s.sources.json")
    shutil.copy2(report, retained / f"{key}.build.json")
    build = check_specialization(report, optimize, specialize)
    sections = check_debug_sections(
        tools["readelf"], executable, True, retained / f"{key}.sections.txt")
    debug_info = run([tools["readelf"], "--debug-dump=info", str(executable)])
    (retained / f"{key}.debug-info.txt").write_text(debug_info)
    raw_lines = run([tools["readelf"], "--debug-dump=rawline", str(executable)])
    (retained / f"{key}.debug-line.txt").write_text(raw_lines)
    frames = run([tools["readelf"], "--debug-dump=frames", str(executable)])
    (retained / f"{key}.debug-frame.txt").write_text(frames)
    ranges = run([tools["readelf"], "--debug-dump=Ranges", str(executable)])
    (retained / f"{key}.debug-ranges.txt").write_text(ranges)
    locations = run([tools["readelf"], "--debug-dump=loc", str(executable)])
    (retained / f"{key}.debug-loc.txt").write_text(locations)
    dwarf_versions = check_dwarf_versions(debug_info, frames)
    dwarf_versions["debug_line_tables"] = check_line_table(
        raw_lines, source_args)
    debug_names = (("sample_keep", "text_emit", "process") if hosted else
                   ("containers_run", "evidence_less", "left", "right",
                    "count", "first", "last") if containers else (
        "debug_outer", "debug_inner", "debug_generic",
        "debug_multiple", "debug_aliases",
        "scalar_param", "pointer_param", "record_param",
        "variant_param", "array_param", "scalar_local",
        "pointer_local", "record_local", "variant_local",
        "array_local", "renamed_left", "renamed_right",
        "loop_element", "debug_record", "debug_choice"))
    for name in debug_names:
        require(name in debug_info, f"DWARF info omits {name}")
    executable_bytes = executable.read_bytes()
    for source_arg in source_args:
        source_name = os.fsencode(Path(source_arg).name)
        require(source_name in executable_bytes,
                f"unstripped debug image omits source basename {source_arg!r}")
    executable_id = read_build_id(tools["readelf"], executable)
    table = check_source_map(map_path, executable_id, source_args, assembly,
                             sources)
    assembly_table = check_source_map(assembly_map_path, executable_id,
                                      source_args, assembly, sources)
    run(guest_command(executable, runner, qemu), cwd=scratch,
        expected_status=42, empty_output=True)
    debugger_cwd = scratch / f"debugger-cwd-{key}"
    debugger_cwd.mkdir()
    script_path = retained / f"{key}.gdb"
    transcript_path = retained / f"{key}.gdb.txt"
    lines = (hosted_lines() if hosted else
             container_lines() if containers else SOURCE_LINES)
    script = (hosted_gdb_script if hosted else
              container_gdb_script if containers else gdb_script)
    with tempfile.TemporaryDirectory(prefix="landin-gdb-") as tmp:
        transcript = run_gdb(gdb, executable, script_path, transcript_path,
                             debugger_cwd, runner, qemu, Path(tmp),
                             lambda start: script(start, lines))
    if hosted:
        check_hosted_transcript(transcript, lines)
    elif containers:
        check_container_transcript(transcript, lines)
    else:
        check_transcript(transcript, lines, CALLER_LINE, CALLER_COLUMN)
    stripped = scratch / f"debug-{key}-stripped"
    shutil.copy2(executable, stripped)
    run([tools["strip"], "--strip-debug", str(stripped)])
    stripped_id = read_build_id(tools["readelf"], stripped)
    require(stripped_id == executable_id,
            "strip --strip-debug changed the exact GNU build ID")
    check_debug_sections(tools["readelf"], stripped, False,
                         retained / f"{key}.stripped-sections.txt")
    stripped_bytes = stripped.read_bytes()
    for source_arg in source_args:
        require(os.fsencode(source_arg) not in stripped_bytes and
                os.fsencode(Path(source_arg).name) not in stripped_bytes,
                f"stripped executable still deploys filename {source_arg!r}")
    run(guest_command(stripped, runner, qemu), cwd=debugger_cwd,
        expected_status=42, empty_output=True)
    resolver = str(ROOT / "scripts/source-location.py")
    caller_id, caller_line, caller_column = 2, CALLER_LINE, CALLER_COLUMN
    if containers or hosted:
        entry_source = fixture / "main.ldn"
        entry_call = "app.run" if hosted else "containers_run"
        caller_id = sources.index(entry_source) + 1
        caller_line = source_line(entry_source, entry_call)
        caller_column = (entry_source.read_text().splitlines()[caller_line - 1]
                         .index(entry_call) + 1)
    coordinate_args = [str(map_path), str(caller_id), str(caller_line),
                       str(caller_column)]
    resolved = run([sys.executable, resolver, *coordinate_args,
                    "--build-id", stripped_id], cwd=debugger_cwd).strip()
    expected_location = (f"{source_args[caller_id - 1]}:"
                         f"{caller_line}:{caller_column}")
    require(resolved == expected_location,
            "D192 source-map decoding failed for the stripped build")
    resolved_assembly = run([sys.executable, resolver, *coordinate_args,
                             "--assembly", str(assembly)],
                            cwd=debugger_cwd).strip()
    require(resolved_assembly == expected_location,
            "D192 source-map decoding failed for the exact assembly")
    wrong_build_id = (("0" if stripped_id[0] != "0" else "1") +
                      stripped_id[1:])
    refusal = run([sys.executable, resolver, *coordinate_args,
                   "--build-id", wrong_build_id], cwd=debugger_cwd,
                  expected_status=2)
    require("build ID does not match" in refusal,
            "D192 resolver accepted or misreported a wrong build ID")
    wrong_assembly = scratch / f"debug-{key}-wrong.s"
    wrong_assembly.write_bytes(assembly.read_bytes() + b"\n")
    refusal = run([sys.executable, resolver, *coordinate_args,
                   "--assembly", str(wrong_assembly)], cwd=debugger_cwd,
                  expected_status=2)
    require("assembly does not match" in refusal,
            "D192 resolver accepted or misreported wrong assembly bytes")
    return {
        "profile": {"optimize": optimize, "specialize": specialize},
        "dwarf_versions": dwarf_versions,
        "build": build,
        "build_id": executable_id,
        "compiler_request": compiler_args[1:],
        "assembly_request": assembly_args[1:],
        "assembly_sha256": hashlib.sha256(assembly.read_bytes()).hexdigest(),
        "debug_sections_sha256": hashlib.sha256(sections.encode()).hexdigest(),
        "debug_info_sha256": hashlib.sha256(debug_info.encode()).hexdigest(),
        "debug_line_sha256": hashlib.sha256(raw_lines.encode()).hexdigest(),
        "debug_frame_sha256": hashlib.sha256(frames.encode()).hexdigest(),
        "debug_ranges_sha256": hashlib.sha256(ranges.encode()).hexdigest(),
        "debug_loc_sha256": hashlib.sha256(locations.encode()).hexdigest(),
        "executable_sha256": hashlib.sha256(executable_bytes).hexdigest(),
        "gdb_script": script_path.read_text(),
        "gdb_transcript": transcript,
        "source_map": table,
        "assembly_source_map": assembly_table,
        "stripped_sha256": hashlib.sha256(stripped_bytes).hexdigest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True,
                        help="checksum-pinned Linux GNAT installation")
    parser.add_argument("--output", type=Path, required=True,
                        help="scratch directory and retained factual evidence")
    parser.add_argument("--gdb", default=os.environ.get("LANDIN_GDB", "gdb"))
    parser.add_argument("--runner", choices=("native", "qemu"),
                        help="debugger transport; default is strict native")
    parser.add_argument("--qemu", metavar="PATH",
                        help="qemu-x86_64 path; also selects qemu by default")
    args = parser.parse_args()
    require(platform.system() == "Linux",
            "source debugging requires Linux; no skip is a pass")
    runner = args.runner or ("qemu" if args.qemu else "native")
    if runner == "native":
        require(args.qemu is None,
                "--qemu cannot be combined with --runner=native")
        require(platform.machine() == "x86_64",
                "native debugging requires Linux x86-64; no skip is a pass")
    refine = args.refine.resolve(strict=True)
    home = args.toolchain.resolve(strict=True)
    tools = {name: tool(home, name) for name in ("readelf", "strip")}
    gdb = command(args.gdb)
    qemu = command(args.qemu or "qemu-x86_64") if runner == "qemu" else None
    versions = {"gdb": run([gdb, "--version"]).splitlines()[0],
                **{name: run([path, "--version"]).splitlines()[0]
                   for name, path in tools.items()}}
    if qemu is not None:
        versions["qemu"] = run([qemu, "--version"]).splitlines()[0]
    args.output.mkdir(parents=True, exist_ok=True)
    failure_path = args.output / "failure.txt"
    evidence_path = args.output / "evidence.json"
    failure_path.unlink(missing_ok=True)
    evidence_path.unlink(missing_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="debugging-") as tmp:
            scratch = Path(tmp)
            measurements = {}
            for profile in PRIMARY_PROFILES:
                measurements[profile[0]] = measure(
                    refine, tools, gdb, runner, qemu,
                    args.output, scratch, profile)
            if not has_concrete_specialization(
                    measurements["size-auto"]["build"]):
                profile = FALLBACK_PROFILE
                measurements[profile[0]] = measure(
                    refine, tools, gdb, runner, qemu,
                    args.output, scratch, profile)
            container_measurements = {}
            for profile in (*PRIMARY_PROFILES, FALLBACK_PROFILE):
                container_measurements[profile[0]] = measure(
                    refine, tools, gdb, runner, qemu,
                    args.output, scratch, profile, containers=True)
            hosted_measurements = {}
            for profile in (*PRIMARY_PROFILES, FALLBACK_PROFILE):
                hosted_measurements[profile[0]] = measure(
                    refine, tools, gdb, runner, qemu,
                    args.output, scratch, profile, hosted=True)
    except Exception as error:
        failure_path.write_text(f"{type(error).__name__}: {error}\n")
        raise
    result = {
        "schema": 1,
        "runner": runner,
        "tools": versions,
        "compiler_sha256": hashlib.sha256(refine.read_bytes()).hexdigest(),
        "compile_cwd": str(ROOT),
        "debugger_cwd_is_distinct": True,
        "specialization_fallback_used": "size-all" in measurements,
        "measurements": measurements,
        "container_measurements": container_measurements,
        "hosted_measurements": hosted_measurements,
    }
    evidence_path.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Native_Transport_Unavailable as error:
        print("debugger acceptance: native debugger transport unavailable: "
              f"{error}; no skip is a pass", file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, subprocess.SubprocessError,
            KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"debugger acceptance: {error}", file=sys.stderr)
        sys.exit(1)
