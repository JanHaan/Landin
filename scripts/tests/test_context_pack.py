#!/usr/bin/env python3
"""Tests for the task-directed context packer."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "context_pack", ROOT / "scripts/context_pack.py",
)
CONTEXT_PACK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTEXT_PACK)


class ContextPackTests(unittest.TestCase):
    def test_comment_stripping_respects_ada_strings(self):
        self.assertEqual(
            CONTEXT_PACK.strip_ada_comment(
                'Put ("-- retained"); -- removed',
            ),
            'Put ("-- retained"); ',
        )
        self.assertEqual(
            CONTEXT_PACK.strip_ada_comment('Put ("a ""--"" b");'),
            'Put ("a ""--"" b");',
        )

    def test_compact_interface_preserves_logical_lines(self):
        source = (
            "-- heading\n"
            "package  Example  is\n"
            "   Name : constant String := \"a  b--c\"; -- note\n"
            "\n"
            "end Example;\n"
        )
        self.assertEqual(
            CONTEXT_PACK.compact_interface(source),
            "package Example is\n"
            "Name : constant String := \"a  b--c\";\n"
            "end Example;\n",
        )

    def test_outline_carries_lines_and_source_identity(self):
        text = (
            "with Ada.Text_IO;\n"
            "package body Example is\n"
            "   procedure Run is\n"
            "   begin\n"
            "      null;\n"
            "   end Run;\n"
            "end Example;\n"
        )
        source = CONTEXT_PACK.Source(
            Path("example.adb"), "example.adb", text, "abc",
        )
        outline = CONTEXT_PACK.declaration_outline(source)
        self.assertIn('path="example.adb"', outline)
        self.assertIn("1: with Ada.Text_IO;", outline)
        self.assertIn("2: package body Example is", outline)
        self.assertIn("3: procedure Run is", outline)

    def test_query_chunks_are_exact_source_slices(self):
        lines = [f"line_{number}\n" for number in range(1, 61)]
        lines[24] = "procedure Important_Check is\n"
        source = CONTEXT_PACK.Source(
            Path("check.adb"), "check.adb", "".join(lines), "def",
        )
        chunks = CONTEXT_PACK.source_chunks(
            source, ("important_check",), chunk_lines=20, overlap=5,
        )
        self.assertEqual(len(chunks), 1)
        self.assertIn('lines="16-35"', chunks[0].text)
        self.assertIn("procedure Important_Check is\n", chunks[0].text)

    def test_short_query_words_do_not_match_inside_identifiers(self):
        self.assertEqual(
            CONTEXT_PACK.relevance("driver.adb", "first mirror", ("ir",)),
            0,
        )
        self.assertGreater(
            CONTEXT_PACK.relevance("landin-ir.adb", "IR unit", ("ir",)),
            0,
        )

    def test_estimator_and_missing_path(self):
        counter = CONTEXT_PACK.TokenCounter("estimate")
        self.assertEqual(counter.count("abcdef"), 2)
        with tempfile.TemporaryDirectory(prefix="landin-context-pack-") as tmp:
            missing = Path(tmp) / "missing"
            arguments = CONTEXT_PACK.parse_arguments([
                str(missing), "--query", "checking",
            ])
            with self.assertRaisesRegex(ValueError, "path does not exist"):
                CONTEXT_PACK.build_pack(arguments)

    def test_query_requires_a_searchable_word(self):
        with tempfile.TemporaryDirectory(prefix="landin-context-pack-") as tmp:
            arguments = CONTEXT_PACK.parse_arguments([
                tmp, "--query", "and the code",
                "--tokenizer", "estimate",
            ])
            with self.assertRaisesRegex(ValueError, "no searchable words"):
                CONTEXT_PACK.build_pack(arguments)

    def test_builds_a_budgeted_pack_outside_git(self):
        with tempfile.TemporaryDirectory(prefix="landin-context-pack-") as tmp:
            root = Path(tmp)
            (root / "AGENTS.md").write_text("Keep exact source.\n")
            (root / "example.ads").write_text(
                "package Example is\n"
                "   procedure Important_Check;\n"
                "end Example;\n"
            )
            (root / "example.adb").write_text(
                "package body Example is\n"
                "   procedure Important_Check is\n"
                "   begin\n"
                "      null;\n"
                "   end Important_Check;\n"
                "end Example;\n"
            )
            arguments = CONTEXT_PACK.parse_arguments([
                str(root), "--query", "important check",
                "--budget-tokens", "5000", "--tokenizer", "estimate",
                "--chunk-lines", "20",
            ])
            output, tokens, unused_name, blocks = CONTEXT_PACK.build_pack(arguments)
            self.assertLessEqual(tokens, 5000)
            self.assertIn('path="AGENTS.md"', output)
            self.assertIn('path="example.ads"', output)
            self.assertIn('<outline path="example.adb"', output)
            self.assertIn('path="example.adb" mode="exact"', output)
            self.assertTrue(blocks)


if __name__ == "__main__":
    unittest.main()
