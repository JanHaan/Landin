"""scripts/add_fixture.py starts a new fixture's Cortex-M row as the
corpus's rules say, and refuses what only a person can decide."""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "compiler/tests"))

import add_fixture  # noqa: E402
import fixture_meta  # noqa: E402


def meta(label, **keys):
    return fixture_meta.Metadata.of(keys, label)


class AddFixtureTest(unittest.TestCase):
    def test_a_runtime_fixture_starts_executing(self):
        self.assertEqual(add_fixture.corpus_row(
            meta("runtime/new"), None, None), {"mode": "execute"})

    def test_a_refusal_names_its_codes_and_reason(self):
        self.assertEqual(add_fixture.corpus_row(
            meta("runtime/new"), "L0015, L0201", "hosted only"),
            {"codes": ["L0015", "L0201"], "mode": "refuse",
             "reason": "hosted only"})
        with self.assertRaises(SystemExit):
            add_fixture.corpus_row(meta("runtime/new"), "L0015", None)

    def test_standard_input_cannot_execute_on_firmware(self):
        with self.assertRaises(SystemExit) as raised:
            add_fixture.corpus_row(meta("runtime/new", stdin="in.txt"),
                                   None, None)
        self.assertIn("--refuse=CODES", str(raised.exception))

    def test_an_abi_fixture_is_a_restriction_with_its_reason(self):
        self.assertEqual(add_fixture.corpus_row(
            meta("abi/new"), None, "a hosted C peer"),
            {"mode": "restriction", "reason": "a hosted C peer",
             "witness": "compiler/tests/fixtures/abi/new/fixture.meta"})
        with self.assertRaises(SystemExit):
            add_fixture.corpus_row(meta("abi/new"), None, None)

    def test_a_missing_fixture_says_to_write_it(self):
        with self.assertRaises(SystemExit) as raised:
            add_fixture.main(["runtime/no-such-fixture-here"])
        self.assertIn("write the fixture first", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
