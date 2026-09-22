#!/usr/bin/env python3
"""Controls for check.py's checks: each one is shown to fire.

Written after measuring that 34 of 37 checks had never been made to fail.
A check nobody has seen fail is a claim, not a check, and this repository
has already paid for that once: renaming tour.md made four of them vacuous
while the run still said `all clean`.

Each control states the property in its name, shows the check silent on a
tree that satisfies it, and shows it speaking on one that does not.  Where
a check reads content-addressed inputs the real files are copied and then
broken in one place, because a recorded sha256 cannot be invented.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_controls import checker, faults, reasons   # noqa: E402

ORACLES = list(checker.BENCHMARK_GAME_ORACLES)


class BenchmarkGameOracles(unittest.TestCase):
    """The three correctness outputs stay byte-for-byte canonical."""

    def test_the_recorded_outputs_pass(self):
        self.assertEqual(
            faults(checker.check_benchmark_game_oracles, copied=ORACLES), [])

    def test_a_changed_byte_is_reported(self):
        def corrupt(root):
            target = root / ORACLES[0]
            target.write_bytes(target.read_bytes() + b"\n")
        with self.subTest(oracle=ORACLES[0]):
            from check_controls import tree
            with tree(copied=ORACLES) as root:
                corrupt(root)
                said = [why for _, _, why
                        in checker.check_benchmark_game_oracles(True)]
            self.assertTrue(said)
            self.assertIn("correctness oracle changed", said[0])

    def test_a_missing_oracle_is_reported_rather_than_skipped(self):
        #  The worst answer to "the file is not there" is silence: that is
        #  what absent() was written for.
        said = reasons(checker.check_benchmark_game_oracles,
                       copied=ORACLES[1:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])


class DocumentReachability(unittest.TestCase):
    """Every tracked document is reachable from README.md."""

    def test_a_linked_document_passes(self):
        self.assertEqual(
            faults(checker.check_document_reachability,
                   written={"README.md": "see [g](docs/g.md)\n",
                            "docs/g.md": "# G\n"}), [])

    def test_an_unlinked_document_is_reported(self):
        said = reasons(checker.check_document_reachability,
                       written={"README.md": "# Root\n",
                                "docs/orphan.md": "# Orphan\n"})
        self.assertEqual(len(said), 1)
        self.assertIn("nothing leads to it", said[0])


class NamedFiles(unittest.TestCase):
    """A document that names a repository file names one that exists."""

    def test_a_name_that_resolves_passes(self):
        self.assertEqual(
            faults(checker.check_named_files,
                   written={"README.md": "see `docs/guide.md`\n",
                            "docs/guide.md": "# Guide\n"}), [])

    def test_a_name_that_does_not_resolve_is_reported(self):
        said = reasons(checker.check_named_files,
                       written={"README.md": "see `docs/absent.md`\n"})
        self.assertTrue(any("not in the repository" in why for why in said))

    def test_the_two_directions_are_independent(self):
        #  check_named_files and check_document_reachability are opposite
        #  directions of the same edge, and neither implies the other.
        #  This tree satisfies naming and violates reachability, which is
        #  how six documents passed a clean run.
        written = {"README.md": "# Root\n", "docs/orphan.md": "# Orphan\n"}
        self.assertEqual(faults(checker.check_named_files, written=written), [])
        self.assertTrue(reasons(checker.check_document_reachability,
                                written=written))


PINS = ["environments/linux-amd64/Containerfile",
        "compiler/ada/TOOLCHAIN.md",
        "environments/pins.sh"]


class PinnedToolchain(unittest.TestCase):
    """Every file that installs or records the toolchain names the same one."""

    def test_the_real_pins_agree(self):
        self.assertEqual(
            faults(checker.check_pinned_toolchain, copied=PINS), [])

    def test_a_recipe_that_names_another_version_is_reported(self):
        from check_controls import tree
        with tree(copied=PINS) as root:
            recipe = root / PINS[0]
            recipe.write_text(
                recipe.read_text().replace("16.1.0", "16.2.0"))
            said = [why for _, _, why in checker.check_pinned_toolchain(True)]
        self.assertTrue(said)

    def test_a_missing_recipe_is_reported_rather_than_skipped(self):
        #  This check used to `return []` when the recipe or the record was
        #  absent, so renaming either made it vacuous while the run still
        #  said all clean -- the exact fault absent() exists to prevent.
        #  Found by writing this control, which is the point of writing it.
        said = reasons(checker.check_pinned_toolchain, copied=PINS[1:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_missing_record_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_pinned_toolchain,
                       copied=[PINS[0], PINS[2]])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])


class SourceLocations(unittest.TestCase):
    """The offline decoder requires build matching and preserves path bytes."""

    def test_the_real_decoder_passes(self):
        self.assertEqual(
            faults(checker.check_source_locations,
                   copied=["scripts/source-location.py"]), [])

    def test_a_missing_decoder_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_source_locations,
                       written={"README.md": "# Root\n"})
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_decoder_that_stops_checking_is_reported(self):
        #  The check drives the real script with a mismatched build id and
        #  a path holding a quote and a non-UTF-8 byte. A decoder that
        #  accepted anything would pass a check that only ran it.
        from check_controls import tree
        with tree(copied=["scripts/source-location.py"]) as root:
            script = root / "scripts/source-location.py"
            script.write_text("#!/usr/bin/env python3\nimport sys\n"
                              "sys.exit(0)\n")
            said = [why for _, _, why in checker.check_source_locations(True)]
        self.assertTrue(said)


class Citations(unittest.TestCase):
    """Every construct citation resolves, and no id is defined twice."""

    def cited(self, tour, spec="# Spec\n"):
        from check_controls import tree
        with tree(written={"tour.md": tour, "spec.md": spec}) as root:
            return [why for _, _, why in checker.check_citations(
                [str(root / "tour.md"), str(root / "spec.md")])]

    def test_a_citation_with_a_definition_passes(self):
        self.assertEqual(
            self.cited("### [0010] A thing\n\nas [0010] says\n"), [])

    def test_a_citation_without_a_definition_is_reported(self):
        self.assertTrue(self.cited("### [0010] A thing\n\nas [0020] says\n"))

    def test_a_definition_in_both_documents_is_reported(self):
        #  A construct is defined in exactly one of the two. Merging the
        #  dictionaries is what makes this catch an id defined in both,
        #  which is the invariant the spec/tour split newly needed.
        self.assertTrue(
            self.cited("### [0010] A thing\n", spec="### [0010] Again\n"))

    def test_citing_nothing_passes(self):
        self.assertEqual(self.cited("# Tour\n\nprose only\n"), [])


#  check_optimization_contract has no control yet, deliberately.  Its
#  docstring claims the quality wiring and the object reader, and it also
#  calls check_phase_handoff -- a roadmap-structure check -- and enforces a
#  tour prose rule about array comparison and reduction.  Three subjects in
#  one function cannot be controlled as one property, and the roadmap half
#  is destined for deletion while the other two are not.  Splitting it is
#  audit work; MOVING.md records it.


DEBUGGER = ["scripts/debug.sh", "compiler/tests/debugging"]

HOSTED = ["compiler/tests/fixtures/runtime/derived-hosted-memory/DERIVATION.md",
          "core/region/region.ldn", "examples/derived_hosted",
          #  The manifest names fixtures, and the check holds those to
          #  existing too: the mapping may not cite evidence that is gone.
          "compiler/tests/fixtures/runtime",
          "compiler/tests/fixtures/negative",
          #  And the roadmap, because the mapping is held to accounting
          #  for prototype 4's W1-W7 findings.
          "ROADMAP.md"]


class DebuggerContract(unittest.TestCase):
    """Every derived workload runs on both compiler modes, without GDB."""

    def test_the_real_schedule_passes(self):
        self.assertEqual(
            faults(checker.check_debugger_contract, copied=DEBUGGER), [])

    def test_a_missing_input_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_debugger_contract, copied=DEBUGGER[:1])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_dropped_profile_is_reported(self):
        #  Nine workloads: parser, containers and hosted, each at none/off,
        #  size/auto and size/all. Losing one is coverage lost quietly,
        #  which is why this is checked without invoking GDB at all.
        from check_controls import tree
        with tree(copied=DEBUGGER) as root:
            target = root / "compiler/tests/debugging/check.py"
            target.write_text(target.read_text().replace(
                '"size-all", "size", "all"', '"size-all", "size", "auto"', 1))
            said = [why for _, _, why in checker.check_debugger_contract(True)]
        self.assertTrue(said)

    def test_a_schedule_that_cannot_be_driven_is_reported(self):
        from check_controls import tree
        with tree(copied=DEBUGGER) as root:
            (root / "compiler/tests/debugging/check.py").write_text(
                "# nothing to measure\n")
            said = [why for _, _, why in checker.check_debugger_contract(True)]
        self.assertTrue(said)
        self.assertIn("workload schedule", said[0])


class HostedDerivation(unittest.TestCase):
    """The complete P4 source inventory stays traceable to its manifest."""

    def test_the_real_manifest_passes(self):
        self.assertEqual(
            faults(checker.check_hosted_derivation, copied=HOSTED), [])

    def test_a_missing_manifest_is_reported_rather_than_skipped(self):
        #  Deleted rather than not copied: the manifest lives inside the
        #  runtime fixture tree, so leaving it out of the copy list puts
        #  it back. The first version of this control did exactly that and
        #  tested nothing.
        from check_controls import tree
        with tree(copied=HOSTED) as root:
            (root / HOSTED[0]).unlink()
            said = [why for _, _, why in checker.check_hosted_derivation(True)]
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_source_the_manifest_omits_is_reported(self):
        #  A source added without updating the mapping must not vanish
        #  from it silently; this checks names, never behaviour.
        from check_controls import tree
        with tree(copied=HOSTED) as root:
            new = root / "examples/derived_hosted/invented.ldn"
            new.write_text("invented: () -> none =\nend invented\n")
            said = [why for _, _, why in checker.check_hosted_derivation(True)]
        self.assertTrue(any("omits source" in why for why in said))


class CodeRules(unittest.TestCase):
    """The six cheap rules over Landin shown in the documents.

    These cannot be replaced by running refine over the blocks, which was
    the plan until it was measured: of 259 fenced blocks, about two in
    five cannot compile by design.  They name things the surrounding prose
    declared, or carry the `...` omission marker, because the documents
    teach by showing a piece of a program.  A heuristic is the only thing
    that can say anything about a fragment, so these rules stay and are
    controlled instead.
    """

    def said(self, code):
        return [why for _, why in checker.check_code(code.splitlines(), 0)]

    def test_ordinary_code_passes(self):
        self.assertEqual(self.said("value: u32 = 7\n"), [])

    def test_a_keyword_where_a_name_belongs_is_reported(self):
        said = self.said("match: u32 = 7\n")
        self.assertTrue(any("keyword" in why for why in said))

    def test_when_outside_an_exit_statement_is_reported(self):
        said = self.said("    total = total + 1 when ready\n")
        self.assertTrue(said)

    def test_when_on_an_exit_statement_passes(self):
        self.assertEqual(self.said("    break when ready\n"), [])

    def test_one_name_declared_twice_in_a_module_is_reported(self):
        said = self.said("value: u32 = 1\nvalue: u32 = 2\n")
        self.assertTrue(any("twice" in why or "declared" in why
                            for why in said))

    def test_an_end_with_no_opener_is_reported(self):
        said = self.said("end invented\n")
        self.assertTrue(said)

    def test_a_fragment_that_cannot_compile_still_passes_these(self):
        #  The case for keeping them: refine refuses this with L0201
        #  because `first` is declared in the prose around it, and the
        #  cheap rules still have something to say about the line.
        self.assertEqual(self.said("mut cursor: ptr u32 = addr first\n"), [])


GRAMMAR = ["spec.md", "compiler/tests/fixtures",
           "compiler/tests/lexical.tokens",
           "compiler/ada/src/syntax", "compiler/ada/src/diagnostics"]


class GrammarCorpus(unittest.TestCase):
    """The specification's grammar derives every positive fixture.

    This is a SECOND implementation on purpose, and the reason it cannot
    be replaced by running refine: the Ada parser meets the same corpus
    from the other side, and a disagreement between the two locates a
    defect in one of them.  Deriving with the compiler instead would
    collapse two witnesses into one and check the parser against itself.
    """

    def test_the_real_grammar_and_corpus_agree(self):
        self.assertEqual(
            faults(checker.check_grammar_corpus, copied=GRAMMAR), [])

    def test_a_missing_specification_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_grammar_corpus, copied=GRAMMAR[1:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_positive_fixture_the_grammar_cannot_derive_is_reported(self):
        from check_controls import tree
        with tree(copied=GRAMMAR) as root:
            invented = root / "compiler/tests/fixtures/positive/invented-shape"
            invented.mkdir(parents=True)
            (invented / "program.ldn").write_text(
                "%%% this is not Landin %%%\n")
            (invented / "fixture.meta").write_text(
                "class: positive\nsummary: invented\nprogram: program.ldn\n")
            said = [why for _, _, why in checker.check_grammar_corpus(True)]
        self.assertTrue(said)

    def test_a_grammar_rule_nothing_reaches_is_reported(self):
        #  Every rule must be defined and reachable: an unreachable
        #  production is grammar nobody can be held to.
        from check_controls import tree
        with tree(copied=GRAMMAR) as root:
            spec = root / "spec.md"
            spec.write_text(spec.read_text().replace(
                "```landin-grammar\nprogram",
                "```landin-grammar\nstranded    ::= \"unreachable\"\nprogram",
                1))
            said = [why for _, _, why in checker.check_grammar_corpus(True)]
        self.assertTrue(said)


TOKENS = ["spec.md", "tour.md",
          "compiler/ada/src/syntax/landin-tokens.ads",
          "compiler/ada/src/syntax/landin-tokens.adb"]


class TokenVocabulary(unittest.TestCase):
    """The scanner's reserved words are the grammar's own.

    This is a transcription held to its source, not a duplicate waiting to
    be generated away.  ROADMAP.md's D3 keeps generated tables out of the
    repository and E3 counts the cases: a third kind of generated source
    triggers a D3 review, which a successor roadmap owns.  So the rule is
    "write it twice and compare", deliberately, and this control is what
    makes the comparison trustworthy.
    """

    def test_the_real_vocabulary_agrees(self):
        self.assertEqual(
            faults(checker.check_token_vocabulary, copied=TOKENS), [])

    def test_a_missing_scanner_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_token_vocabulary, copied=TOKENS[:1])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_word_the_scanner_reserves_and_the_grammar_does_not(self):
        from check_controls import tree
        with tree(copied=TOKENS) as root:
            spec = root / TOKENS[2]
            spec.write_text(spec.read_text().replace(
                "Kw_Match", "Kw_Invented", 1))
            said = [why for _, _, why
                    in checker.check_token_vocabulary(True)]
        self.assertTrue(any("differ from the grammar" in why
                            for why in said))

    def test_a_word_the_grammar_reserves_and_the_scanner_does_not(self):
        #  The other direction, which is the one a language change causes:
        #  a keyword added to the grammar and not to the scanner.
        from check_controls import tree
        with tree(copied=TOKENS) as root:
            spec = root / "spec.md"
            text = spec.read_text()
            spec.write_text(text.replace('"match"', '"match" | "invented"', 1))
            said = [why for _, _, why
                    in checker.check_token_vocabulary(True)]
        self.assertTrue(any("differ from the grammar" in why
                            for why in said))


#  Every live document, read from check.py so this list cannot drift from
#  the one the checks actually walk.
LIVE = list(checker.LIVE_DOCS)


class DocumentForm(unittest.TestCase):
    """The four rules that hold the documents' form.

    Each exists because a conversion destroyed something no word count
    could see: prose that lost an em dash, Landin that fell out of its
    fence, a table row that grew a cell and broke an inline span, and the
    comment markers that ARE the demonstration in [0010] and [0020].
    """

    def broken(self, check, document, replace, with_):
        from check_controls import tree
        with tree(copied=LIVE) as root:
            target = root / document
            text = target.read_text()
            self.assertIn(replace, text, "the control's own anchor is gone")
            target.write_text(text.replace(replace, with_))
            return [why for _, _, why in check(True)]

    def test_the_real_documents_pass(self):
        for check in (checker.check_ascii_dashes, checker.check_unfenced_code,
                      checker.check_table_shape, checker.check_comment_forms):
            with self.subTest(check=check.__name__):
                self.assertEqual(faults(check, copied=LIVE), [])

    def test_a_spaced_ascii_dash_in_prose_is_reported(self):
        self.assertTrue(self.broken(
            checker.check_ascii_dashes, "README.md",
            "## Checking", "## Checking -- and why\n"))

    def test_landin_outside_a_fence_is_reported(self):
        self.assertTrue(self.broken(
            checker.check_unfenced_code, "tour.md",
            "## WHAT WAS TRIED AND DROPPED",
            "stray: u32 = 7\n\n## WHAT WAS TRIED AND DROPPED"))

    def test_a_table_row_with_an_extra_cell_is_reported(self):
        self.assertTrue(self.broken(
            checker.check_table_shape, "README.md",
            "## Checking",
            "| a | b |\n|---|---|\n| one | two | three |\n\n## Checking"))

    def test_a_comment_opener_the_tour_stops_showing_is_reported(self):
        #  The markers are the demonstration: [0010]'s marker IS a line
        #  comment. A conversion that read them as markup destroyed the
        #  section with every word intact.
        self.assertTrue(self.broken(
            checker.check_comment_forms, "tour.md", "--(", "-- ("))


ICONS = ["assets/icons.py", "assets/icon.svg", "assets/landin_icon.py",
         "docs/site/render_html.py", "assets/README.md"]

HIGHLIGHT = ["highlight", "assets/fonts.py", "docs/site/render_html.py"]

BINDINGS = ["bindings", "AGENTS.md", "README.md", "docs/targets.md",
            "compiler/ada/TOOLCHAIN.md", "spec.md", "tour.md"]


class Artifacts(unittest.TestCase):
    """The mark, the borrowed icons, the editor packages, the generator."""

    def test_the_real_artifacts_pass(self):
        for check, inputs in ((checker.check_borrowed_icons, ICONS),
                              (checker.check_icon, ICONS),
                              (checker.check_highlighters, HIGHLIGHT),
                              (checker.check_binding_generator, BINDINGS)):
            with self.subTest(check=check.__name__):
                self.assertEqual(faults(check, copied=inputs), [])

    def test_a_missing_drawing_is_reported_rather_than_skipped(self):
        #  This one returned [] when the drawing was renamed, so the mark
        #  stopped being checked while the run still said all clean. The
        #  second check found that way, after check_pinned_toolchain.
        said = reasons(checker.check_icon, copied=ICONS[2:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_generated_rendering_that_drifted_is_reported(self):
        #  The copied editor files are deterministic renderings of one
        #  source; regenerating is the only way to change them.
        from check_controls import tree
        import runpy
        with tree(copied=HIGHLIGHT) as root:
            #  Asked of the generator rather than guessed: outputs() is
            #  the list the check compares, so this disturbs exactly one
            #  thing the check is looking at.
            #  The generator imports its own vocabulary module, the way
            #  check.py arranges for it.
            sys.path.insert(0, str(root / "highlight"))
            try:
                namespace = runpy.run_path(
                    str(root / "highlight/generate.py"),
                    run_name="outputs_probe")
            finally:
                sys.path.pop(0)
            generated = sorted(namespace["outputs"]())
            self.assertTrue(generated, "the generator renders nothing")
            target = root / generated[0]
            target.write_bytes(target.read_bytes() + b"\n#  drifted\n")
            said = [why for _, _, why in checker.check_highlighters(True)]
        self.assertTrue(said)

    def test_a_missing_generator_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_binding_generator, copied=BINDINGS[1:])
        self.assertTrue(said)


if __name__ == "__main__":
    unittest.main()
