#!/usr/bin/env python3
"""Check caches preserve offsets, refusals and changed inputs."""
import importlib.util
from pathlib import Path
import tempfile
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


class GrammarCorpusCache(unittest.TestCase):
    def test_reuses_only_matching_source_grammar_and_checker_bytes(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "spec.md").write_text("grammar one")
            (root / "check.py").write_text("checker one")
            case = root / "compiler/tests/fixtures/positive/sample"
            case.mkdir(parents=True)
            source = case / "program.ldn"
            source.write_text("good")
            calls = []

            def recognises(rules, trees, tokens):
                calls.append(tokens)
                return tokens == "good"

            with patch.object(CHECK, "ROOT", raw), \
                 patch.object(CHECK, "__file__", str(root / "check.py")), \
                 patch.object(CHECK, "read_grammar",
                              return_value=({}, {"program": ()}, [])), \
                 patch.object(CHECK, "grammar_signs", return_value=set()), \
                 patch.object(CHECK, "landin_tokens",
                              side_effect=lambda source, *_: (source, None)), \
                 patch.object(CHECK, "grammar_recognises",
                              side_effect=recognises), \
                 patch.object(CHECK, "frontend_codes", return_value=set()), \
                 patch.object(CHECK, "token_dump", return_value=None):
                def faults():
                    return [why for where, _, why
                            in CHECK.check_grammar_corpus(True)
                            if where.endswith("program.ldn")]

                self.assertEqual(faults(), [])
                self.assertEqual(faults(), [])
                self.assertEqual(calls, ["good"])

                meta = case / "fixture.meta"
                meta.write_text("lex: wanted complaint\n")
                self.assertTrue(any("scanner says" in why for why
                                    in faults()))
                self.assertEqual(len(calls), 1)
                meta.unlink()

                source.write_text("bad")
                self.assertTrue(faults())
                self.assertEqual(calls, ["good", "bad"])
                self.assertTrue(faults())
                self.assertEqual(len(calls), 2)

                source.write_text("good")
                self.assertEqual(faults(), [])
                (root / "spec.md").write_text("grammar two")
                self.assertEqual(faults(), [])
                (root / "check.py").write_text("checker two")
                self.assertEqual(faults(), [])
                self.assertEqual(len(calls), 5)

                (case / "other.ldn").write_text("bad")
                self.assertTrue(any("other.ldn" in where for where, _, _
                                    in CHECK.check_grammar_corpus(True)))
                self.assertEqual(len(calls), 6)
class FixtureMetadataCache(unittest.TestCase):
    def test_reuses_metadata_without_leaking_the_firmware_row(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            meta = root / "compiler/tests/fixtures/positive/example/fixture.meta"
            meta.parent.mkdir(parents=True)
            meta.write_text("targets: linux-x86-64\n", encoding="utf-8")
            driver = root / "compiler/tests/driver/fixture.json"
            driver.parent.mkdir(parents=True)
            driver.write_text('{"targets": "cortex-m"}', encoding="utf-8")
            with patch.object(CHECK, "ROOT", str(root)):
                records = CHECK.fixture_records()
                meta.write_text("targets: macos-arm64\n", encoding="utf-8")
                self.assertIs(CHECK.fixture_records(), records)
                self.assertEqual(records["positive/example"][1]["targets"],
                                 "linux-x86-64")
                augmented = CHECK.prototype_evidence_records()
                self.assertIn("firmware/derived-driver", augmented)
                self.assertNotIn("firmware/derived-driver", records)
            CHECK._fixture_records.cache_clear()

    def test_a_different_root_reads_its_own_metadata(self):
        with tempfile.TemporaryDirectory() as first, \
                tempfile.TemporaryDirectory() as second:
            for root, target in ((Path(first), "linux-x86-64"),
                                 (Path(second), "macos-arm64")):
                meta = root / "compiler/tests/fixtures/positive/example/fixture.meta"
                meta.parent.mkdir(parents=True)
                meta.write_text("targets: %s\n" % target, encoding="utf-8")
            with patch.object(CHECK, "ROOT", first):
                left = CHECK.fixture_records()
            with patch.object(CHECK, "ROOT", second):
                right = CHECK.fixture_records()
            self.assertEqual(left["positive/example"][1]["targets"],
                             "linux-x86-64")
            self.assertEqual(right["positive/example"][1]["targets"],
                             "macos-arm64")
            CHECK._fixture_records.cache_clear()


if __name__ == "__main__":
    unittest.main()
