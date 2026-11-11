"""scripts/add_fixture.py starts a new fixture's Cortex-M row as the
corpus's rules say, lays out its sources, refuses what only a person can
decide, and names every step left for its class."""

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

    def test_an_abi_fixture_executes_where_it_names_cortex_m0(self):
        #  The corpus builds its C peers freestanding and runs it (D985).
        self.assertEqual(add_fixture.corpus_row(
            meta("abi/new", targets="cortex-m0"), None, None, []),
            {"mode": "execute"})
        self.assertEqual(add_fixture.corpus_row(
            meta("abi/new", targets="linux-x86-64"), None, None, ["L0015"]),
            {"codes": ["L0015"], "mode": "refuse"})
        with self.assertRaises(SystemExit) as raised:
            add_fixture.corpus_row(meta("abi/new", targets="linux-x86-64"),
                                   None, None, [])
        self.assertIn("--stops=", str(raised.exception))

    def test_a_frame_past_the_reference_stack_is_a_recorded_limit(self):
        #  Cortex-M0 compiles it without an entry, and under one L0507
        #  refuses it, which no refuse row can hold: the lanes compile a
        #  refusal without an entry.
        hosted = meta("runtime/new", targets="linux-x86-64")
        self.assertEqual(add_fixture.corpus_row(
            hosted, None, "a 16 MiB frame", [], None, 16777272, 4096),
            {"mode": "execute", "profile_limit": "selected-image",
             "reason": "a 16 MiB frame"})
        self.assertEqual(add_fixture.corpus_row(
            hosted, None, None, [], None, 4096, 4096), {"mode": "execute"})
        with self.assertRaises(SystemExit) as raised:
            add_fixture.corpus_row(hosted, None, None, [], None, 4100, 4096)
        self.assertIn("4100 bytes of stack", str(raised.exception))
        self.assertIn("--reason=TEXT", str(raised.exception))
        self.assertNotIn("drop cortex-m0", str(raised.exception))
        with self.assertRaises(SystemExit) as raised:
            add_fixture.corpus_row(meta("runtime/new", targets="cortex-m0"),
                                   None, "large", [], None, 4100, 4096)
        self.assertIn("drop cortex-m0 from its targets:",
                      str(raised.exception))

    def test_the_stack_is_read_from_the_build_report(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "refine"
            new = meta("runtime/new", program="main.ldn")
            fake.write_text(
                "#!/bin/sh\nfor a in \"$@\"; do case $a in"
                " --build-report=*) printf '%s'"
                " '{\"build\":{\"routines\":[{\"stack_bytes\":24},"
                "{\"stack_bytes\":4104}]}}' > \"${a#--build-report=}\";;"
                " esac; done\n")
            os.chmod(fake, 0o755)
            self.assertEqual(add_fixture.cortex_stack(new, directory, fake),
                             4104)
            fake.write_text("#!/bin/sh\necho broken\nexit 70\n")
            with self.assertRaises(SystemExit) as raised:
                add_fixture.cortex_stack(new, directory, fake)
            self.assertIn("ended with 70", str(raised.exception))
        self.assertEqual(add_fixture.reference_stack(), 4096)

    def test_a_restriction_names_what_stops_it_and_why(self):
        #  D986: the corpus holds the fixture's build to its stop.
        self.assertEqual(add_fixture.corpus_row(
            meta("abi/new"), None, "it prints", [], "c-headers"),
            {"mode": "restriction", "reason": "it prints", "stops": "c-headers"})
        for stops, reason in (("c-headers", None), ("threads", "it starts threads")):
            with self.assertRaises(SystemExit) as raised:
                add_fixture.corpus_row(meta("abi/new"), None, reason, [], stops)
            self.assertIn("c-options, c-headers", str(raised.exception))

    def test_each_class_is_told_every_step_left(self):
        #  A positive fixture is in lowering.ir, which only the test
        #  program records, and in the lexer's, parser's and formatter's
        #  corpus cases; the integration pass parses its source.
        positive = add_fixture.remaining_steps(
            meta("positive/new", program="program.ldn"), False)
        self.assertEqual(positive, [
            "./scripts/dev-test.sh --record=lowering",
            "./scripts/dev-test.sh --fixture=positive/new"
            " --case='lexer/agrees with the corpus'"
            " --case='parser/agrees with the corpus'"
            " --case='lowering/the recorded corpus is current'"
            " --case='formatting/the corpus is formatted'",
            "./highlight/test.sh --integration, inside nix develop",
            "python3 check.py"])
        #  A negative fixture's report is recorded until it is written, and
        #  its layout is its evidence, so neither formatter nor editor
        #  grammar is held to it.
        negative = meta("negative/new", program="program.ldn",
                        expect="expected.txt", args="program.ldn")
        self.assertEqual(add_fixture.remaining_steps(negative, False), [
            "./scripts/dev-test.sh --record=negative/new",
            "./scripts/dev-test.sh --fixture=negative/new"
            " --case='lexer/agrees with the corpus'"
            " --case='parser/agrees with the corpus'",
            "python3 check.py"])
        self.assertNotIn("--record", " ".join(
            add_fixture.remaining_steps(negative, True)))
        #  A runtime fixture is formatted and parsed by the editor grammar,
        #  and recorded nowhere.
        runtime = add_fixture.remaining_steps(
            meta("runtime/new", program="main.ldn"), False,
            "compiler/tests/fixtures/runtime/new")
        self.assertTrue(runtime[0].startswith(
            "refine fmt compiler/tests/fixtures/runtime/new"))
        self.assertEqual(runtime[1:], [
            "./scripts/dev-test.sh --fixture=runtime/new"
            " --case='formatting/the corpus is formatted'",
            "./highlight/test.sh --integration, inside nix develop",
            "python3 check.py"])
        #  A unit fixture with no report has no lane of its own.
        self.assertEqual(add_fixture.remaining_steps(meta("unit/new"), False),
                         ["python3 check.py"])

    def test_the_layout_is_held_where_the_corpus_case_holds_it(self):
        self.assertTrue(add_fixture.held_to_layout(
            meta("positive/new", constructs="0010")))
        self.assertTrue(add_fixture.held_to_layout(meta("abi/new")))
        self.assertFalse(add_fixture.held_to_layout(meta("negative/new")))
        self.assertFalse(add_fixture.held_to_layout(
            meta("runtime/new", constructs="0010, 1750")))
        #  The exemption is the fixture's own `layout: evidence`, which
        #  the corpus case reads from the same metadata and no list here
        #  or there mirrors.
        self.assertFalse(add_fixture.held_to_layout(
            meta("positive/new", constructs="0010", layout="evidence")))
        source = (ROOT / "compiler/ada/tests/src/"
                  "landin-tests-formatting_suite.adb").read_text()
        case = source[source.index("procedure The_Corpus_Is_Formatted"):]
        case = case[:case.index("end The_Corpus_Is_Formatted")]
        self.assertIn("Fixtures.Layout_Evidence (Fixture)", case)
        self.assertNotIn(" in \"", case)
        declared = [one.label for one in fixture_meta.discover(
            ("positive", "runtime", "abi")) if one.get("layout")]
        self.assertEqual(declared, [
            "positive/value-continued-at-any-indentation",
            "runtime/r490-lexical-module-observation"])

    def test_sources_are_laid_out_and_named(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "main.ldn").write_text("fn main()\n")
            (base / "kept.ldn").write_text("kept\n")
            fake = base / "refine"
            #  A refine fmt that lays out main.ldn and leaves kept.ldn.
            fake.write_text("#!/bin/sh\nprintf 'laid out\\n' > \"$2/main.ldn\"\n")
            os.chmod(fake, 0o755)
            changed = add_fixture.format_sources(
                meta("runtime/new"), base, fake)
            self.assertEqual(changed, [base / "main.ldn"])
            fake.write_text("#!/bin/sh\necho 'error[L0010]: no' >&2\nexit 1\n")
            with self.assertRaises(SystemExit) as raised:
                add_fixture.format_sources(meta("runtime/new"), base, fake)
            self.assertIn("L0010", str(raised.exception))

    def test_a_missing_fixture_says_to_write_it(self):
        with self.assertRaises(SystemExit) as raised:
            add_fixture.main(["runtime/no-such-fixture-here"])
        self.assertIn("write the fixture first", str(raised.exception))

    def test_several_fixtures_share_one_recording_and_one_test_run(self):
        #  Several fixtures' steps join, the recordings in one run
        #  of the test program, the cases in another, every other step once.
        first = add_fixture.remaining_steps(meta("positive/new"), False)
        second = add_fixture.remaining_steps(meta("runtime/other"), True)
        steps = add_fixture.combined_steps([first, second])
        tests = [step for step in steps if step.startswith("./scripts/dev-test.sh")]
        self.assertEqual(len(tests), 2)
        self.assertIn("--record=lowering", tests[0])
        self.assertIn("--fixture=positive/new", tests[1])
        self.assertIn("--fixture=runtime/other", tests[1])
        self.assertEqual(tests[1].count("--case='formatting/the corpus is formatted'"), 1)
        self.assertEqual(steps.count("python3 check.py"), 1)
        self.assertEqual(steps[-1], "python3 check.py")

    def test_a_borrowed_program_has_nothing_to_lay_out(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "fixture.meta").write_text("program: ../other/main.ldn\n")
            fake = base / "refine"
            #  refine fmt refuses a directory with no source, L0002.
            fake.write_text("#!/bin/sh\necho 'error[L0002]: fmt found no"
                            " .ldn source' >&2\nexit 1\n")
            os.chmod(fake, 0o755)
            self.assertEqual(add_fixture.own_sources(base), [])
            self.assertEqual(add_fixture.format_sources(
                meta("runtime/borrows"), base, fake), [])

    def run_main(self, arguments, fixtures):
        """main over a scratch tree holding FIXTURES, label to metadata
        text: what it returned or raised, its output and the corpus."""
        import contextlib
        import io
        import json
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for label, text in fixtures.items():
                home = root / "compiler/tests/fixtures" / label
                home.mkdir(parents=True)
                (home / "fixture.meta").write_text(text)
                if "program: main.ldn" in text:
                    (home / "main.ldn").write_text("fn main()\n")
            corpus = root / "corpus.json"
            corpus.write_text(json.dumps({"fixtures": {}}))
            parity = root / "parity.json"
            parity.write_text(json.dumps({"differences": {}}))
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(add_fixture, "ROOT", root), \
                    mock.patch.object(add_fixture, "CORPUS", corpus), \
                    mock.patch.object(add_fixture, "ARM64_PARITY", parity), \
                    mock.patch.object(add_fixture, "GENERATED", ()), \
                    mock.patch.object(add_fixture, "cortex_codes",
                                      lambda *a: []), \
                    mock.patch.object(add_fixture, "cortex_stack",
                                      lambda *a: self.deepest), \
                    mock.patch.object(add_fixture, "format_sources",
                                      lambda *a: []), \
                    contextlib.redirect_stdout(out), \
                    contextlib.redirect_stderr(err):
                try:
                    status = add_fixture.main(
                        [*arguments, "--refine=/no/refine"])
                except SystemExit as refusal:
                    status = refusal
            return (status, out.getvalue(), err.getvalue(),
                    json.loads(corpus.read_text())["fixtures"])

    #  What run_main's refine measures as the fixture's deepest routine.
    deepest = 0

    def test_a_recorded_limit_is_said_and_is_no_unmeasured_execution(self):
        hosted = self.RUNTIME.replace(", cortex-m0", "")
        self.deepest = 16777272
        try:
            status, out, _, rows = self.run_main(
                ["runtime/first", "--reason=a 16 MiB frame"],
                {"runtime/first": hosted})
            self.assertEqual((status, rows), (0, {"runtime/first": {
                "mode": "execute", "profile_limit": "selected-image",
                "reason": "a 16 MiB frame"}}))
            self.assertIn("runtime/first: a routine takes 16777272 bytes of"
                          " stack, past the 4096", out)
            self.assertNotIn("not measured", out)
            status, _, _, rows = self.run_main(
                ["runtime/first"], {"runtime/first": hosted})
            self.assertNotEqual(status, 0)
            self.assertEqual(rows, {})
        finally:
            self.deepest = 0

    RUNTIME = ("class: runtime\nprofiles: standard\nsummary: s\n"
               "targets: linux-x86-64, linux-arm64, cortex-m0\n"
               "program: main.ldn\nstatus: 0\nconstructs: 0570\n")

    def test_arm64_not_emitting_yet_stands_for_a_parity_record(self):
        """D1308: a fixture arm64 does not emit yet says so instead of a
        record naming a counterpart that does not exist."""
        alone = self.RUNTIME.replace(", linux-arm64, cortex-m0", "")
        status, out, _, _ = self.run_main(["runtime/first"],
                                          {"runtime/first": alone})
        self.assertEqual(status, 1)
        self.assertIn("left to do: runtime/first: name linux-arm64 in its"
                      " targets; or, while arm64 does not emit", out)
        self.assertIn("not_yet_emitted: linux-arm64=CODE", out)
        status, out, _, _ = self.run_main(
            ["runtime/first"],
            {"runtime/first": alone + "not_yet_emitted: linux-arm64=L0500\n"})
        self.assertEqual(status, 0)
        self.assertNotIn("left to do", out)

    def test_a_batch_continues_past_one_refusal(self):
        status, out, err, rows = self.run_main(
            ["runtime/first", "runtime/broken", "runtime/absent",
             "runtime/last"],
            {"runtime/first": self.RUNTIME, "runtime/last": self.RUNTIME,
             "runtime/broken": "class: runtime\n"})
        self.assertEqual(status, 1)
        self.assertEqual(sorted(rows), ["runtime/first", "runtime/last"])
        self.assertIn("refused runtime/broken: ", err)
        self.assertIn("refused runtime/absent: ", err)
        self.assertIn("write the fixture first", err)
        self.assertIn("not added, each refused above: runtime/broken"
                      " runtime/absent", err)
        self.assertIn("--fixture=runtime/first", out)
        self.assertIn("--fixture=runtime/last", out)
        self.assertIn("not measured: runtime/first, runtime/last are", out)

    def test_an_execute_row_says_it_was_not_measured(self):
        status, out, _, rows = self.run_main(
            ["runtime/first"], {"runtime/first": self.RUNTIME})
        self.assertEqual((status, rows), (0, {"runtime/first":
                                              {"mode": "execute"}}))
        last = out.strip().splitlines()[-1]
        self.assertTrue(last.startswith(
            "not measured: runtime/first is `execute` because Cortex-M0"
            " compiles it; nothing here linked an image or measured it"
            " against the map"), last)
        self.assertIn("backend_corpus.py --refine=PATH --output=DIR"
                      " --case=runtime/first", last)
        #  A row that was already there, or is no execute row, says nothing.
        status, out, _, _ = self.run_main(
            ["negative/plain"],
            {"negative/plain": "class: negative\nsummary: s\n"
                               "targets: linux-x86-64\nprogram: main.ldn\n"
                               "status: 1\ncodes: L0202\n"
                               "constructs: 0570\n"})
        self.assertNotIn("not measured", out)

    def test_expect_without_args_names_the_line_to_write(self):
        status, _, err, _ = self.run_main(
            ["negative/recorded"],
            {"negative/recorded":
             "class: negative\nsummary: s\ntargets: linux-x86-64\n"
             "program: main.ldn\nexpect: expected.txt\nstatus: 1\n"
             "codes: L0202\nconstructs: 0570\n"})
        said = str(status)
        self.assertIn("expect without args: nothing would produce it", said)
        self.assertIn("\n    args: ../tests/fixtures/negative/recorded/"
                      "main.ldn\n", said)
        self.assertIn("from compiler/ada", said)

    def test_one_row_options_take_one_fixture(self):
        with self.assertRaises(SystemExit) as raised:
            add_fixture.main(["runtime/a", "runtime/b", "--stops=link",
                              "--reason=why"])
        self.assertIn("in a run of its own", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
