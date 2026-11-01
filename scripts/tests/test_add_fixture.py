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
            add_fixture.corpus_row(meta("runtime/new"), "L0346", None)

    def test_a_namespace_refusal_needs_no_reason(self):
        #  The corpus reads the refused modules from the refusal itself.
        self.assertEqual(add_fixture.corpus_row(
            meta("runtime/new"), "L0015", None),
            {"codes": ["L0015"], "mode": "refuse"})

    def test_standard_input_cannot_execute_on_firmware(self):
        with self.assertRaises(SystemExit) as raised:
            add_fixture.corpus_row(meta("runtime/new", stdin="in.txt"),
                                   None, None)
        self.assertIn("status oracle", str(raised.exception))

    def test_the_row_is_the_refusal_refine_gave(self):
        #  A runtime fixture's row is what Cortex-M0 compilation does with
        #  it: refused by namespace, it is an L0015 row with no reason.
        self.assertEqual(add_fixture.corpus_row(
            meta("runtime/new", run_expect="out.txt"), None, None, ["L0015"]),
            {"codes": ["L0015"], "mode": "refuse"})
        with self.assertRaises(SystemExit) as raised:
            add_fixture.corpus_row(meta("runtime/new"), None, None,
                                   ["L0300", "L0344"])
        self.assertIn("L0300, L0344", str(raised.exception))
        self.assertEqual(add_fixture.corpus_row(
            meta("runtime/new"), None, None, []), {"mode": "execute"})

    def test_written_codes_are_the_set_the_corpus_compares(self):
        self.assertEqual(add_fixture.corpus_row(
            meta("runtime/new"), "L0344,L0344,L0300,L0344", "why",
            ["L0300", "L0344"]),
            {"codes": ["L0300", "L0344"], "mode": "refuse", "reason": "why"})
        with self.assertRaises(SystemExit) as raised:
            add_fixture.corpus_row(meta("runtime/new"), "L0015", None, [])
        self.assertIn("refuses it on Cortex-M0 with nothing",
                      str(raised.exception))

    def test_codes_are_read_from_refine(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "refine"
            new = meta("runtime/new", program="main.ldn")
            for said, status, expected in (
                    ("error[L0015]: x\nerror[L0015]: y\n", 1, ["L0015"]),
                    ("", 0, [])):
                fake.write_text("#!/bin/sh\nprintf '%s'\nexit %d\n" % (said, status))
                os.chmod(fake, 0o755)
                self.assertEqual(add_fixture.cortex_codes(new, directory, fake),
                                 expected)
            fake.write_text("#!/bin/sh\necho 'error[L0006]: module not found'\nexit 1\n")
            with self.assertRaises(SystemExit) as raised:
                add_fixture.cortex_codes(new, directory, fake)
            self.assertIn("--refine=PATH", str(raised.exception))

    def test_an_output_oracle_cannot_execute_on_firmware(self):
        with self.assertRaises(SystemExit) as raised:
            add_fixture.corpus_row(meta("runtime/new", run_expect="out.txt"),
                                   None, None)
        self.assertIn("run_expect:", str(raised.exception))
        self.assertIn("status oracle", str(raised.exception))

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
