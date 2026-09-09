#!/usr/bin/env python3
"""Standard-library tests for the Clang-backed binding generator."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from typing import Any

HERE = pathlib.Path(__file__).resolve().parent
GENERATOR = HERE / "generate.py"
FIXTURE = (HERE.parent / "compiler" / "tests" / "fixtures" / "abi" /
           "r440-bindings-generated")
TARGET = "x86_64-pc-linux-gnu"

HEADER = r"""
typedef struct Pair {
    double real;
    int count;
} Pair;

typedef enum Mode {
    MODE_NEGATIVE = -1,
    MODE_ZERO = 0,
    MODE_ALIAS = 0,
    MODE_LARGE = 4000000000U
} Mode;

typedef union Value {
    int signed_value;
    double real_value;
} Value;

typedef struct Bits {
    signed int signed_bits : 3;
    unsigned int : 0;
    unsigned int unsigned_bits : 5;
    int neighbour;
} Bits;

typedef int (*callback)(int value);

extern Pair adjust_pair(Pair value);
extern Value rotate_value(Value value);
extern int call_optional(callback action, int value);
extern callback select_callback(int which);
extern const int *borrowed_pointer(int *base);
extern int global_counter;
extern _Thread_local int tls_counter;
extern int receive_many(int count, ...);
""".lstrip()


def annotation(*, ownership: str = "borrowed", nullability: str = "nonnullable",
               retention: str = "call", sources: list[str] | None = None) -> dict[str, Any]:
    return {
        "ownership": ownership,
        "nullability": nullability,
        "from": [] if sources is None else sources,
        "retention": retention,
    }


def policy() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "namespace": "r440_test",
        "abi": {
            "target": TARGET,
            "data_model": "lp64",
            "plain_char": "signed",
            "enum_policy": "clang-default",
        },
        "declarations": [
            {
                "kind": "record", "name": "Pair", "landin_name": "pair",
                "representation": "auto", "fields": {},
            },
            {
                "kind": "enum", "name": "Mode", "landin_name": "mode",
            },
            {
                "kind": "record", "name": "Value", "landin_name": "value_object",
                "representation": "auto", "fields": {},
            },
            {
                "kind": "record", "name": "Bits", "landin_name": "bits_object",
                "representation": "auto", "fields": {},
            },
            {
                "kind": "callback", "name": "callback", "landin_name": "callback",
                "nullable": True, "parameters": {},
            },
            {
                "kind": "function", "name": "adjust_pair", "landin_name": "adjust_pair",
                "direction": "import", "parameters": {},
            },
            {
                "kind": "function", "name": "rotate_value", "landin_name": "rotate_value",
                "direction": "import", "parameters": {},
            },
            {
                "kind": "function", "name": "call_optional", "landin_name": "call_optional",
                "direction": "import", "parameters": {
                    "action": annotation(nullability="nullable"),
                },
            },
            {
                "kind": "function", "name": "select_callback", "landin_name": "select_callback",
                "direction": "import", "parameters": {},
                "result": annotation(ownership="static", nullability="nullable",
                                     retention="static"),
            },
            {
                "kind": "function", "name": "borrowed_pointer", "landin_name": "borrowed_pointer",
                "direction": "import", "parameters": {
                    "base": annotation(ownership="caller_owned"),
                },
                "result": annotation(nullability="nullable", retention="returned",
                                     sources=["base"]),
            },
            {
                "kind": "variable", "name": "global_counter", "landin_name": "global_counter",
                "storage": "import", "writable": True,
            },
            {
                "kind": "variable", "name": "tls_counter", "landin_name": "tls_counter",
                "storage": "define", "writable": True,
            },
            {
                "kind": "incoming_varargs", "name": "receive_many",
                "landin_name": "receive_many", "handler": "landin_receive_many_handler",
                "count_parameter": "count", "parameters": {},
                "schema": [
                    {"name": "i1", "promoted": "c_int"},
                    {"name": "i2", "promoted": "c_int"},
                    {"name": "i3", "promoted": "c_int"},
                    {"name": "i4", "promoted": "c_int"},
                    {"name": "d1", "promoted": "c_double"},
                    {"name": "d2", "promoted": "c_double"},
                    {"name": "d3", "promoted": "c_double"},
                    {"name": "d4", "promoted": "c_double"},
                    {"name": "d5", "promoted": "c_double"},
                    {"name": "d6", "promoted": "c_double"},
                    {"name": "d7", "promoted": "c_double"},
                    {"name": "d8", "promoted": "c_double"},
                    {"name": "d9", "promoted": "c_double"},
                    {"name": "d10", "promoted": "c_double"},
                    {"name": "l1", "promoted": "c_long"},
                    {"name": "l2", "promoted": "c_long"},
                ],
            },
        ],
    }


class GeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        requested = os.environ.get("CLANG", "clang")
        clang = shutil.which(requested)
        if clang is None:
            raise RuntimeError(f"external Clang {requested!r} is required")
        cls.clang = pathlib.Path(clang).resolve()
        process = subprocess.run([str(cls.clang), "-print-resource-dir"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, check=True)
        cls.resource_include = pathlib.Path(process.stdout.strip()) / "include"
        if not cls.resource_include.is_dir():
            raise RuntimeError("Clang resource include directory is missing")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="landin-bindings-test-")
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_tree(self, parent: pathlib.Path, *, header: str = HEADER,
                  selected_policy: dict[str, Any] | None = None) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
        parent.mkdir(parents=True)
        sysroot = parent / "sysroot"
        sysroot.mkdir()
        includes = parent / "includes"
        includes.mkdir()
        (includes / "stdlib.h").write_text(
            "#ifndef TEST_STDLIB_H\n#define TEST_STDLIB_H\n"
            "typedef __SIZE_TYPE__ size_t;\n"
            "void *calloc(size_t, size_t);\nvoid free(void *);\n#endif\n",
            encoding="utf-8")
        (parent / "api.h").write_text(header, encoding="utf-8")
        (parent / "policy.json").write_text(
            json.dumps(policy() if selected_policy is None else selected_policy,
                       indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return sysroot, includes, parent / "generated"

    def command(self, parent: pathlib.Path, sysroot: pathlib.Path,
                includes: pathlib.Path, output: pathlib.Path) -> list[str]:
        return [
            sys.executable, str(GENERATOR), "--clang", str(self.clang),
            "--target", TARGET, "--sysroot", str(sysroot),
            "--header", f"api/api.h={parent / 'api.h'}",
            "--policy", str(parent / "policy.json"), "--out-dir", str(output),
            "--system-include-dir", str(includes),
            "--system-include-dir", str(self.resource_include),
            "--define", "LANDIN_BINDING_TEST=1",
        ]

    def generate(self, parent: pathlib.Path, *, header: str = HEADER,
                 selected_policy: dict[str, Any] | None = None,
                 expect_success: bool = True) -> tuple[subprocess.CompletedProcess[str], pathlib.Path]:
        sysroot, includes, output = self.make_tree(
            parent, header=header, selected_policy=selected_policy)
        process = subprocess.run(self.command(parent, sysroot, includes, output),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if expect_success and process.returncode != 0:
            self.fail(f"generator failed:\n{process.stderr}")
        if not expect_success and process.returncode == 0:
            self.fail("generator unexpectedly succeeded")
        return process, output

    def test_generation_is_relocatable_deterministic_and_path_free(self) -> None:
        _, first = self.generate(self.root / "first-location")
        _, second = self.generate(self.root / "unrelated" / "second-location")
        for name in ("bindings.ldn", "adapters.c", "exports.h", "bindings.json"):
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes(), name)
        combined = b"".join((first / name).read_bytes() for name in
                            ("bindings.ldn", "adapters.c", "exports.h", "bindings.json"))
        self.assertNotIn(str(self.root).encode(), combined)
        metadata = json.loads((first / "bindings.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["abi"]["target"], TARGET)
        self.assertEqual(metadata["inputs"]["headers"][0]["name"], "api/api.h")
        self.assertEqual(metadata["inputs"]["defines"][0]["name"], "LANDIN_BINDING_TEST")
        self.assertEqual(metadata["outputs"]["adapters.c"],
                         hashlib.sha256((first / "adapters.c").read_bytes()).hexdigest())

    def test_committed_fixture_is_exactly_regenerable(self) -> None:
        parent = self.root / "fixture-regeneration"
        sysroot, includes, output = self.make_tree(
            parent,
            header=(FIXTURE / "r440-bindings.h").read_text(encoding="utf-8"),
            selected_policy=json.loads((FIXTURE / "policy.json").read_text(
                encoding="utf-8")))
        shutil.move(parent / "api.h", parent / "r440-bindings.h")
        command = [
            sys.executable, str(GENERATOR), "--clang", str(self.clang),
            "--target", TARGET, "--sysroot", str(sysroot),
            "--header", f"r440-bindings.h={parent / 'r440-bindings.h'}",
            "--policy", str(parent / "policy.json"), "--out-dir", str(output),
            "--system-include-dir", str(includes),
            "--system-include-dir", str(self.resource_include),
        ]
        process = subprocess.run(command, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        for name in ("bindings.ldn", "adapters.c", "exports.h", "bindings.json"):
            self.assertEqual((output / name).read_bytes(),
                             (FIXTURE / name).read_bytes(), name)

        peer = subprocess.run([
            str(self.clang), "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-pthread", "-fsyntax-only", "-I", str(FIXTURE),
            str(FIXTURE / "peer.c"),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(peer.returncode, 0, peer.stderr)

    def test_landin_output_uses_canonical_abi_and_real_opaque_objects(self) -> None:
        _, output = self.generate(self.root / "source")
        text = (output / "bindings.ldn").read_text(encoding="utf-8")
        self.assertIn("compiler.assert(compiler.c_sysv_lp64)", text)
        self.assertNotIn("import landin/compiler", text)
        self.assertIn("public pair: type = layout(c) struct", text)
        self.assertIn("public mode: type = c.c_long", text)
        self.assertIn("public mode_negative: mode = -1", text)
        self.assertIn("public mode_alias: mode = 0", text)
        self.assertIn("value_object_allocate", text)
        self.assertIn("bits_object_signed_bits_set", text)
        self.assertIn("callback_cell_clear", text)
        self.assertIn("callback_cell_invoke", text)
        self.assertIn("borrowed_pointer_result_optional", text)
        self.assertIn("from base", text)
        self.assertNotIn("[16]u8", text)

    def test_generated_adapters_compile_for_target_and_execute_locally(self) -> None:
        source = self.root / "source"
        _, output = self.generate(source)
        logical = source / "api"
        logical.mkdir()
        shutil.copyfile(source / "api.h", logical / "api.h")
        target_compile = [
            str(self.clang), f"--target={TARGET}", f"--sysroot={source / 'sysroot'}",
            "-std=c11", "-nostdinc", "-Wall", "-Wextra", "-Werror", "-fsyntax-only",
            "-I", str(output), "-I", str(source), "-isystem", str(source / "includes"),
            "-isystem", str(self.resource_include), str(output / "adapters.c"),
        ]
        target = subprocess.run(target_compile, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        self.assertEqual(target.returncode, 0, target.stderr)

        harness = source / "harness.c"
        harness.write_text(r'''
#include "generated/exports.h"
#include <pthread.h>
#include <stdlib.h>

int global_counter;
static int worker_status;

Pair adjust_pair(Pair value)
{
    value.real += 1.0;
    value.count += 1;
    return value;
}

Value rotate_value(Value value)
{
    value.signed_value += 7;
    return value;
}

static int plus_three(int value)
{
    return value + 3;
}

int call_optional(callback action, int value)
{
    return action == 0 ? value - 1 : action(value);
}

callback select_callback(int which)
{
    return which == 0 ? 0 : plus_three;
}

const int *borrowed_pointer(int *base)
{
    return *base == 0 ? 0 : base;
}

int landin_receive_many_handler(int count, int i1, int i2, int i3, int i4,
                                double d1, double d2, double d3, double d4,
                                double d5, double d6, double d7, double d8,
                                double d9, double d10, long l1, long l2)
{
    if (count != 16 || i1 != 1 || i2 != 2 || i3 != 3 || i4 != 4 ||
        d1 != 5.0 || d2 != 6.0 || d3 != 7.0 || d4 != 8.0 ||
        d5 != 9.0 || d6 != 10.0 || d7 != 11.0 || d8 != 12.0 ||
        d9 != 13.0 || d10 != 14.0 || l1 != 15 || l2 != 16) return 9;
    return 42;
}

static void *tls_worker(void *unused)
{
    (void)unused;
    landin_r440_test_tls_counter_write(29);
    worker_status = landin_r440_test_tls_counter_read() == 29 ? 0 : 1;
    return 0;
}

int main(void)
{
    Pair pair = {3.5, 4};
    pair = adjust_pair(pair);
    if (pair.real != 4.5 || pair.count != 5) return 1;

    void *value = landin_r440_test_value_object_allocate();
    void *other = landin_r440_test_value_object_allocate();
    if (value == 0 || other == 0) return 2;
    landin_r440_test_value_object_signed_value_set(value, 11);
    if (landin_r440_test_value_object_signed_value_get(value) != 11) return 3;
    landin_r440_test_rotate_value_call(other, value);
    if (landin_r440_test_value_object_signed_value_get(other) != 18) return 4;
    landin_r440_test_value_object_release(other);
    landin_r440_test_value_object_release(value);

    void *bits = landin_r440_test_bits_object_allocate();
    if (bits == 0) return 5;
    landin_r440_test_bits_object_neighbour_set(bits, 99);
    landin_r440_test_bits_object_signed_bits_set(bits, -2);
    landin_r440_test_bits_object_unsigned_bits_set(bits, 17U);
    if (landin_r440_test_bits_object_signed_bits_get(bits) != -2 ||
        landin_r440_test_bits_object_unsigned_bits_get(bits) != 17U ||
        landin_r440_test_bits_object_neighbour_get(bits) != 99) return 6;
    landin_r440_test_bits_object_release(bits);

    void *cell = landin_r440_test_callback_cell_allocate();
    if (cell == 0 || landin_r440_test_callback_cell_present(cell)) return 7;
    landin_r440_test_callback_cell_set(cell, plus_three);
    int callback_result = 0;
    if (!landin_r440_test_callback_cell_invoke(cell, 8, &callback_result) ||
        callback_result != 11 ||
        landin_r440_test_callback_cell_access(cell)(9) != 12) return 8;
    if (landin_r440_test_call_optional_call(cell, 10) != 13) return 9;
    landin_r440_test_callback_cell_clear(cell);
    if (landin_r440_test_callback_cell_present(cell) ||
        landin_r440_test_call_optional_call(cell, 10) != 9) return 10;
    landin_r440_test_select_callback_call(cell, 1);
    if (!landin_r440_test_callback_cell_present(cell) ||
        landin_r440_test_callback_cell_access(cell)(10) != 13) return 11;
    landin_r440_test_callback_cell_release(cell);

    landin_r440_test_global_counter_write(31);
    if (landin_r440_test_global_counter_read() != 31 ||
        *landin_r440_test_global_counter_address() != 31) return 12;

    landin_r440_test_tls_counter_write(17);
    pthread_t thread;
    if (pthread_create(&thread, 0, tls_worker, 0) != 0) return 13;
    if (pthread_join(thread, 0) != 0 || worker_status != 0 ||
        landin_r440_test_tls_counter_read() != 17) return 14;

    if (receive_many(16, 1, 2, 3, 4, 5.0, 6.0, 7.0, 8.0,
                     9.0, 10.0, 11.0, 12.0, 13.0, 14.0,
                     (long)15, (long)16) != 42) return 15;
    return 0;
}
'''.lstrip(), encoding="utf-8")
        executable = source / "adapter-test"
        host_compile = subprocess.run([
            str(self.clang), "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-I", str(output), "-I", str(source), str(output / "adapters.c"),
            str(harness), "-pthread", "-o", str(executable),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(host_compile.returncode, 0, host_compile.stderr)
        executed = subprocess.run([str(executable)], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        self.assertEqual(executed.returncode, 0,
                         f"stdout={executed.stdout!r}\nstderr={executed.stderr!r}")

    def assert_generation_error(self, selected_policy: dict[str, Any], expected: str,
                                *, header: str = HEADER) -> None:
        process, output = self.generate(self.root / ("case-" + str(len(list(self.root.iterdir())))),
                                        header=header, selected_policy=selected_policy,
                                        expect_success=False)
        self.assertIn(expected, process.stderr)
        self.assertEqual(process.returncode, 2)
        self.assertNotIn("Traceback", process.stderr)
        self.assertFalse(output.exists())

    def assert_precise_refusal_preserves_outputs(
            self, selected_policy: dict[str, Any], expected: str, *, header: str,
            trailing_detail: bool = False) -> None:
        names = ("bindings.ldn", "adapters.c", "exports.h", "bindings.json")
        for preexisting in (False, True):
            with self.subTest(preexisting=preexisting):
                parent = self.root / ("precise-refusal-" +
                                      str(len(list(self.root.iterdir()))))
                sysroot, includes, output = self.make_tree(
                    parent, header=header, selected_policy=selected_policy)
                original = {name: ("preserved " + name + "\n").encode()
                            for name in names}
                if preexisting:
                    output.mkdir()
                    for name, content in original.items():
                        (output / name).write_bytes(content)
                process = subprocess.run(
                    self.command(parent, sysroot, includes, output),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertEqual(process.stdout, "")
                self.assertNotIn("Traceback", process.stderr)
                if preexisting:
                    self.assertEqual(
                        {name: (output / name).read_bytes() for name in names},
                        original)
                    self.assertEqual({item.name for item in output.iterdir()}, set(names))
                else:
                    self.assertFalse(output.exists())
                    for name in names:
                        self.assertFalse((output / name).exists())
                prefix = "bindings: error: " + expected
                if trailing_detail:
                    self.assertRegex(process.stderr,
                                     r"\A" + re.escape(prefix) + r": [^\n]+\n\Z")
                else:
                    self.assertEqual(process.stderr, prefix + "\n")

    def test_dependency_names_cannot_reuse_selected_names(self) -> None:
        selected = {
            "schema_version": 1, "namespace": "collision", "abi": policy()["abi"],
            "declarations": [
                {"kind": "function", "name": "get_pair", "landin_name": "pair",
                 "direction": "import", "parameters": {}},
            ],
        }
        self.assert_generation_error(
            selected, "record dependency 'Pair': Landin name 'pair' collides",
            header=("typedef struct Pair { int value; } Pair;\n"
                    "extern Pair get_pair(void);\n"))

    def test_forward_typedefs_follow_complete_tag_redeclarations(self) -> None:
        selected = {
            "schema_version": 1, "namespace": "forward", "abi": policy()["abi"],
            "declarations": [
                {"kind": "record", "name": "Forward", "landin_name": "forward",
                 "representation": "auto", "fields": {}},
                {"kind": "enum", "name": "Choice", "landin_name": "choice"},
            ],
        }
        _, output = self.generate(
            self.root / "forward-typedef",
            header=("typedef struct Forward Forward;\n"
                    "struct Forward { int value; };\n"
                    "typedef enum Choice Choice;\n"
                    "enum Choice { CHOICE_ONE = 1 };\n"),
            selected_policy=selected)
        text = (output / "bindings.ldn").read_text(encoding="utf-8")
        self.assertIn("public forward: type = layout(c) struct", text)
        self.assertIn("    value: c.c_int", text)
        self.assertIn("public choice_one: choice = 1", text)

    def test_struct_containing_union_stays_c_owned(self) -> None:
        selected = {
            "schema_version": 1, "namespace": "nested", "abi": policy()["abi"],
            "declarations": [
                {"kind": "record", "name": "Outer", "landin_name": "outer",
                 "representation": "auto", "fields": {}},
            ],
        }
        _, output = self.generate(
            self.root / "nested-union",
            header=("typedef union Inner { int value; } Inner;\n"
                    "typedef struct Outer { Inner inner; int neighbour; } Outer;\n"),
            selected_policy=selected)
        text = (output / "bindings.ldn").read_text(encoding="utf-8")
        self.assertNotIn("public outer: type = layout(c) struct", text)
        self.assertIn("outer_allocate", text)
        self.assertIn("outer_inner_get", text)
        metadata = json.loads((output / "bindings.json").read_text(encoding="utf-8"))
        outer = next(item for item in metadata["declarations"]
                     if item.get("c_name") == "Outer")
        self.assertEqual(outer["representation"], "c-owned-opaque")

    def test_const_global_has_read_only_address_adapter(self) -> None:
        selected = {
            "schema_version": 1, "namespace": "constant", "abi": policy()["abi"],
            "declarations": [
                {"kind": "variable", "name": "constant_value",
                 "landin_name": "constant_value", "storage": "import",
                 "writable": False},
                {"kind": "variable", "name": "observed_value",
                 "landin_name": "observed_value", "storage": "import",
                 "writable": False},
            ],
        }
        _, output = self.generate(
            self.root / "constant-variable",
            header=("extern const int constant_value;\n"
                    "extern int observed_value;\n"),
            selected_policy=selected)
        bindings = (output / "bindings.ldn").read_text(encoding="utf-8")
        exports = (output / "exports.h").read_text(encoding="utf-8")
        self.assertIn("constant_value_address: () -> (address: ptr c.c_int)", bindings)
        self.assertNotIn("constant_value_write", bindings)
        self.assertIn("const int * landin_constant_constant_value_address(void);", exports)
        self.assertIn("int landin_constant_constant_value_read(void);", exports)
        self.assertIn("observed_value_address: () -> (address: ptr c.c_int)", bindings)
        self.assertNotIn("observed_value_write", bindings)
        self.assertIn("const int * landin_constant_observed_value_address(void);", exports)

    def test_retained_references_mark_generated_inputs_escaping(self) -> None:
        retained = annotation(retention="stored")
        selected = {
            "schema_version": 1, "namespace": "retained", "abi": policy()["abi"],
            "declarations": [
                {"kind": "record", "name": "Holder", "landin_name": "holder",
                 "representation": "auto", "fields": {"pointer": retained}},
                {"kind": "record", "name": "Box", "landin_name": "box",
                 "representation": "opaque", "fields": {"pointer": retained}},
                {"kind": "function", "name": "keep_holder", "landin_name": "keep_holder",
                 "direction": "import", "parameters": {"value": retained}},
                {"kind": "variable", "name": "saved_pointer", "landin_name": "saved_pointer",
                 "storage": "import", "writable": True, "value": retained},
            ],
        }
        _, output = self.generate(
            self.root / "retained-references",
            header=("typedef struct Holder { int *pointer; } Holder;\n"
                    "typedef union Box { int *pointer; int value; } Box;\n"
                    "extern void keep_holder(Holder value);\n"
                    "extern int *saved_pointer;\n"),
            selected_policy=selected)
        bindings = (output / "bindings.ldn").read_text(encoding="utf-8")
        self.assertIn("keep_holder: (escaping value: holder) -> none", bindings)
        self.assertIn("saved_pointer_write: (escaping value: ptr mut c.c_int) -> none",
                      bindings)
        self.assertIn("box_pointer_set: (object: ptr mut u8, escaping value: ptr mut c.c_int) -> none",
                      bindings)

    def test_anonymous_enum_keeps_exact_values_and_aliases(self) -> None:
        selected = {
            "schema_version": 1, "namespace": "anonymous", "abi": policy()["abi"],
            "declarations": [
                {"kind": "enum", "name": "@FIRST_VALUE", "landin_name": "values"},
            ],
        }
        _, output = self.generate(
            self.root / "anonymous-enum",
            header=("enum { FIRST_VALUE = -2, NEXT_VALUE, "
                    "VALUE_ALIAS = NEXT_VALUE };\n"),
            selected_policy=selected)
        bindings = (output / "bindings.ldn").read_text(encoding="utf-8")
        self.assertIn("public values: type = c.c_int", bindings)
        self.assertIn("public first_value: values = -2", bindings)
        self.assertIn("public next_value: values = -1", bindings)
        self.assertIn("public value_alias: values = -1", bindings)

    def test_missing_pointer_policy_is_precise(self) -> None:
        selected = policy()
        for declaration in selected["declarations"]:
            if declaration["name"] == "borrowed_pointer":
                declaration["parameters"] = {}
        self.assert_generation_error(selected,
                                     "parameter 'base': missing required pointer policy")

    def test_stale_selection_is_precise(self) -> None:
        selected = policy()
        selected["declarations"].append({
            "kind": "function", "name": "removed_api", "landin_name": "removed_api",
            "direction": "import", "parameters": {},
        })
        self.assert_generation_error(selected,
                                     "selected function was not found in Clang AST (stale policy)")

    def test_selected_unsupported_forms_are_not_silently_skipped(self) -> None:
        base = {
            "schema_version": 1,
            "namespace": "refusal",
            "abi": policy()["abi"],
            "declarations": [],
        }
        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "function", "name": "complex_api", "landin_name": "complex_api",
            "direction": "import", "parameters": {},
        }]
        self.assert_generation_error(
            selected, "unsupported complex type",
            header="extern _Complex double complex_api(_Complex double value);\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "record", "name": "Packed", "landin_name": "packed_record",
            "representation": "auto", "fields": {},
        }]
        self.assert_generation_error(
            selected, "unsupported record attribute PackedAttr",
            header="typedef struct __attribute__((packed)) Packed { int value; } Packed;\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "record", "name": "Aligned", "landin_name": "aligned_record",
            "representation": "auto", "fields": {},
        }]
        self.assert_generation_error(
            selected, "unsupported typedef attribute AlignedAttr",
            header=("typedef struct Aligned { int value; } Aligned "
                    "__attribute__((aligned(16)));\n"))

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "function", "name": "old_api", "landin_name": "old_api",
            "direction": "import", "parameters": {},
        }]
        self.assert_generation_error(selected, "old-style function declaration is unsupported",
                                     header="extern int old_api();\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "record", "name": "Flexible", "landin_name": "flexible",
            "representation": "auto", "fields": {},
        }]
        self.assert_generation_error(
            selected, "flexible or zero-size array is unsupported",
            header="typedef struct Flexible { int count; int values[]; } Flexible;\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "record", "name": "Hidden", "landin_name": "hidden",
            "representation": "native", "fields": {},
        }]
        self.assert_generation_error(
            selected, "incomplete record cannot have native representation",
            header="typedef struct Hidden Hidden;\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "variable", "name": "values", "landin_name": "values",
            "storage": "import", "writable": True,
        }]
        self.assert_generation_error(
            selected, "array object adapters are unsupported",
            header="extern int values[4];\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "variable", "name": "private_value", "landin_name": "private_value",
            "storage": "import", "writable": True,
        }]
        self.assert_generation_error(
            selected, "variable policy requires only external header declarations",
            header="static int private_value;\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "variable", "name": "raw_callback", "landin_name": "raw_callback",
            "storage": "import", "writable": False, "value": annotation(),
        }]
        self.assert_generation_error(
            selected, "callback object adapter requires a named function-pointer typedef",
            header="extern int (*raw_callback)(int);\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [{
            "kind": "function", "name": "landin_receiver",
            "landin_name": "landin_receiver", "direction": "export",
            "parameters": {},
        }]
        self.assert_generation_error(
            selected, "variadic export must use kind incoming_varargs",
            header="extern int landin_receiver(int count, ...);\n")

        selected = json.loads(json.dumps(base))
        selected["declarations"] = [
            {"kind": "record", "name": "Value", "landin_name": "value_object",
             "representation": "auto", "fields": {}},
            {"kind": "callback", "name": "value_callback", "landin_name": "value_callback",
             "nullable": False, "parameters": {}},
        ]
        self.assert_generation_error(
            selected, "C-owned opaque by-value type is unsupported",
            header=("typedef union Value { int value; } Value;\n"
                    "typedef int (*value_callback)(Value value);\n"))

        cases = (
            (
                "extended-x87",
                {"kind": "function", "name": "extended_api",
                 "landin_name": "extended_api", "direction": "import",
                 "parameters": {}},
                "extern long double extended_api(long double value);\n",
                "policy declaration 1 (function 'extended_api') result: "
                "unsupported extended or x87 floating type: long double",
                False,
            ),
            (
                "integer-128",
                {"kind": "function", "name": "wide_api",
                 "landin_name": "wide_api", "direction": "import",
                 "parameters": {}},
                "extern __int128 wide_api(__int128 value);\n",
                "policy declaration 1 (function 'wide_api') result: "
                "unsupported 128-bit integer type: __int128",
                False,
            ),
            (
                "vector",
                {"kind": "alias", "name": "Vector", "landin_name": "vector"},
                "typedef int Vector __attribute__((vector_size(16)));\n",
                "typedef 'Vector': unsupported vector or calling-convention attribute",
                True,
            ),
            (
                "atomic",
                {"kind": "function", "name": "atomic_api",
                 "landin_name": "atomic_api", "direction": "import",
                 "parameters": {}},
                "extern void atomic_api(_Atomic(int) value);\n",
                "policy declaration 1 (function 'atomic_api') parameter value: "
                "unsupported atomic or volatile qualified type: _Atomic(int)",
                False,
            ),
            (
                "volatile",
                {"kind": "function", "name": "volatile_api",
                 "landin_name": "volatile_api", "direction": "import",
                 "parameters": {}},
                "extern void volatile_api(volatile int value);\n",
                "policy declaration 1 (function 'volatile_api') parameter value: "
                "unsupported atomic or volatile qualified type: volatile int",
                False,
            ),
            (
                "empty-record",
                {"kind": "record", "name": "Empty", "landin_name": "empty",
                 "representation": "auto", "fields": {}},
                "typedef struct Empty {} Empty;\n",
                "record 'Empty': empty or zero-size record is unsupported",
                False,
            ),
            (
                "zero-size-record",
                {"kind": "record", "name": "ZeroSized",
                 "landin_name": "zero_sized", "representation": "auto",
                 "fields": {}},
                "typedef struct ZeroSized { int values[0]; } ZeroSized;\n",
                "record 'ZeroSized' field values: flexible or zero-size array is unsupported",
                False,
            ),
            (
                "anonymous-unaliased",
                {"kind": "function", "name": "anonymous_api",
                 "landin_name": "anonymous_api", "direction": "import",
                 "parameters": {}},
                "extern void anonymous_api(struct { int value; } value);\n",
                "policy declaration 1 (function 'anonymous_api') parameter value: "
                "unsupported anonymous unaliased aggregate",
                True,
            ),
        )
        for name, entry, header, expected, trailing_detail in cases:
            with self.subTest(form=name):
                selected = json.loads(json.dumps(base))
                selected["declarations"] = [entry]
                self.assert_precise_refusal_preserves_outputs(
                    selected, expected, header=header,
                    trailing_detail=trailing_detail)

    def test_adapter_required_varargs_reports_no_forwarding(self) -> None:
        selected = {
            "schema_version": 1, "namespace": "forwarding", "abi": policy()["abi"],
            "declarations": [
                {"kind": "record", "name": "Value", "landin_name": "value_object",
                 "representation": "auto", "fields": {}},
                {"kind": "function", "name": "variadic_value", "landin_name": "variadic_value",
                 "direction": "import", "parameters": {}},
            ],
        }
        self.assert_generation_error(
            selected, "unsupported va_list forwarding",
            header=("typedef union Value { int i; double d; } Value;\n"
                    "extern Value variadic_value(int count, ...);\n"))

    @staticmethod
    def selection(*declarations: dict[str, Any]) -> dict[str, Any]:
        return {"schema_version": 1, "namespace": "probe", "abi": policy()["abi"],
                "declarations": list(declarations)}

    @staticmethod
    def function(name: str, **extra: Any) -> dict[str, Any]:
        return {"kind": "function", "name": name, "direction": "import",
                "parameters": {}, **extra}

    @staticmethod
    def record(name: str, **extra: Any) -> dict[str, Any]:
        return {"kind": "record", "name": name, "representation": "auto",
                "fields": {}, **extra}

    def execute_adapters(self, source: pathlib.Path, body: str) -> None:
        logical = source / "api"
        logical.mkdir(exist_ok=True)
        shutil.copyfile(source / "api.h", logical / "api.h")
        harness = source / "probe.c"
        harness.write_text('#include "generated/exports.h"\n' + body, encoding="utf-8")
        executable = source / "probe"
        compiled = subprocess.run([
            str(self.clang), "-std=c11", "-fno-short-enums", "-Wall", "-Wextra", "-Werror",
            "-I", str(source), "-I", str(source / "generated"),
            str(source / "generated" / "adapters.c"), str(harness),
            "-pthread", "-o", str(executable),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        executed = subprocess.run([str(executable)], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        self.assertEqual((executed.returncode, executed.stdout, executed.stderr), (0, "", ""))

    def test_stored_tls_and_opaque_array_setters_preserve_escape(self) -> None:
        retained = annotation(retention="stored")
        selected = self.selection(
            self.record("Box", representation="opaque", fields={"pointers": retained}),
            {"kind": "variable", "name": "saved", "storage": "import",
             "writable": True, "value": retained})
        source = self.root / "stored"
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef union Box { int *pointers[2]; int other; } Box;\n"
            "extern _Thread_local int *saved;\n"))
        text = (output / "bindings.ldn").read_text()
        self.assertIn("saved_write: (escaping value: ptr mut c.c_int) -> none", text)
        self.assertIn("box_pointers_set: (object: ptr mut u8, index: usize, "
                      "escaping value: ptr mut c.c_int) -> none", text)
        self.execute_adapters(source, r'''
_Thread_local int *saved;
int main(void) {
    int a = 17, b = 29;
    Box object = { .pointers = {&a, &a} };
    landin_probe_box_pointers_set(&object, 1, &b);
    landin_probe_saved_write(&b);
    return object.pointers[0] != &a || object.pointers[1] != &b ||
           saved != &b || landin_probe_saved_read() != &b;
}
''')

    def test_opaque_aggregate_setters_keep_recursive_retention(self) -> None:
        stored = annotation(retention="stored")
        selected = self.selection(
            self.record("Box", fields={"pointer": stored}),
            self.record("Outer", representation="opaque", fields={"one": stored, "many": stored}),
            {"kind": "variable", "name": "value", "storage": "import", "writable": True,
             "value": stored},
            self.function("keep", parameters={"input": stored}))
        source = self.root / "opaque-retention"
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef union Box { int *pointer; int number; } Box;\n"
            "typedef struct Outer { Box one; Box many[2]; } Outer;\n"
            "extern Box value; extern void keep(Box input);\n"))
        text = (output / "bindings.ldn").read_text()
        for signature in (
                "value_write: (escaping value: ptr u8) -> none",
                "keep: (escaping input: ptr u8) -> none",
                "outer_one_set: (object: ptr mut u8, escaping value: ptr u8) -> none",
                "outer_many_set: (object: ptr mut u8, index: usize, escaping value: ptr u8) -> none",
                "box_copy: (target: ptr mut u8, escaping source: ptr u8) -> none"):
            self.assertIn(signature, text)
        self.execute_adapters(source, r'''
Box value;
static int *kept;
void keep(Box input) { kept = input.pointer; }
int main(void) {
    int n = 37;
    Box input = { .pointer = &n };
    Outer outer = { .one = {.pointer = &n}, .many = {{.pointer = &n}, {.pointer = &n}} };
    landin_probe_value_write(&input);
    landin_probe_outer_one_set(&outer, &input);
    landin_probe_outer_many_set(&outer, 1, &input);
    landin_probe_keep_call(&input);
    return value.pointer != &n || outer.one.pointer != &n ||
           outer.many[1].pointer != &n || kept != &n;
}
''')

    def test_anonymous_and_nested_callback_policies_are_recursive(self) -> None:
        selected = self.selection(self.function("run", parameters={"cb": annotation()}))
        for signature in ("void (*cb)(int *)", "void (*cb)(void (*)(int *))"):
            with self.subTest(signature=signature):
                self.assert_generation_error(selected, "anonymous callback with reference positions",
                                             header=f"extern void run({signature});\n")
        selected = self.selection(
            {"kind": "callback", "name": "Inner", "nullable": False, "parameters": {}},
            {"kind": "callback", "name": "Outer", "nullable": False,
             "parameters": {"argument_1": annotation()}},
            self.function("run", parameters={"cb": annotation()}))
        header = ("typedef void (*Inner)(int *); typedef void (*Outer)(Inner);\n"
                  "extern void run(Outer cb);\n")
        self.assert_generation_error(selected, "callback 'Inner' parameter 'argument_1': missing",
                                     header=header)
        selected["declarations"][0]["parameters"] = {
            "argument_1": annotation(nullability="nullable")}
        _, output = self.generate(self.root / "nested-callback", header=header,
                                  selected_policy=selected)
        text = (output / "bindings.ldn").read_text()
        self.assertIn("public inner: type = extern(c) (argument_1: probe_inner_argument_1_optional)", text)
        self.assertIn("public outer: type = extern(c) (argument_1: inner) -> none", text)

    def test_reference_aggregate_origins_and_retention_are_recursive(self) -> None:
        borrowed = annotation()
        retained = annotation(retention="stored")
        selected = self.selection(
            self.record("View", fields={"data": borrowed}),
            self.record("Views", fields={"items": borrowed}),
            self.function("borrow", parameters={"src": borrowed},
                          result=annotation(retention="returned", sources=["src"])),
            self.function("keep", parameters={"value": retained}))
        header = ("typedef struct View { const int *data; } View;\n"
                  "typedef View Alias; typedef struct Views { Alias items[2]; } Views;\n"
                  "extern Views borrow(const int *src); extern void keep(Views value);\n")
        _, output = self.generate(self.root / "aggregate-origins", header=header,
                                  selected_policy=selected)
        text = (output / "bindings.ldn").read_text()
        self.assertIn("items: [2]view", text)
        self.assertIn("borrow: (src: ptr c.c_int) -> (result: views from src)", text)
        self.assertIn("keep: (escaping value: views) -> none", text)
        for index, key in ((2, "result"), (3, "parameters")):
            broken = json.loads(json.dumps(selected))
            if key == "result":
                del broken["declarations"][index][key]
            else:
                broken["declarations"][index][key] = {}
            self.assert_generation_error(broken, "missing required pointer policy", header=header)
        # Recursive pointers must terminate classification without erasing references.
        recursive = self.selection(self.record("Node", fields={"next": borrowed}),
                                   self.function("keep", parameters={"value": retained}))
        _, output = self.generate(self.root / "recursive-node", selected_policy=recursive,
                                  header="typedef struct Node { struct Node *next; } Node; void keep(Node value);\n")
        self.assertIn("keep: (escaping value: node) -> none", (output / "bindings.ldn").read_text())

    def test_nonsquare_array_shape_and_row_offsets(self) -> None:
        source = self.root / "matrix"
        selected = self.selection(self.record("Matrix"), {"kind": "alias", "name": "Grid"})
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef int Grid[2][3]; typedef struct Matrix { int values[2][3]; Grid alias; } Matrix;\n"))
        text = (output / "bindings.ldn").read_text()
        self.assertIn("public grid: type = [2][3]c.c_int", text)
        self.assertIn("values: [2][3]c.c_int", text)
        metadata = json.loads((output / "bindings.json").read_text())
        matrix = next(item for item in metadata["declarations"] if item["kind"] == "record")
        self.assertEqual((matrix["size"], matrix["alignment"], matrix["offsets"]),
                         (48, 4, {"values": 0, "alias": 24}))
        self.execute_adapters(source, r'''
_Static_assert(__builtin_offsetof(Matrix, values[1][0]) == 12, "row stride");
_Static_assert(sizeof(((Matrix *)0)->values[0]) == 12, "inner extent");
int main(void) {
    Matrix m = { .values = {{1,2,3},{4,5,6}}, .alias = {{7,8,9},{10,11,12}} };
    return m.values[1][0] != 4 || m.alias[1][2] != 12;
}
''')

    def test_enum_compatible_type_includes_unnamed_highbit_values(self) -> None:
        source = self.root / "enum-compatible"
        _, output = self.generate(source, selected_policy=self.selection(
            {"kind": "enum", "name": "Small"}, {"kind": "enum", "name": "Signed"},
            {"kind": "enum", "name": "Wide"}), header=(
                "typedef enum Small { LOW=0, HIGH=1 } Small;\n"
                "typedef enum Signed { NEG=-1, POS=1 } Signed;\n"
                "typedef enum Wide { WIDE_VALUE=4294967296UL } Wide;\n"))
        text = (output / "bindings.ldn").read_text()
        self.assertIn("public small: type = c.c_uint", text)
        self.assertIn("public signed: type = c.c_int", text)
        self.assertIn("public wide: type = c.c_ulong", text)
        metadata = json.loads((output / "bindings.json").read_text())
        self.assertEqual({item["landin_name"]: (item["underlying_c_type"], item["size"])
                          for item in metadata["declarations"]},
                         {"small": ("unsigned int", 4), "signed": ("int", 4),
                          "wide": ("unsigned long", 8)})
        self.execute_adapters(source, r'''
_Static_assert(__builtin_types_compatible_p(Small, unsigned int), "unsigned compatible");
_Static_assert(__builtin_types_compatible_p(Signed, int), "signed compatible");
_Static_assert(__builtin_types_compatible_p(Wide, unsigned long), "wide compatible");
int main(void) {
    Small x = (Small)0x80000000U, y = (Small)0xffffffffU;
    return !(x > 0 && (long)x == 2147483648L && (unsigned long)y == 4294967295UL);
}
''')

    def test_pointer_returning_callback_and_function_typedef_alias(self) -> None:
        for name, declaration in (
                ("Direct", "typedef int *(*Direct)(int *);"),
                ("Chained", "typedef int *Function(int *); typedef Function *Chained;")):
            for nullable in (False, True):
                with self.subTest(name=name, nullable=nullable):
                    source = self.root / f"callback-{name}-{nullable}"
                    selected = self.selection({"kind": "callback", "name": name,
                        "nullable": nullable, "parameters": {"argument_1": annotation()},
                        "result": annotation(retention="returned", sources=["argument_1"])})
                    _, output = self.generate(source, header=declaration + "\n", selected_policy=selected)
                    text = (output / "bindings.ldn").read_text()
                    self.assertIn(f"public {name.lower()}: type = extern(c) "
                                  "(argument_1: ptr mut c.c_int) -> "
                                  "(result: ptr mut c.c_int from argument_1)", text)
                    if nullable:
                        self.assertIn(f"{name.lower()}_cell_invoke: (cell: ptr u8, "
                                      "escaping argument_1: ptr mut c.c_int, "
                                      "result: ptr mut ptr mut c.c_int) -> (invoked: bool)", text)
                        stem = f"landin_probe_{name}_cell"
                        self.execute_adapters(source, f'''
static int *identity(int *p) {{ return p; }}
int main(void) {{
    int n = 19, *result = 0;
    void *cell = {stem}_allocate();
    if (!cell || {stem}_invoke(cell, &n, &result)) return 1;
    {stem}_set(cell, identity);
    if (!{stem}_invoke(cell, &n, &result) || result != &n || *result != 19) return 2;
    {stem}_release(cell);
    return 0;
}}
''')

    def test_adapter_output_labels_do_not_collide_with_source_parameters(self) -> None:
        stored = annotation(retention="stored")
        borrowed = annotation()
        nullable_callback = annotation(nullability="nullable")
        returned = annotation(retention="returned", sources=["result"])
        nullable_returned = annotation(
            nullability="nullable", retention="returned", sources=["result"])
        selected = self.selection(
            self.record("View", fields={"data": stored}),
            {"kind": "callback", "name": "CB", "nullable": True, "parameters": {}},
            self.function("borrow", parameters={"result": borrowed}, result=returned),
            self.function("choose", parameters={"result": nullable_callback},
                          result=nullable_returned))
        source = self.root / "output-label-collision"
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef union View { const int *data; int tag; } View;\n"
            "typedef int (*CB)(int);\n"
            "extern View borrow(const int *result);\n"
            "extern CB choose(CB result);\n"))
        text = (output / "bindings.ldn").read_text()
        self.assertIn(
            "borrow: (result_: ptr mut u8, escaping result: ptr c.c_int) -> none", text)
        self.assertIn(
            "choose: (result_: ptr mut u8, escaping result: ptr u8) -> none", text)
        metadata = json.loads((output / "bindings.json").read_text())
        functions = {item["c_name"]: item for item in metadata["declarations"]
                     if item["kind"] == "function"}
        self.assertEqual(functions["borrow"]["parameters"][0], {
            "c_name": "result", "landin_name": "result", "c_type": "const int *",
            "landin_type": "ptr c.c_int", "policy": borrowed,
        })
        self.assertEqual(functions["borrow"]["result"]["policy"], returned)
        self.assertEqual(functions["choose"]["parameters"][0]["policy"], nullable_callback)
        self.assertEqual(functions["choose"]["result"]["policy"], nullable_returned)
        self.assertEqual(functions["borrow"]["adapter_output_escaping_sources"], ["result"])
        self.assertEqual(functions["choose"]["adapter_output_escaping_sources"], ["result"])
        self.execute_adapters(source, r'''
View borrow(const int *result) { return (View){.data=result}; }
static int plus_one(int n) { return n + 1; }
CB choose(CB result) { return result; }
int main(void) {
    int n = 41;
    View view = {.tag=0};
    void *input = landin_probe_CB_cell_allocate();
    void *output = landin_probe_CB_cell_allocate();
    if (!input || !output) return 1;
    landin_probe_borrow_call(&view, &n);
    if (view.data != &n) return 2;
    landin_probe_CB_cell_set(input, plus_one);
    landin_probe_choose_call(output, input);
    if (landin_probe_CB_cell_access(output)(41) != 42) return 3;
    landin_probe_CB_cell_release(output);
    landin_probe_CB_cell_release(input);
    return 0;
}
''')

    def test_output_result_origins_become_explicit_adapter_escape_obligations(self) -> None:
        borrowed = annotation()
        stored = annotation(retention="stored")
        returned = annotation(retention="returned", sources=["src"])
        selected = self.selection(
            self.record("View", fields={"data": stored}),
            self.record("Native", fields={"data": borrowed}),
            self.function("borrow", parameters={"src": borrowed, "unused": borrowed}, result=returned),
            self.function("native_borrow", parameters={"src": borrowed}, result=returned),
            self.function("inline_borrow", parameters={"src": borrowed}, result=returned),
            self.function("copy_view", parameters={"src": borrowed}, result=returned))
        source = self.root / "output-origins"
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef union View { const int *data; int tag; } View;\n"
            "typedef struct Native { const int *data; } Native;\n"
            "extern View borrow(const int *src, const int *unused);\n"
            "extern Native native_borrow(const int *src);\n"
            "static inline Native inline_borrow(const int *src) { return (Native){src}; }\n"
            "extern View copy_view(View src);\n"))
        text = (output / "bindings.ldn").read_text()
        for signature in (
                "borrow: (result: ptr mut u8, escaping src: ptr c.c_int, unused: ptr c.c_int) -> none",
                "copy_view: (result: ptr mut u8, escaping src: ptr u8) -> none",
                "native_borrow: (src: ptr c.c_int) -> (result: native from src)",
                "inline_borrow: (src: ptr c.c_int) -> (result: native from src)",
                "view_data_get: (object: ptr u8) -> (value: ptr c.c_int from object)",
                "view_copy: (target: ptr mut u8, escaping source: ptr u8) -> none"):
            self.assertIn(signature, text)
        metadata = json.loads((output / "bindings.json").read_text())
        functions = {item["c_name"]: item for item in metadata["declarations"]
                     if item["kind"] == "function"}
        for name in ("borrow", "copy_view", "native_borrow", "inline_borrow"):
            self.assertEqual(functions[name]["result"]["policy"], returned)
            self.assertEqual(functions[name]["parameters"][0]["policy"], borrowed)
            self.assertEqual(functions[name]["adapter_output_escaping_sources"],
                             ["src"] if name in {"borrow", "copy_view"} else [])
        self.execute_adapters(source, r'''
View borrow(const int *src, const int *unused) { (void)unused; return (View){.data=src}; }
Native native_borrow(const int *src) { return (Native){src}; }
View copy_view(View src) { return src; }
int main(void) {
    int n = 43, unused = 0;
    View out = {.tag=0}, copy = {.tag=0};
    landin_probe_borrow_call(&out, &n, &unused);
    if (out.data != &n || *out.data != 43) return 1;
    landin_probe_copy_view_call(&copy, &out);
    if (copy.data != &n || landin_probe_view_data_get(&copy) != &n) return 2;
    if (landin_probe_inline_borrow_call(&n).data != &n || native_borrow(&n).data != &n) return 3;
    landin_probe_view_copy(&out, &copy);
    return out.data != &n;
}
''')

    def test_nullable_callback_outputs_preserve_origins_without_code_pointer_casts(self) -> None:
        borrowed = annotation()
        returned = annotation(retention="returned", sources=["argument_1"])
        source = self.root / "callback-output-origins"
        selected = self.selection(
            {"kind": "callback", "name": "CB", "nullable": True,
             "parameters": {"argument_1": borrowed, "argument_2": borrowed}, "result": returned},
            self.function("select_cb", parameters={"src": annotation(nullability="nullable")},
                          result=annotation(retention="returned", nullability="nullable", sources=["src"])))
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef int *(*CB)(int *, int *); extern CB select_cb(CB src);\n"))
        text = (output / "bindings.ldn").read_text()
        self.assertIn("public cb: type = extern(c) (argument_1: ptr mut c.c_int, "
                      "argument_2: ptr mut c.c_int) -> (result: ptr mut c.c_int from argument_1)", text)
        self.assertIn("cb_cell_invoke: (cell: ptr u8, escaping argument_1: ptr mut c.c_int, "
                      "argument_2: ptr mut c.c_int, result: ptr mut ptr mut c.c_int) -> (invoked: bool)", text)
        self.assertIn("select_cb: (result: ptr mut u8, escaping src: ptr u8) -> none", text)
        metadata = json.loads((output / "bindings.json").read_text())
        callback = next(item for item in metadata["declarations"] if item["kind"] == "callback")
        self.assertEqual(callback["adapter_output_escaping_sources"], ["argument_1"])
        self.assertEqual(callback["parameters"][0]["policy"], borrowed)
        self.assertEqual(callback["result"]["policy"], returned)
        adapters = (output / "adapters.c").read_text()
        self.assertNotRegex(adapters, r"\(\s*(?:const\s+)?void\s*\*\s*\)\s*(?:src|argument_1|value)")
        self.execute_adapters(source, r'''
CB select_cb(CB src) { return src; }
static int *identity(int *src, int *unused) { (void)unused; return src; }
int main(void) {
    int n = 47, unused = 0, *out = &unused;
    void *cell = landin_probe_CB_cell_allocate(), *copy = landin_probe_CB_cell_allocate();
    if (!cell || !copy) return 1;
    if (landin_probe_CB_cell_invoke(cell, &n, &unused, &out) || out != &unused) return 2;
    landin_probe_CB_cell_set(cell, identity);
    landin_probe_select_cb_call(copy, cell);
    if (!landin_probe_CB_cell_invoke(copy, &n, &unused, &out) || out != &n || *out != 47) return 3;
    if (landin_probe_CB_cell_access(copy) != identity) return 4;
    landin_probe_CB_cell_clear(copy);
    if (landin_probe_CB_cell_invoke(copy, &n, &unused, &out) || out != &n) return 5;
    landin_probe_CB_cell_release(copy); landin_probe_CB_cell_release(cell);
    return 0;
}
''')

    def test_opaque_getter_output_copies_keep_reference_sources(self) -> None:
        stored = annotation(retention="stored")
        source = self.root / "getter-output-origins"
        selected = self.selection(
            self.record("View", fields={"data": stored}),
            self.record("Native", fields={"data": annotation()}),
            self.record("Outer", representation="opaque",
                        fields={name: stored for name in ("one", "many", "native", "natives", "pointers")}),
            {"kind": "variable", "name": "saved", "storage": "import", "writable": True, "value": stored})
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef union View { const int *data; int tag; } View;\n"
            "typedef struct Native { const int *data; } Native;\n"
            "typedef struct Outer { View one; View many[2]; Native native; Native natives[2]; const int *pointers[2]; } Outer;\n"
            "extern View saved;\n"))
        text = (output / "bindings.ldn").read_text()
        for signature in (
                "outer_one_get: (escaping object: ptr u8, value: ptr mut u8) -> none",
                "outer_many_get: (escaping object: ptr u8, index: usize, value: ptr mut u8) -> none",
                "outer_native_get: (object: ptr u8) -> (value: native from object)",
                "outer_natives_get: (object: ptr u8, index: usize) -> (value: native from object)",
                "outer_pointers_get: (object: ptr u8, index: usize) -> (value: ptr c.c_int from object)",
                "outer_copy: (target: ptr mut u8, escaping source: ptr u8) -> none",
                "saved_read: (value: ptr mut u8) -> none",
                "saved_write: (escaping value: ptr u8) -> none"):
            self.assertIn(signature, text)
        self.execute_adapters(source, r'''
static int n = 53;
View saved = {.data=&n};
int main(void) {
    Outer object = {.one={.data=&n}, .many={{.data=&n},{.data=&n}},
                    .native={&n}, .natives={{&n},{&n}}, .pointers={&n,&n}};
    View out = {.tag=0};
    landin_probe_outer_one_get(&object, &out);
    if (out.data != &n) return 1;
    out.tag = 0; landin_probe_outer_many_get(&object, 1, &out);
    if (out.data != &n) return 2;
    if (landin_probe_outer_native_get(&object).data != &n ||
        landin_probe_outer_natives_get(&object, 1).data != &n ||
        landin_probe_outer_pointers_get(&object, 1) != &n) return 3;
    out.tag = 0; landin_probe_saved_read(&out);
    return out.data != &n;
}
''')

    def test_generator_owned_stores_reject_call_only_policy(self) -> None:
        stored = annotation(retention="stored")
        # A native aggregate's field policy is not a generated setter. Its
        # whole-value policy must nevertheless admit this generated global store.
        kinds = (
            ("int *", "", []),
            ("Native", "typedef struct Native { int *p; } Native;\n",
             [self.record("Native", fields={"p": annotation()})]),
            ("Box", "typedef union Box { int *p; int tag; } Box;\n",
             [self.record("Box", fields={"p": stored})]),
            ("CB", "typedef int (*CB)(int);\n",
             [{"kind": "callback", "name": "CB", "nullable": True, "parameters": {}}]))
        for kind, header, declarations in kinds:
            for tls in ("", "_Thread_local "):
                for storage in ("import", "define"):
                    with self.subTest(kind=kind, tls=tls, storage=storage):
                        selected = self.selection(*declarations, {
                            "kind": "variable", "name": "saved", "storage": storage,
                            "writable": True, "value": annotation(nullability="nullable")})
                        self.assert_generation_error(selected, "retention 'call' contradicts generated retaining store",
                            header=header + f"extern {tls}{kind} saved;\n")
        for declaration, fields in (
                ("int *p;", {"p": annotation()}),
                ("int *p[2];", {"p": annotation()}),
                ("Native p;", {"p": annotation()}),
                ("Native p[2];", {"p": annotation()}),
                ("CB p;", {"p": annotation(nullability="nullable")})):
            with self.subTest(field=declaration):
                self.assert_generation_error(self.selection(
                    self.record("Native", fields={"data": annotation()}),
                    {"kind": "callback", "name": "CB", "nullable": True, "parameters": {}},
                    self.record("Box", fields=fields)),
                    "retention 'call' contradicts generated retaining store",
                    header="typedef struct Native { int *data; } Native; typedef int (*CB)(int);\n"
                           f"typedef union Box {{ {declaration} int tag; }} Box;\n")
        # No inference about unselected foreign bodies, or a read-only accessor.
        _, output = self.generate(self.root / "call-only-not-a-store", selected_policy=self.selection(
            self.function("consume", parameters={"p": annotation()}),
            {"kind": "variable", "name": "observed", "storage": "import", "writable": False,
             "value": annotation()}), header="extern void consume(int *p); extern int *observed;\n")
        text = (output / "bindings.ldn").read_text()
        self.assertIn("consume: (p: ptr mut c.c_int) -> none", text)
        self.assertIn("observed_read: () -> (value: ptr mut c.c_int)", text)
        self.assertNotIn("observed_write", text)

    def test_generated_store_retention_policies_are_explicit_and_escaping(self) -> None:
        for retention in ("stored", "returned", "static"):
            for tls in ("", "_Thread_local "):
                source = self.root / f"store-{retention}-{bool(tls)}"
                contract = annotation(retention=retention, nullability="nullable")
                _, output = self.generate(source, selected_policy=self.selection(
                    {"kind": "variable", "name": "saved", "storage": "define", "writable": True,
                     "value": contract}), header=f"extern {tls}int *saved;\n")
                text = (output / "bindings.ldn").read_text()
                self.assertIn("saved_write: (escaping value: probe_saved_value_optional) -> none", text)
                metadata = json.loads((output / "bindings.json").read_text())
                variable = next(item for item in metadata["declarations"] if item["kind"] == "variable")
                self.assertEqual(variable["policy"], contract)
                self.execute_adapters(source, r'''
static int n = 59;
int main(void) {
    if (saved != 0) return 1;
    landin_probe_saved_write(&n);
    if (saved != &n || landin_probe_saved_read() != &n || *saved != 59) return 2;
    landin_probe_saved_write(0);
    return saved != 0;
}
''')

    def test_incoming_varargs_locals_avoid_typedefs_and_policy_handlers(self) -> None:
        selected = self.selection({
            "kind": "incoming_varargs", "name": "receive", "handler": "tail_1",
            "count_parameter": "count", "parameters": {},
            "schema": [{"name": "value", "promoted": "c_int"}],
        })
        source = self.root / "incoming-local-collisions"
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef int fixed_1; extern int receive(fixed_1 count, ...);\n"))
        adapters = (output / "adapters.c").read_text()
        self.assertIn("int receive(fixed_1 fixed_1_, ...)", adapters)
        self.assertIn("if (fixed_1_ != (fixed_1)1) __builtin_trap();", adapters)
        self.assertIn("int tail_1_ = va_arg(arguments, int);", adapters)
        self.assertIn("return tail_1(fixed_1_, tail_1_);", adapters)
        self.execute_adapters(source, r'''
int tail_1(fixed_1 count, int value) { return count == 1 ? value + 1 : 0; }
int main(void) { return receive(1, 36) != 37; }
''')

    def test_incoming_handler_prototype_avoids_typedef_shadowing(self) -> None:
        selected = self.selection({
            "kind": "incoming_varargs", "name": "receive", "handler": "handle",
            "count_parameter": "argument_1", "parameters": {},
            "schema": [{"name": "one", "promoted": "c_int"}],
        })
        source = self.root / "incoming-handler-typedef-shadow"
        _, output = self.generate(source, selected_policy=selected, header=(
            "typedef int argument_1; int receive(int, argument_1, ...);\n"))
        exports = (output / "exports.h").read_text()
        self.assertIn("int handle(int, argument_1 argument_2, int one);", exports)
        bindings = (output / "bindings.ldn").read_text()
        self.assertIn("(argument_1: c.c_int, argument_2: argument_1, one: c.c_int)", bindings)

    def test_opaque_local_names_are_disjoint_from_all_header_declarations(self) -> None:
        for name in ("object", "value", "source", "target", "index", "result", "argument_1"):
            for explicit in (False, True):
                with self.subTest(name=name, explicit=explicit):
                    source = self.root / f"opaque-local-{name}-{explicit}"
                    l_name = "chosen_object" if explicit else name
                    selected = self.selection(self.record(name, **({"landin_name": l_name} if explicit else {})),
                                              self.function("roundtrip"))
                    if explicit:
                        selected["namespace"] = "explicit_module"
                    stem = "landin_" + selected["namespace"]
                    _, output = self.generate(source, selected_policy=selected, header=(
                        f"typedef union {name} {{ int number; }} {name};\n"
                        f"extern {name} roundtrip({name} input);\n"))
                    text = (output / "bindings.ldn").read_text()
                    self.assertIn(f"{l_name}_copy: (target: ptr mut u8, source: ptr u8) -> none", text)
                    self.assertIn("roundtrip: (result: ptr mut u8, input: ptr u8) -> none", text)
                    self.execute_adapters(source, f'''
{name} roundtrip({name} input) {{ input.number += 1; return input; }}
int main(void) {{
    void *a = {stem}_{l_name}_allocate(), *b = {stem}_{l_name}_allocate();
    if (!a || !b) return 1;
    if ({stem}_{l_name}_size() != sizeof({name}) ||
        {stem}_{l_name}_alignment() != _Alignof({name})) return 2;
    {stem}_{l_name}_number_set(a, 61);
    {stem}_{l_name}_copy(b, a);
    if ({stem}_{l_name}_number_get(b) != 61) return 3;
    {stem}_roundtrip_call(a, b);
    if ({stem}_{l_name}_number_get(a) != 62) return 4;
    {stem}_{l_name}_release(b); {stem}_{l_name}_release(a);
    return 0;
}}
''')
        # Exercise every opaque accessor branch with colliding nested typedefs,
        # including suffixes the allocator must skip, not just four spellings.
        source = self.root / "opaque-local-all-helpers"
        stored = annotation(retention="stored")
        _, output = self.generate(source, selected_policy=self.selection(
            self.record("object", fields={"cb": annotation(retention="stored", nullability="nullable"),
                                         "callbacks": stored}),
            self.record("value"), self.record("target"), self.record("source"),
            {"kind": "callback", "name": "index", "nullable": True, "parameters": {}}), header=(
                "typedef int (*index)(int);\n"
                "typedef union value { int n; } value; typedef union target { int n; } target;\n"
                "typedef union source { int n; } source;\n"
                "extern int object_, value_, index_;\n"
                "typedef union object { value one; target many[2]; source other; int numbers[2]; "
                "index cb; index callbacks[2]; } object;\n"))
        self.assertIn("object_cb_access: (object: ptr u8) -> (value: index from object)",
                      (output / "bindings.ldn").read_text())
        self.execute_adapters(source, r'''
static int plus_one(int n) { return n + 1; }
int main(void) {
    object a; value v = {.n=67}, out = {.n=0}; target t = {.n=71}, tout = {.n=0};
    source s = {.n=73}, sout = {.n=0};
    landin_probe_object_one_set(&a, &v); landin_probe_object_one_get(&a, &out);
    if (out.n != 67) return 1;
    landin_probe_object_many_set(&a, 1, &t); landin_probe_object_many_get(&a, 1, &tout);
    if (tout.n != 71) return 2;
    landin_probe_object_other_set(&a, &s); landin_probe_object_other_get(&a, &sout);
    if (sout.n != 73) return 3;
    landin_probe_object_numbers_set(&a, 1, 79);
    if (landin_probe_object_numbers_get(&a, 1) != 79) return 4;
    landin_probe_object_cb_clear(&a);
    if (landin_probe_object_cb_present(&a)) return 5;
    landin_probe_object_cb_set(&a, plus_one);
    if (!landin_probe_object_cb_present(&a) || landin_probe_object_cb_access(&a)(82) != 83) return 6;
    landin_probe_object_callbacks_set(&a, 1, plus_one);
    if (landin_probe_object_callbacks_get(&a, 1)(88) != 89) return 7;
    return 0;
}
''')

    def test_residual_validation_failures_preserve_the_complete_output_set(self) -> None:
        parent = self.root / "residual-validation"
        sysroot, includes, output = self.make_tree(parent, header="extern int *saved;\n",
            selected_policy=self.selection({"kind": "variable", "name": "saved", "storage": "import",
                                            "writable": True, "value": annotation(retention="stored")}))
        command = self.command(parent, sysroot, includes, output)
        process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        names = ("bindings.ldn", "adapters.c", "exports.h", "bindings.json")
        original = {name: (output / name).read_bytes() for name in names}
        cases = (
            ("extern int *saved;\n", self.selection({"kind": "variable", "name": "saved", "storage": "import",
                "writable": True, "value": annotation()}), "contradicts generated retaining store"),
            ("typedef union View { int *data; int tag; } View; extern View borrow(int src);\n",
             self.selection(self.record("View", fields={"data": annotation(retention="stored")}),
                            self.function("borrow", result=annotation(retention="returned", sources=["src"]))),
             "from must name reference-bearing parameters"),
            # A header macro colliding with an adapter is legal until generated
            # C is validated. Fail after rendering, before replacing any output.
            ("#define landin_probe_object_number_set 1\n"
             "typedef union object { int number; } object;\n",
             self.selection(self.record("object")), "validating generated adapters"))
        for header, selected, error in cases:
            with self.subTest(error=error):
                (parent / "api.h").write_text(header)
                (parent / "policy.json").write_text(json.dumps(selected))
                process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn(error, process.stderr)
                self.assertNotIn("Traceback", process.stderr)
                self.assertEqual({name: (output / name).read_bytes() for name in names}, original)
                self.assertEqual({item.name for item in output.iterdir()}, set(names))

    def test_global_value_setters_do_not_shadow_objects_or_types(self) -> None:
        kinds = {
            "scalar": ("int", "", None, "int input = 37;", "value == 37"),
            "pointer": ("int *", "", annotation(retention="stored"),
                        "int n = 37; int *input = &n;", "value == &n"),
            "callback": ("CB", "typedef int (*CB)(int);", annotation(retention="stored"),
                         "CB input = plus_one;", "value(36) == 37"),
            "nullable": ("CB", "typedef int (*CB)(int);",
                         annotation(retention="stored", nullability="nullable"),
                         "CB input = plus_one;", "value(36) == 37"),
            "opaque": ("Box", "typedef union Box { int number; } Box;", None,
                       "Box input = {.number = 37};", "value.number == 37"),
        }
        for kind, (ctype, types, contract, setup, check) in kinds.items():
            for tls in ("", "_Thread_local "):
                with self.subTest(kind=kind, tls=bool(tls)):
                    declarations = []
                    if kind in {"callback", "nullable"}:
                        declarations.append({"kind": "callback", "name": "CB",
                                             "nullable": kind == "nullable", "parameters": {}})
                    if kind == "opaque":
                        declarations.append(self.record("Box"))
                    variable = {"kind": "variable", "name": "value", "storage": "import", "writable": True}
                    if contract:
                        variable["value"] = contract
                    declarations.append(variable)
                    source = self.root / f"value-{kind}-{bool(tls)}"
                    _, output = self.generate(source, header=f"{types}\nextern {tls}{ctype} value;\n",
                                              selected_policy=self.selection(*declarations))
                    adapters = (output / "adapters.c").read_text()
                    self.assertNotIn("\n    value = value;\n", adapters)
                    self.assertIn("value = " + ("*(const Box *)value_;" if kind == "opaque" else "value_;"), adapters)
                    helper = "static int plus_one(int n) { return n + 1; }" if "CB" == ctype else ""
                    argument = "&input" if kind == "opaque" else "input"
                    self.execute_adapters(source, f'''
{tls}{ctype} value;
{helper}
int main(void) {{
    {setup}
    landin_probe_value_write({argument});
    if (!({check})) return 1;
    return 0;
}}
''')

    def test_every_normative_keyword_is_normalized_and_explicit_names_refused(self) -> None:
        module = runpy.run_path(str(GENERATOR))
        spec = (HERE.parent / "spec.md").read_text()
        production = re.search(r'^keyword\s*::=(.*?)(?=\n\n)', spec, re.M | re.S)
        self.assertIsNotNone(production)
        keywords = set(re.findall(r'"([a-z]+)"', production.group(1)))
        self.assertEqual(module["LANDIN_KEYWORDS"], keywords)
        c_keywords = {"auto", "break", "case", "char", "const", "continue", "default",
                      "do", "double", "else", "enum", "extern", "float", "for", "goto",
                      "if", "inline", "int", "long", "register", "restrict", "return",
                      "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
                      "union", "unsigned", "void", "volatile", "while"}
        fields = sorted(keywords - c_keywords | {"compiler", "assembler", "linker"})
        _, output = self.generate(self.root / "keywords", selected_policy=self.selection(self.record("Names")),
                                  header="typedef struct Names { " +
                                  " ".join(f"int {name};" for name in fields) + " } Names;\n")
        text = (output / "bindings.ldn").read_text()
        for name in fields:
            self.assertIn(f"    c_{name}: c.c_int", text)
        for name in sorted(keywords | {"compiler", "assembler", "linker"}):
            with self.subTest(name=name):
                self.assertEqual(module["sanitize_landin"](name), "c_" + name)
                self.assert_generation_error(self.selection(self.function("f", landin_name=name)),
                                             "is reserved", header="int f(void);\n")

    def test_unsupported_function_abi_and_unnamed_result_publish_nothing(self) -> None:
        cases = [
            ("int __attribute__((ms_abi)) f(int x);", {}, "unsupported calling convention"),
            ("int f(void *p __attribute__((pass_object_size(0))));",
             {"parameters": {"p": annotation()}}, "PassObjectSizeAttr"),
            ("int (*f(void))(int);", {}, "unsupported nested function return declarator"),
            ("typedef int (__attribute__((ms_abi)) *CB)(int);", None, "unsupported")]
        for index, (header, extra, message) in enumerate(cases):
            with self.subTest(header=header):
                entry = (self.function("f", **extra) if extra is not None else
                         {"kind": "callback", "name": "CB", "nullable": False, "parameters": {}})
                process, output = self.generate(self.root / f"abi-refusal-{index}", header=header + "\n",
                                               selected_policy=self.selection(entry), expect_success=False)
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn(message, process.stderr)
                self.assertFalse(output.exists())

    def test_local_typedef_shadowing_cannot_change_public_signature(self) -> None:
        source = self.root / "shadow"
        _, output = self.generate(source, selected_policy=self.selection(self.function("f")), header=(
            "typedef int T; int f(T x);\n"
            "static inline void unused(void) { typedef double T; T x=0; (void)x; }\n"))
        text = (output / "bindings.ldn").read_text()
        self.assertIn("public t: type = c.c_int", text)
        self.assertIn("f: (x: t) -> (result: c.c_int)", text)
        self.assertNotIn("c.c_double", text)
        self.execute_adapters(source, r'''
_Static_assert(__builtin_types_compatible_p(__typeof__(&f), int (*)(int)), "public typedef");
int f(T x) { return x + 1; }
int main(void) { return f(36) != 37; }
''')

    def test_chained_record_and_enum_selections_preserve_identity(self) -> None:
        _, output = self.generate(self.root / "chained-tags", selected_policy=self.selection(
            self.record("Third"), {"kind": "enum", "name": "Last"}), header=(
                "typedef struct S { int x; } S; typedef S Second; typedef Second Third;\n"
                "typedef enum E { E_ONE=1 } E; typedef E Next; typedef Next Last;\n"))
        text = (output / "bindings.ldn").read_text()
        self.assertIn("public third: type = layout(c) struct\n    x: c.c_int\nend third", text)
        self.assertIn("public last: type = c.c_uint\npublic e_one: last = 1", text)
        metadata = json.loads((output / "bindings.json").read_text())
        self.assertEqual(len(metadata["declarations"]), 2)

    def test_ambient_include_variables_are_excluded_from_every_clang_invocation(self) -> None:
        parent = self.root / "ambient"
        sysroot, includes, output = self.make_tree(parent, header="#include <dep.h>\n",
                                                  selected_policy=self.selection(self.function("ambient")))
        ambient = self.root / "ambient-includes"
        ambient.mkdir()
        (ambient / "dep.h").write_text("int ambient(int x);\n")
        for variable in ("CPATH", "C_INCLUDE_PATH"):
            with self.subTest(variable=variable):
                env = dict(os.environ, **{variable: str(ambient)})
                process = subprocess.run(self.command(parent, sysroot, includes, output),
                                         env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn("'dep.h' file not found", process.stderr)
                self.assertFalse(output.exists())
        # Instrument real subprocess calls in-process: include exclusion must
        # hold for triple/macros/preprocessing/AST/enum probe/adapter validation.
        (parent / "api.h").write_text("typedef enum E { ONE=1 } E;\n")
        (parent / "policy.json").write_text(json.dumps(self.selection({"kind": "enum", "name": "E"})))
        module = runpy.run_path(str(GENERATOR))
        real_run = subprocess.run
        calls: list[list[str]] = []
        def checked_run(command: list[str], **kwargs: Any) -> Any:
            calls.append(command)
            self.assertIn("env", kwargs)
            for variable in ("CPATH", "C_INCLUDE_PATH", "CCC_OVERRIDE_OPTIONS"):
                self.assertNotIn(variable, kwargs["env"])
            return real_run(command, **kwargs)
        with mock.patch.dict(os.environ, {"CPATH": str(ambient), "C_INCLUDE_PATH": str(ambient),
                                          "CCC_OVERRIDE_OPTIONS": "+-fshort-enums"}), \
                mock.patch.object(subprocess, "run", side_effect=checked_run):
            self.assertEqual(module["main"](self.command(parent, sysroot, includes, output)[2:]), 0)
        self.assertGreaterEqual(len(calls), 6)
        self.assertTrue(any("enum-probe.i" in " ".join(command) for command in calls))
        self.assertTrue(any("adapters.c" in " ".join(command) for command in calls))

    def test_anonymous_enums_are_deterministic_across_hash_seeds(self) -> None:
        parent = self.root / "hash-seeds"
        sysroot, includes, output = self.make_tree(parent, header="enum { A=1 }; enum { B=2 };\n",
            selected_policy=self.selection({"kind": "enum", "name": "@A", "landin_name": "a_enum"},
                                           {"kind": "enum", "name": "@B", "landin_name": "b_enum"}))
        baseline = None
        for seed in range(12):
            process = subprocess.run(self.command(parent, sysroot, includes, output),
                                     env=dict(os.environ, PYTHONHASHSEED=str(seed)),
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            actual = {name: (output / name).read_bytes() for name in
                      ("bindings.ldn", "adapters.c", "exports.h", "bindings.json")}
            if baseline is None:
                baseline = actual
            self.assertEqual(actual, baseline, f"hash seed {seed}")
        text = (output / "bindings.ldn").read_text()
        self.assertLess(text.index("public a_enum:"), text.index("public b_enum:"))

    def test_transitive_file_macros_are_relocation_independent(self) -> None:
        for option in ("--include-dir", "--system-include-dir"):
            baseline = None
            for location in ("short", "a-much-longer-parent/relocated"):
                parent = self.root / option[2:] / location
                sysroot, includes, output = self.make_tree(parent, header="#include <dep.h>\n",
                    selected_policy=self.selection({"kind": "enum", "name": "E"}))
                transitive = parent / "transitive"
                transitive.mkdir()
                (transitive / "dep.h").write_text('#include "nested.h"\n')
                (transitive / "nested.h").write_text("enum E { FILE_BYTES = sizeof(__FILE__) };\n")
                command = self.command(parent, sysroot, includes, output) + [option, str(transitive)]
                process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                self.assertEqual(process.returncode, 0, process.stderr)
                actual = {name: (output / name).read_bytes() for name in
                          ("bindings.ldn", "adapters.c", "exports.h", "bindings.json")}
                if baseline is None:
                    baseline = actual
                self.assertEqual(actual, baseline, (option, location))
                logical = "include/1/nested.h" if option == "--include-dir" else "system/3/nested.h"
                self.assertIn(f"public file_bytes: e = {len(logical) + 1}",
                              (output / "bindings.ldn").read_text())

    def test_publication_preflight_and_injected_failure_preserve_output_set(self) -> None:
        parent = self.root / "publication"
        sysroot, includes, output = self.make_tree(parent, header="int f(void);\n",
                                                  selected_policy=self.selection(self.function("f")))
        output.mkdir()
        names = ("bindings.ldn", "adapters.c", "exports.h", "bindings.json")
        for name in names:
            if name == "adapters.c":
                (output / name).mkdir()
            else:
                (output / name).write_text("old " + name)
        process = subprocess.run(self.command(parent, sysroot, includes, output),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("existing output is not a regular file", process.stderr)
        self.assertNotIn("Traceback", process.stderr)
        self.assertTrue((output / "adapters.c").is_dir())
        for name in set(names) - {"adapters.c"}:
            self.assertEqual((output / name).read_text(), "old " + name)
        (output / "adapters.c").rmdir()
        # Rollback after each possible successful prefix, with both preexisting
        # and newly created destinations. Use real replacement except one fault.
        module = runpy.run_path(str(GENERATOR))
        real_replace = os.replace
        for existing in (True, False):
            for fail_at in range(1, 5):
                destination = parent / f"destination-{existing}-{fail_at}"
                staging = parent / f"staging-{existing}-{fail_at}"
                staging.mkdir()
                if existing:
                    destination.mkdir()
                for name in names:
                    (staging / name).write_text("new " + name)
                    if existing:
                        (destination / name).write_text("old " + name)
                calls = 0
                def fail_once(src: pathlib.Path, dst: pathlib.Path) -> None:
                    nonlocal calls
                    calls += 1
                    if calls == fail_at:
                        raise OSError(5, "injected publication failure")
                    real_replace(src, dst)
                with mock.patch.object(os, "replace", side_effect=fail_once):
                    with self.assertRaisesRegex(module["BindingError"], "previous outputs restored"):
                        module["publish_outputs"](staging, destination)
                if existing:
                    self.assertEqual({name: (destination / name).read_text() for name in names},
                                     {name: "old " + name for name in names})
                else:
                    self.assertFalse(destination.exists())
        self.assertFalse(list(parent.glob(".landin-bindings-backup-*")))

    def test_failed_validation_does_not_replace_outputs(self) -> None:
        parent = self.root / "atomic"
        sysroot, includes, output = self.make_tree(parent)
        output.mkdir()
        for name in ("bindings.ldn", "adapters.c", "exports.h", "bindings.json"):
            (output / name).write_text("sentinel\n", encoding="utf-8")
        broken = policy()
        broken["declarations"][0]["fields"] = {"removed": annotation()}
        (parent / "policy.json").write_text(json.dumps(broken), encoding="utf-8")
        process = subprocess.run(self.command(parent, sysroot, includes, output),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(process.returncode, 2)
        self.assertIn("stale policy", process.stderr)
        for name in ("bindings.ldn", "adapters.c", "exports.h", "bindings.json"):
            self.assertEqual((output / name).read_text(encoding="utf-8"), "sentinel\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
