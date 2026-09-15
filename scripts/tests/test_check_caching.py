#!/usr/bin/env python3
"""Lexical reuse must preserve offsets, refusals and grammar edits."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("landin_check", ROOT / "check.py")
CHECK = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CHECK)


class LexicalCache(unittest.TestCase):
    def grammar(self):
        return {"keyword": ("lit", "if"), "identifier": ("lit", "name"),
                "space": ("lit", " "),
                "line_end": ("alt", [("lit", "\r"), ("lit", "\n")])}

    def test_repetition_retains_byte_offsets(self):
        self.assertEqual(CHECK.landin_tokens("name name\r\nif", set(), self.grammar()),
                         ([("word", "name", 0), ("word", "name", 5),
                           ("word", "if", 11)], None))

    def test_grammar_edit_invalidates_success_and_refusal(self):
        trees = self.grammar()
        self.assertIsNotNone(CHECK.landin_tokens("name name", set(), trees)[0])
        trees["identifier"] = ("lit", "other")
        self.assertIsNone(CHECK.landin_tokens("name name", set(), trees)[0])
        trees["identifier"] = ("lit", "name")
        self.assertIsNotNone(CHECK.landin_tokens("name name", set(), trees)[0])
        trees["space"] = ("lit", "\t")
        self.assertIn("whitespace byte", CHECK.landin_tokens("name name", set(), trees)[1])

    def test_cached_and_uncached_results_agree(self):
        _, trees, problems = CHECK.read_grammar(str(ROOT / "spec.md"))
        self.assertEqual(problems, [])
        signs = CHECK.grammar_signs(trees)
        examples = ["n: u32 = 1\r\nn: u32 = 1\r\n", "x: i32 = 1__0\n",
                    "_ _ if if", "--( nested --( comment )-- )--\n",
                    "s = \"\\q\"", "s = '\\u{110000}'", "name @ name",
                    "s = '\xc3\xa9'\n", "\"\"\"raw\n text\n\"\"\""]
        for text in examples:
            with self.subTest(text=text):
                cached = CHECK.landin_tokens(text, signs, trees)
                with patch.object(CHECK, "lru_cache", side_effect=lambda **kw: lambda f: f):
                    uncached = CHECK.landin_tokens(text, signs, trees)
                self.assertEqual(cached, uncached)


if __name__ == "__main__":
    unittest.main()
