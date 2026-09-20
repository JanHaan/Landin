#!/usr/bin/env python3
"""Refusal controls for the declared determinism contract.

`test_determinism.py` passes today, which proves nothing on its own: a check
that cannot fail reports success forever while the property it named rots.
R730-18's editor grammar drifted for exactly that reason, and R730-22 records
that the pass nobody runs still cannot fail.  So every refusal in the
determinism contract is exercised here against a synthetic artifact that
violates it, and this file runs in the same acceptance jobs.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import unittest.mock

SPEC = importlib.util.spec_from_file_location(
    "landin_determinism", Path(__file__).with_name("test_determinism.py"))
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def report(paths, *, hashes=None, identities=None):
    sources = []
    for index, path in enumerate(paths, start=1):
        sources.append({
            "source": index if identities is None else identities[index - 1],
            "path_hex": path.encode().hex(),
            "sha256": (hashes[index - 1] if hashes else "%064x" % index)})
    return json.dumps({"schema": 1, "build": {"target": "linux-x86-64"},
                       "sources": sources, "items": []}).encode()


DEBUG = """\t.file 1 "main.ldn"
\tmov\t%rsp,%rbp
\t.asciz "{directory}"
\tadd\t$0x1,%rax
# Landin caller files {identity}
.ascii "{identity}"
"""


def debug_text(directory, identity, body="\tadd\t$0x1,%rax"):
    return DEBUG.format(directory=directory, identity=identity).replace(
        "\tadd\t$0x1,%rax", body).encode()


class ReportControls(unittest.TestCase):
    def test_paths_are_the_only_permitted_report_difference(self):
        left = report(["main.ldn"])
        right = report(["/elsewhere/main.ldn"])
        self.assertEqual(CHECK.without_paths(left), CHECK.without_paths(right))

    def test_a_changed_content_hash_is_refused(self):
        left = report(["main.ldn"], hashes=["a" * 64])
        right = report(["main.ldn"], hashes=["b" * 64])
        self.assertNotEqual(CHECK.without_paths(left),
                            CHECK.without_paths(right))

    def test_a_report_source_must_carry_a_path_and_a_hash(self):
        parsed = json.loads(report(["main.ldn"]))
        del parsed["sources"][0]["sha256"]
        with self.assertRaises(CHECK.Failure):
            CHECK.without_paths(json.dumps(parsed).encode())

    def test_imported_sources_must_be_in_canonical_order(self):
        CHECK.check_canonical_sources(
            report(["app/main.ldn", "core/mem/a.ldn", "core/mem/b.ldn"]), "x")
        with self.assertRaises(CHECK.Failure):
            CHECK.check_canonical_sources(
                report(["app/main.ldn", "core/mem/b.ldn", "core/mem/a.ldn"]),
                "x")

    def test_source_identities_must_number_one_to_n(self):
        with self.assertRaises(CHECK.Failure):
            CHECK.check_canonical_sources(
                report(["a.ldn", "b.ldn"], identities=[1, 3]), "x")

    def test_a_malformed_content_hash_is_refused(self):
        with self.assertRaises(CHECK.Failure):
            CHECK.check_canonical_sources(
                report(["a.ldn"], hashes=["not-a-hash"]), "x")


def panic_map(paths, *, assembly=b"assembly\n", build_id="a" * 64,
              offsets=None):
    files = []
    for index, path in enumerate(paths, start=1):
        files.append({"file_id": index, "path_hex": path.encode().hex(),
                      "source_sha256": "%064x" % index, "panic_base": 100,
                      "byte_length": 9,
                      "line_offsets": offsets or [0, 5]})
    import hashlib
    return json.dumps({
        "build_id": build_id,
        "assembly_sha256": hashlib.sha256(assembly).hexdigest(),
        "files": files}).encode()


class PanicMapControls(unittest.TestCase):
    def test_paths_are_the_only_permitted_map_difference(self):
        self.assertEqual(CHECK.without_map_paths(panic_map(["main.ldn"])),
                         CHECK.without_map_paths(panic_map(["/far/main.ldn"])))

    def test_a_map_must_carry_a_build_identity(self):
        with self.assertRaises(CHECK.Failure):
            CHECK.without_map_paths(panic_map(["a.ldn"], build_id="short"))

    def test_a_map_file_must_carry_a_content_hash(self):
        parsed = json.loads(panic_map(["a.ldn"]))
        del parsed["files"][0]["source_sha256"]
        with self.assertRaises(CHECK.Failure):
            CHECK.without_map_paths(json.dumps(parsed).encode())

    def test_unordered_line_offsets_are_refused(self):
        with self.assertRaises(CHECK.Failure):
            CHECK.without_map_paths(panic_map(["a.ldn"], offsets=[5, 0]))

    def test_a_map_must_name_the_assembly_it_describes(self):
        CHECK.check_map_binds_assembly(panic_map(["a.ldn"]), b"assembly\n", "x")
        with self.assertRaises(CHECK.Failure) as raised:
            CHECK.check_map_binds_assembly(panic_map(["a.ldn"]), b"other\n", "x")
        self.assertIn("not bound to the assembly", str(raised.exception))


class DebugResidueControls(unittest.TestCase):
    def setUp(self):
        self.left = Path("/build/alpha")
        self.right = Path("/build/beta-longer")

    def residue(self, first, second):
        CHECK.debug_residue(first, second, self.left, self.right, "x")

    def test_only_the_directory_and_its_identity_may_move(self):
        self.residue(debug_text(self.left, "a" * 64),
                     debug_text(self.right, "b" * 64))

    def test_an_instruction_that_moved_is_refused(self):
        with self.assertRaises(CHECK.Failure) as raised:
            self.residue(debug_text(self.left, "a" * 64),
                         debug_text(self.right, "b" * 64,
                                    body="\tadd\t$0x2,%rax"))
        self.assertIn("moved with the build directory", str(raised.exception))

    def test_a_string_literal_shaped_like_a_path_is_not_excused(self):
        #  The excuse is naming the directory the compilation ran in, not
        #  looking like an absolute path.  A Landin string literal that
        #  happens to start with a slash must not buy an exemption.
        with self.assertRaises(CHECK.Failure):
            self.residue(debug_text(self.left, "a" * 64,
                                    body='\t.asciz "/usr/share/one"'),
                         debug_text(self.right, "b" * 64,
                                    body='\t.asciz "/usr/share/two"'))

    def test_an_identity_alone_is_not_a_compilation_directory(self):
        same = str(self.left)
        with self.assertRaises(CHECK.Failure) as raised:
            self.residue(debug_text(same, "a" * 64),
                         debug_text(same, "b" * 64))
        self.assertIn("recorded no compilation directory",
                      str(raised.exception))

    def test_a_changed_length_is_refused(self):
        with self.assertRaises(CHECK.Failure):
            self.residue(debug_text(self.left, "a" * 64),
                         debug_text(self.right, "b" * 64) + b"\tnop\n")

    def test_debug_assembly_must_record_a_directory_at_all(self):
        plain = b"\tmov\t%rsp,%rbp\n"
        with self.assertRaises(CHECK.Failure):
            self.residue(plain, plain)


class PlumbingControls(unittest.TestCase):
    """A failing comparison must reach the exit status, not just a predicate."""

    def test_a_nondeterministic_compiler_fails_the_run(self):
        calls = {"n": 0}

        def perturbing(refine, source, output, **kwargs):
            calls["n"] += 1
            Path(output).write_bytes(b"assembly %d\n" % calls["n"])
            report = kwargs.get("report")
            if report is not None:
                Path(report).write_bytes(report_bytes())

        def report_bytes():
            return report(["main.ldn"])

        with tempfile.TemporaryDirectory() as scratch:
            with unittest.mock.patch.object(CHECK, "compile", perturbing):
                with self.assertRaises(CHECK.Failure) as raised:
                    CHECK.equivalent_closures(
                        Path("refine"), Path("main.ldn"), None,
                        "linux-x86-64", ("size", "auto"), "probe",
                        Path(scratch) / "area")
        self.assertIn("assembly is not deterministic", str(raised.exception))


class ContractControls(unittest.TestCase):
    def test_every_target_declares_a_debug_flag(self):
        self.assertEqual(set(CHECK.DEBUG_FLAG), set(CHECK.TARGETS))
        self.assertEqual(CHECK.DEBUG_FLAG["cortex-m0"], "lines")

    def test_the_contract_covers_all_three_targets(self):
        self.assertEqual(CHECK.TARGETS,
                         ("linux-x86-64", "darwin-arm64", "cortex-m0"))

    def test_the_corpus_is_shared_by_every_target(self):
        fixtures = CHECK.repository_root() / "compiler/tests/fixtures/runtime"
        for name in CHECK.CORPUS:
            self.assertTrue((fixtures / name / "main.ldn").is_file(), name)
        self.assertTrue((fixtures / CHECK.CLOSURE_FIXTURE).is_dir())

    def test_an_unknown_target_is_refused(self):
        with unittest.mock.patch.object(
                sys, "argv",
                [__file__, "--refine", __file__, "--targets", "vax"]):
            with self.assertRaises(CHECK.Failure):
                CHECK.main()

    def test_profiles_span_both_ends_of_the_option_space(self):
        self.assertIn(("none", "off"), CHECK.PROFILES)
        self.assertIn(("speed", "all"), CHECK.PROFILES)


if __name__ == "__main__":
    unittest.main()
